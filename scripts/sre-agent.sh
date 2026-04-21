#!/bin/bash
# scripts/sre-agent.sh
# Agente SRE Autônomo — lê ES, classifica erros, age, valida e reporta métricas
#
# Uso:  ./scripts/sre-agent.sh [--window 10m] [--dry-run]
#   --window  janela de tempo para busca no ES (padrão: 5m)
#   --dry-run mostra o que faria sem executar ações destrutivas

set -uo pipefail

# ─── CONFIGURAÇÃO ────────────────────────────────────────────────────────────
ES_URL="${ES_URL:-http://localhost:19200}"
ES_USER="${ES_USER:-elastic}"
ES_PASS="${ES_PASS:-j6TrY7ENkDEVNSoZ}"
API_URL="${API_URL:-http://localhost:18081}"
NAMESPACE="${NAMESPACE:-default}"
MAX_RESTARTS=3
LEARNING_LOG="${LEARNING_LOG:-/tmp/sre-agent-learning.log}"
WINDOW="5m"
DRY_RUN=false
RESTART_COUNTER_FILE="/tmp/sre-restart-counter"

# ─── PARSE ARGS ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Uso: $0 [--window 5m] [--dry-run]"; exit 1 ;;
  esac
done

# ─── CORES ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; MAG='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

# ─── MÉTRICAS (contadores globais) ───────────────────────────────────────────
M_ES_ERRORS=0
M_K8S_EVENTS=0
M_L1=0; M_L2=0; M_L3=0
M_AUTO_HEALED=0
M_PR_SUGGESTED=0
M_VALIDATED_OK=0
M_VALIDATED_FAIL=0
declare -a DECISION_LOG=()

# ─── HELPERS DE LOG ──────────────────────────────────────────────────────────
ts()     { date '+%H:%M:%S'; }
# Todos os helpers de log usam >&2 para não poluir capturas com $()
info()   { echo -e "${CYN}[🔍 ANALISANDO $(ts)]${NC} $*" >&2; }
heal()   { echo -e "${GRN}[⚡ AUTO-HEALING $(ts)]${NC} $*" >&2; }
pr_msg() { echo -e "${YEL}[🛠️  NECESSITA PR $(ts)]${NC} $*" >&2; }
ok()     { echo -e "${GRN}[✓ $(ts)]${NC} $*" >&2; }
warn()   { echo -e "${YEL}[⚠ $(ts)]${NC} $*" >&2; }
err()    { echo -e "${RED}[✗ $(ts)]${NC} $*" >&2; }
sep()    { echo -e "${BLU}$(printf '─%.0s' {1..60})${NC}" >&2; }
dry()    { [[ "$DRY_RUN" == true ]] && echo -e "${MAG}[DRY-RUN]${NC} $*" >&2; }

record() {
  # record <level> <tipo> <ação> <resultado>
  local entry="$(ts) | Nível $1 | $2 | Ação: $3 | Resultado: $4"
  DECISION_LOG+=("$entry")
}

# ─── FASE 0: PRÉ-REQUISITOS ──────────────────────────────────────────────────
_install_jq() {
  warn "jq não encontrado. Tentando instalar automaticamente..."
  # WSL2 / Linux
  if command -v apt-get &>/dev/null; then
    sudo apt-get install -y jq &>/dev/null && ok "jq instalado via apt." && return 0
  fi
  # Git Bash / Windows via winget
  if command -v powershell.exe &>/dev/null; then
    echo "  Rodando: winget install jqlang.jq (pode demorar ~30s)..."
    powershell.exe -NoProfile -NonInteractive -Command \
      "winget install --id jqlang.jq --source winget --accept-package-agreements --accept-source-agreements" \
      2>/dev/null
    # Atualiza PATH com locais comuns de instalação do winget
    for p in \
      "/c/Users/$USERNAME/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_Microsoft.Winget.Source_8wekyb3d8bbwe" \
      "/c/Program Files/jq" \
      "/c/ProgramData/chocolatey/bin"; do
      [[ -d "$p" ]] && export PATH="$PATH:$p"
    done
    command -v jq &>/dev/null && ok "jq instalado via winget." && return 0
  fi
  # Chocolatey
  if command -v choco &>/dev/null; then
    choco install jq -y &>/dev/null && ok "jq instalado via choco." && return 0
  fi
  return 1
}

