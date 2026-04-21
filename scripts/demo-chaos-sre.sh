#!/bin/bash
# scripts/demo-chaos-sre.sh
# Demo completo: 2 cenários de chaos + SRE agent + métricas agregadas
#
# Cenário A: DB down → agent detecta via K8s events → Level 1 auto-heal
# Cenário B: Null Pointer (código) → agent detecta via ES → Level 3 PR
#
# Uso: bash scripts/demo-chaos-sre.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_URL="${API_URL:-http://localhost:18081}"
ES_URL="${ES_URL:-http://localhost:19200}"
NAMESPACE="${NAMESPACE:-default}"
AGENT_LOG_A="/tmp/sre-agent-run-A.log"
AGENT_LOG_B="/tmp/sre-agent-run-B.log"
METRICS_A="/tmp/sre-agent-metrics-A.json"
METRICS_B="/tmp/sre-agent-metrics-B.json"
LEARNING_LOG="/tmp/sre-agent-learning.log"
RESTART_COUNTER="/tmp/sre-restart-counter"
HTML_REPORT="${HTML_REPORT:-/tmp/sre-chaos-report.html}"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; MAG='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

ts()   { date '+%H:%M:%S'; }
log()  { echo -e "${BLU}[$(ts)]${NC} $*"; }
ok()   { echo -e "${GRN}[✓ $(ts)]${NC} $*"; }
warn() { echo -e "${YEL}[⚠ $(ts)]${NC} $*"; }
err()  { echo -e "${RED}[✗ $(ts)]${NC} $*"; }
sep()  { echo -e "${CYN}$(printf '═%.0s' {1..65})${NC}"; }
hsep() { echo -e "${BLU}$(printf '─%.0s' {1..65})${NC}"; }

banner() {
  echo ""
  sep
  echo -e "${BOLD}${CYN}  $1${NC}"
  sep
  echo ""
}

# ─── PRÉ-VERIFICAÇÕES ────────────────────────────────────────────────────────
preflight() {
  log "Verificando pré-requisitos..."

  # Limpa contadores da sessão anterior
  rm -f "$RESTART_COUNTER"

  # ES acessível?
  if ! curl -sf --max-time 5 "$ES_URL/_cluster/health" &>/dev/null; then
    err "Elasticsearch indisponível em $ES_URL"
    err "Rode: kubectl port-forward svc/elasticsearch-master -n default 19200:9200 --address 127.0.0.1 &"
    exit 1
  fi
  ok "Elasticsearch: OK"

  # API acessível?
  local api_ok=false
  if curl -sf --max-time 3 "$API_URL/health" &>/dev/null; then
    ok "API: OK ($API_URL)"
    api_ok=true
  else
    warn "API não responde em $API_URL — port-forward inativo."
    warn "Iniciando port-forward da API em background..."
    kubectl port-forward svc/api-service -n "$NAMESPACE" 18081:80 --address 127.0.0.1 &>/dev/null &
    sleep 3
    if curl -sf --max-time 3 "$API_URL/health" &>/dev/null; then
      ok "API port-forward iniciado: $API_URL"
      api_ok=true
    else
      warn "API ainda indisponível — cenário B usará janela maior no ES."
    fi
  fi

  # kubectl OK?
  kubectl get pods -n "$NAMESPACE" &>/dev/null || { err "kubectl falhou."; exit 1; }
  ok "kubectl: OK"

  echo ""
}

# ─── EXTRAI MÉTRICAS DO JSON GERADO PELO AGENTE ──────────────────────────────
_jq() { jq -r "$1" "$2" 2>/dev/null || echo "0"; }

