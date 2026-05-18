# Post-Deployment Validation Script
# Validates that SQL Server Always On HA deployment is healthy

param(
    [string]$ResourceGroup = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    [string[]]$Nodes = @("poc-ha-sql-01", "poc-ha-sql-02")
)

$ErrorActionPreference = 'Continue'

Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  SQL Server HA Deployment Validation  ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════╝`n" -ForegroundColor Cyan

$allPassed = $true

# Validate each node
foreach ($node in $Nodes) {
    Write-Host "`n┌─ Validating $node " -NoNewline -ForegroundColor Yellow
    Write-Host ("─" * (50 - $node.Length)) -ForegroundColor Yellow

    try {
        $result = az vm run-command invoke `
            --resource-group $ResourceGroup `
            --name $node `
            --command-id RunPowerShellScript `
            --scripts @"
`$results = @{}

# 1. Cluster Access
`$access = Get-ClusterAccess -ErrorAction SilentlyContinue | Where-Object { `$_.IdentityReference -eq 'NT SERVICE\MSSQLSERVER' }
`$results['ClusterAccess'] = if (`$access) { 'PASS' } else { 'FAIL' }

# 2. Cluster Visibility
`$cluster = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT cluster_name FROM sys.dm_hadr_cluster" 2>&1
`$results['ClusterVisible'] = if (`$cluster -match 'sqlpoc') { 'PASS' } else { 'FAIL' }

# 3. HADR Enabled
`$hadr = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS VARCHAR)" 2>&1
`$results['HadrEnabled'] = if (`$hadr -match '^\s*1\s*$') { 'PASS' } else { 'FAIL' }

# 4. Endpoint Count
`$ep = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.endpoints WHERE type_desc='DATABASE_MIRRORING'" 2>&1
`$results['Endpoint'] = if (`$ep -match '^\s*1\s*$') { 'PASS' } else { 'FAIL' }

# 5. Certificate Count
`$certs = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.certificates WHERE name LIKE '%HADR%'" 2>&1
`$results['Certificates'] = if (`$certs -match '^\s*2\s*$') { 'PASS' } else { 'FAIL' }

# Output results
foreach (`$key in `$results.Keys | Sort-Object) {
    Write-Host "`$key=`$(`$results[`$key])"
}
"@ --query "value[0].message" -o tsv 2>$null

        # Parse results
        $checks = @{
            'ClusterAccess' = $false
            'ClusterVisible' = $false
            'HadrEnabled' = $false
            'Endpoint' = $false
            'Certificates' = $false
        }

        foreach ($line in $result -split "`n") {
            if ($line -match '^(\w+)=(PASS|FAIL)') {
                $checkName = $matches[1]
                $passed = $matches[2] -eq 'PASS'
                $checks[$checkName] = $passed

                $icon = if ($passed) { '✓' } else { '✗'; $allPassed = $false }
                $color = if ($passed) { 'Green' } else { 'Red' }
                Write-Host "  $icon $checkName" -ForegroundColor $color
            }
        }

    } catch {
        Write-Host "  ✗ Failed to validate $node : $_" -ForegroundColor Red
        $allPassed = $false
    }
}

# Validate Availability Group
Write-Host "`n┌─ Availability Group Status " -NoNewline -ForegroundColor Yellow
Write-Host ("─" * 26) -ForegroundColor Yellow

try {
    $agResult = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $Nodes[0] `
        --command-id RunPowerShellScript `
        --scripts @"
`$ag = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_groups" 2>&1
if (`$ag -match '^\s*1\s*$') {
    Write-Host 'AGExists=PASS'

    `$replicas = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_replicas" 2>&1
    if (`$replicas -match '^\s*2\s*$') {
        Write-Host 'Replicas=PASS'
    } else {
        Write-Host 'Replicas=FAIL'
    }

    `$listener = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_group_listeners" 2>&1
    if (`$listener -match '^\s*1\s*$') {
        Write-Host 'Listener=PASS'
    } else {
        Write-Host 'Listener=FAIL'
    }
} else {
    Write-Host 'AGExists=FAIL'
}
"@ --query "value[0].message" -o tsv 2>$null

    foreach ($line in $agResult -split "`n") {
        if ($line -match '^(\w+)=(PASS|FAIL)') {
            $checkName = $matches[1]
            $passed = $matches[2] -eq 'PASS'

            $icon = if ($passed) { '✓' } else { '✗'; $allPassed = $false }
            $color = if ($passed) { 'Green' } else { 'Red' }
            Write-Host "  $icon $checkName" -ForegroundColor $color
        }
    }

} catch {
    Write-Host "  ✗ Failed to validate AG: $_" -ForegroundColor Red
    $allPassed = $false
}

# Summary
Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "║   ✓ ALL VALIDATION CHECKS PASSED      ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════╝`n" -ForegroundColor Cyan
    Write-Host "Deployment is HEALTHY and ready for use.`n" -ForegroundColor Green
    exit 0
} else {
    Write-Host "║   ✗ VALIDATION FAILED                  ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════╝`n" -ForegroundColor Cyan
    Write-Host "Check logs on VMs for details:`n" -ForegroundColor Yellow
    Write-Host "  C:\Windows\Temp\create-failover-cluster.log" -ForegroundColor Gray
    Write-Host "  C:\Windows\Temp\configure-hadr-endpoints.log" -ForegroundColor Gray
    Write-Host "  C:\Windows\Temp\create-availability-group.log`n" -ForegroundColor Gray
    exit 1
}
