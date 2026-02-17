<#
.SYNOPSIS
    Injects random data into the primary and verifies it replicates to all DR nodes.
.EXAMPLE
    .\Test-DAG-BulkReplication.ps1 -PrimaryNode "poc-ha-sql-01.sql.internal" `
        -DRNodes "poc-ha-dr-sql01.sql.internal","poc-ha-dr-sql02.sql.internal" `
        -PrimarySqlPassword 'xxx' -DrSqlPassword 'yyy'
#>
[CmdletBinding()]
param(
    [string]$PrimaryNode = "poc-ha-sql-01.sql.internal",
    [string[]]$DRNodes = @("poc-ha-dr-sql01.sql.internal","poc-ha-dr-sql02.sql.internal"),
    [string]$DatabaseName = "TestDB2",
    [string]$SqlUser = "sqladmin",
    [Parameter(Mandatory)][string]$PrimarySqlPassword,
    [Parameter(Mandatory)][string]$DrSqlPassword,
    [int]$RowCount = 500,
    [int]$TimeoutSeconds = 120,
    [int]$PollIntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Sql {
    param(
        [string]$Server, [string]$Query, [string]$Password, [int]$Timeout = 30
    )
    Invoke-Sqlcmd -ServerInstance $Server -Database $script:DatabaseName -Query $Query `
        -Username $script:SqlUser -Password $Password `
        -TrustServerCertificate -QueryTimeout $Timeout -ErrorAction Stop
}

$batchId = "BULK_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

Write-Host "`n=== DAG Bulk Replication Test ===" -ForegroundColor Cyan
Write-Host "Primary  : $PrimaryNode"
Write-Host "DR nodes : $($DRNodes -join ', ')"
Write-Host "Database : $DatabaseName"
Write-Host "Batch    : $batchId"
Write-Host "Rows     : $RowCount`n"

# ── 1. Create table + insert random data on primary ─────────────────
$setupSql = @"
IF OBJECT_ID('dbo.BulkReplicationTest','U') IS NULL
CREATE TABLE dbo.BulkReplicationTest (
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    BatchId     NVARCHAR(60)   NOT NULL,
    RowNum      INT            NOT NULL,
    RandomValue UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    Amount      DECIMAL(18,2)  NOT NULL,
    Label       NVARCHAR(100)  NOT NULL,
    CreatedUtc  DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
);
"@

Write-Host "[PRIMARY] Creating BulkReplicationTest table..." -ForegroundColor Yellow
Invoke-Sql -Server $PrimaryNode -Query $setupSql -Password $PrimarySqlPassword

# Insert in batches of 100 for efficiency
$inserted = 0
while ($inserted -lt $RowCount) {
    $batchSize = [Math]::Min(100, $RowCount - $inserted)
    $valueRows = 1..$batchSize | ForEach-Object {
        $num = $inserted + $_
        $amount = [Math]::Round((Get-Random -Minimum 1 -Maximum 100000) / 100.0, 2)
        $label = "Item_$($num)_$(([guid]::NewGuid().ToString('N')).Substring(0,6))"
        "(N'$batchId', $num, NEWID(), $amount, N'$label', SYSUTCDATETIME())"
    }
    $insertSql = "INSERT INTO dbo.BulkReplicationTest (BatchId, RowNum, RandomValue, Amount, Label, CreatedUtc) VALUES $($valueRows -join ",`n");"
    Invoke-Sql -Server $PrimaryNode -Query $insertSql -Password $PrimarySqlPassword
    $inserted += $batchSize
    Write-Host "[PRIMARY] Inserted $inserted / $RowCount rows..." -ForegroundColor Yellow
}

# Get checksum from primary
$checksumSql = @"
SET NOCOUNT ON;
SELECT
    COUNT(*)           AS [RowCount],
    SUM(Amount)        AS [TotalAmount],
    MIN(RowNum)        AS [MinRow],
    MAX(RowNum)        AS [MaxRow],
    CHECKSUM_AGG(CHECKSUM(BatchId, RowNum, Amount, Label)) AS [DataChecksum]
FROM dbo.BulkReplicationTest
WHERE BatchId = N'$batchId';
"@

$primaryStats = Invoke-Sql -Server $PrimaryNode -Query $checksumSql -Password $PrimarySqlPassword
Write-Host "`n[PRIMARY] Stats:" -ForegroundColor Green
Write-Host "  Rows     : $($primaryStats.RowCount)"
Write-Host "  Total $  : $($primaryStats.TotalAmount)"
Write-Host "  Checksum : $($primaryStats.DataChecksum)`n"

# ── 2. Poll DR nodes for matching data ──────────────────────────────
$results = @{}
foreach ($dr in $DRNodes) { $results[$dr] = $null }

$sw = [System.Diagnostics.Stopwatch]::StartNew()

while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    foreach ($dr in $DRNodes) {
        if ($results[$dr]) { continue }
        try {
            $drStats = Invoke-Sql -Server $dr -Query $checksumSql -Password $DrSqlPassword
            if ($drStats -and $drStats.RowCount -eq $primaryStats.RowCount -and
                $drStats.DataChecksum -eq $primaryStats.DataChecksum) {
                $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
                Write-Host "[DR] $dr  -> MATCH in ${elapsed}s (rows=$($drStats.RowCount), checksum=$($drStats.DataChecksum))" -ForegroundColor Green
                $results[$dr] = $drStats
            } elseif ($drStats -and $drStats.RowCount -gt 0) {
                Write-Host "[DR] $dr  -> partial: $($drStats.RowCount)/$($primaryStats.RowCount) rows..." -ForegroundColor DarkYellow
            }
        } catch {
            $errMsg = $_.Exception.Message
            if ($sw.Elapsed.TotalSeconds -lt 10) {
                Write-Host "[DR] $dr  -> waiting... ($($_.Exception.Message -split "`n" | Select-Object -First 1))" -ForegroundColor DarkGray
            }
        }
    }

    if (-not ($results.Values -contains $null)) { break }
    Start-Sleep -Seconds $PollIntervalSeconds
}

# ── 3. Summary ──────────────────────────────────────────────────────
Write-Host "`n=== Results ===" -ForegroundColor Cyan
$allOk = $true
foreach ($dr in $DRNodes) {
    if ($results[$dr]) {
        Write-Host "  [PASS] $dr  (rows=$($results[$dr].RowCount) checksum=$($results[$dr].DataChecksum))" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $dr" -ForegroundColor Red
        $allOk = $false
    }
}

Write-Host ""
if ($allOk) {
    Write-Host "Bulk replication OK — $RowCount rows with matching checksums on all nodes." -ForegroundColor Green
} else {
    Write-Host "Bulk replication ISSUE — not all nodes matched within ${TimeoutSeconds}s." -ForegroundColor Red
    exit 1
}
