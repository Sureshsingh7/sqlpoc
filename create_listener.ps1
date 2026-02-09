$sqlDual = @'
USE master;
ALTER AVAILABILITY GROUP [poc-ha-AG]
ADD LISTENER 'poc-ha-listener' (
    WITH IP (
        ('10.10.0.6', '255.255.255.192'),
        ('10.10.0.68', '255.255.255.192')
    ),
    PORT = 1433
);
'@

$sqlSingle = @'
USE master;
ALTER AVAILABILITY GROUP [poc-ha-AG]
ADD LISTENER 'poc-ha-listener' (
    WITH IP (('10.10.0.6', '255.255.255.192')),
    PORT = 1433
);
'@

Write-Host "Attempting to create listener with dual IPs..."
try {
    Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate -Query $sqlDual -QueryTimeout 120 -ErrorAction Stop
    Write-Host "SUCCESS: Listener created with both IPs"
    exit 0
} catch {
    Write-Host "Dual IP failed: $_"
    Write-Host "Attempting single IP..."
    try {
        Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate -Query $sqlSingle -QueryTimeout 120 -ErrorAction Stop
        Write-Host "SUCCESS: Listener created with single IP"
        exit 0
    } catch {
        Write-Host "ERROR: Both methods failed: $_"
        exit 1
    }
}
