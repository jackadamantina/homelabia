# DevOps Autonomic Agent Protocol - SRE / Homelab Edition

## 1. Contexto do Ambiente

- **OS:** Windows 11 (executando via PowerShell / WSL2)
- **Orquestração:** Kubernetes via `kind` — cluster: `kind-kind` (1 nó, `kind-control-plane`)
- **GitOps:** ArgoCD v3.3.7 monitorando `infra/helm/app/` no branch `main` do GitHub
- **Repositório GitHub:** `https://github.com/jackadamantina/homelabia.git`
- **Observabilidade:** Elasticsearch 8.5.1 coletando logs (acesso via HTTPS)
- **Stack de Apps:** `api-deployment` (Deployment Node.js) e `db-pod` (StatefulSet PostgreSQL 15)

---

## 2. Estado do Cluster (Referência)

### Pods em execução (namespace: default)
| Pod | Tipo | Imagem | Status |
|---|---|---|---|
| `api-deployment-*` | Deployment | `homelab-api:latest` (local) | Running |
| `db-pod-0` | StatefulSet | `postgres-homelab:15` (local) | Running |
| `elasticsearch-master-0` | StatefulSet | `elasticsearch-local:8.5.1` (local) | Running |

### ArgoCD (namespace: argocd)
| Pod | Status |
|---|---|
| `argocd-server-*` | Running |
| `argocd-application-controller-0` | Running |
| `argocd-repo-server-*` | Running |
| `argocd-redis-*` | Running |
| `argocd-dex-server-*` | Running |
| `argocd-applicationset-controller-*` | Running |
| `argocd-notifications-controller-*` | Running |

### Imagens carregadas no kind (via `kind load`)
Todas as imagens usam `imagePullPolicy: Never` — a rede corporativa bloqueia pulls externos
dentro do cluster (erro `x509: certificate signed by unknown authority`).

| Tag local | Origem |
|---|---|
| `homelab-api:latest` | Build local de `apps/api/` |
| `postgres-homelab:15` | Achatada de `postgres:15-alpine` |
| `elasticsearch-local:8.5.1` | Achatada de `docker.elastic.co/elasticsearch/elasticsearch:8.5.1` |
| `argocd-local:v3.3.7` | Achatada de `quay.io/argoproj/argocd:v3.3.7` |
| `dex-local:v2.43.0` | Achatada de `ghcr.io/dexidp/dex:v2.43.0` |
| `redis-local:8.2.3` | Achatada de `public.ecr.aws/docker/library/redis:8.2.3-alpine` |

**Procedimento para adicionar uma nova imagem ao cluster:**
```powershell
# 1. Pull local (usa proxy do host, que tem o cert corporativo)
docker pull <imagem>:<tag>
# 2. Achatar para single-platform (elimina manifest-list multi-arch)
echo "FROM <imagem>:<tag>" | docker build -t <nome-local>:<tag> -
# 3. Carregar no kind
kind load docker-image <nome-local>:<tag> --name kind
```

---

## 3. Acessos aos Serviços

> **Porta 8080 ocupada pelo Docker Desktop** — usar portas alternativas abaixo.

| Serviço | URL | Usuário | Senha |
|---|---|---|---|
| **ArgoCD UI** | `https://localhost:18080` | `admin` | `YKPN5VRj2OO3spou` |
| **Elasticsearch** | `https://localhost:19200` | `elastic` | `j6TrY7ENkDEVNSoZ` |
| **API (chaos)** | `http://localhost:18081` | — | — |

### Iniciar port-forwards (rodar após cada reinício da máquina)
```powershell
.\scripts\expose-services.ps1
```
Ou manualmente:
```powershell
# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 18080:443 --address 127.0.0.1

# Elasticsearch
kubectl port-forward svc/elasticsearch-master -n default 19200:9200 --address 127.0.0.1

# API (para testes de chaos)
kubectl port-forward svc/api-service -n default 18081:80 --address 127.0.0.1
```
Encerrar todos:
```powershell
Get-Process kubectl | Stop-Process
```

---

## 4. Fluxo GitOps (GitFlow → GitOps → kind)

```
Developer  →  Git branch  →  PR  →  Merge main  →  ArgoCD detecta  →  kubectl apply  →  Pod atualizado
```