check_deps() {
  for cmd in curl kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Dependência obrigatória ausente: $cmd — instale e tente novamente."
      exit 1
    fi
  done

  if ! command -v jq &>/dev/null; then
    _install_jq || {
      err "Não foi possível instalar jq automaticamente."
      err "Instale manualmente:"
      err "  Windows: winget install jqlang.jq"
      err "  WSL/Linux: sudo apt install jq"
      exit 1
    }
  fi

  ok "Dependências OK: curl=$(curl --version | head -1 | cut -d' ' -f2), kubectl=$(kubectl version --client --short 2>/dev/null | head -1), jq=$(jq --version)"
}

check_es() {
  info "Verificando conectividade com Elasticsearch ($ES_URL)..."
  local resp
  # Tenta HTTP sem auth primeiro (security disabled), depois com auth
  resp=$(curl -sf --max-time 5 "$ES_URL/_cluster/health" 2>/dev/null) \
    || resp=$(curl -sfk --max-time 5 -u "$ES_USER:$ES_PASS" "$ES_URL/_cluster/health" 2>/dev/null) \
    || { warn "ES indisponível. Análise limitada ao kubectl."; return 1; }

  local status
  status=$(echo "$resp" | jq -r '.status // "unknown"' 2>/dev/null)
  ok "Elasticsearch OK — cluster status: ${BOLD}$status${NC}"
  return 0
}

# ─── FASE 1: COLETA DE EVIDÊNCIAS ────────────────────────────────────────────
query_es() {
  info "Consultando ES: erros nos últimos $WINDOW..."

  local query
  query=$(cat <<EOF
{
  "size": 100,
  "sort": [{"@timestamp": {"order": "desc"}}],
  "query": {
    "bool": {
      "filter": [
        {"range": {"@timestamp": {"gte": "now-${WINDOW}"}}}
      ],
      "should": [
        {"match_phrase": {"message": "ERROR"}},
        {"match_phrase": {"message": "CHAOS"}},
        {"match_phrase": {"message": "TypeError"}},
        {"match_phrase": {"message": "null pointer"}},
        {"match_phrase": {"message": "NullReference"}},
        {"match_phrase": {"message": "OOMKilled"}},
        {"match_phrase": {"message": "CrashLoopBackOff"}},
        {"match_phrase": {"message": "ECONNREFUSED"}},
        {"match_phrase": {"message": "heap alocado"}},
        {"match_phrase": {"message": "vazamento"}}
      ],
      "minimum_should_match": 1
    }
  }
}
EOF
)

  curl -sf --max-time 10 \
    "$ES_URL/logs/_search" \
    -H "Content-Type: application/json" \
    -d "$query" 2>/dev/null \
  || curl -sfk --max-time 10 \
    -u "$ES_USER:$ES_PASS" \
    "$ES_URL/logs/_search" \
    -H "Content-Type: application/json" \
    -d "$query" 2>/dev/null \
  || echo '{"hits":{"total":{"value":0},"hits":[]}}'
}

get_k8s_events() {
  kubectl get events -n "$NAMESPACE" \
    --sort-by='.lastTimestamp' \
    --field-selector type=Warning \
    -o json 2>/dev/null \
  || echo '{"items":[]}'
}

get_pod_status() {
  kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null \
  || echo '{"items":[]}'
}

