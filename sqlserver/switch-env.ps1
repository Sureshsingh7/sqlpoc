# Helper script to switch between deployment environments for LOCAL development
# Usage: .\switch-env.ps1 -Environment dev-ha
#        .\switch-env.ps1 -Environment dev-ha-dr
#
# Note: GitHub Actions workflow handles backend config automatically

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('dev', 'dev-ha', 'dev-ha-dr')]
    [string]$Environment
)

$ErrorActionPreference = "Stop"

Write-Host "`nSwitching to environment: $Environment" -ForegroundColor Cyan

# Derive state key (matches GitHub Actions pattern)
$stateKey = "sqlserver-$Environment.tfstate"
$backendConfig = "env/backend-$Environment.tfbackend"

Write-Host "Backend config: $backendConfig" -ForegroundColor Yellow
Write-Host "State file key: $stateKey" -ForegroundColor Yellow

# Reconfigure backend to point to correct state file
Write-Host "`nReconfiguring backend..." -ForegroundColor Yellow
terraform init -reconfigure -backend-config="$backendConfig" -backend-config="key=$stateKey"

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✓ Successfully switched to $Environment environment" -ForegroundColor Green
    Write-Host "`nYou can now run:" -ForegroundColor White
    Write-Host "  terraform plan -var-file=`"env/$Environment.tfvars`" -var=`"use_msi=false`"" -ForegroundColor Gray
    Write-Host "  terraform apply -var-file=`"env/$Environment.tfvars`" -var=`"use_msi=false`"" -ForegroundColor Gray
} else {
    Write-Host "`n✗ Failed to switch environment" -ForegroundColor Red
    exit 1
}
