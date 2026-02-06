# Quick verification of HADR endpoint status
Write-Host "=== HADR Verification on $env:COMPUTERNAME ==="

Write-Host "`n1. Cluster visibility:"
$cluster = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT cluster_name FROM sys.dm_hadr_cluster" 2>&1
if ($cluster -match "sqlpoc") {
    Write-Host "   ✓ Cluster visible: $cluster"
} else {
    Write-Host "   ✗ Cluster NOT visible"
}

Write-Host "`n2. HADR Endpoints:"
$epCount = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.endpoints WHERE type_desc='DATABASE_MIRRORING'" 2>&1
Write-Host "   Endpoint count: $epCount"

if ($epCount -match "^\s*1\s*$") {
    $epDetail = & sqlcmd -E -C -Q "SELECT name, state_desc FROM sys.endpoints WHERE type_desc='DATABASE_MIRRORING'" 2>&1
    Write-Host "   Endpoint details:"
    Write-Host $epDetail
} else {
    Write-Host "   ✗ No HADR endpoint found!"
}

Write-Host "`n3. SQL Certificates:"
$certCount = & sqlcmd -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.certificates WHERE name LIKE '%HADR%'" 2>&1
Write-Host "   Certificate count: $certCount"

if ($certCount -match "^\s*[2-9]\s*$") {
    Write-Host "   ✓ Certificates present"
} else {
    Write-Host "   ✗ Missing certificates!"
}

Write-Host "`n4. Sentinel files:"
if (Test-Path 'C:\Windows\Temp\.hadr-endpoint-configured') {
    Write-Host "   ✓ HADR sentinel exists"
} else {
    Write-Host "   ✗ HADR sentinel missing"
}

Write-Host "`n=== Verification Complete ==="
