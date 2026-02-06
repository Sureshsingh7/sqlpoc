param(
    [Parameter(Mandatory=$true)]
    [string]$AGName,

    [Parameter(Mandatory=$true)]
    [string]$ListenerName,

    [Parameter(Mandatory=$true)]
    [string]$ListenerIPs,  # Comma-separated string from Terraform

    [Parameter(Mandatory=$true)]
    [string]$PrimaryReplica,

    [Parameter(Mandatory=$true)]
    [string]$SecondaryReplicas,  # Comma-separated string from Terraform

    [Parameter(Mandatory=$false)]
    [int]$ListenerPort = 1433,

    [Parameter(Mandatory=$false)]
    [int]$ProbePort = 59999,

    [Parameter(Mandatory=$true)]
    [string]$SqlAdminUsername,

    [Parameter(Mandatory=$true)]
    [string]$SqlAdminPassword
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

function LW([string]$m) { 
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN] $m"
    Add-Content -Path $log -Value $msg
    Write-Host $msg
}

# Parse comma-separated parameters from Terraform
$ListenerIPArray = @($ListenerIPs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$SecondaryReplicaArray = @($SecondaryReplicas -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

# Check if already completed
if (Test-Path $sentinel) {
    L "AG setup already completed - exiting"
    exit 0
}

try {
    L "Starting Availability Group creation"
    L "AG Name: $AGName"
    L "Listener: $ListenerName"
    L "Listener IPs ($($ListenerIPArray.Count)): $($ListenerIPArray -join ', ')"
    L "Primary: $PrimaryReplica"
    L "Secondaries ($($SecondaryReplicaArray.Count)): $($SecondaryReplicaArray -join ', ')"

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
    $hadrEnabled = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
    if ($hadrEnabled.IsEnabled -ne 1) {
        LE "Always On is not enabled on $currentNode"
        exit 1
    }
    L "Always On is enabled"

    # Check if AG already exists
    $existingAG = Invoke-Sqlcmd -Query "SELECT name FROM sys.availability_groups WHERE name = '$AGName'" -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue
    $existingListener = $null
    $agExists = $false
    $listenerExists = $false
    
    if ($existingAG) {
        $agExists = $true
        L "Availability Group '$AGName' already exists"
        
        # Check if listener also exists
        $existingListener = Invoke-Sqlcmd -Query "SELECT dns_name FROM sys.availability_group_listeners WHERE dns_name = '$ListenerName'" -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue
        if ($existingListener) {
            $listenerExists = $true
            L "Listener '$ListenerName' already exists"
            L "AG and listener both configured - setup complete"
            New-Item -Path $sentinel -ItemType File -Force | Out-Null
            exit 0
        } else {
            L "Listener '$ListenerName' does not exist - will attempt to create it"
        }
    }
    
    # Only create AG if it doesn't exist
    if (-not $agExists) {

    # Create test database if it doesn't exist
    $dbName = "TestDB"
    L "Creating test database '$dbName'..."
    $dbExists = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE name = '$dbName'" -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
    if (-not $dbExists) {
        Invoke-Sqlcmd -Query "CREATE DATABASE [$dbName]" -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
        Invoke-Sqlcmd -Query "ALTER DATABASE [$dbName] SET RECOVERY FULL" -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
        Invoke-Sqlcmd -Query "BACKUP DATABASE [$dbName] TO DISK = 'NUL'" -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
        L "Database created and backed up"
    } else {
        L "Database already exists"
    }

    # Create Availability Group
    L "Creating Availability Group '$AGName'..."
    
    $createAGSQL = @"
CREATE AVAILABILITY GROUP [$AGName]
WITH (CLUSTER_TYPE = WSFC, AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, DTC_SUPPORT = NONE)
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
    foreach ($secondary in $SecondaryReplicaArray) {
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

    Invoke-Sqlcmd -Query $createAGSQL -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
    L "Availability Group created"

    # Wait for secondaries to join
    foreach ($secondary in $SecondaryReplicaArray) {
        L "Waiting for $secondary to join AG..."
        $timeout = 60
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            try {
                Invoke-Sqlcmd -Query "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE" -ServerInstance $secondary -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
                L "$secondary joined successfully"
                break
            } catch {
                Start-Sleep -Seconds 5
                $elapsed += 5
            }
        }
    }
    }  # End of AG creation (if not exists)

    # Create Listener with DNN cluster compatibility (runs even if AG already exists)
    if (-not $listenerExists) {
        L "Creating AG Listener '$ListenerName'..."
    
    # Ensure cluster networks allow client connectivity
    try {
        Import-Module FailoverClusters -ErrorAction Stop
        $networks = Get-ClusterNetwork -ErrorAction Stop
        foreach ($network in $networks) {
            if ($network.Role -ne "ClusterAndClient") {
                L "Setting cluster network '$($network.Name)' role to ClusterAndClient"
                $network.Role = "ClusterAndClient"
            }
        }
    } catch {
        LW "Could not configure cluster networks: $_"
    }

    # Use proper subnet mask for /26 subnets (Azure standard)
    $subnetMask = "255.255.255.192"
    
    # Try creating listener with multiple IPs first (multi-subnet AG pattern)
    $listenerCreated = $false
    if ($ListenerIPArray.Count -gt 1) {
        L "Attempting multi-subnet listener with IPs: $($ListenerIPArray -join ', ')"
        try {
            $listenerSQL = "ALTER AVAILABILITY GROUP [$AGName] ADD LISTENER N'$ListenerName' (WITH IP ("
            $ipParts = @()
            foreach ($ip in $ListenerIPArray) {
                $ipParts += "(N'$ip', N'$subnetMask')"
            }
            $listenerSQL += $ipParts -join ", "
            $listenerSQL += "), PORT=$ListenerPort)"
            
            Invoke-Sqlcmd -Query $listenerSQL -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -QueryTimeout 120 -ErrorAction Stop
            L "Multi-subnet listener created successfully"
            $listenerCreated = $true
        } catch {
            LW "Multi-subnet listener failed: $_"
        }
    }
    
    # Fallback: Try single IP (primary subnet)
    if (-not $listenerCreated) {
        $primaryIP = $ListenerIPArray[0]
        L "Attempting single-IP listener with: $primaryIP"
        try {
            $listenerSQL = "ALTER AVAILABILITY GROUP [$AGName] ADD LISTENER N'$ListenerName' (WITH IP ((N'$primaryIP', N'$subnetMask')), PORT=$ListenerPort)"
            Invoke-Sqlcmd -Query $listenerSQL -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -QueryTimeout 120 -ErrorAction Stop
            L "Single-IP listener created successfully"
            L "Note: For multi-subnet failover, use MultiSubnetFailover=True in connection strings"
            $listenerCreated = $true
        } catch {
            LE "Listener creation failed: $_"
        }
    }
    
    if (-not $listenerCreated) {
        LE "Failed to create AG listener - manual configuration required"
    }

    # Wait for listener resources to appear in cluster
    if ($listenerCreated) {
        L "Waiting for cluster resources to initialize..."
        Start-Sleep -Seconds 10

        # Configure probe port on listener IPs
        L "Configuring Azure Load Balancer probe port..."
        try {
            Import-Module FailoverClusters -ErrorAction Stop
            
            $ipResources = Get-ClusterResource -ErrorAction Stop | Where-Object { 
                $_.ResourceType -eq 'IP Address' -and $_.OwnerGroup -like "*$AGName*"
            }

            if ($ipResources) {
                foreach ($ipResource in $ipResources) {
                    try {
                        $network = ($ipResource | Get-ClusterParameter -Name Network).Value
                        $address = ($ipResource | Get-ClusterParameter -Name Address).Value
                        L "Configuring IP resource: $($ipResource.Name) ($address)"
                        
                        # Azure multi-subnet AG pattern: /32 mask + OverrideAddressMatch
                        # This allows ANY node to host the IP regardless of its own subnet
                        $ipResource | Set-ClusterParameter -Multiple @{
                            "Address" = $address
                            "ProbePort" = $ProbePort
                            "SubnetMask" = "255.255.255.255"
                            "Network" = $network
                            "OverrideAddressMatch" = 1
                            "EnableDhcp" = 0
                        }
                        L "IP resource $($ipResource.Name) configured successfully"
                    } catch {
                        LW "Failed to configure IP resource $($ipResource.Name): $_"
                    }
                }

                # Restart listener to apply probe port
                L "Restarting listener resources..."
                $listenerResource = Get-ClusterResource -ErrorAction Stop | Where-Object { 
                    $_.ResourceType -eq 'Network Name' -and $_.Name -like "*$ListenerName*"
                }
                
                if ($listenerResource) {
                    Stop-ClusterResource $listenerResource.Name -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    Start-ClusterResource $listenerResource.Name -ErrorAction Stop
                    L "Listener restarted successfully"
                } else {
                    LW "Listener cluster resource not found - probe port may not be configured"
                }
            } else {
                LW "No IP address resources found for AG - listener may not have cluster resources"
            }
        } catch {
            LW "Failed to configure probe port: $_"
        }
    }
    }  # End of listener creation (if not exists)

    L "Availability Group setup completed successfully"
    New-Item -Path $sentinel -ItemType File -Force | Out-Null

} catch {
    LE "Error creating Availability Group: $_"
    $_ | Out-File "C:\Windows\Temp\create-availability-group.err.txt" -Force
    exit 1
}