### 4.1 Mudança apenas em manifesto Kubernetes (infra)
1. Edite os arquivos em `infra/helm/app/*.yaml`
2. Crie um branch, abra PR, faça merge para `main`
3. ArgoCD faz sync automático em até **3 minutos** (polling interval padrão)
4. Verifique em `https://localhost:18080` → app `homelab-app`

### 4.2 Mudança no código da API (apps/api/)
```powershell
# Edite apps/api/server.js, depois:
.\scripts\update-api.ps1 -Version "1.0.1" -Message "fix: descrição da mudança"
```
O script faz:
- `docker build` da nova imagem
- `kind load` da imagem no cluster
- Atualiza a tag no `api-deployment.yaml`
- Commit + push para `main`
- Aguarda ArgoCD sincronizar

### 4.3 ArgoCD Application
- **Arquivo:** `infra/argocd/homelab-app.yaml`
- **Repo:** `https://github.com/jackadamantina/homelabia.git`
- **Path monitorado:** `infra/helm/app/`
- **Branch:** `HEAD` (main)
- **Auto-sync:** habilitado (`prune: true`, `selfHeal: true`)
- **TLS:** `insecure: true` via `infra/argocd/repo-secret.yaml` (proxy corporativo)

### 4.4 Verificar status do sync
```bash
kubectl get application homelab-app -n argocd
kubectl get application homelab-app -n argocd -o jsonpath='{.status.sync.status} | {.status.health.status}'
```

---

## 5. Comandos de Operação (SRE Toolkit)

```bash
# Status geral do cluster
kubectl get pods,events --sort-by='.metadata.creationTimestamp' -A

# Logs rápidos
kubectl logs deployment/api-deployment --tail=50
kubectl logs statefulset/db-pod --tail=50
kubectl logs statefulset/elasticsearch-master --tail=50

# Logs de erro via Elasticsearch
curl -sk -u elastic:j6TrY7ENkDEVNSoZ \
  "https://localhost:19200/logs/_search?q=level:ERROR&pretty"

# Forçar sync do ArgoCD
kubectl patch application homelab-app -n argocd \
  --type=merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

---

## 6. Chaos Monkey — Simulação de Incidentes

### Pré-requisito: expor a API
```powershell
kubectl port-forward svc/api-service -n default 18081:80 --address 127.0.0.1
```

### Executar o chaos monkey
```bash
# Linux/WSL
API_URL=http://localhost:18081 bash ./scripts/chaos-monkey.sh

# PowerShell (direto)
# Opção 1 — Memory Leak (simula OOMKilled)
curl -X POST http://localhost:18081/chaos/memory-leak

