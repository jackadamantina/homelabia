#!/bin/bash
# scripts/chaos-monkey.sh
# Uso: ./chaos-monkey.sh [1|2|3|all]
#   1 = Memory Leak (OOMKilled)
#   2 = Null Pointer (500 TypeError x10)
#   3 = DB down (resiliência)
#   all = executa os 3 em sequência

API_URL="${API_URL:-http://localhost:18081}"
SCENARIO="${1:-}"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'

banner() { echo -e "\n${YEL}🐒 ═══════════════════════════════════════${NC}"; echo -e "${YEL}   CHAOS MONKEY — $1${NC}"; echo -e "${YEL}🐒 ═══════════════════════════════════════${NC}\n"; }

run_1() {
  banner "Cenário 1: Memory Leak → OOMKilled"
  echo -e "${RED}[CHAOS]${NC} POST /chaos/memory-leak → alocando ~10MB/200ms até OOMKilled..."
  curl -sf -X POST "$API_URL/chaos/memory-leak" && echo "" || echo -e "${RED}[ERRO] API indisponível em $API_URL${NC}"
}

run_2() {
  banner "Cenário 2: Null Pointer → TypeError 500"
  echo -e "${RED}[CHAOS]${NC} POST /chaos/null-pointer × 10..."
  for i in $(seq 1 10); do
    resp=$(curl -sf -X POST "$API_URL/chaos/null-pointer" 2>/dev/null || echo '{"error":"unreachable"}')
    echo "  [$i] $(echo "$resp" | grep -o '"type":"[^"]*"' || echo "$resp")"
  done
}

run_3() {
  banner "Cenário 3: DB Down → Teste de resiliência da API"
  echo -e "${RED}[CHAOS]${NC} Deletando pod do banco de dados..."
  kubectl delete pod -l app=database -n default 2>/dev/null \
    || kubectl delete pod db-pod-0 -n default 2>/dev/null \
    || echo -e "${RED}[ERRO]${NC} Pod do banco não encontrado. Verifique: kubectl get pods -n default"
  echo -e "${YEL}[INFO]${NC} StatefulSet vai recriar db-pod-0 automaticamente."
}

# ─── MENU ──────────────────────────────────────────────────────────────────
if [[ -z "$SCENARIO" ]]; then
  echo -e "${YEL}🐒 Chaos Monkey — Homelab${NC}"
  echo "  1) Memory Leak (OOMKilled)"
  echo "  2) Null Pointer (500 TypeError)"
  echo "  3) DB Down (resiliência)"
  echo "  4) Todos os cenários"
  read -rp "Opção: " SCENARIO
fi

case "$SCENARIO" in
  1) run_1 ;;
  2) run_2 ;;
  3) run_3 ;;
  all|4)
    run_2      # erros de código primeiro (ficam no ES)
    sleep 2
    run_3      # derruba banco
    sleep 2
    run_1      # memory leak por último
    ;;
  *) echo "Uso: $0 [1|2|3|all]"; exit 1 ;;
esac

echo -e "\n${GRN}[✓] Chaos aplicado. Rode ./scripts/sre-agent.sh para triagem autônoma.${NC}\n"
