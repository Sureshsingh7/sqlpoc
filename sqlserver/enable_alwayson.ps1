param(
  [Parameter(Mandatory=$false)][string]$SqlInstance = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

function Ensure-SqlServerModule {
  try {
    Import-Module SqlServer -ErrorAction Stop
    return
  } catch {
    # try install if missing
  }

  try {
    $null = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $?) {
      Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    }
  } catch {
    # best effort
  }

  try {
    # PSGallery sometimes defaults to Untrusted
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
  } catch {
    # best effort
  }

  Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers
  Import-Module SqlServer -ErrorAction Stop
}

function Get-IsHadrEnabled {
  param([string]$Instance)
  try {
    $r = Invoke-Sqlcmd -ServerInstance $Instance -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled" -QueryTimeout 30
    return [int]$r.IsHadrEnabled
  } catch {
    return -1
  }
}

# Ensure SQL service is up before we query it
try {
  $svc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne 'Running') {
    Start-Service -Name MSSQLSERVER
    Start-Sleep -Seconds 10
  }
} catch {
  # best effort
}

Ensure-SqlServerModule

$before = Get-IsHadrEnabled -Instance $SqlInstance
Write-Host "IsHadrEnabled(before)=$before"

if ($before -eq 1) {
  Write-Host 'Always On is already enabled.'
  exit 0
}

Write-Host "Enabling Always On Availability Groups on instance: $SqlInstance"
Enable-SqlAlwaysOn -ServerInstance $SqlInstance -Force

Start-Sleep -Seconds 10
$after = Get-IsHadrEnabled -Instance $SqlInstance
Write-Host "IsHadrEnabled(after)=$after"

if ($after -ne 1) {
  throw "Always On did not report enabled after Enable-SqlAlwaysOn (IsHadrEnabled=$after)."
}

Write-Host 'Always On enabled successfully.'
