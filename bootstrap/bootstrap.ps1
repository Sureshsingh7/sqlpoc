
# bootstrap.ps1 (PowerShell 7+)
# Creates:
# - Backend RG + Storage Account + tfstate container (for Terraform state)
# - Workload RG
# - User Assigned Managed Identity (UAMI) + RBAC
# - Generates output.local.env.ps1 (dot-source to load variables)

param (
  [string]$Location = 'centralus',
  [string]$BootstrapRg = 'rg-fnz-poc-tfstate',
  [string]$TfstateContainer = 'tfstate',
  [string]$TfstateKey = 'fnz-poc.tfstate',
  [string]$WorkloadRg = 'rg-fnz-poc-workload',
  [string]$UamiName = 'uami-fnz-poc-tf',

  # Optional: force a specific storage account name (must be globally unique, 3-24 chars, lowercase+digits)
  [string]$TfstateSaName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------
# Helpers
# -------------------------

function Test-CommandAvailable([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}
function Invoke-Az {
  param(
    [Parameter(Mandatory)]
    [string[]] $AzArgs,

    [switch] $AllowFailure
  )

  # Capture output (stdout+stderr) so we can surface real errors when needed
  $out = & az @AzArgs 2>&1
  $code = $LASTEXITCODE

  if (-not $AllowFailure -and $code -ne 0) {
    throw ("Azure CLI failed (exit {0}): az {1}`n{2}" -f $code, ($AzArgs -join ' '), ($out | Out-String))
  }

  # Return both output and exit code
  [pscustomobject]@{
    Output   = $out
    ExitCode = $code
  }
}
function Invoke-AzJson {
  param(
    [Parameter(Mandatory)]
    [string[]] $AzArgs
  )

  $res = Invoke-Az -AzArgs ($AzArgs + @('--output','json'))  # will throw on failure
  $text = ($res.Output | Out-String).Trim()

  # If Azure CLI ever leaks warnings, strip until first JSON char
  $i1 = $text.IndexOf('{')
  $i2 = $text.IndexOf('[')
  $start = if ($i1 -ge 0 -and $i2 -ge 0) { [Math]::Min($i1,$i2) } elseif ($i1 -ge 0) { $i1 } else { $i2 }
  if ($start -gt 0) { $text = $text.Substring($start).Trim() }

  try {
    return $text | ConvertFrom-Json
  } catch {
    $preview = $text.Substring(0, [Math]::Min(300, $text.Length))
    throw "Expected JSON from Azure CLI, but got:`n$preview"
  }
}
function New-RandomStorageAccountName([string]$prefix='stfnzpoc', [int]$suffixLen=6) {
  $chars = ('a'..'z') + ('0'..'9')
  $suffix = -join (1..$suffixLen | ForEach-Object { $chars | Get-Random })
  $name = ($prefix + $suffix).ToLower()
  if ($name.Length -gt 24) { $name = $name.Substring(0,24) }
  return $name
}
function Set-RoleAssignment([string]$PrincipalId, [string]$RoleName, [string]$Scope) {
  # Idempotent: check if assignment exists
  $existing = Invoke-Az @('role','assignment','list','--assignee-object-id',$PrincipalId,'--scope',$Scope,'--query',"length([?roleDefinitionName=='$RoleName'])") -AllowFailure
  $countText = (($existing.Output | Out-String).Trim() -replace '"','')
  [int]$count = 0
  [void][int]::TryParse($countText, [ref]$count)

  if ($count -eq 0) {
    Invoke-Az @('role','assignment','create',
      '--assignee-object-id',$PrincipalId,
      '--assignee-principal-type','ServicePrincipal',
      '--role',$RoleName,
      '--scope',$Scope
    ) | Out-Null
  }
}

# -------------------------
# Pre-flight
# -------------------------
if (-not (Test-CommandAvailable 'az')) {
  throw "Required command 'az' not found in PATH."
}

# Confirm az account context is valid
$acct = Invoke-AzJson @('account','show')
$SubscriptionId = $acct.id
$TenantId       = $acct.tenantId

Write-Host "Subscription: $SubscriptionId"
Write-Host "Tenant:       $TenantId"
Write-Host "Location:     $Location"

# Decide storage account name
$TfstateSa = if ([string]::IsNullOrWhiteSpace($TfstateSaName)) { New-RandomStorageAccountName } else { $TfstateSaName.ToLower() }
Write-Host "TFSTATE Storage Account: $TfstateSa"

# Script dir + output env file
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutEnvPs1  = Join-Path $ScriptDir 'output.local.env.ps1'

# -------------------------
# 1) Backend RG + Storage Account
# -------------------------
Write-Host "`n== Backend RG / Storage =="

Invoke-Az @('group','create','-n',$BootstrapRg,'-l',$Location) | Out-Null

# Does SA exist?
$saShow = Invoke-Az @('storage','account','show','-g',$BootstrapRg,'-n',$TfstateSa,'-o','none') -AllowFailure
$saExists = ($saShow.ExitCode -eq 0)

if (-not $saExists) {
  Write-Host "Creating storage account: $TfstateSa"
  Invoke-Az @(
    'storage','account','create',
    '-g',$BootstrapRg,
    '-n',$TfstateSa,
    '-l',$Location,
    '--sku','Standard_LRS',
    '--kind','StorageV2',
    '--min-tls-version','TLS1_2',
    '--allow-blob-public-access','false'
  ) | Out-Null
} else {
  Write-Host "Storage account already exists: $TfstateSa"
}

# -------------------------
# 2) Container (try data plane, then fallback to ARM)
# -------------------------
Write-Host "`n== TFSTATE Container =="

$containerCreated = $false
try {
  Invoke-Az @(
    'storage','container','create',
    '--name',$TfstateContainer,
    '--account-name',$TfstateSa,
    '--auth-mode','login'
  ) | Out-Null
  $containerCreated = $true
} catch {
  Write-Host "Data-plane container create failed (often DNS/proxy). Trying ARM fallback..."
}

if (-not $containerCreated) {
  # ARM fallback: PUT container resource
  $saId = ((Invoke-Az @('storage','account','show','-g',$BootstrapRg,'-n',$TfstateSa,'--query','id','-o','tsv')).Output | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($saId)) {
    throw "Could not resolve storage account resource ID via ARM."
  }

  $url = "https://management.azure.com$saId/blobServices/default/containers/$TfstateContainer?api-version=2023-01-01"
  Invoke-Az @(
    'rest','--method','put',
    '--url',$url,
    '--body','{"properties":{"publicAccess":"None"}}'
  ) | Out-Null
  $containerCreated = $true
}

Write-Host "Container ensured: $TfstateContainer"

# -------------------------
# 3) Workload RG + UAMI
# -------------------------
Write-Host "`n== Workload RG / UAMI =="

Invoke-Az @('group','create','-n',$WorkloadRg,'-l',$Location) | Out-Null

$uami = Invoke-AzJson @('identity','create','-g',$WorkloadRg,'-n',$UamiName,'-l',$Location)
$UamiClientId    = $uami.clientId
$UamiPrincipalId = $uami.principalId
$UamiResourceId  = $uami.id

Write-Host "UAMI name:      $UamiName"
Write-Host "UAMI clientId:  $UamiClientId"
Write-Host "UAMI principal: $UamiPrincipalId"

# -------------------------
# 4) RBAC
# -------------------------
Write-Host "`n== RBAC Assignments =="

$WorkloadRgId = ((Invoke-Az @('group','show','-n',$WorkloadRg,'--query','id','-o','tsv')).Output | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($WorkloadRgId)) { throw "Could not resolve workload RG ID." }

# Contributor on workload RG
Set-RoleAssignment -PrincipalId $UamiPrincipalId -RoleName 'Contributor' -Scope $WorkloadRgId
Write-Host "RBAC OK: Contributor on $WorkloadRg"

# Storage Blob Data Contributor on container scope
$TfstateContainerScope = "/subscriptions/$SubscriptionId/resourceGroups/$BootstrapRg/providers/Microsoft.Storage/storageAccounts/$TfstateSa/blobServices/default/containers/$TfstateContainer"
Set-RoleAssignment -PrincipalId $UamiPrincipalId -RoleName 'Storage Blob Data Contributor' -Scope $TfstateContainerScope
Write-Host "RBAC OK: Storage Blob Data Contributor on tfstate container"

# -------------------------
# 5) Write output.local.env.ps1
# -------------------------
Write-Host "`n== Writing $OutEnvPs1 =="

@"
# Generated by bootstrap.ps1 - DO NOT COMMIT
# Load with: . `"$OutEnvPs1`"

# Azure context
`$env:ARM_SUBSCRIPTION_ID = "$SubscriptionId"
`$env:ARM_TENANT_ID       = "$TenantId"

# Terraform backend (azurerm)
`$env:TFSTATE_RESOURCE_GROUP  = "$BootstrapRg"
`$env:TFSTATE_STORAGE_ACCOUNT = "$TfstateSa"
`$env:TFSTATE_CONTAINER       = "$TfstateContainer"
`$env:TFSTATE_KEY             = "$TfstateKey"

# Defaults
`$env:TF_LOCATION             = "$Location"
`$env:TF_WORKLOAD_RG          = "$WorkloadRg"

# UAMI for later pipelines / automation
`$env:TF_UAMI_NAME            = "$UamiName"
`$env:TF_UAMI_CLIENT_ID       = "$UamiClientId"
`$env:TF_UAMI_PRINCIPAL_ID    = "$UamiPrincipalId"
`$env:TF_UAMI_RESOURCE_ID     = "$UamiResourceId"

"@ | Set-Content -Path $OutEnvPs1 -Encoding UTF8

Write-Host "`nBootstrap complete."
Write-Host "Next:"
Write-Host "  1) Load env:  . `"$OutEnvPs1`""