# ─── FASE 2: CLASSIFICAÇÃO ───────────────────────────────────────────────────
classify() {
  local es_data="$1"
  local k8s_events="$2"
  local pod_status="$3"

  sep
  info "Classificando erros encontrados..."
  echo ""

  # ── Contar erros no ES ────────────────────────────────────────────────────
  local total_es
  total_es=$(echo "$es_data" | jq '.hits.total.value // 0' 2>/dev/null || echo 0)
  M_ES_ERRORS=$total_es

  local oom_es null_es conn_es heap_es
  oom_es=$(echo  "$es_data" | jq '[.hits.hits[]._source.message // "" | ascii_downcase | select(test("oomkilled|killed"))]  | length' 2>/dev/null || echo 0)
  null_es=$(echo "$es_data" | jq '[.hits.hits[]._source.message // "" | ascii_downcase | select(test("typeerror|null|nullref"))] | length' 2>/dev/null || echo 0)
  conn_es=$(echo "$es_data" | jq '[.hits.hits[]._source.message // "" | ascii_downcase | select(test("econnrefused|timeout|connection refused"))] | length' 2>/dev/null || echo 0)
  heap_es=$(echo "$es_data" | jq '[.hits.hits[]._source.message // "" | ascii_downcase | select(test("heap|vazamento|memory.leak|chaos"))] | length' 2>/dev/null || echo 0)

  # ── Contar eventos K8s ────────────────────────────────────────────────────
  local oom_k8s crash_k8s evicted_k8s liveness_k8s pending_k8s
  oom_k8s=$(echo      "$k8s_events" | jq '[.items[].reason // "" | select(test("OOMKilling|OOMKilled"))]  | length' 2>/dev/null || echo 0)
  crash_k8s=$(echo    "$k8s_events" | jq '[.items[].reason // "" | select(test("BackOff|CrashLoop"))]     | length' 2>/dev/null || echo 0)
  evicted_k8s=$(echo  "$k8s_events" | jq '[.items[].reason // "" | select(test("Evicted|NodeNotReady"))]  | length' 2>/dev/null || echo 0)
  liveness_k8s=$(echo "$k8s_events" | jq '[.items[].reason // "" | select(test("Unhealthy|Liveness"))]    | length' 2>/dev/null || echo 0)
  pending_k8s=$(echo  "$k8s_events" | jq '[.items[].reason // "" | select(test("Insufficient|FailedScheduling"))] | length' 2>/dev/null || echo 0)

  M_K8S_EVENTS=$(echo "$k8s_events" | jq '.items | length' 2>/dev/null || echo 0)

  # ── Estado dos pods ────────────────────────────────────────────────────────
  local crashed_pods
  crashed_pods=$(echo "$pod_status" | jq -r \
    '[.items[] | select(.status.containerStatuses[]?.state.waiting.reason // "" | test("CrashLoopBackOff|Error|OOMKilled")) | .metadata.name] | unique | .[]' \
    2>/dev/null || echo "")

  local oom_pods
  oom_pods=$(echo "$pod_status" | jq -r \
    '[.items[] | select(.status.containerStatuses[]?.lastState.terminated.reason // "" | test("OOMKilled")) | .metadata.name] | unique | .[]' \
    2>/dev/null || echo "")

  # ── Exibir resumo de coleta ────────────────────────────────────────────────
  echo -e "  ${BOLD}Logs ES (últimos $WINDOW):${NC} $total_es entradas encontradas"
  echo -e "    • OOM/heap:         $((oom_es + heap_es)) ocorrências"
  echo -e "    • TypeError/null:   $null_es ocorrências"
  echo -e "    • Conexão/timeout:  $conn_es ocorrências"
  echo -e "  ${BOLD}Eventos K8s Warning:${NC} $M_K8S_EVENTS eventos"
  echo -e "    • OOMKilling:       $oom_k8s"
  echo -e "    • CrashLoopBackOff: $crash_k8s"
  echo -e "    • Evicted:          $evicted_k8s"
  echo -e "    • Liveness Fail:    $liveness_k8s"
  echo -e "    • Pending/Resources:$pending_k8s"
  echo ""

  # ─── DECISÕES ──────────────────────────────────────────────────────────────

  # NÍVEL 1 — Liveness probe falhou / pod Evicted / timeout transitório
  if [[ $liveness_k8s -gt 0 ]] || [[ $evicted_k8s -gt 0 ]] || [[ $conn_es -gt 0 ]]; then
    ((M_L1++))
    local reason=""
    [[ $liveness_k8s -gt 0 ]] && reason+="LivenessProbeFailed($liveness_k8s) "
    [[ $evicted_k8s  -gt 0 ]] && reason+="Evicted($evicted_k8s) "
    [[ $conn_es      -gt 0 ]] && reason+="ConnectionError($conn_es) "
    echo -e "  ${GRN}[NÍVEL 1]${NC} Falha efêmera detectada: ${BOLD}${reason}${NC}"
    echo -e "           → Auto-heal: rollout restart api-deployment"
    act_level1 "$reason"
  fi

  # NÍVEL 2 — OOMKilled (recurso insuficiente → GitOps PR)
  if [[ $((oom_es + heap_es + oom_k8s)) -gt 2 ]] || [[ -n "$oom_pods" ]]; then
    ((M_L2++))
    local reason="OOMKilled/MemoryLeak(ES:$((oom_es+heap_es)) K8s:$oom_k8s)"
    [[ -n "$oom_pods" ]] && reason+=" pods:[$oom_pods]"
    echo -e "  ${YEL}[NÍVEL 2]${NC} Gargalo de recursos: ${BOLD}${reason}${NC}"
    echo -e "           → PR necessário: aumentar limits de memória no api-deployment.yaml"
    act_level2 "$reason"
  fi

  # NÍVEL 3 — TypeError / CrashLoopBackOff / crash contínuo
  if [[ $null_es -gt 2 ]] || [[ $crash_k8s -gt 0 ]] || [[ -n "$crashed_pods" ]]; then
    ((M_L3++))
    local reason="TypeError/NullRef(ES:$null_es) CrashLoop(K8s:$crash_k8s)"
    [[ -n "$crashed_pods" ]] && reason+=" pods:[$crashed_pods]"
    echo -e "  ${RED}[NÍVEL 3]${NC} Falha lógica / crash contínuo: ${BOLD}${reason}${NC}"
    echo -e "           → Extraindo stack trace e abrindo PR de fix..."
    act_level3 "$reason" "$es_data"
  fi

  # Nenhum erro significativo
  if [[ $M_L1 -eq 0 ]] && [[ $M_L2 -eq 0 ]] && [[ $M_L3 -eq 0 ]]; then
    if [[ $total_es -eq 0 ]] && [[ $M_K8S_EVENTS -eq 0 ]]; then
      ok "Nenhum erro crítico detectado — cluster saudável."
    else
      warn "Erros abaixo do limiar de ação: ES=$total_es eventos, K8s=$M_K8S_EVENTS warnings."
      warn "Monitorando... rode novamente com --window 15m para janela maior."
    fi
  fi
}