parse_agent_metrics() {
  local json_file="$1"
  if [[ ! -f "$json_file" ]]; then
    echo "ES_ERRORS=0 K8S=0 L1=0 L2=0 L3=0 HEALED=0 PRS=0 VAL_OK=0 VAL_FAIL=0"
    echo "STATUS=sem dados"
    return
  fi
  local es_errors k8s_events l1 l2 l3 auto_healed prs val_ok val_fail final_status
  es_errors=$(_jq '.collect.es_errors'         "$json_file")
  k8s_events=$(_jq '.collect.k8s_events'       "$json_file")
  l1=$(_jq '.classification.level1'            "$json_file")
  l2=$(_jq '.classification.level2'            "$json_file")
  l3=$(_jq '.classification.level3'            "$json_file")
  auto_healed=$(_jq '.actions.auto_healed'     "$json_file")
  prs=$(_jq '.actions.prs_suggested'           "$json_file")
  val_ok=$(_jq '.validation.ok'                "$json_file")
  val_fail=$(_jq '.validation.fail'            "$json_file")
  final_status=$(_jq '.status'                 "$json_file")
  echo "ES_ERRORS=${es_errors:-0} K8S=${k8s_events:-0} L1=${l1:-0} L2=${l2:-0} L3=${l3:-0} HEALED=${auto_healed:-0} PRS=${prs:-0} VAL_OK=${val_ok:-0} VAL_FAIL=${val_fail:-0}"
  echo "STATUS=${final_status:-desconhecido}"
}

# ─── CENÁRIO A: DB DOWN ───────────────────────────────────────────────────────
run_scenario_a() {
  banner "CENÁRIO A  —  DB Down: Teste de Resiliência do Pod"
  echo -e "  ${BOLD}Objetivo:${NC} Deletar db-pod-0 → agente detecta instabilidade"
  echo -e "  ${BOLD}Ação esperada:${NC} Level 1 auto-heal (liveness probe / restart)"
  echo ""

  # Estado inicial
  log "Estado inicial dos pods:"
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{printf "  %-45s %-10s %-10s\n", $1, $2, $3}'
  echo ""

  # Aplica o chaos
  log "🐒 Aplicando Chaos Monkey — Cenário 3 (DB Down)..."
  local chaos_result
  if kubectl delete pod db-pod-0 -n "$NAMESPACE" &>/dev/null; then
    ok "db-pod-0 deletado com sucesso."
    chaos_result="DB pod deletado"
  else
    warn "db-pod-0 não encontrado. Tentando por label..."
    if kubectl delete pod -l app=database -n "$NAMESPACE" &>/dev/null; then
      ok "Pod de banco deletado por label."
      chaos_result="DB pod deletado por label"
    else
      warn "Nenhum pod de banco encontrado. Forçando evento via API..."
      curl -sf -X POST "$API_URL/chaos/null-pointer" &>/dev/null || true
      chaos_result="Simulação via API (pod já inexistente)"
    fi
  fi

  log "Aguardando 10s para eventos K8s propagarem..."
  sleep 10

  # Estado após chaos
  log "Estado dos pods após chaos:"
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{printf "  %-45s %-10s %-10s\n", $1, $2, $3}'
  echo ""

  # Roda o agente SRE
  log "🤖 Iniciando SRE Agent — Análise e Correção..."
  echo ""
  # Limpa contador para cenário B não ser bloqueado pelo guard-rail
  rm -f "$RESTART_COUNTER"
  METRICS_FILE="$METRICS_A" bash "$SCRIPT_DIR/sre-agent.sh" --window 10m 2>&1 | tee "$AGENT_LOG_A"
  echo ""

  # Estado pós-correção
  log "Estado pós-correção:"
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{printf "  %-45s %-10s %-10s\n", $1, $2, $3}'

  # Grava resultado do cenário A
  SCENARIO_A_CHAOS="$chaos_result"
  echo ""
}

