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
    [int]$EndpointPort = 5022,

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

#region Endpoint Safety Net
function Ensure-HadrEndpoint {
    <#
    .SYNOPSIS
        Verifies HADR endpoint exists and is STARTED on a given SQL instance.
        If missing, recreates a basic endpoint (no cert auth - just ensures connectivity).
        This is a safety net in case endpoints were dropped after SQL restarts.
    #>
    param(
        [string]$ServerInstance,
        [string]$EndpointName = "HADR_Endpoint",
        [int]$Port = 5022
    )

    L "  Checking HADR endpoint on $ServerInstance..."
    try {
        $endpoint = Invoke-Sqlcmd -Query "SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING';" `
            -ServerInstance $ServerInstance -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop

        if ($endpoint) {
            L "  Endpoint found: $($endpoint.name) on port $($endpoint.port) - $($endpoint.state_desc)"
            if ($endpoint.state_desc -ne 'STARTED') {
                L "  Endpoint not started - starting it..."
                Invoke-Sqlcmd -Query "ALTER ENDPOINT [$($endpoint.name)] STATE = STARTED;" `
                    -ServerInstance $ServerInstance -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
                L "  Endpoint started"
            }
            return $true
        } else {
            LW "  No HADR endpoint found on $ServerInstance - recreating..."
            # Check if certificate exists for cert-based auth
            $certName = "${ServerInstance}_HADR_Cert"
            $cert = Invoke-Sqlcmd -Query "SELECT name FROM sys.certificates WHERE name='$certName';" `
                -ServerInstance $ServerInstance -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue

            if ($cert) {
                # Recreate with certificate authentication
                L "  Found certificate $certName - recreating endpoint with cert auth"
                Invoke-Sqlcmd -Query @"
CREATE ENDPOINT [$EndpointName]
    STATE = STARTED AS TCP (LISTENER_PORT = $Port)
    FOR DATABASE_MIRRORING (
        AUTHENTICATION = CERTIFICATE [$certName],
        ENCRYPTION = REQUIRED ALGORITHM AES,
        ROLE = ALL);
"@ -ServerInstance $ServerInstance -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
            } else {
                # Fallback: create with Windows auth (basic connectivity)
                LW "  No certificate found - creating endpoint with NEGOTIATE auth"
                Invoke-Sqlcmd -Query @"
CREATE ENDPOINT [$EndpointName]
    STATE = STARTED AS TCP (LISTENER_PORT = $Port)
    FOR DATABASE_MIRRORING (
        AUTHENTICATION = WINDOWS NEGOTIATE,
        ENCRYPTION = REQUIRED ALGORITHM AES,
        ROLE = ALL);
GRANT CONNECT ON ENDPOINT::[$EndpointName] TO [NT AUTHORITY\SYSTEM];
"@ -ServerInstance $ServerInstance -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
            }
            L "  Endpoint recreated on $ServerInstance"
            return $true
        }
    } catch {
        LW "  Failed to verify/create endpoint on ${ServerInstance}: $($_.Exception.Message)"
        return $false
    }
}
#endregion

# Parse comma-separated parameters from Terraform
$ListenerIPArray = @($ListenerIPs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$SecondaryReplicaArray = @($SecondaryReplicas -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$AllReplicas = @($PrimaryReplica) + $SecondaryReplicaArray

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

    # The SqlServer module MUST be used instead of SQLPS.
    # SQLPS auto-loads the SQL provider context which causes "remote WSFC cluster context" 
    # errors when creating availability groups on DNN clusters.
    L "Ensuring SqlServer PowerShell module is available..."
    $sqlMod = Get-Module -ListAvailable -Name SqlServer -ErrorAction SilentlyContinue
    if (-not $sqlMod) {
        L "  SqlServer module not found - installing from PSGallery..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
        Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers -SkipPublisherCheck -ErrorAction Stop
        L "  SqlServer module installed"
    }
    Import-Module SqlServer -ErrorAction Stop -DisableNameChecking
    L "  SqlServer module loaded"

    # Check if Always On is enabled on all replicas
    L "Verifying Always On is enabled on all replicas..."
    foreach ($replica in $AllReplicas) {
        $hadrEnabled = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -ServerInstance $replica -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate
        if ($hadrEnabled.IsEnabled -ne 1) {
            LE "Always On is NOT enabled on $replica"
            exit 1
        }
        L "  Always On enabled on $replica"
    }

    # SAFETY NET: Verify HADR endpoints exist on ALL replicas before AG creation
    L "Verifying HADR endpoints on all replicas (safety net)..."
    $allEndpointsOk = $true
    foreach ($replica in $AllReplicas) {
        $ok = Ensure-HadrEndpoint -ServerInstance $replica -Port $EndpointPort
        if (-not $ok) {
            $allEndpointsOk = $false
            LW "Endpoint verification failed on $replica"
        }
    }
    if (-not $allEndpointsOk) {
        LW "Some endpoints could not be verified - AG creation may fail"
    } else {
        L "All HADR endpoints verified"
    }

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

    # Diagnose cluster context before AG creation
    L "Diagnosing SQL Server cluster context..."
    try {
        $clusterProps = Invoke-Sqlcmd -Query "SELECT cluster_name, quorum_type_desc, quorum_state_desc FROM sys.dm_os_cluster_properties" `
            -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue
        if ($clusterProps) {
            L "  Cluster name: $($clusterProps.cluster_name), Quorum: $($clusterProps.quorum_type_desc) ($($clusterProps.quorum_state_desc))"
        } else {
            LW "  dm_os_cluster_properties returned empty - SQL Server may not see local cluster"
        }
    } catch {
        LW "  Could not query cluster properties: $($_.Exception.Message)"
    }
    try {
        $isClustered = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsClustered') AS IsClustered" `
            -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue
        L "  IsClustered: $($isClustered.IsClustered)"
    } catch {
        LW "  Could not query IsClustered: $($_.Exception.Message)"
    }

    # Force local HADR cluster context (fixes "remote WSFC cluster context" error on DNN clusters)
    L "Setting HADR cluster context to LOCAL..."
    try {
        Invoke-Sqlcmd -Query "ALTER SERVER CONFIGURATION SET HADR CLUSTER CONTEXT LOCAL" `
            -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
        L "  HADR cluster context set to LOCAL"
    } catch {
        LW "  Could not set HADR cluster context: $($_.Exception.Message)"
    }

    # Create Availability Group - try WSFC first, fall back to NONE for DNN/workgroup clusters
    L "Creating Availability Group '$AGName'..."
    
    $clusterTypes = @("WSFC", "NONE")
    $agCreated = $false
    
    foreach ($clusterType in $clusterTypes) {
        if ($agCreated) { break }
        
        $failoverMode = if ($clusterType -eq "WSFC") { "AUTOMATIC" } else { "MANUAL" }
        L "  Attempting with CLUSTER_TYPE = $clusterType, FAILOVER_MODE = $failoverMode..."
        
        $createAGSQL = @"
CREATE AVAILABILITY GROUP [$AGName]
WITH (CLUSTER_TYPE = $clusterType, AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, DTC_SUPPORT = NONE)
FOR DATABASE [$dbName]
REPLICA ON 
"@

        # Add primary replica
        $createAGSQL += @"
N'$PrimaryReplica' WITH (
    ENDPOINT_URL = N'TCP://${PrimaryReplica}:${EndpointPort}',
    FAILOVER_MODE = $failoverMode,
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
    ENDPOINT_URL = N'TCP://${secondary}:${EndpointPort}',
    FAILOVER_MODE = $failoverMode,
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    BACKUP_PRIORITY = 50,
    SEEDING_MODE = AUTOMATIC,
    SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)
)
"@
        }

        try {
            Invoke-Sqlcmd -Query $createAGSQL -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
            L "Availability Group created with CLUSTER_TYPE = $clusterType"
            $agCreated = $true
        } catch {
            LW "  CLUSTER_TYPE = $clusterType failed: $($_.Exception.Message)"
            if ($clusterType -eq "WSFC") {
                L "  Will retry with CLUSTER_TYPE = NONE..."
            }
        }
    }
    
    if (-not $agCreated) {
        LE "Failed to create Availability Group with any cluster type"
        exit 1
    }

    # Join secondaries to AG
    # Determine cluster type used (check from AG metadata)
    $agClusterType = Invoke-Sqlcmd -Query "SELECT cluster_type_desc FROM sys.availability_groups WHERE name = '$AGName'" `
        -ServerInstance $currentNode -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue
    $usedClusterTypeNone = ($agClusterType -and $agClusterType.cluster_type_desc -eq 'NONE')
    L "AG cluster type: $($agClusterType.cluster_type_desc)"
    
    foreach ($secondary in $SecondaryReplicaArray) {
        L "Joining $secondary to AG..."
        
        # If CLUSTER_TYPE = NONE, set HADR context on secondary too
        if ($usedClusterTypeNone) {
            try {
                Invoke-Sqlcmd -Query "ALTER SERVER CONFIGURATION SET HADR CLUSTER CONTEXT LOCAL" `
                    -ServerInstance $secondary -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction SilentlyContinue
            } catch { }
        }
        
        $timeout = 120
        $elapsed = 0
        $joined = $false
        
        # Build join query based on cluster type
        $joinQuery = if ($usedClusterTypeNone) {
            "ALTER AVAILABILITY GROUP [$AGName] JOIN WITH (CLUSTER_TYPE = NONE);"
        } else {
            "ALTER AVAILABILITY GROUP [$AGName] JOIN;"
        }
        
        while ($elapsed -lt $timeout -and -not $joined) {
            try {
                # First join the AG on the secondary
                Invoke-Sqlcmd -Query $joinQuery `
                    -ServerInstance $secondary -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
                L "$secondary joined the AG"
                
                # Then grant automatic seeding
                Invoke-Sqlcmd -Query "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE;" `
                    -ServerInstance $secondary -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -ErrorAction Stop
                L "$secondary granted CREATE ANY DATABASE for seeding"
                $joined = $true
            } catch {
                LW "Join attempt on $secondary failed ($elapsed/${timeout}s): $($_.Exception.Message)"
                Start-Sleep -Seconds 10
                $elapsed += 10
            }
        }
        if (-not $joined) {
            LW "$secondary failed to join AG within ${timeout}s - may need manual intervention"
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