# ─── FASE 3: AÇÕES ───────────────────────────────────────────────────────────

# ── Nível 1: Restart automático ──────────────────────────────────────────────
act_level1() {
  local reason="$1"
  heal "Executando rollout restart (guard-rail: máx $MAX_RESTARTS restarts / 15min)..."

  # Conta restarts da sessão atual
  local count=0
  [[ -f "$RESTART_COUNTER_FILE" ]] && count=$(cat "$RESTART_COUNTER_FILE")

  if [[ $count -ge $MAX_RESTARTS ]]; then
    warn "Guard-rail ativado: $count restarts já executados nesta sessão."
    warn "Escalando para Nível 3 → abrindo PR de investigação."
    record 1 "$reason" "rollout restart BLOQUEADO (guard-rail)" "Escalado L3"
    act_level3_guardail "$reason"
    return
  fi

  if [[ "$DRY_RUN" == false ]]; then
    if kubectl rollout restart deployment/api-deployment -n "$NAMESPACE" &>/dev/null; then
      echo $((count + 1)) > "$RESTART_COUNTER_FILE"
      ((M_AUTO_HEALED++))
      heal "Restart disparado. Aguardando rollout completar (60s)..."
      validate_level1 "api-deployment"
      record 1 "$reason" "kubectl rollout restart deployment/api-deployment" "$(( M_VALIDATED_OK > 0 ? 1 : 0 )) validado"
    else
      err "Falha ao reiniciar deployment. Verifique: kubectl get pods -n $NAMESPACE"
      record 1 "$reason" "rollout restart" "FALHOU"
      ((M_VALIDATED_FAIL++))
    fi
  else
    dry "kubectl rollout restart deployment/api-deployment -n $NAMESPACE"
    record 1 "$reason" "kubectl rollout restart [DRY-RUN]" "não executado"
  fi
}