# ─── CENÁRIO B: CÓDIGO — NULL POINTER ────────────────────────────────────────
run_scenario_b() {
  banner "CENÁRIO B  —  Erro de Código: Null Pointer → PR de Fix"
  echo -e "  ${BOLD}Objetivo:${NC} Disparar 10x TypeError 500 → ES acumula erros → agente abre PR"
  echo -e "  ${BOLD}Ação esperada:${NC} Level 3 — extração de stack trace + branch de fix"
  echo ""

  # Limpa contador
  rm -f "$RESTART_COUNTER"

  # Verifica se API está acessível
  if ! curl -sf --max-time 3 "$API_URL/health" &>/dev/null; then
    warn "API indisponível. Injetando logs de erro diretamente no pod para simular..."
    # Injeta log de erro diretamente no pod via kubectl exec
    local pod_name
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=api-pod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$pod_name" ]]; then
      for i in $(seq 1 10); do
        kubectl exec "$pod_name" -n "$NAMESPACE" -- \
          node -e "console.error('[ERROR] TypeError: Cannot read properties of null (reading \'property\') - chaos simulation $i')" \
          2>/dev/null || true
      done
      ok "10 erros TypeError injetados via kubectl exec no pod $pod_name"
    else
      warn "Pod da API não encontrado. Usando janela maior de ES (60m)."
    fi
    CHAOS_WINDOW="60m"
  else
    # Dispara os erros via API
    log "🐒 Aplicando Chaos Monkey — Cenário 2 (Null Pointer ×15)..."
    local success=0 fail=0
    for i in $(seq 1 15); do
      local resp
      resp=$(curl -sf --max-time 5 -X POST "$API_URL/chaos/null-pointer" 2>/dev/null || echo '{"error":"unreachable"}')
      local typ
      typ=$(echo "$resp" | jq -r '.type // .error // "?"' 2>/dev/null || echo "?")
      echo "  [$i] → $typ"
      [[ "$typ" == "NullReferenceException" ]] && ((success++)) || ((fail++))
    done
    echo ""
    ok "Chaos aplicado: $success erros TypeError registrados, $fail falhas de comunicação"
    CHAOS_WINDOW="5m"
  fi

  log "Aguardando 15s para fluent-bit indexar logs no ES..."
  sleep 15

  # Confirma que ES captou os erros
  local error_count
  error_count=$(curl -s "$ES_URL/logs/_count" -H "Content-Type: application/json" -d '{
    "query": {"bool": {"must": [
      {"range": {"@timestamp": {"gte": "now-5m"}}},
      {"match": {"message": "TypeError"}}
    ]}}
  }' 2>/dev/null | jq '.count // 0' 2>/dev/null || echo 0)

  if [[ $error_count -gt 0 ]]; then
    ok "ES confirmou: $error_count logs com TypeError nos últimos 5m"
  else
    warn "ES sem logs TypeError nos últimos 5m. Agente usará janela de 60m."
    CHAOS_WINDOW="60m"
  fi
  echo ""

  # Roda o agente SRE
  log "🤖 Iniciando SRE Agent — Análise e Classificação de Erro de Código..."
  echo ""
  METRICS_FILE="$METRICS_B" bash "$SCRIPT_DIR/sre-agent.sh" --window "${CHAOS_WINDOW:-5m}" 2>&1 | tee "$AGENT_LOG_B"
  echo ""
}

