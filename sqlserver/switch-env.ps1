# Helper script to switch between deployment environments
# Usage: .\switch-env.ps1 -Environment dev-ha
#        .\switch-env.ps1 -Environment dev-ha-dr

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('dev', 'dev-ha', 'dev-ha-dr')]
    [string]$Environment
)

$ErrorActionPreference = "Stop"

Write-Host "`nSwitching to environment: $Environment" -ForegroundColor Cyan

# Reconfigure backend to point to correct state file
Write-Host "Reconfiguring backend..." -ForegroundColor Yellow
terraform init -reconfigure -backend-config="env/backend-$Environment.tfbackend"

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✓ Successfully switched to $Environment environment" -ForegroundColor Green
    Write-Host "`nYou can now run:" -ForegroundColor White
    Write-Host "  terraform plan -var-file=`"env/$Environment.tfvars`" -var=`"use_msi=false`"" -ForegroundColor Gray
    Write-Host "  terraform apply -var-file=`"env/$Environment.tfvars`" -var=`"use_msi=false`"" -ForegroundColor Gray
} else {
    Write-Host "`n✗ Failed to switch environment" -ForegroundColor Red
    exit 1
}
