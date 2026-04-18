# expose-services.ps1 - Expoe ArgoCD e Elasticsearch do kind para o browser do host
# Uso: .\scripts\expose-services.ps1
# Para encerrar: feche as janelas abertas ou rode Stop-Job (Get-Job)

Write-Host "🌐 Expondo servicos do Homelab para o host..." -ForegroundColor Cyan

# Mata port-forwards antigos se existirem
Get-Process -Name "kubectl" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "port-forward" } |
    Stop-Process -Force -ErrorAction SilentlyContinue

# Nota: porta 8080 ocupada pelo Docker Desktop — usamos 18080 e 19200
# ArgoCD  - porta 18080 -> argocd-server:443  (HTTPS)
# Elastic - porta 19200 -> elasticsearch-master:9200 (HTTPS)

$argoProc = Start-Process -NoNewWindow -FilePath 'kubectl' `
    -ArgumentList 'port-forward','svc/argocd-server','-n','argocd','18080:443','--address','127.0.0.1' `
    -RedirectStandardOutput 'C:/tmp/argocd-pf.log' `
    -RedirectStandardError  'C:/tmp/argocd-pf-err.log' -PassThru

$esProc = Start-Process -NoNewWindow -FilePath 'kubectl' `
    -ArgumentList 'port-forward','svc/elasticsearch-master','-n','default','19200:9200','--address','127.0.0.1' `
    -RedirectStandardOutput 'C:/tmp/es-pf.log' `
    -RedirectStandardError  'C:/tmp/es-pf-err.log' -PassThru

Start-Sleep -Seconds 3

Write-Host ""
Write-Host "✅ Servicos expostos:" -ForegroundColor Green
Write-Host "   ArgoCD:        https://localhost:18080  (admin / YKPN5VRj2OO3spou)" -ForegroundColor Yellow
Write-Host "   Elasticsearch: https://localhost:19200  (elastic / j6TrY7ENkDEVNSoZ)" -ForegroundColor Yellow
Write-Host ""
Write-Host "PIDs: ArgoCD=$($argoProc.Id)  Elastic=$($esProc.Id)"
Write-Host "Para encerrar: Get-Process kubectl | Stop-Process"
Write-Host ""
Write-Host "Aguardando... (Ctrl+C para sair, port-forwards continuam em background)" -ForegroundColor Gray

# Mantem o script vivo para exibir erros se algum job falhar
while ($true) {
    Start-Sleep -Seconds 30
    $jobs = Get-Job -Id $argoJob.Id, $esJob.Id
    foreach ($job in $jobs) {
        if ($job.State -eq "Failed") {
            Write-Host "[WARN] Job $($job.Id) falhou. Reiniciando..." -ForegroundColor Red
        }
    }
}