# ─── RELATÓRIO FINAL AGREGADO ────────────────────────────────────────────────
print_final_report() {
  banner "RELATÓRIO FINAL AGREGADO — CHAOS + SRE AGENT"

  # Parse métricas dos dois runs
  local metrics_a metrics_b
  metrics_a=$(parse_agent_metrics "$METRICS_A")
  metrics_b=$(parse_agent_metrics "$METRICS_B")

  # Extrai valores — parse simples via grep na linha key=value
  _get_metric() { echo "$1" | grep -oP "${2}=\K[0-9]+" | head -1 || echo 0; }

  local a_es a_k8s a_l1 a_l2 a_l3 a_heal a_prs a_ok a_fail a_status
  local line_a; line_a=$(echo "$metrics_a" | head -1)
  a_es=$(_get_metric "$line_a" "ES_ERRORS")
  a_k8s=$(_get_metric "$line_a" "K8S")
  a_l1=$(_get_metric "$line_a" "L1")
  a_l2=$(_get_metric "$line_a" "L2")
  a_l3=$(_get_metric "$line_a" "L3")
  a_heal=$(_get_metric "$line_a" "HEALED")
  a_prs=$(_get_metric "$line_a" "PRS")
  a_ok=$(_get_metric "$line_a" "VAL_OK")
  a_fail=$(_get_metric "$line_a" "VAL_FAIL")
  a_status=$(echo "$metrics_a" | grep "^STATUS=" | cut -d= -f2- | head -1 || echo "?")

  local b_es b_k8s b_l1 b_l2 b_l3 b_heal b_prs b_ok b_fail b_status
  local line_b; line_b=$(echo "$metrics_b" | head -1)
  b_es=$(_get_metric "$line_b" "ES_ERRORS")
  b_k8s=$(_get_metric "$line_b" "K8S")
  b_l1=$(_get_metric "$line_b" "L1")
  b_l2=$(_get_metric "$line_b" "L2")
  b_l3=$(_get_metric "$line_b" "L3")
  b_heal=$(_get_metric "$line_b" "HEALED")
  b_prs=$(_get_metric "$line_b" "PRS")
  b_ok=$(_get_metric "$line_b" "VAL_OK")
  b_fail=$(_get_metric "$line_b" "VAL_FAIL")
  b_status=$(echo "$metrics_b" | grep "^STATUS=" | cut -d= -f2- | head -1 || echo "?")

  # Totais
  local total_errors=$(( a_es + b_es ))
  local total_k8s=$(( a_k8s + b_k8s ))
  local total_l1=$(( a_l1 + b_l1 ))
  local total_l2=$(( a_l2 + b_l2 ))
  local total_l3=$(( a_l3 + b_l3 ))
  local total_healed=$(( a_heal + b_heal ))
  local total_prs=$(( a_prs + b_prs ))
  local total_ok=$(( a_ok + b_ok ))
  local total_fail=$(( a_fail + b_fail ))

  # ── Tabela comparativa ────────────────────────────────────────────────────
  printf "${BOLD}  %-32s %-18s %-18s %-12s${NC}\n" "Métrica" "Cenário A (DB)" "Cenário B (Código)" "TOTAL"
  hsep
  printf "  %-32s ${RED}%-18s${NC} ${RED}%-18s${NC} ${BOLD}%-12s${NC}\n" "Logs de erro no ES" "$a_es" "$b_es" "$total_errors"
  printf "  %-32s ${YEL}%-18s${NC} ${YEL}%-18s${NC} ${BOLD}%-12s${NC}\n" "Eventos K8s Warning" "$a_k8s" "$b_k8s" "$total_k8s"
  hsep
  printf "  %-32s ${GRN}%-18s${NC} ${GRN}%-18s${NC} ${BOLD}%-12s${NC}\n" "Gatilhos Nível 1 (auto-heal)" "$a_l1" "$b_l1" "$total_l1"
  printf "  %-32s ${YEL}%-18s${NC} ${YEL}%-18s${NC} ${BOLD}%-12s${NC}\n" "Gatilhos Nível 2 (recurso/PR)" "$a_l2" "$b_l2" "$total_l2"
  printf "  %-32s ${RED}%-18s${NC} ${RED}%-18s${NC} ${BOLD}%-12s${NC}\n" "Gatilhos Nível 3 (código/PR)" "$a_l3" "$b_l3" "$total_l3"
  hsep
  printf "  %-32s ${GRN}%-18s${NC} ${GRN}%-18s${NC} ${BOLD}%-12s${NC}\n" "Auto-heals executados" "$a_heal" "$b_heal" "$total_healed"
  printf "  %-32s ${YEL}%-18s${NC} ${YEL}%-18s${NC} ${BOLD}%-12s${NC}\n" "PRs sugeridos/criados" "$a_prs" "$b_prs" "$total_prs"
  hsep
  printf "  %-32s ${GRN}%-18s${NC} ${GRN}%-18s${NC} ${BOLD}%-12s${NC}\n" "Validações OK" "$a_ok" "$b_ok" "$total_ok"
  printf "  %-32s ${RED}%-18s${NC} ${RED}%-18s${NC} ${BOLD}%-12s${NC}\n" "Validações com falha" "$a_fail" "$b_fail" "$total_fail"
  hsep

  echo ""
  echo -e "  ${BOLD}Status por Cenário:${NC}"
  echo -e "  • Cenário A (DB Down):        ${GRN}$a_status${NC}"
  echo -e "  • Cenário B (Null Pointer):   ${GRN}$b_status${NC}"

  # ── Histórico de aprendizado ──────────────────────────────────────────────
  echo ""
  if [[ -f "$LEARNING_LOG" ]]; then
    local lines; lines=$(wc -l < "$LEARNING_LOG")
    echo -e "  ${BOLD}Histórico de Aprendizado ($lines entradas totais):${NC}"
    cat "$LEARNING_LOG" | while IFS= read -r line; do
      local icon="🟡"
      [[ "$line" =~ "SUCESSO" ]] && icon="🟢"
      [[ "$line" =~ "FALHA" ]]  && icon="🔴"
      echo "  $icon $line"
    done
  fi

  # ── Taxa de sucesso ───────────────────────────────────────────────────────
  echo ""
  hsep
  local success_rate=0
  local total_actions=$(( total_healed + total_prs ))
  if [[ $total_actions -gt 0 ]] && [[ $total_ok -gt 0 ]]; then
    success_rate=$(( total_ok * 100 / total_actions ))
  fi

  local total_incidents=$(( total_l1 + total_l2 + total_l3 ))
  echo ""
  echo -e "  ${BOLD}Resumo Executivo:${NC}"
  printf "  %-35s ${BOLD}%s${NC}\n" "Incidentes detectados:" "$total_incidents"
  printf "  %-35s ${GRN}${BOLD}%s${NC}\n" "Resolvidos automaticamente:" "$total_healed"
  printf "  %-35s ${YEL}${BOLD}%s${NC}\n" "PRs abertos para aprovação:" "$total_prs"
  printf "  %-35s ${BOLD}%s%%${NC}\n"    "Taxa de sucesso na validação:" "$success_rate"
  echo ""
  hsep

  # ── Decisões tomadas (filtradas do log) ──────────────────────────────────
  echo ""
  echo -e "  ${BOLD}Decisões Tomadas pelo Agente:${NC}"
  for logfile in "$AGENT_LOG_A" "$AGENT_LOG_B"; do
    local label="A"
    [[ "$logfile" == "$AGENT_LOG_B" ]] && label="B"
    grep '│' "$logfile" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed "s/^[[:space:]]*/  [Cen.$label] /" || true
  done

  echo ""
  sep
  echo -e "  ${BOLD}Logs completos:${NC}"
  echo "  Cenário A: $AGENT_LOG_A"
  echo "  Cenário B: $AGENT_LOG_B"
  echo "  Aprendizado: $LEARNING_LOG"
  sep
  echo ""
}