# Opção 2 — Null Pointer (simula CrashLoopBackOff / Erro 500)
for ($i=0; $i -lt 10; $i++) { curl -X POST http://localhost:18081/chaos/null-pointer }

# Opção 3 — Derrubar o banco (testa resiliência da API)
kubectl delete pod -l app=database -n default
```

### Rotas da API
| Rota | Método | Efeito esperado |
|---|---|---|
| `/health` | GET | `200 OK` — liveness check |
| `/chaos/memory-leak` | POST | Aloca ~10MB/200ms até OOMKilled |
| `/chaos/null-pointer` | POST | `500 TypeError` — NullReference |

---

## 7. Matriz de Decisão e Triagem (The Brain)

O agente atua como SRE Autônomo. Ao ser acionado por um evento de erro (Elastic ou K8s Events),
classifica e atua conforme os níveis abaixo.

### Nível 1 — Infraestrutura Efêmera (Auto-Healing imediato, sem aprovação)
*Falhas de rede transitórias ou travamentos silenciosos que um restart resolve.*

**Gatilhos:**
- `LivenessProbeFailed` na API
- Erros intermitentes de timeout (`Connection Refused` esporádico para o DB)
- Pod com status `Evicted` ou `Unknown`

**Ação permitida:**
```bash
kubectl rollout restart deployment/api-deployment
kubectl delete pod <nome-do-pod>
```

**Guard-rail:** máximo de 3 restarts por Deployment em 15 minutos.
Se falhar na 4ª vez → escalar para Nível 3.

---

### Nível 2 — Gargalo de Recursos (Ajuste de Infra via PR)
*Erros que exigem alteração na infraestrutura declarativa.*

**Gatilhos:**
- Pod com status `OOMKilled`
- Alertas de `CPU Throttling` no Elasticsearch
- Pod travado em `Pending` por `Insufficient cpu/memory`

**Ação (GitOps Flow):**
1. Criar branch `chore/scale-resources-<timestamp>`
2. Editar `infra/helm/app/api-deployment.yaml` — aumentar `limits`/`requests`
3. Abrir PR: `gh pr create --title "Scale resources for api" --body "Fixing OOMKilled"`
4. Postar link do PR e aguardar aprovação

---

### Nível 3 — Falha Lógica ou Crash Contínuo (Refatoração via PR)
*O sistema não vai se recuperar sozinho; a lógica está quebrada.*

**Gatilhos:**
- `CrashLoopBackOff` persistente após start (variável de ambiente faltando ou erro fatal)
- Erros `500` contínuos com `TypeError`, `NullReferenceException` etc.
- DB down com "Corrupted Index" ou "Invalid Schema"

**Ação (Dev Flow):**
1. Extrair Stack Trace do Elasticsearch
2. Identificar arquivo e linha em `apps/api/` ou `apps/database/`
3. Criar branch `fix/bug-resolution-<id>`
4. Refatorar o código
5. Rodar `.\scripts\update-api.ps1 -Version "<nova>" -Message "fix: <descrição>"`
6. Criar PR e postar link para aprovação

---

## 8. Padrões de Comunicação do Agente

- Toda ação deve ser precedida por log: `[🔍 ANALISANDO]`, `[⚡ AUTO-HEALING]`, `[🛠️ NECESSITA PR]`
- Se o banco cair (`db-pod`): verificar logs do DB *antes* da API (a API gerará cascata de falsos erros)
- **Nunca** usar `kubectl edit` ou `kubectl patch` para corrigir configurações — toda verdade vem do GitHub
- Senhas e credenciais: não commitar no repositório (usar Kubernetes Secrets)

---

## 9. Estrutura do Repositório

```
homelabia/
├── apps/
│   └── api/
│       ├── server.js          # API Node.js (Express) com rotas de chaos
│       ├── package.json
│       └── Dockerfile         # Multi-stage Alpine, ~60MB
├── infra/
│   ├── argocd/
│   │   ├── homelab-app.yaml   # ArgoCD Application CRD (GitOps entry point)
│   │   └── repo-secret.yaml   # Secret do repo com insecure:true (proxy corporativo)
│   └── helm/
│       └── app/
│           ├── api-deployment.yaml   # Deployment da API (imagePullPolicy: Never)
│           ├── api-service.yaml      # ClusterIP :80 → :3000
│           ├── db-statefulset.yaml   # StatefulSet PostgreSQL 15 + PVC 1Gi
│           └── db-service.yaml       # Headless service para o StatefulSet
├── scripts/
│   ├── setup-lab.ps1          # Provisiona cluster kind + ArgoCD + Elasticsearch
│   ├── expose-services.ps1    # Inicia port-forwards para o browser do host
│   ├── update-api.ps1         # Build + kind load + push GitOps da API
│   └── chaos-monkey.sh        # Menu interativo para simular incidentes
└── CLAUDE.md                  # Este arquivo — documentação completa do homelab
```

---

## 10. Troubleshooting Conhecido

### Imagem não inicia — `ErrImagePull` / `x509: certificate`
A rede corporativa tem proxy com inspeção SSL. O cluster kind não tem o certificado root.
**Solução:** sempre usar `kind load` conforme procedimento da seção 2.

### Porta 8080 ocupada (Docker Desktop)
O Docker Desktop ocupa permanentemente a porta `8080`.
**Solução:** usar `18080` para ArgoCD e `19200` para Elasticsearch.

### ArgoCD não consegue clonar o repositório
Verificar se o Secret `homelab-repo-secret` existe no namespace `argocd`:
```bash
kubectl get secret homelab-repo-secret -n argocd
```
Se não existir: `kubectl apply -f infra/argocd/repo-secret.yaml`

### Port-forwards morrem após fechar o terminal
Rodar `.\scripts\expose-services.ps1` novamente. Os processos `kubectl port-forward`
são filhos do terminal no Windows — não sobrevivem ao fechamento da sessão.
