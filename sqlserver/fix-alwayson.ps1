Import-Module SqlServer -DisableNameChecking
Write-Output "Step1: Current status"
$b = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS H, SERVERPROPERTY('IsClustered') AS C" -ServerInstance localhost -TrustServerCertificate
Write-Output "  Hadr=$($b.H) Clustered=$($b.C)"

Write-Output "Step2: Disabling AlwaysOn..."
Disable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force
Start-Sleep -Seconds 10

Write-Output "Step3: Re-enabling AlwaysOn..."
Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force
Start-Sleep -Seconds 10

Write-Output "Step4: Verifying..."
$a = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS H, SERVERPROPERTY('IsClustered') AS C" -ServerInstance localhost -TrustServerCertificate
Write-Output "  Hadr=$($a.H) Clustered=$($a.C)"

$cp = Invoke-Sqlcmd -Query "SELECT cluster_name, quorum_type_desc FROM sys.dm_os_cluster_properties" -ServerInstance localhost -TrustServerCertificate -ErrorAction SilentlyContinue
if ($cp) { Write-Output "  Cluster=$($cp.cluster_name) Quorum=$($cp.quorum_type_desc)" } else { Write-Output "  dm_os_cluster_properties: STILL EMPTY" }

Write-Output "Step5: Test AG creation..."
try {
    Invoke-Sqlcmd -Query "CREATE AVAILABILITY GROUP [test_ag] WITH (CLUSTER_TYPE = WSFC) FOR REPLICA ON N'$($env:COMPUTERNAME)' WITH (ENDPOINT_URL = N'TCP://$($env:COMPUTERNAME).sqlpoc.local:5022', FAILOVER_MODE = MANUAL, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, SEEDING_MODE = AUTOMATIC)" -ServerInstance localhost -TrustServerCertificate -QueryTimeout 30
    Write-Output "  test_ag CREATED with WSFC!"
    Invoke-Sqlcmd -Query "DROP AVAILABILITY GROUP [test_ag]" -ServerInstance localhost -TrustServerCertificate
    Write-Output "  test_ag dropped"
} catch {
    Write-Output "  WSFC AG failed: $($_.Exception.Message)"
    Write-Output "  Trying CLUSTER_TYPE=NONE..."
    try {
        Invoke-Sqlcmd -Query "CREATE AVAILABILITY GROUP [test_ag] WITH (CLUSTER_TYPE = NONE) FOR REPLICA ON N'$($env:COMPUTERNAME)' WITH (ENDPOINT_URL = N'TCP://$($env:COMPUTERNAME).sqlpoc.local:5022', FAILOVER_MODE = MANUAL, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, SEEDING_MODE = AUTOMATIC)" -ServerInstance localhost -TrustServerCertificate -QueryTimeout 30
        Write-Output "  test_ag CREATED with NONE!"
        Invoke-Sqlcmd -Query "DROP AVAILABILITY GROUP [test_ag]" -ServerInstance localhost -TrustServerCertificate
        Write-Output "  test_ag dropped"
    } catch {
        Write-Output "  NONE AG failed: $($_.Exception.Message)"
    }
}