# ─── GERADOR HTML ────────────────────────────────────────────────────────────
generate_html_report() {
  local ma="$METRICS_A"
  local mb="$METRICS_B"
  local ts_now; ts_now=$(date '+%Y-%m-%d %H:%M:%S')

  # Lê métricas dos JSONs
  _jqf() { [[ -f "$2" ]] && jq -r "$1" "$2" 2>/dev/null || echo "0"; }

  local a_es a_k8s a_l1 a_l2 a_l3 a_heal a_prs a_ok a_fail a_status a_ts a_win
  local b_es b_k8s b_l1 b_l2 b_l3 b_heal b_prs b_ok b_fail b_status b_ts b_win
  a_es=$(_jqf   '.collect.es_errors'       "$ma"); a_k8s=$(_jqf '.collect.k8s_events'     "$ma")
  a_l1=$(_jqf   '.classification.level1'   "$ma"); a_l2=$(_jqf  '.classification.level2'  "$ma"); a_l3=$(_jqf '.classification.level3' "$ma")
  a_heal=$(_jqf '.actions.auto_healed'     "$ma"); a_prs=$(_jqf  '.actions.prs_suggested' "$ma")
  a_ok=$(_jqf   '.validation.ok'           "$ma"); a_fail=$(_jqf '.validation.fail'        "$ma")
  a_status=$(_jqf '.status'                "$ma"); a_ts=$(_jqf   '.timestamp'              "$ma"); a_win=$(_jqf '.window' "$ma")

  b_es=$(_jqf   '.collect.es_errors'       "$mb"); b_k8s=$(_jqf '.collect.k8s_events'     "$mb")
  b_l1=$(_jqf   '.classification.level1'   "$mb"); b_l2=$(_jqf  '.classification.level2'  "$mb"); b_l3=$(_jqf '.classification.level3' "$mb")
  b_heal=$(_jqf '.actions.auto_healed'     "$mb"); b_prs=$(_jqf  '.actions.prs_suggested' "$mb")
  b_ok=$(_jqf   '.validation.ok'           "$mb"); b_fail=$(_jqf '.validation.fail'        "$mb")
  b_status=$(_jqf '.status'                "$mb"); b_ts=$(_jqf   '.timestamp'              "$mb"); b_win=$(_jqf '.window' "$mb")

  # Decisões dos JSONs
  local a_decisions b_decisions
  a_decisions=$([[ -f "$ma" ]] && jq -r '.decisions[]' "$ma" 2>/dev/null | sed 's/</\&lt;/g;s/>/\&gt;/g' || echo "")
  b_decisions=$([[ -f "$mb" ]] && jq -r '.decisions[]' "$mb" 2>/dev/null | sed 's/</\&lt;/g;s/>/\&gt;/g' || echo "")

  # Totais
  local t_es=$(( ${a_es:-0} + ${b_es:-0} ))
  local t_k8s=$(( ${a_k8s:-0} + ${b_k8s:-0} ))
  local t_l1=$(( ${a_l1:-0} + ${b_l1:-0} ))
  local t_l2=$(( ${a_l2:-0} + ${b_l2:-0} ))
  local t_l3=$(( ${a_l3:-0} + ${b_l3:-0} ))
  local t_heal=$(( ${a_heal:-0} + ${b_heal:-0} ))
  local t_prs=$(( ${a_prs:-0} + ${b_prs:-0} ))
  local t_ok=$(( ${a_ok:-0} + ${b_ok:-0} ))
  local t_fail=$(( ${a_fail:-0} + ${b_fail:-0} ))

  # Aprendizado
  local learning_rows=""
  if [[ -f "$LEARNING_LOG" ]]; then
    while IFS= read -r line; do
      local icon="🟡" cls="warn"
      [[ "$line" =~ SUCESSO ]] && icon="🟢" && cls="ok"
      [[ "$line" =~ FALHA   ]] && icon="🔴" && cls="err"
      learning_rows+="<tr class='${cls}'><td>${icon}</td><td>$(echo "$line" | sed 's/</\&lt;/g;s/>/\&gt;/g')</td></tr>"
    done < "$LEARNING_LOG"
  else
    learning_rows="<tr><td colspan='2'>Nenhum registro de aprendizado.</td></tr>"
  fi

  # Logs dos cenários (sem ANSI)
  local log_a="" log_b=""
  [[ -f "$AGENT_LOG_A" ]] && log_a=$(sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$AGENT_LOG_A" | sed 's/</\&lt;/g;s/>/\&gt;/g')
  [[ -f "$AGENT_LOG_B" ]] && log_b=$(sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$AGENT_LOG_B" | sed 's/</\&lt;/g;s/>/\&gt;/g')

  _status_badge() {
    local s="$1"
    case "$s" in
      "CLUSTER RECUPERADO"|"SEM INCIDENTES") echo "<span class='badge badge-ok'>✓ $s</span>" ;;
      "ACAO PENDENTE")                        echo "<span class='badge badge-warn'>⚠ PR Pendente</span>" ;;
      *) echo "<span class='badge badge-err'>✗ $s</span>" ;;
    esac
  }

  cat > "$HTML_REPORT" <<HTML
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SRE Agent — Chaos Report · ${ts_now}</title>
<style>
  :root{--bg:#0d1117;--card:#161b22;--border:#30363d;--txt:#e6edf3;--sub:#8b949e;
        --ok:#3fb950;--warn:#d29922;--err:#f85149;--blue:#58a6ff;--purple:#bc8cff}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--txt);font-family:'Segoe UI',system-ui,sans-serif;padding:24px}
  h1{font-size:1.6rem;margin-bottom:4px;color:var(--blue)}
  .sub{color:var(--sub);font-size:.85rem;margin-bottom:24px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:24px}
  .kpi{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:16px;text-align:center}
  .kpi .val{font-size:2.4rem;font-weight:700;line-height:1}
  .kpi .lbl{font-size:.8rem;color:var(--sub);margin-top:4px}
  .val-ok{color:var(--ok)}.val-warn{color:var(--warn)}.val-err{color:var(--err)}
  .card{background:var(--card);border:1px solid var(--border);border-radius:8px;margin-bottom:20px;overflow:hidden}
  .card-hdr{padding:12px 16px;font-weight:600;font-size:.95rem;border-bottom:1px solid var(--border);
            display:flex;align-items:center;gap:8px}
  .card-body{padding:16px}
  table{width:100%;border-collapse:collapse;font-size:.87rem}
  th{text-align:left;color:var(--sub);padding:6px 10px;border-bottom:1px solid var(--border);font-weight:500}
  td{padding:6px 10px;border-bottom:1px solid #21262d}
  tr:last-child td{border-bottom:none}
  tr.ok td{color:var(--ok)} tr.warn td{color:var(--warn)} tr.err td{color:var(--err)}
  .badge{display:inline-block;padding:3px 10px;border-radius:20px;font-size:.78rem;font-weight:600}
  .badge-ok{background:#1a3626;color:var(--ok);border:1px solid var(--ok)}
  .badge-warn{background:#2d2307;color:var(--warn);border:1px solid var(--warn)}
  .badge-err{background:#2d1315;color:var(--err);border:1px solid var(--err)}
  .scenario-hdr{padding:10px 14px;font-weight:600;border-radius:6px;margin-bottom:12px;font-size:.9rem}
  .sc-a{background:#1a2637;color:var(--blue)} .sc-b{background:#1e1a2e;color:var(--purple)}
  pre{background:#010409;border:1px solid var(--border);border-radius:6px;padding:14px;
      font-size:.78rem;overflow-x:auto;max-height:400px;overflow-y:auto;line-height:1.5;color:#adbac7}
  .tabs{display:flex;gap:8px;margin-bottom:12px}
  .tab{padding:6px 14px;border-radius:6px;cursor:pointer;font-size:.85rem;background:var(--border);color:var(--sub);border:none}
  .tab.active{background:var(--blue);color:#000}
  .tab-panel{display:none}.tab-panel.active{display:block}
  .decision-row{padding:8px 10px;border-left:3px solid var(--border);margin-bottom:6px;
                background:#010409;border-radius:0 4px 4px 0;font-size:.82rem;font-family:monospace}
</style>
</head>
<body>
<h1>🤖 SRE Agent — Chaos Monkey Report</h1>
<p class="sub">Gerado em ${ts_now} · Cluster: kind-kind · Namespace: ${NAMESPACE}</p>

<!-- KPIs -->
<div class="grid">
  <div class="kpi"><div class="val val-err">${t_es}</div><div class="lbl">Logs de erro no ES</div></div>
  <div class="kpi"><div class="val val-warn">${t_k8s}</div><div class="lbl">Eventos K8s Warning</div></div>
  <div class="kpi"><div class="val val-ok">${t_heal}</div><div class="lbl">Auto-heals executados</div></div>
  <div class="kpi"><div class="val val-warn">${t_prs}</div><div class="lbl">PRs sugeridos</div></div>
  <div class="kpi"><div class="val val-ok">${t_ok}</div><div class="lbl">Validações OK</div></div>
  <div class="kpi"><div class="val val-err">${t_fail}</div><div class="lbl">Validações com falha</div></div>
</div>

<!-- Tabela comparativa por cenário -->
<div class="card">
  <div class="card-hdr">📊 Métricas por Cenário</div>
  <div class="card-body">
    <table>
      <thead><tr><th>Métrica</th><th>Cenário A — DB Down</th><th>Cenário B — Código</th><th>Total</th></tr></thead>
      <tbody>
        <tr><td>Logs ES coletados</td><td>${a_es}</td><td>${b_es}</td><td><b>${t_es}</b></td></tr>
        <tr><td>Eventos K8s Warning</td><td>${a_k8s}</td><td>${b_k8s}</td><td><b>${t_k8s}</b></td></tr>
        <tr class="ok"><td>Nível 1 — Auto-heal</td><td>${a_l1}</td><td>${b_l1}</td><td><b>${t_l1}</b></td></tr>
        <tr class="warn"><td>Nível 2 — Recurso/PR</td><td>${a_l2}</td><td>${b_l2}</td><td><b>${t_l2}</b></td></tr>
        <tr class="err"><td>Nível 3 — Código/PR</td><td>${a_l3}</td><td>${b_l3}</td><td><b>${t_l3}</b></td></tr>
        <tr class="ok"><td>Auto-heals disparados</td><td>${a_heal}</td><td>${b_heal}</td><td><b>${t_heal}</b></td></tr>
        <tr class="warn"><td>PRs gerados</td><td>${a_prs}</td><td>${b_prs}</td><td><b>${t_prs}</b></td></tr>
        <tr class="ok"><td>Recuperações confirmadas</td><td>${a_ok}</td><td>${b_ok}</td><td><b>${t_ok}</b></td></tr>
        <tr><td>Falhas de validação</td><td>${a_fail}</td><td>${b_fail}</td><td><b>${t_fail}</b></td></tr>
        <tr><td>Janela de análise</td><td>${a_win}</td><td>${b_win}</td><td>—</td></tr>
        <tr><td><b>Status Final</b></td>
            <td>$(_status_badge "${a_status:-?}")</td>
            <td>$(_status_badge "${b_status:-?}")</td><td>—</td></tr>
      </tbody>
    </table>
  </div>
</div>

<!-- Decisões tomadas -->
<div class="card">
  <div class="card-hdr">🧠 Decisões Tomadas pelo Agente</div>
  <div class="card-body">
    <div class="scenario-hdr sc-a">Cenário A — DB Down (${a_ts})</div>
$(echo "$a_decisions" | while IFS= read -r d; do [[ -n "$d" ]] && echo "    <div class='decision-row'>$d</div>"; done)
    <div class="scenario-hdr sc-b" style="margin-top:14px">Cenário B — Null Pointer (${b_ts})</div>
$(echo "$b_decisions" | while IFS= read -r d; do [[ -n "$d" ]] && echo "    <div class='decision-row'>$d</div>"; done)
  </div>
</div>

<!-- Aprendizado -->
<div class="card">
  <div class="card-hdr">🧬 Histórico de Aprendizado</div>
  <div class="card-body">
    <table>
      <thead><tr><th></th><th>Registro</th></tr></thead>
      <tbody>${learning_rows}</tbody>
    </table>
  </div>
</div>

<!-- Logs completos (abas) -->
<div class="card">
  <div class="card-hdr">📋 Logs Completos</div>
  <div class="card-body">
    <div class="tabs">
      <button class="tab active" onclick="showTab('log-a',this)">Cenário A — DB Down</button>
      <button class="tab" onclick="showTab('log-b',this)">Cenário B — Null Pointer</button>
    </div>
    <div id="log-a" class="tab-panel active"><pre>${log_a}</pre></div>
    <div id="log-b" class="tab-panel"><pre>${log_b}</pre></div>
  </div>
</div>

<script>
function showTab(id,btn){
  document.querySelectorAll('.tab-panel').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(b=>b.classList.remove('active'));
  document.getElementById(id).classList.add('active');
  btn.classList.add('active');
}
</script>
</body></html>
HTML

  ok "Relatório HTML gerado: ${HTML_REPORT}"
  log "Abrindo no navegador..."
  # Tenta abrir no Windows
  start "" "$(cygpath -w "$HTML_REPORT")" 2>/dev/null \
    || powershell.exe -Command "Start-Process '$(cygpath -w "$HTML_REPORT")'" 2>/dev/null \
    || warn "Abra manualmente: $HTML_REPORT"
}

# ─── MAIN ────────────────────────────────────────────────────────────────────
main() {
  clear
  echo -e "${BOLD}${CYN}"
  echo "  ╔═══════════════════════════════════════════════════════════════╗"
  echo "  ║        DEMO: CHAOS MONKEY + SRE AGENT AUTÔNOMO               ║"
  echo "  ║   Cenário A: DB Down → Auto-Heal                             ║"
  echo "  ║   Cenário B: Null Pointer → PR de Fix                        ║"
  echo "  ╚═══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  Data: $(date '+%Y-%m-%d %H:%M:%S')   Namespace: ${NAMESPACE}   ES: ${ES_URL}"
  echo ""

  preflight
  run_scenario_a
  run_scenario_b
  print_final_report
  generate_html_report
}

main "$@"
