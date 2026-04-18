Write-Host "🚀 Iniciando Homelab DevOps..."

# 1. Criar o cluster
Write-Host "📦 Criando cluster Kubernetes com Kind..."
kind create cluster --name devops-lab

# 2. Instalar ArgoCD
Write-Host "🐙 Instalando ArgoCD..."
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Instalar Elasticsearch + Fluent-bit (Básico via Helm)
Write-Host "🔍 Instalando Stack de Observabilidade..."
helm repo add elastic https://helm.elastic.co
helm repo update
helm install elasticsearch elastic/elasticsearch --version 8.5.1 --set replicas=1 -n default

Write-Host "✅ Homelab provisionado! Verifique os pods com: kubectl get pods -A"