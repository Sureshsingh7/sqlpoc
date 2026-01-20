Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "SqlInstance: $SqlInstance"
Get-Service *MSSQL* | Select Name,Status | Format-Table -Auto

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
  function Invoke-WithTimeout {
    param(
      [scriptblock]$Script,
      [int]$TimeoutSeconds = 300,
      [string]$Description = "operation"
    )

    $job = Start-Job -ScriptBlock $Script
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
      Stop-Job -Job $job -Force | Out-Null
      Remove-Job -Job $job -Force | Out-Null
      throw "Timed out during $Description after ${TimeoutSeconds}s."
    }
    $result = Receive-Job -Job $job -ErrorAction Stop
    Remove-Job -Job $job -Force | Out-Null
    return $result
  }

  try {
    Write-Log "Trying Import-Module SqlServer"
    Invoke-WithTimeout -TimeoutSeconds 120 -Description "Import-Module SqlServer" -Script { Import-Module SqlServer -ErrorAction Stop }
    Write-Log "SqlServer module already available"
    return
  } catch {
    # try install if missing
  }

  # Fallback to legacy SQLPS if present (often installed with SQL Server)
  try {
    Write-Log "SqlServer module not available; trying SQLPS"
    Invoke-WithTimeout -TimeoutSeconds 120 -Description "Import-Module SQLPS" -Script { Import-Module SQLPS -DisableNameChecking -ErrorAction Stop }
    Write-Log "SQLPS module imported"
    return
  } catch {
    # continue to install SqlServer module
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
  Invoke-WithTimeout -TimeoutSeconds 600 -Description "Install-Module SqlServer" -Script { Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers -ErrorAction Stop }
  Invoke-WithTimeout -TimeoutSeconds 120 -Description "Import-Module SqlServer" -Script { Import-Module SqlServer -ErrorAction Stop }
  Write-Log "SqlServer module installed and imported"
}

function Get-IsHadrEnabled {
  param([string]$Instance)
  try {
    $r = Invoke-Sqlcmd -ServerInstance $Instance -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled" -QueryTimeout 30
    return [int]$r.IsHadrEnabled
  } catch {
      Write-Host "Invoke-Sqlcmd failed: $($_.Exception.Message)"
      throw
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
