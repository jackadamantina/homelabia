# update-api.ps1
# Fluxo GitOps para mudancas no codigo da API:
#   1. Build da nova imagem Docker
#   2. Carrega no cluster kind
#   3. Faz commit + push para main
#   4. ArgoCD detecta a mudanca e aplica automaticamente
#
# Uso: .\scripts\update-api.ps1 -Version "1.0.1" -Message "fix: corrige null pointer"

param(
    [Parameter(Mandatory=$true)]
    [string]$Version,

    [Parameter(Mandatory=$true)]
    [string]$Message
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$ImageName = "homelab-api"
$Tag = $Version

Write-Host "🔨 [1/5] Build da imagem $ImageName`:$Tag..." -ForegroundColor Cyan
docker build -t "${ImageName}:${Tag}" -t "${ImageName}:latest" "$RepoRoot/apps/api/"

Write-Host "📦 [2/5] Carregando imagem no cluster kind..." -ForegroundColor Cyan
# Achatar para single-platform (workaround proxy corporativo)
"FROM ${ImageName}:${Tag}" | docker build -t "${ImageName}-local:${Tag}" -
kind load docker-image "${ImageName}-local:${Tag}" --name kind

Write-Host "✏️  [3/5] Atualizando tag no manifesto Kubernetes..." -ForegroundColor Cyan
$deploymentFile = "$RepoRoot/infra/helm/app/api-deployment.yaml"
$content = Get-Content $deploymentFile -Raw
$content = $content -replace 'image: homelab-api(-local)?:[^\s]+', "image: ${ImageName}-local:${Tag}"
Set-Content $deploymentFile $content

Write-Host "📤 [4/5] Commit e push para main..." -ForegroundColor Cyan
Set-Location $RepoRoot
git add infra/helm/app/api-deployment.yaml apps/api/
git commit -m $Message
git push origin main

Write-Host "⏳ [5/5] Aguardando ArgoCD sincronizar (até 3 min)..." -ForegroundColor Cyan
$timeout = 180
$elapsed = 0
do {
    Start-Sleep 10
    $elapsed += 10
    $status = kubectl get application homelab-app -n argocd -o jsonpath='{.status.sync.status}' 2>$null
    Write-Host "   sync status: $status ($elapsed`s)"
} while ($status -ne "Synced" -and $elapsed -lt $timeout)

if ($status -eq "Synced") {
    Write-Host "✅ Deploy concluido! Pod atualizado com $ImageName-local:$Tag" -ForegroundColor Green
    kubectl rollout status deployment/api-deployment -n default
} else {
    Write-Host "⚠️  Timeout aguardando sync. Verifique no ArgoCD: https://localhost:18080" -ForegroundColor Yellow
}
