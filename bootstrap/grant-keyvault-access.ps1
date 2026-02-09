# grant-keyvault-access.ps1
# Grants Terraform UAMI "Key Vault Secrets Officer" role on PRIMARY and DR Key Vaults
#
# REQUIRED: Run this script AFTER deploying the PRIMARY Key Vault (terraform-ops, preset: dev)
#
# Why needed: The Terraform UAMI needs "Key Vault Secrets Officer" to create and manage
# secrets. The UAMI cannot grant itself this role (would require "User Access Administrator"
# privilege, which is a security risk). This script grants the access manually for PRIMARY.
# For DR, the workflow automatically grants access via Azure CLI.
#
# Note: UAMI already has Contributor role which provides read access to secrets.

param (
  [string]$PrimaryKvName = 'kv-fnz-poc-se',
  [string]$DrKvName = 'kv-fnz-poc-dr-swc',
  [string]$OpsRg = 'rg-fnz-poc-ops-se',
  [string]$DrRg = 'rg-fnz-poc-sql-dr-swc',
  [string]$UamiPrincipalId = '2680641f-e875-4270-aa05-246cdef65d17'  # From bootstrap output
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Az {
  param(
    [Parameter(Mandatory)]
    [string[]] $AzArgs,
    [switch] $AllowFailure
  )
  $out = & az @AzArgs 2>&1
  $code = $LASTEXITCODE
  if (-not $AllowFailure -and $code -ne 0) {
    throw ("Azure CLI failed (exit {0}): az {1}`n{2}" -f $code, ($AzArgs -join ' '), ($out | Out-String))
  }
  [pscustomobject]@{
    Output   = $out
    ExitCode = $code
  }
}

function Set-RoleAssignment([string]$PrincipalId, [string]$RoleName, [string]$Scope) {
  # Idempotent: check if assignment exists
  $existing = Invoke-Az @('role','assignment','list','--assignee-object-id',$PrincipalId,'--scope',$Scope,'--query',"length([?roleDefinitionName=='$RoleName'])") -AllowFailure
  $countText = (($existing.Output | Out-String).Trim() -replace '"','')
  [int]$count = 0
  [void][int]::TryParse($countText, [ref]$count)

  if ($count -eq 0) {
    Write-Host "Assigning $RoleName to $PrincipalId on $Scope"
    Invoke-Az @('role','assignment','create',
      '--assignee-object-id',$PrincipalId,
      '--assignee-principal-type','ServicePrincipal',
      '--role',$RoleName,
      '--scope',$Scope
    ) | Out-Null
  } else {
    Write-Host "Already assigned: $RoleName on $Scope"
  }
}

Write-Host "`n== Granting Key Vault Access to Terraform UAMI =="

# Get PRIMARY Key Vault scope
Write-Host "`nChecking PRIMARY Key Vault: $PrimaryKvName"
$primaryKvCheck = Invoke-Az @('keyvault','show','-n',$PrimaryKvName,'-g',$OpsRg,'--query','id','-o','tsv') -AllowFailure
if ($primaryKvCheck.ExitCode -eq 0) {
  $primaryScope = ($primaryKvCheck.Output | Out-String).Trim()
  Set-RoleAssignment -PrincipalId $UamiPrincipalId -RoleName 'Key Vault Secrets Officer' -Scope $primaryScope
  Write-Host "✓ PRIMARY Key Vault access granted"
} else {
  Write-Warning "PRIMARY Key Vault not found: $PrimaryKvName (may not be deployed yet)"
}

# Get DR Key Vault scope
Write-Host "`nChecking DR Key Vault: $DrKvName"
$drKvCheck = Invoke-Az @('keyvault','show','-n',$DrKvName,'-g',$DrRg,'--query','id','-o','tsv') -AllowFailure
if ($drKvCheck.ExitCode -eq 0) {
  $drScope = ($drKvCheck.Output | Out-String).Trim()
  Set-RoleAssignment -PrincipalId $UamiPrincipalId -RoleName 'Key Vault Secrets Officer' -Scope $drScope
  Write-Host "✓ DR Key Vault access granted"
} else {
  Write-Warning "DR Key Vault not found: $DrKvName (deploy ops module first)"
}

Write-Host "`n✓ Key Vault access configuration complete"
Write-Host "Next: Run ops and sqlserver workflows to deploy infrastructure"
