<#
.SYNOPSIS
    Quick DAG replication smoke-test.
    Writes a tiny transaction on the global primary and verifies it flows to DR nodes.

.DESCRIPTION
    1) Creates a small test table (idempotent) on the primary AG database.
    2) INSERTs a uniquely-tagged row with a UTC timestamp.
    3) Polls each DR node until the row appears or a timeout is reached.

.NOTES
    Prerequisite: Install-Module -Name SqlServer -Force -AllowClobber -Scope CurrentUser

.EXAMPLE
    .\Validate-DAG-Replication.ps1 -PrimaryNode "poc-ha-sql-01" -DRNodes "poc-ha-dr-sql-01","poc-ha-dr-sql-02"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PrimaryNode,

    [Parameter(Mandatory)]
    [string[]]$DRNodes,

    [string]$DatabaseName = "TestDB",

    [string]$SqlUser = "sqladmin",

    [Parameter(Mandatory)]
    [string]$PrimarySqlPassword,

    [Parameter(Mandatory)]
    [string]$DrSqlPassword,

    [int]$TimeoutSeconds = 60,

    [int]$PollIntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── helpers ──────────────────────────────────────────────────────────
function Invoke-Sql {
    param(
        [string]$Server,
        [string]$Query,
        [string]$Password,
        [string]$Database = $script:DatabaseName,
        [int]$Timeout = 15
    )
    Write-Verbose "Invoke-Sql: Server=$Server Database=$Database User=$($script:SqlUser)"
    Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $Query `
        -Username $script:SqlUser -Password $Password `
        -TrustServerCertificate -QueryTimeout $Timeout -ErrorAction Stop
}

# ── 1. write marker on primary ──────────────────────────────────────
$marker = "DAG_CHECK_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$([guid]::NewGuid().ToString('N').Substring(0,8))"
Write-Host "`n=== DAG Replication Smoke-Test ===" -ForegroundColor Cyan
Write-Host "Primary  : $PrimaryNode"
Write-Host "DR nodes : $($DRNodes -join ', ')"
Write-Host "Database : $DatabaseName"
Write-Host "Marker   : $marker`n"

$setupSql = @"
IF OBJECT_ID('dbo.DagHealthCheck','U') IS NULL
BEGIN
    CREATE TABLE dbo.DagHealthCheck (
        Id         INT IDENTITY(1,1) PRIMARY KEY,
        Marker     NVARCHAR(120)  NOT NULL,
        CreatedUtc DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
END;
"@

Write-Host "[PRIMARY] Ensuring DagHealthCheck table exists..." -ForegroundColor Yellow
Invoke-Sql -Server $PrimaryNode -Query $setupSql -Password $PrimarySqlPassword

$insertSql = "INSERT INTO dbo.DagHealthCheck (Marker) VALUES (N'$marker');"
Write-Host "[PRIMARY] Inserting marker row..." -ForegroundColor Yellow
Invoke-Sql -Server $PrimaryNode -Query $insertSql -Password $PrimarySqlPassword
Write-Host "[PRIMARY] Marker written at $(Get-Date -Format 'HH:mm:ss') UTC`n" -ForegroundColor Green

# ── 2. poll DR nodes ────────────────────────────────────────────────
$checkSql = "SET NOCOUNT ON; SELECT Marker, CreatedUtc FROM dbo.DagHealthCheck WHERE Marker = N'$marker';"

$results = @{}
foreach ($dr in $DRNodes) { $results[$dr] = $false }

$sw = [System.Diagnostics.Stopwatch]::StartNew()

while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    foreach ($dr in $DRNodes) {
        if ($results[$dr]) { continue }
        try {
            $row = Invoke-Sql -Server $dr -Query $checkSql -Password $DrSqlPassword
            if ($row -and $row.Marker -eq $marker) {
                $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Write-Host "[DR] $dr  -> marker replicated in ${elapsed}s" -ForegroundColor Green
                $results[$dr] = $true
            }
        } catch {
            $errMsg = $_.Exception.Message
            if (-not $results.ContainsKey("${dr}_lastErr") -or $results["${dr}_lastErr"] -ne $errMsg) {
                Write-Host "[DR] $dr  -> error: $errMsg" -ForegroundColor DarkYellow
                $results["${dr}_lastErr"] = $errMsg
            }
        }
    }

    if ($results.Values -notcontains $false) { break }
    Start-Sleep -Seconds $PollIntervalSeconds
}

# ── 3. summary ──────────────────────────────────────────────────────
Write-Host "`n=== Results ===" -ForegroundColor Cyan
$allOk = $true
foreach ($dr in $DRNodes) {
    if ($results[$dr]) {
        Write-Host "  [PASS] $dr" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $dr  (marker not seen within ${TimeoutSeconds}s)" -ForegroundColor Red
        $allOk = $false
    }
}

if ($allOk) {
    Write-Host "`nDAG replication OK — data flowed from primary to all DR nodes.`n" -ForegroundColor Green
} else {
    Write-Host "`nDAG replication ISSUE — check synchronization state on failed nodes.`n" -ForegroundColor Red
    Write-Host "Troubleshooting queries (run on a DR node):"
    Write-Host @"
  -- replica & DAG health
  SELECT ag.name, rs.role_desc, rs.synchronization_health_desc
  FROM sys.dm_hadr_availability_replica_states rs
  JOIN sys.availability_replicas r ON rs.replica_id = r.replica_id
  JOIN sys.availability_groups ag ON rs.group_id = ag.group_id;

  -- database-level sync state
  SELECT d.name, drs.synchronization_state_desc, drs.log_send_queue_size
  FROM sys.dm_hadr_database_replica_states drs
  JOIN sys.databases d ON drs.database_id = d.database_id;
"@
    exit 1
}
