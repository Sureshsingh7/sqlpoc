param(
  [Parameter(Mandatory=$false)][string]$SqlInstance = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logPath = 'C:\Windows\Temp\enable-alwayson.log'
function Write-Log {
  param([string]$Message)
  $ts = (Get-Date).ToString('o')
  $line = "$ts $Message"
  $line | Out-File -FilePath $logPath -Append -Encoding utf8
  Write-Host $line
}

Write-Log "Starting enable_alwayson.ps1 for instance: $SqlInstance"

# Ensure TLS 1.2 for PSGallery downloads
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
  Write-Log "Failed to set TLS 1.2: $($_.Exception.Message)"
}

function Ensure-SqlServerModule {
  try {
    Import-Module SqlServer -ErrorAction Stop
    Write-Log "SqlServer module already available"
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

  Write-Log "Installing SqlServer module from PSGallery..."
  Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
  Import-Module SqlServer -ErrorAction Stop
  Write-Log "SqlServer module installed and imported"
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

function Wait-SqlReady {
  param([string]$Instance)
  for ($i = 1; $i -le 30; $i++) {
    $state = Get-IsHadrEnabled -Instance $Instance
    if ($state -ne -1) {
      Write-Log "SQL responded to query (attempt $i/30)."
      return $true
    }
    Start-Sleep -Seconds 10
  }
  Write-Log "SQL did not respond after waiting ~5 minutes."
  return $false
}

# Ensure SQL service is up before we query it
try {
  $svc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne 'Running') {
    Write-Log "Starting MSSQLSERVER service..."
    Start-Service -Name MSSQLSERVER
    Start-Sleep -Seconds 10
  }
} catch {
  # best effort
}

Ensure-SqlServerModule

if (-not (Wait-SqlReady -Instance $SqlInstance)) {
  throw "SQL Server did not become ready in time."
}

$before = Get-IsHadrEnabled -Instance $SqlInstance
Write-Log "IsHadrEnabled(before)=$before"

if ($before -eq 1) {
  Write-Log 'Always On is already enabled.'
  exit 0
}

Write-Log "Enabling Always On Availability Groups on instance: $SqlInstance"
try {
  Enable-SqlAlwaysOn -ServerInstance $SqlInstance -Force
} catch {
  Write-Log "Enable-SqlAlwaysOn failed: $($_.Exception.Message)"
  throw
}

Start-Sleep -Seconds 10
$after = Get-IsHadrEnabled -Instance $SqlInstance
Write-Log "IsHadrEnabled(after)=$after"

if ($after -ne 1) {
  throw "Always On did not report enabled after Enable-SqlAlwaysOn (IsHadrEnabled=$after)."
}

Write-Log 'Always On enabled successfully.'