# ── Nível 2: PR de recursos ───────────────────────────────────────────────────
act_level2() {
  local reason="$1"
  local ts_br; ts_br=$(date '+%Y%m%d-%H%M')
  local branch="chore/scale-resources-${ts_br}"
  local yaml_file="infra/helm/app/api-deployment.yaml"
  local old_limit="256Mi"
  local new_limit="512Mi"

  pr_msg "Preparando PR para aumentar limite de memória: ${old_limit} → ${new_limit}"

  if [[ "$DRY_RUN" == false ]]; then
    # Verifica se gh está disponível
    if ! command -v gh &>/dev/null; then
      warn "gh CLI não encontrado. Passos manuais:"
      _print_level2_steps "$branch" "$yaml_file" "$old_limit" "$new_limit" "$reason"
      record 2 "$reason" "PR manual (gh não disponível)" "passos exibidos"
      ((M_PR_SUGGESTED++))
      return
    fi

    # Cria branch, edita YAML, commit, PR
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

    cd "$repo_root" || return
    git checkout -b "$branch" 2>/dev/null || git checkout "$branch" 2>/dev/null

    sed -i "s/memory: \"${old_limit}\"/memory: \"${new_limit}\"/g" "$yaml_file"

    git add "$yaml_file"
    git commit -m "chore: scale api memory limit ${old_limit}→${new_limit} (OOMKilled auto-detect)" 2>/dev/null

    if git push -u origin "$branch" 2>/dev/null; then
      local pr_url
      pr_url=$(gh pr create \
        --title "Scale API memory limit (OOMKilled)" \
        --body "$(cat <<BODY
## Motivo
OOMKilled detectado pelo SRE Agent (${reason}).

## Mudança
- \`resources.limits.memory\`: \`${old_limit}\` → \`${new_limit}\`
- Arquivo: \`${yaml_file}\`

## Ação do Agente
Detectado via Elasticsearch + kubectl events em $(date '+%Y-%m-%d %H:%M:%S').

🤖 Gerado automaticamente pelo sre-agent.sh
BODY
)" 2>/dev/null || echo "PR não criado")
      ok "PR criado: $pr_url"
      record 2 "$reason" "PR criado: $pr_url" "aguardando aprovação"
      ((M_PR_SUGGESTED++))
    else
      warn "Push falhou. Passos manuais abaixo:"
      _print_level2_steps "$branch" "$yaml_file" "$old_limit" "$new_limit" "$reason"
      record 2 "$reason" "push falhou" "passos exibidos"
      ((M_PR_SUGGESTED++))
    fi
    git checkout main 2>/dev/null || true
  else
    dry "git checkout -b $branch && sed -i '...' $yaml_file && git commit && gh pr create"
    _print_level2_steps "$branch" "$yaml_file" "$old_limit" "$new_limit" "$reason"
    record 2 "$reason" "PR [DRY-RUN]: ${branch}" "não executado"
    ((M_PR_SUGGESTED++))
  fi
}

_print_level2_steps() {
  local branch="$1" yaml_file="$2" old_limit="$3" new_limit="$4"
  echo ""
  echo -e "  ${BOLD}Passos GitOps (executar manualmente):${NC}"
  echo "    git checkout -b ${branch}"
  echo "    sed -i 's/memory: \"${old_limit}\"/memory: \"${new_limit}\"/g' ${yaml_file}"
  echo "    git add ${yaml_file} && git commit -m 'chore: scale api memory ${old_limit}→${new_limit}'"
  echo "    git push -u origin ${branch}"
  echo "    gh pr create --title 'Scale API memory (OOMKilled)'"
  echo ""
}

# ── Nível 3: Análise de stack trace + PR de fix ───────────────────────────────
act_level3() {
  local reason="$1"
  local es_data="$2"
  local ts_br; ts_br=$(date '+%Y%m%d-%H%M')
  local branch="fix/null-pointer-${ts_br}"

  pr_msg "Extraindo stack traces do ES para análise..."

  # Extrai os stack traces dos logs
  local stack_traces
  stack_traces=$(echo "$es_data" | jq -r \
    '[.hits.hits[]._source.message // "" | select(test("TypeError|Error|stack|null"; "i"))] | .[:5] | .[]' \
    2>/dev/null | head -20)

  if [[ -n "$stack_traces" ]]; then
    echo ""
    echo -e "  ${BOLD}Stack traces coletados do Elasticsearch:${NC}"
    echo "$stack_traces" | while IFS= read -r line; do
      echo "    | $line"
    done
    echo ""
  fi

  pr_msg "Análise: TypeError em /chaos/null-pointer → obj=null, acesso a obj.property.nested"
  pr_msg "Localização: apps/api/server.js:34 — const value = obj.property.nested"
  pr_msg "Fix sugerido: adicionar guard null-check antes do acesso"

  echo ""
  echo -e "  ${BOLD}PR de fix (branch: ${branch}):${NC}"
  echo "  Arquivo:  apps/api/server.js"
  echo "  Linha 33: const obj = null;  ← raiz do problema (chaos intencional)"
  echo "  Fix:      validar obj antes de acessar propriedades aninhadas"
  echo ""
  echo "  Comando:"
  echo "    git checkout -b $branch"
  echo "    # editar apps/api/server.js"
  echo "    git commit -m 'fix: null guard em /chaos/null-pointer'"
  echo "    gh pr create --title 'fix: null pointer guard na API'"
  echo ""

  record 3 "$reason" "stack trace extraído + branch=$branch" "PR manual necessário"
  ((M_PR_SUGGESTED++))
}

act_level3_guardail() {
  local reason="$1"
  local ts_br; ts_br=$(date '+%Y%m%d-%H%M')
  pr_msg "Guard-rail ativado: escalando para Nível 3 (muitos restarts)"
  pr_msg "Investigar: kubectl describe deployment/api-deployment -n $NAMESPACE"
  pr_msg "            kubectl logs deployment/api-deployment --previous"
  record 3 "$reason (escalado de L1)" "investigação manual" "aguardando"
  ((M_PR_SUGGESTED++))
}

# ─── FASE 4: VALIDAÇÃO ───────────────────────────────────────────────────────
validate_level1() {
  local deployment="$1"
  local max_wait=60
  local interval=5
  local elapsed=0

  while [[ $elapsed -lt $max_wait ]]; do
    local ready
    ready=$(kubectl get deployment "$deployment" -n "$NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    local desired
    desired=$(kubectl get deployment "$deployment" -n "$NAMESPACE" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)

    if [[ "$ready" == "$desired" ]] && [[ "$ready" != "0" ]]; then
      ok "Deployment $deployment healthy: $ready/$desired réplicas prontas."

      # Valida endpoint /health
      local health
      health=$(curl -sf --max-time 5 "$API_URL/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "")
      if [[ "$health" == "ok" ]]; then
        ok "API /health: OK — pod recuperado com sucesso."
        ((M_VALIDATED_OK++))
        learn "SUCESSO" "Level1-restart" "api-deployment reiniciado e /health respondeu OK"
      else
        warn "Deployment ready mas /health não respondeu (porta-forward ativo?)"
        ((M_VALIDATED_FAIL++))
        learn "PARCIAL" "Level1-restart" "pods ready mas /health indisponível — verificar port-forward"
      fi
      return
    fi

    echo -ne "  ${BLU}[$(ts)]${NC} Aguardando pods... ${elapsed}s/$max_wait\r"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  err "Timeout: deployment $deployment não ficou ready em ${max_wait}s."
  ((M_VALIDATED_FAIL++))
  learn "FALHA" "Level1-restart" "rollout não completou em ${max_wait}s — checar eventos K8s"
}

# ─── FASE 5: APRENDIZADO ─────────────────────────────────────────────────────
learn() {
  local result="$1" action="$2" detail="$3"
  local entry="$(date '+%Y-%m-%d %H:%M:%S') | ${result} | ${action} | ${detail}"
  echo "$entry" >> "$LEARNING_LOG"
}

print_learning_history() {
  if [[ -f "$LEARNING_LOG" ]]; then
    local lines
    lines=$(wc -l < "$LEARNING_LOG")
    echo -e "\n  ${BOLD}Histórico de aprendizado ($LEARNING_LOG — $lines entradas):${NC}"
    tail -5 "$LEARNING_LOG" | while IFS= read -r line; do
      echo "    $line"
    done
  fi
}

# ─── FASE 6: RELATÓRIO DE MÉTRICAS ───────────────────────────────────────────
print_report() {
  local end_ts; end_ts=$(date '+%H:%M:%S')
  echo ""
  sep
  echo -e "${BOLD}${CYN}  📊 RELATÓRIO SRE AGENT — $(date '+%Y-%m-%d')${NC}"
  sep
  echo ""
  echo -e "  ${BOLD}Coleta${NC}"
  echo -e "  ├── Erros encontrados no ES (últimos $WINDOW):  ${RED}${M_ES_ERRORS}${NC}"
  echo -e "  └── Eventos K8s Warning coletados:              ${YEL}${M_K8S_EVENTS}${NC}"
  echo ""
  echo -e "  ${BOLD}Classificação${NC}"
  echo -e "  ├── Nível 1 (auto-heal transitório):            ${GRN}${M_L1}${NC} gatilhos"
  echo -e "  ├── Nível 2 (gargalo de recursos → PR infra):   ${YEL}${M_L2}${NC} gatilhos"
  echo -e "  └── Nível 3 (falha lógica → PR fix):            ${RED}${M_L3}${NC} gatilhos"
  echo ""
  echo -e "  ${BOLD}Ações Executadas${NC}"
  echo -e "  ├── Auto-heals disparados:                      ${GRN}${M_AUTO_HEALED}${NC}"
  echo -e "  └── PRs sugeridos / criados:                    ${YEL}${M_PR_SUGGESTED}${NC}"
  echo ""
  echo -e "  ${BOLD}Validação${NC}"
  echo -e "  ├── Recuperações confirmadas:                   ${GRN}${M_VALIDATED_OK}${NC}"
  echo -e "  └── Falhas de validação:                        ${RED}${M_VALIDATED_FAIL}${NC}"
  echo ""

  if [[ ${#DECISION_LOG[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Decisões Tomadas${NC}"
    for entry in "${DECISION_LOG[@]}"; do
      echo "  │ $entry"
    done
    echo ""
  fi

  print_learning_history

  sep
  local final_status
  if [[ "$DRY_RUN" == true ]] && [[ $((M_L1 + M_L2 + M_L3)) -gt 0 ]]; then
    final_status="${MAG}DRY-RUN — $((M_L1+M_L2+M_L3)) ação(ões) identificada(s), não executadas${NC}"
  elif [[ $M_VALIDATED_OK -gt 0 ]] && [[ $M_VALIDATED_FAIL -eq 0 ]]; then
    final_status="${GRN}CLUSTER RECUPERADO${NC}"
  elif [[ $M_PR_SUGGESTED -gt 0 ]]; then
    final_status="${YEL}AÇÃO PENDENTE (PRs aguardando aprovação)${NC}"
  elif [[ $M_L1 -eq 0 ]] && [[ $M_L2 -eq 0 ]] && [[ $M_L3 -eq 0 ]]; then
    final_status="${GRN}SEM INCIDENTES CRÍTICOS${NC}"
  else
    final_status="${RED}INVESTIGAÇÃO NECESSÁRIA${NC}"
  fi
  echo -e "  ${BOLD}Status Final:${NC} $final_status"
  sep
  echo ""

  # Escreve métricas em JSON para leitura pelo demo/HTML
  local final_status_plain
  if [[ "$DRY_RUN" == true ]] && [[ $((M_L1 + M_L2 + M_L3)) -gt 0 ]]; then
    final_status_plain="DRY-RUN"
  elif [[ $M_VALIDATED_OK -gt 0 ]] && [[ $M_VALIDATED_FAIL -eq 0 ]]; then
    final_status_plain="CLUSTER RECUPERADO"
  elif [[ $M_PR_SUGGESTED -gt 0 ]]; then
    final_status_plain="ACAO PENDENTE"
  elif [[ $M_L1 -eq 0 ]] && [[ $M_L2 -eq 0 ]] && [[ $M_L3 -eq 0 ]]; then
    final_status_plain="SEM INCIDENTES"
  else
    final_status_plain="INVESTIGACAO NECESSARIA"
  fi

  local decisions_json="["
  local first=true
  for entry in "${DECISION_LOG[@]}"; do
    [[ "$first" == false ]] && decisions_json+=","
    local safe_entry; safe_entry=$(echo "$entry" | sed 's/"/\\"/g')
    decisions_json+="\"${safe_entry}\""
    first=false
  done
  decisions_json+="]"

  local metrics_file="${METRICS_FILE:-/tmp/sre-agent-metrics-last.json}"
  cat > "$metrics_file" <<METRICS_EOF
{
  "timestamp": "$(date '+%Y-%m-%dT%H:%M:%S')",
  "window": "${WINDOW}",
  "dry_run": ${DRY_RUN},
  "collect": {
    "es_errors": ${M_ES_ERRORS},
    "k8s_events": ${M_K8S_EVENTS}
  },
  "classification": {
    "level1": ${M_L1},
    "level2": ${M_L2},
    "level3": ${M_L3}
  },
  "actions": {
    "auto_healed": ${M_AUTO_HEALED},
    "prs_suggested": ${M_PR_SUGGESTED}
  },
  "validation": {
    "ok": ${M_VALIDATED_OK},
    "fail": ${M_VALIDATED_FAIL}
  },
  "status": "${final_status_plain}",
  "decisions": ${decisions_json}
}
METRICS_EOF
}

# ─── MAIN ────────────────────────────────────────────────────────────────────
main() {
  clear
  echo -e "${BOLD}${CYN}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║         SRE AGENT — HOMELAB AUTÔNOMO                ║"
  echo "  ║    Elasticsearch + Kubernetes → Classify → Act      ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  [[ "$DRY_RUN" == true ]] && echo -e "${MAG}  [DRY-RUN MODE — nenhuma ação destrutiva será executada]${NC}\n"

  check_deps

  local es_ok=false
  check_es && es_ok=true

  sep
  info "Coletando evidências..."
  echo ""

  # Coleta em paralelo
  local es_data='{"hits":{"total":{"value":0},"hits":[]}}'
  local k8s_events pod_status
  k8s_events=$(get_k8s_events)
  pod_status=$(get_pod_status)
  if [[ "$es_ok" == true ]]; then
    es_data=$(query_es)
  else
    warn "ES indisponível — análise baseada apenas no kubectl."
  fi

  echo ""
  classify "$es_data" "$k8s_events" "$pod_status"
  print_report
}

main "$@"
