param(
    [Parameter(Mandatory=$true)]
    [string]$AGName,

    [Parameter(Mandatory=$true)]
    [string]$ListenerName,

    [Parameter(Mandatory=$true)]
    [string[]]$ListenerIPs,

    [Parameter(Mandatory=$true)]
    [string]$PrimaryReplica,

    [Parameter(Mandatory=$true)]
    [string[]]$SecondaryReplicas,

    [Parameter(Mandatory=$false)]
    [int]$ListenerPort = 1433,

    [Parameter(Mandatory=$false)]
    [int]$ProbePort = 59999
)

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\create-availability-group.log'
$sentinel = 'C:\Windows\Temp\.ag-setup-completed'

function L([string]$m) { 
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] $m"
    Add-Content -Path $log -Value $msg
    Write-Host $msg
}

function LE([string]$m) { 
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] $m"
    Add-Content -Path $log -Value $msg
    Write-Error $msg
}

# Check if already completed
if (Test-Path $sentinel) {
    L "AG setup already completed - exiting"
    exit 0
}

try {
    L "Starting Availability Group creation"
    L "AG Name: $AGName"
    L "Listener: $ListenerName"
    L "Listener IPs: $($ListenerIPs -join ', ')"
    L "Primary: $PrimaryReplica"
    L "Secondaries: $($SecondaryReplicas -join ', ')"

    # Check if this is the primary replica
    $currentNode = $env:COMPUTERNAME
    if ($currentNode -ne $PrimaryReplica) {
        L "This is not the primary replica ($PrimaryReplica), skipping AG creation"
        New-Item -Path $sentinel -ItemType File -Force | Out-Null
        exit 0
    }

    L "This is the primary replica - proceeding with AG creation"

    # Import SQL Server module
    L "Importing SQL Server PowerShell module..."
    Import-Module SqlServer -ErrorAction Stop

    # Check if Always On is enabled
    $hadrEnabled = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -ServerInstance $currentNode
    if ($hadrEnabled.IsEnabled -ne 1) {
        LE "Always On is not enabled on $currentNode"
        exit 1
    }
    L "Always On is enabled"

    # Check if AG already exists
    $existingAG = Invoke-Sqlcmd -Query "SELECT name FROM sys.availability_groups WHERE name = '$AGName'" -ServerInstance $currentNode -ErrorAction SilentlyContinue
    if ($existingAG) {
        L "Availability Group '$AGName' already exists"
        New-Item -Path $sentinel -ItemType File -Force | Out-Null
        exit 0
    }

    # Create test database if it doesn't exist
    $dbName = "TestDB"
    L "Creating test database '$dbName'..."
    $dbExists = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE name = '$dbName'" -ServerInstance $currentNode
    if (-not $dbExists) {
        Invoke-Sqlcmd -Query "CREATE DATABASE [$dbName]" -ServerInstance $currentNode
        Invoke-Sqlcmd -Query "ALTER DATABASE [$dbName] SET RECOVERY FULL" -ServerInstance $currentNode
        Invoke-Sqlcmd -Query "BACKUP DATABASE [$dbName] TO DISK = 'NUL'" -ServerInstance $currentNode
        L "Database created and backed up"
    } else {
        L "Database already exists"
    }

    # Create Availability Group
    L "Creating Availability Group '$AGName'..."
    
    $createAGSQL = @"
CREATE AVAILABILITY GROUP [$AGName]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, DTC_SUPPORT = NONE)
FOR DATABASE [$dbName]
REPLICA ON 
"@

    # Add primary replica
    $createAGSQL += @"
N'$PrimaryReplica' WITH (
    ENDPOINT_URL = N'TCP://${PrimaryReplica}:5022',
    FAILOVER_MODE = AUTOMATIC,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY = 50,
    SEEDING_MODE = AUTOMATIC,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
)
"@

    # Add secondary replicas
    foreach ($secondary in $SecondaryReplicas) {
        $createAGSQL += @"
,
N'$secondary' WITH (
    ENDPOINT_URL = N'TCP://${secondary}:5022',
    FAILOVER_MODE = AUTOMATIC,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY = 50,
    SEEDING_MODE = AUTOMATIC,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
)
"@
    }

    Invoke-Sqlcmd -Query $createAGSQL -ServerInstance $currentNode
    L "Availability Group created"

    # Wait for secondaries to join
    foreach ($secondary in $SecondaryReplicas) {
        L "Waiting for $secondary to join AG..."
        $timeout = 60
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            try {
                Invoke-Sqlcmd -Query "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE" -ServerInstance $secondary -ErrorAction Stop
                L "$secondary joined successfully"
                break
            } catch {
                Start-Sleep -Seconds 5
                $elapsed += 5
            }
        }
    }

    # Create Listener
    L "Creating AG Listener '$ListenerName'..."
    $listenerSQL = "ALTER AVAILABILITY GROUP [$AGName] ADD LISTENER N'$ListenerName' (WITH IP ("

    $ipParts = @()
    foreach ($ip in $ListenerIPs) {
        $ipParts += "(N'$ip', N'255.255.255.255')"
    }
    $listenerSQL += $ipParts -join ", "
    $listenerSQL += "), PORT=$ListenerPort)"

    Invoke-Sqlcmd -Query $listenerSQL -ServerInstance $currentNode
    L "Listener created"

    # Wait for listener resources to appear in cluster
    L "Waiting for cluster resources..."
    Start-Sleep -Seconds 10

    # Configure probe port on listener IPs
    L "Configuring Azure Load Balancer probe port..."
    Import-Module FailoverClusters
    
    $ipResources = Get-ClusterResource | Where-Object { 
        $_.ResourceType -eq 'IP Address' -and $_.OwnerGroup -like "*$AGName*"
    }

    foreach ($ipResource in $ipResources) {
        $network = ($ipResource | Get-ClusterParameter -Name Network).Value
        $address = ($ipResource | Get-ClusterParameter -Name Address).Value
        L "Configuring IP resource: $($ipResource.Name) ($address)"
        
        $ipResource | Set-ClusterParameter -Multiple @{
            "ProbePort" = $ProbePort
            "SubnetMask" = "255.255.255.255"
            "Network" = $network
            "OverrideAddressMatch" = 1
            "EnableDhcp" = 0
        }
    }

    # Restart listener to apply probe port
    L "Restarting listener resources..."
    $listenerResource = Get-ClusterResource | Where-Object { 
        $_.ResourceType -eq 'Network Name' -and $_.Name -like "*$ListenerName*"
    }
    
    if ($listenerResource) {
        Stop-ClusterResource $listenerResource.Name
        Start-ClusterResource $listenerResource.Name
        L "Listener restarted"
    }

    L "Availability Group setup completed successfully"
    New-Item -Path $sentinel -ItemType File -Force | Out-Null

} catch {
    LE "Error creating Availability Group: $_"
    $_ | Out-File "C:\Windows\Temp\create-availability-group.err.txt" -Force
    exit 1
}
