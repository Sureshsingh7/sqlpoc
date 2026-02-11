param(
    [Parameter(Mandatory=$true)]
    [string]$AGName,

    [Parameter(Mandatory=$true)]
    [string]$ListenerName,

    [Parameter(Mandatory=$true)]
    [string]$ListenerIPs,  # Comma-separated ILB frontend IPs from Terraform

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
    [string]$SqlAdminPassword,

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminUsername = "clusteradmin",

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminPassword = ""
)

<#
.SYNOPSIS
    Creates a SQL Server Always On Availability Group following the FNZ proven pattern:
    1. PRIMARY: Create AG EMPTY (no databases) with MANUAL seeding
    2. SECONDARY: Poll primary, JOIN locally, GRANT CREATE ANY DATABASE
    3. PRIMARY: Wait for secondary → backup DB → restore on secondary via SMB → add DB to AG
    4. PRIMARY: Create VNN listener with Azure ILB probe port configuration
.NOTES
    This script runs on ALL nodes (primary AND secondaries) in parallel via
    azurerm_virtual_machine_run_command. Each node determines its role and acts accordingly.
#>

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

#region Helpers

# Run SQL with standard auth, with optional error suppression
function Invoke-Sql {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Server = $env:COMPUTERNAME,
        [int]$Timeout = 30,
        [switch]$Safe   # Safe = suppress errors, return $null
    )
    try {
        return Invoke-Sqlcmd -Query $Query -ServerInstance $Server `
            -Username $SqlAdminUsername -Password $SqlAdminPassword `
            -TrustServerCertificate -QueryTimeout $Timeout -ErrorAction Stop
    } catch {
        if ($Safe) { return $null }
        throw
    }
}

# Build FQDN endpoint URL using the domain suffix set by create_failover_cluster.ps1
# e.g. TCP://poc-ha-sql-01.sqlpoc.local:5022 (matches FNZ pattern: TCP://ukdivmprim.ukag.fnz:5022)
function Get-EndpointUrl([string]$Hostname) {
    $suffix = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\services\Tcpip\Parameters" `
        -Name "NV Domain" -ErrorAction SilentlyContinue).'NV Domain'
    if (-not [string]::IsNullOrWhiteSpace($suffix)) {
        return "TCP://${Hostname}.${suffix}:${EndpointPort}"
    }
    return "TCP://${Hostname}:${EndpointPort}"
}

#endregion

# Resolve ClusterAdminPassword: use SqlAdminPassword if not provided
if ([string]::IsNullOrWhiteSpace($ClusterAdminPassword)) {
    $ClusterAdminPassword = $SqlAdminPassword
}

# Parse comma-separated parameters from Terraform
$ListenerIPArray = @($ListenerIPs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$SecondaryReplicaArray = @($SecondaryReplicas -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$AllReplicas = @($PrimaryReplica) + $SecondaryReplicaArray
$currentNode = $env:COMPUTERNAME
$isPrimary = ($currentNode -eq $PrimaryReplica)

# Check if already completed
if (Test-Path $sentinel) {
    L "AG setup already completed - exiting"
    exit 0
}

try {
    L "=========================================="
    L "Availability Group Setup (FNZ Pattern)"
    L "Node: $currentNode | Role: $(if ($isPrimary) {'PRIMARY'} else {'SECONDARY'})"
    L "AG: $AGName | Primary: $PrimaryReplica"
    L "Secondaries: $($SecondaryReplicaArray -join ', ')"
    L "Pattern: Empty AG → Join → Manual Backup/Restore Seeding"
    L "=========================================="

    # The SqlServer module MUST be used instead of SQLPS.
    # SQLPS auto-loads the SQL provider context which causes "remote WSFC cluster context"
    # errors when creating availability groups.
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

    # ======================================================================
    # PRIMARY NODE FLOW
    # Step 1: Create empty AG (no databases, MANUAL seeding) — matches FNZ pattern
    # Step 2: Wait for secondaries to join (they join themselves)
    # Step 3: Backup/restore DB to secondaries via SMB, then add DB to AG
    # Step 4: Create VNN listener with Azure ILB probe port
    # ======================================================================
    if ($isPrimary) {
        L "--- PRIMARY FLOW ---"

        # Verify Always On is enabled on all replicas
        L "Verifying Always On on all replicas..."
        foreach ($replica in $AllReplicas) {
            $hadrEnabled = Invoke-Sql "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -Server $replica -Safe
            if (-not $hadrEnabled -or $hadrEnabled.IsEnabled -ne 1) {
                LE "Always On is NOT enabled on $replica"
                exit 1
            }
            L "  $replica - Always On enabled"
        }

        # Verify HADR endpoints are STARTED on all replicas
        L "Verifying HADR endpoints on all replicas..."
        foreach ($replica in $AllReplicas) {
            $ep = Invoke-Sql "SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING'" -Server $replica -Safe
            if ($ep) {
                L "  $replica - Endpoint: $($ep.name) port $($ep.port) ($($ep.state_desc))"
                if ($ep.state_desc -ne 'STARTED') {
                    Invoke-Sql "ALTER ENDPOINT [$($ep.name)] STATE = STARTED" -Server $replica -Safe
                    L "  $replica - Endpoint started"
                }
            } else {
                LW "  $replica - No HADR endpoint found! Certificate exchange may have failed."
            }
        }

        # Test TCP connectivity to secondary endpoints (port 5022)
        L "Testing endpoint TCP connectivity to secondaries..."
        foreach ($sec in $SecondaryReplicaArray) {
            $tcp = Test-NetConnection -ComputerName $sec -Port $EndpointPort -WarningAction SilentlyContinue
            if ($tcp.TcpTestSucceeded) {
                L "  TCP OK: ${sec}:${EndpointPort}"
            } else {
                LW "  TCP FAILED: ${sec}:${EndpointPort} - AG data movement will fail!"
            }
        }

        # --- Check if AG already exists ---
        $existingAG = Invoke-Sql "SELECT name FROM sys.availability_groups WHERE name = '$AGName'" -Safe
        $existingListener = $null
        $listenerExists = $false
        $agExists = ($null -ne $existingAG)

        if ($agExists) {
            L "AG '$AGName' already exists"
            $existingListener = Invoke-Sql "SELECT dns_name FROM sys.availability_group_listeners WHERE dns_name = '$ListenerName'" -Safe
            if ($existingListener) {
                $listenerExists = $true
                L "Listener '$ListenerName' already exists - setup complete"
                New-Item -Path $sentinel -ItemType File -Force | Out-Null
                exit 0
            }
            L "Listener not found - will create after secondary join"
        } else {
            # --- Create test database (before AG, like FNZ pattern) ---
            $dbName = "TestDB"
            L "Creating test database '$dbName'..."
            $dbExists = Invoke-Sql "SELECT name FROM sys.databases WHERE name = '$dbName'" -Safe
            if (-not $dbExists) {
                Invoke-Sql "CREATE DATABASE [$dbName]"
                Invoke-Sql "ALTER DATABASE [$dbName] SET RECOVERY FULL"
                L "Database '$dbName' created with FULL recovery model"
            } else {
                L "Database '$dbName' already exists"
            }

            # --- Diagnose cluster context ---
            L "Diagnosing SQL Server cluster context..."
            $isDomainJoined = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).PartOfDomain
            L "  Domain joined: $isDomainJoined"

            try {
                $clusterProps = Invoke-Sql "SELECT cluster_name, quorum_type_desc, quorum_state_desc FROM sys.dm_os_cluster_properties" -Safe
                if ($clusterProps) {
                    L "  Cluster: $($clusterProps.cluster_name), Quorum: $($clusterProps.quorum_type_desc) ($($clusterProps.quorum_state_desc))"
                } else {
                    # On workgroup clusters, SQL Server does NOT detect the WSFC cluster when
                    # AlwaysOn was enabled before the cluster was created. This is expected.
                    # DO NOT restart SQL Server here — it makes things worse by putting AlwaysOn
                    # into a "Waiting for WSFC" state that blocks ALL AG creation.
                    L "  dm_os_cluster_properties empty - expected for workgroup clusters"
                    L "  AG will use CLUSTER_TYPE=NONE (supported for workgroup clusters)"
                }
            } catch { LW "  Could not query cluster properties: $($_.Exception.Message)" }

            try {
                $isClustered = Invoke-Sql "SELECT SERVERPROPERTY('IsClustered') AS IsClustered" -Safe
                L "  IsClustered: $($isClustered.IsClustered)"
            } catch { LW "  Could not query IsClustered: $($_.Exception.Message)" }

            # ==============================================================
            # STEP 1: Create EMPTY Availability Group (FNZ pattern)
            # No FOR DATABASE clause — AG starts with no databases.
            # SEEDING_MODE = MANUAL — databases added via backup/restore.
            # FAILOVER_MODE = MANUAL (NONE only supports MANUAL).
            # For workgroup clusters: use CLUSTER_TYPE = NONE directly.
            # The VNN listener still works via WSFC even with CLUSTER_TYPE = NONE.
            # ==============================================================
            L "STEP 1: Creating EMPTY Availability Group '$AGName' (FNZ pattern)..."
            $agCreated = $false

            # Build replica definitions with FQDN endpoint URLs
            $primaryUrl = Get-EndpointUrl $PrimaryReplica
            L "  Primary endpoint: $primaryUrl"

            $replicaSQL = @"
    N'$PrimaryReplica' WITH (
        ENDPOINT_URL     = N'$primaryUrl',
        FAILOVER_MODE    = MANUAL,
        AVAILABILITY_MODE= SYNCHRONOUS_COMMIT,
        BACKUP_PRIORITY  = 50,
        SECONDARY_ROLE   (ALLOW_CONNECTIONS = ALL),
        SEEDING_MODE     = MANUAL
    )
"@
            foreach ($secondary in $SecondaryReplicaArray) {
                $secUrl = Get-EndpointUrl $secondary
                L "  Secondary endpoint: $secUrl"
                $replicaSQL += @"
,
    N'$secondary' WITH (
        ENDPOINT_URL     = N'$secUrl',
        FAILOVER_MODE    = MANUAL,
        AVAILABILITY_MODE= SYNCHRONOUS_COMMIT,
        BACKUP_PRIORITY  = 50,
        SECONDARY_ROLE   (ALLOW_CONNECTIONS = ALL),
        SEEDING_MODE     = MANUAL
    )
"@
            }

            # For domain-joined clusters, try WSFC first then NONE.
            # For workgroup clusters, go directly to NONE (WSFC will never work).
            $clusterTypes = if ($isDomainJoined) { @("WSFC", "NONE") } else { @("NONE") }
            if (-not $isDomainJoined) {
                L "  Workgroup cluster detected - using CLUSTER_TYPE=NONE directly"
            }

            foreach ($clusterType in $clusterTypes) {
                if ($agCreated) { break }
                L "  Attempting CLUSTER_TYPE = $clusterType..."

                $createAGSQL = @"
CREATE AVAILABILITY GROUP [$AGName]
WITH (
    CLUSTER_TYPE = $clusterType
)
FOR REPLICA ON
$replicaSQL
"@
                try {
                    Invoke-Sql $createAGSQL -Timeout 120
                    L "AG '$AGName' created (EMPTY, CLUSTER_TYPE=$clusterType, SEEDING_MODE=MANUAL)"
                    $agCreated = $true
                } catch {
                    LW "  CLUSTER_TYPE=$clusterType failed: $($_.Exception.Message)"
                    if ($clusterType -eq "WSFC") {
                        LW "  Falling back to NONE..."
                    }
                }
            }

            if (-not $agCreated) {
                LE "Failed to create AG with any cluster type"
                exit 1
            }
        }

        # ==============================================================
        # STEP 2: Wait for secondaries to join
        # Secondaries join THEMSELVES via their own script instance.
        # ==============================================================
        L "STEP 2: Waiting for secondary replicas to connect (up to 5 minutes)..."
        L "(Secondaries join themselves via their own run command instance)"
        $allConnected = $false
        $waitElapsed = 0
        $waitTimeout = 300

        while ($waitElapsed -lt $waitTimeout -and -not $allConnected) {
            $states = Invoke-Sql @"
SELECT r.replica_server_name, rs.role_desc, rs.connected_state_desc, rs.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_replicas r ON rs.replica_id = r.replica_id AND rs.group_id = r.group_id
WHERE r.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$AGName')
"@ -Safe
            if ($states) {
                $connected = @($states | Where-Object { $_.connected_state_desc -eq 'CONNECTED' })
                L "  Connected replicas: $($connected.Count)/$($AllReplicas.Count) (${waitElapsed}s)"
                foreach ($s in @($states)) {
                    L "    $($s.replica_server_name): role=$($s.role_desc) connected=$($s.connected_state_desc) health=$($s.synchronization_health_desc)"
                }
                if ($connected.Count -ge $AllReplicas.Count) {
                    $allConnected = $true
                }
            } else {
                L "  No replica state data yet (${waitElapsed}s)"
            }
            if (-not $allConnected) {
                Start-Sleep -Seconds 15
                $waitElapsed += 15
            }
        }

        if ($allConnected) {
            L "All replicas connected!"
        } else {
            LW "Timeout waiting for all replicas - proceeding anyway"
        }

        # ==============================================================
        # STEP 3: Add database to AG via manual backup/restore seeding
        # This is the FNZ pattern: backup on primary → copy to secondary
        # via SMB → restore WITH NORECOVERY → add DB to AG on both sides.
        # ==============================================================
        if (-not $agExists) {
            $dbName = "TestDB"
            $backupDir = "C:\SQLBackups"
            $backupFile = "$backupDir\${dbName}_AG_Init.bak"
            $logBackupFile = "$backupDir\${dbName}_AG_Init.trn"

            L "STEP 3: Adding database '$dbName' to AG via manual seeding..."

            # Create backup directory
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }

            # Full backup on primary
            L "  Taking FULL backup of '$dbName'..."
            Invoke-Sql "BACKUP DATABASE [$dbName] TO DISK = N'$backupFile' WITH FORMAT, INIT, COMPRESSION" -Timeout 300
            L "  Full backup complete: $backupFile"

            # Transaction log backup on primary
            L "  Taking LOG backup of '$dbName'..."
            Invoke-Sql "BACKUP LOG [$dbName] TO DISK = N'$logBackupFile' WITH FORMAT, INIT, COMPRESSION" -Timeout 120
            L "  Log backup complete: $logBackupFile"

            # Copy backups to each secondary via SMB and restore WITH NORECOVERY
            foreach ($secondary in $SecondaryReplicaArray) {
                L "  --- Seeding '$dbName' to $secondary ---"
                $uncPath = "\\$secondary\C`$"
                $remoteBackupDir = "$uncPath\SQLBackups"

                try {
                    # Connect via SMB
                    L "  Connecting to $secondary via SMB..."
                    $netResult = cmd /c "net use $uncPath /user:$secondary\$ClusterAdminUsername `"$ClusterAdminPassword`" 2>&1"
                    if ($LASTEXITCODE -ne 0 -and $netResult -notmatch "already") {
                        throw "net use failed: $netResult"
                    }

                    # Create remote backup directory
                    if (-not (Test-Path $remoteBackupDir)) {
                        New-Item -ItemType Directory -Path $remoteBackupDir -Force | Out-Null
                    }

                    # Copy backup files
                    L "  Copying backup files to $secondary..."
                    Copy-Item $backupFile "$remoteBackupDir\${dbName}_AG_Init.bak" -Force
                    Copy-Item $logBackupFile "$remoteBackupDir\${dbName}_AG_Init.trn" -Force
                    L "  Backups copied to $secondary"

                    # Disconnect SMB
                    cmd /c "net use $uncPath /delete /y 2>&1" | Out-Null

                    # Restore WITH NORECOVERY on secondary
                    L "  Restoring WITH NORECOVERY on $secondary..."
                    # Get default data/log paths on secondary
                    $secDataPath = Invoke-Sql "SELECT SERVERPROPERTY('InstanceDefaultDataPath') AS DataPath" -Server $secondary -Safe
                    $secLogPath = Invoke-Sql "SELECT SERVERPROPERTY('InstanceDefaultLogPath') AS LogPath" -Server $secondary -Safe

                    $dataDir = if ($secDataPath) { $secDataPath.DataPath.TrimEnd('\') } else { "C:\SQLBackups" }
                    $logDir = if ($secLogPath) { $secLogPath.LogPath.TrimEnd('\') } else { "C:\SQLBackups" }

                    $restoreSQL = @"
RESTORE DATABASE [$dbName] FROM DISK = N'C:\SQLBackups\${dbName}_AG_Init.bak'
WITH NORECOVERY, REPLACE,
MOVE N'${dbName}' TO N'$dataDir\${dbName}.mdf',
MOVE N'${dbName}_log' TO N'$logDir\${dbName}_log.ldf'
"@
                    Invoke-Sql $restoreSQL -Server $secondary -Timeout 300
                    L "  Full restore complete on $secondary"

                    # Restore log WITH NORECOVERY
                    $restoreLogSQL = @"
RESTORE LOG [$dbName] FROM DISK = N'C:\SQLBackups\${dbName}_AG_Init.trn' WITH NORECOVERY
"@
                    Invoke-Sql $restoreLogSQL -Server $secondary -Timeout 120
                    L "  Log restore complete on $secondary"

                } catch {
                    LW "  Failed to seed $secondary via manual backup/restore: $($_.Exception.Message)"
                    LW "  Falling back to automatic seeding for $secondary..."
                    # Fallback: try to switch this replica to AUTOMATIC seeding
                    try {
                        Invoke-Sql "ALTER AVAILABILITY GROUP [$AGName] MODIFY REPLICA ON N'$secondary' WITH (SEEDING_MODE = AUTOMATIC)" -Safe
                        Invoke-Sql "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE" -Server $secondary -Safe
                    } catch { LW "  Automatic seeding fallback also failed: $_" }
                }
            }

            # Add database to AG on PRIMARY
            L "  Adding '$dbName' to AG on primary..."
            Invoke-Sql "ALTER AVAILABILITY GROUP [$AGName] ADD DATABASE [$dbName]" -Timeout 60
            L "  Database added to AG on primary"

            # Add database to AG on each SECONDARY
            foreach ($secondary in $SecondaryReplicaArray) {
                L "  Adding '$dbName' to AG on $secondary..."
                try {
                    # Check if DB is in restoring state (manual seeding path)
                    $dbState = Invoke-Sql "SELECT state_desc FROM sys.databases WHERE name = '$dbName'" -Server $secondary -Safe
                    if ($dbState -and $dbState.state_desc -eq 'RESTORING') {
                        Invoke-Sql "ALTER DATABASE [$dbName] SET HADR AVAILABILITY GROUP = [$AGName]" -Server $secondary -Timeout 60
                        L "  Database joined AG on $secondary (manual seeding path)"
                    } else {
                        L "  DB state on ${secondary}: $(if($dbState){$dbState.state_desc}else{'not found'}) - may use auto-seeding"
                        Invoke-Sql "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE" -Server $secondary -Safe
                    }
                } catch {
                    LW "  Failed to add DB to AG on ${secondary}: $_"
                }
            }

            # Wait for database sync
            L "  Waiting for database synchronization (up to 2 minutes)..."
            $syncOk = $false
            $syncWait = 0
            while ($syncWait -lt 120 -and -not $syncOk) {
                $dbSyncStates = Invoke-Sql @"
SELECT r.replica_server_name, d.name AS db_name,
       drs.synchronization_state_desc, drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas r ON drs.replica_id = r.replica_id
JOIN sys.databases d ON drs.database_id = d.database_id
WHERE drs.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$AGName')
"@ -Safe
                if ($dbSyncStates) {
                    foreach ($s in @($dbSyncStates)) {
                        L "    $($s.replica_server_name)/$($s.db_name): $($s.synchronization_state_desc) ($($s.synchronization_health_desc))"
                    }
                    $synced = @($dbSyncStates | Where-Object { $_.synchronization_state_desc -in @('SYNCHRONIZED','SYNCHRONIZING') })
                    if ($synced.Count -ge 2) {
                        L "  Database synchronization OK!"
                        $syncOk = $true
                    }
                }
                if (-not $syncOk) { Start-Sleep -Seconds 10; $syncWait += 10 }
            }
            if (-not $syncOk) { LW "  Database sync not confirmed within timeout" }

            # Note: CLUSTER_TYPE=NONE only supports FAILOVER_MODE=MANUAL
            # Automatic failover requires CLUSTER_TYPE=WSFC (domain-joined clusters only)
            $agType = Invoke-Sql "SELECT cluster_type_desc FROM sys.availability_groups WHERE name = '$AGName'" -Safe
            if ($agType -and $agType.cluster_type_desc -eq 'WSFC') {
                L "  Upgrading FAILOVER_MODE to AUTOMATIC (WSFC supports it)..."
                foreach ($replica in $AllReplicas) {
                    try {
                        Invoke-Sql "ALTER AVAILABILITY GROUP [$AGName] MODIFY REPLICA ON N'$replica' WITH (FAILOVER_MODE = AUTOMATIC)"
                        L "  ${replica}: FAILOVER_MODE = AUTOMATIC"
                    } catch {
                        LW "  Could not set AUTOMATIC failover on ${replica}: $($_.Exception.Message)"
                    }
                }
            } else {
                L "  CLUSTER_TYPE=NONE - keeping FAILOVER_MODE=MANUAL (only supported mode)"
            }
        }

        # ==============================================================
        # STEP 4: Create VNN Listener
        # ==============================================================
        if (-not $listenerExists) {
            L "STEP 4: Creating VNN Listener '$ListenerName'..."

            # Ensure cluster networks allow client connectivity
            try {
                Import-Module FailoverClusters -ErrorAction Stop
                Get-ClusterNetwork | ForEach-Object {
                    if ($_.Role -ne "ClusterAndClient") {
                        L "  Setting cluster network '$($_.Name)' to ClusterAndClient"
                        $_.Role = "ClusterAndClient"
                    }
                }
            } catch { LW "Could not configure cluster networks: $_" }

            # Azure ILB VNN pattern: /32 subnet mask + OverrideAddressMatch + ProbePort
            # This is CRITICAL - /26 or other masks will NOT work with Azure ILB floating IP
            $subnetMask = "255.255.255.255"

            $listenerCreated = $false

            # Try multi-subnet listener first (2 ILB frontend IPs)
            if ($ListenerIPArray.Count -gt 1) {
                L "Creating multi-subnet VNN listener (IPs: $($ListenerIPArray -join ', '))..."
                try {
                    $ipParts = ($ListenerIPArray | ForEach-Object { "(N'$_', N'$subnetMask')" }) -join ", "
                    $listenerSQL = "ALTER AVAILABILITY GROUP [$AGName] ADD LISTENER N'$ListenerName' (WITH IP ($ipParts), PORT=$ListenerPort)"
                    Invoke-Sql $listenerSQL -Timeout 120
                    L "Multi-subnet VNN listener created"
                    $listenerCreated = $true
                } catch {
                    LW "Multi-subnet listener failed: $_"
                }
            }

            # Fallback: single IP
            if (-not $listenerCreated) {
                L "Creating single-IP VNN listener..."
                try {
                    $listenerSQL = "ALTER AVAILABILITY GROUP [$AGName] ADD LISTENER N'$ListenerName' (WITH IP ((N'$($ListenerIPArray[0])', N'$subnetMask')), PORT=$ListenerPort)"
                    Invoke-Sql $listenerSQL -Timeout 120
                    L "Single-IP VNN listener created"
                    $listenerCreated = $true
                } catch {
                    LE "All listener creation methods failed: $_"
                }
            }

            # ================================================================
            # Configure Azure ILB probe port via WSFC cluster resources
            # With CLUSTER_TYPE=NONE, ADD LISTENER creates a SQL-only listener
            # but does NOT create WSFC resources (IP Address, Network Name).
            # We must create them manually so the Azure ILB health probe
            # on $ProbePort can detect which node is primary.
            # ================================================================
            if ($listenerCreated) {
                L "Creating WSFC cluster resources for ILB probe port..."
                Start-Sleep -Seconds 10

                try {
                    Import-Module FailoverClusters -ErrorAction Stop

                    # Get cluster networks to match each listener IP to its network
                    $clusterNetworks = Get-ClusterNetwork -ErrorAction Stop
                    L "  Cluster networks:"
                    foreach ($cn in $clusterNetworks) {
                        L "    $($cn.Name): $($cn.Address)/$($cn.AddressMask)"
                    }

                    # Helper: find which cluster network an IP belongs to
                    function Find-ClusterNetworkForIP($ip) {
                        foreach ($cn in $clusterNetworks) {
                            $netAddr  = [System.Net.IPAddress]::Parse($cn.Address)
                            $netMask  = [System.Net.IPAddress]::Parse($cn.AddressMask)
                            $testAddr = [System.Net.IPAddress]::Parse($ip)
                            $netBytes  = $netAddr.GetAddressBytes()
                            $maskBytes = $netMask.GetAddressBytes()
                            $testBytes = $testAddr.GetAddressBytes()
                            $match = $true
                            for ($i = 0; $i -lt 4; $i++) {
                                if (($netBytes[$i] -band $maskBytes[$i]) -ne ($testBytes[$i] -band $maskBytes[$i])) {
                                    $match = $false; break
                                }
                            }
                            if ($match) { return $cn.Name }
                        }
                        return $null
                    }

                    # Create a cluster role (group) for the AG listener
                    $groupName = $AGName
                    $existingGroup = Get-ClusterGroup -Name $groupName -ErrorAction SilentlyContinue
                    if (-not $existingGroup) {
                        L "  Creating cluster group '$groupName'..."
                        Add-ClusterGroup -Name $groupName -ErrorAction Stop | Out-Null
                        L "  Cluster group created"
                    } else {
                        L "  Cluster group '$groupName' already exists"
                    }

                    # Create IP Address resources for each listener IP
                    $ipResourceNames = @()
                    foreach ($ip in $ListenerIPArray) {
                        $resName = "${ListenerName}_$ip"
                        $network = Find-ClusterNetworkForIP $ip
                        if (-not $network) {
                            LW "  Could not find cluster network for IP $ip - skipping"
                            continue
                        }

                        $existing = Get-ClusterResource -Name $resName -ErrorAction SilentlyContinue
                        if (-not $existing) {
                            L "  Creating IP resource '$resName' ($ip on '$network')..."
                            Add-ClusterResource -Name $resName -ResourceType "IP Address" -Group $groupName -ErrorAction Stop | Out-Null
                        } else {
                            L "  IP resource '$resName' already exists"
                        }

                        Get-ClusterResource -Name $resName | Set-ClusterParameter -Multiple @{
                            "Address"              = $ip
                            "ProbePort"            = $ProbePort
                            "SubnetMask"           = "255.255.255.255"
                            "Network"              = $network
                            "OverrideAddressMatch" = 1
                            "EnableDhcp"           = 0
                        }
                        L "  $resName configured: ProbePort=$ProbePort, Network=$network"
                        $ipResourceNames += $resName
                    }

                    # Create Network Name resource for the listener
                    $nnResName = "${ListenerName}_name"
                    $existingNN = Get-ClusterResource -Name $nnResName -ErrorAction SilentlyContinue
                    if (-not $existingNN) {
                        L "  Creating Network Name resource '$nnResName'..."
                        Add-ClusterResource -Name $nnResName -ResourceType "Network Name" -Group $groupName -ErrorAction Stop | Out-Null
                    } else {
                        L "  Network Name resource '$nnResName' already exists"
                    }
                    Get-ClusterResource -Name $nnResName | Set-ClusterParameter -Multiple @{
                        "Name"    = $ListenerName
                        "DnsName" = $ListenerName
                    }
                    L "  Network Name configured: $ListenerName"

                    # Set dependency: Network Name depends on IP resources (OR logic)
                    if ($ipResourceNames.Count -gt 0) {
                        $depExpr = ($ipResourceNames | ForEach-Object { "[$_]" }) -join " or "
                        L "  Setting dependency: $nnResName -> $depExpr"
                        Set-ClusterResourceDependency -Resource $nnResName -Dependency $depExpr -ErrorAction Stop
                    }

                    # Bring resources online
                    L "  Starting cluster group '$groupName'..."
                    Start-ClusterGroup -Name $groupName -ErrorAction Stop | Out-Null
                    L "  Cluster group online!"

                    # Verify final state
                    L "  Final cluster resources:"
                    Get-ClusterResource -ErrorAction SilentlyContinue | ForEach-Object {
                        L "    Name='$($_.Name)' Type='$($_.ResourceType)' Group='$($_.OwnerGroup)' State='$($_.State)'"
                    }

                } catch {
                    LW "Failed to create WSFC resources for ILB probe: $_"
                    LW "The AG listener works but ILB health probe may not route correctly."
                }
            }
        }

    # ======================================================================
    # SECONDARY NODE FLOW
    # Waits for the AG to be created on primary, then JOINs locally.
    # Exactly like FNZ: ALTER AVAILABILITY GROUP [x] JOIN + GRANT CREATE ANY DATABASE
    # ======================================================================
    } else {
        L "--- SECONDARY FLOW ---"

        # Verify Always On is enabled locally
        $hadrEnabled = Invoke-Sql "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled"
        if ($hadrEnabled.IsEnabled -ne 1) {
            LE "Always On is NOT enabled on $currentNode"
            exit 1
        }
        L "Always On enabled locally"

        # Verify local HADR endpoint is STARTED
        $ep = Invoke-Sql "SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING'" -Safe
        if ($ep) {
            L "Local endpoint: $($ep.name) port $($ep.port) ($($ep.state_desc))"
            if ($ep.state_desc -ne 'STARTED') {
                Invoke-Sql "ALTER ENDPOINT [$($ep.name)] STATE = STARTED" -Safe
                L "Endpoint started"
            }
        } else {
            LW "No HADR endpoint found locally - AG join may fail"
        }

        # Check if already joined as SECONDARY
        $localAG = Invoke-Sql "SELECT name FROM sys.availability_groups WHERE name = '$AGName'" -Safe
        if ($localAG) {
            $localRole = Invoke-Sql "SELECT role_desc FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1" -Safe
            if ($localRole -and $localRole.role_desc -eq 'SECONDARY') {
                L "Already joined AG as SECONDARY - granting seeding and exiting"
                Invoke-Sql "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE" -Safe
                New-Item -Path $sentinel -ItemType File -Force | Out-Null
                exit 0
            }
            L "AG exists locally but role is: $(if ($localRole) { $localRole.role_desc } else { 'UNKNOWN' }) - will attempt join"
        }

        # Wait for AG to exist on primary (primary creates it in its own script instance)
        L "Polling primary '$PrimaryReplica' for AG '$AGName'..."
        $agFound = $false
        $maxWait = 600   # 10 minutes
        $waited = 0

        while ($waited -lt $maxWait -and -not $agFound) {
            try {
                $ag = Invoke-Sqlcmd -Query "SELECT name FROM sys.availability_groups WHERE name = '$AGName'" `
                    -ServerInstance $PrimaryReplica -Username $SqlAdminUsername -Password $SqlAdminPassword `
                    -TrustServerCertificate -ErrorAction Stop
                if ($ag) {
                    L "AG '$AGName' found on primary (after ${waited}s)"
                    $agFound = $true
                }
            } catch {
                if ($waited % 60 -lt 15) {
                    L "  Still waiting for AG on primary... (${waited}/${maxWait}s) $($_.Exception.Message)"
                }
            }
            if (-not $agFound) { Start-Sleep -Seconds 15; $waited += 15 }
        }

        if (-not $agFound) {
            LE "Timeout: AG '$AGName' not found on primary after ${maxWait}s"
            exit 1
        }

        # Small delay to let the primary fully commit the AG configuration
        Start-Sleep -Seconds 10

        # Set HADR cluster context
        Invoke-Sql "ALTER SERVER CONFIGURATION SET HADR CLUSTER CONTEXT LOCAL" -Safe

        # Determine join clause based on AG cluster type on primary
        $agMeta = Invoke-Sqlcmd -Query "SELECT cluster_type_desc FROM sys.availability_groups WHERE name = '$AGName'" `
            -ServerInstance $PrimaryReplica -Username $SqlAdminUsername -Password $SqlAdminPassword `
            -TrustServerCertificate -ErrorAction SilentlyContinue

        $joinSQL = "ALTER AVAILABILITY GROUP [$AGName] JOIN;"
        if ($agMeta -and $agMeta.cluster_type_desc -eq 'NONE') {
            $joinSQL = "ALTER AVAILABILITY GROUP [$AGName] JOIN WITH (CLUSTER_TYPE = NONE);"
            L "AG uses CLUSTER_TYPE = NONE"
        } else {
            L "AG uses WSFC cluster type"
        }

        # Join AG locally with retries (FNZ pattern: simple JOIN + GRANT)
        $joined = $false
        $maxRetries = 12   # 12 x 15s = 3 minutes
        for ($i = 1; $i -le $maxRetries; $i++) {
            try {
                L "Join attempt $i/$maxRetries..."
                Invoke-Sql $joinSQL -Timeout 60
                L "Successfully joined AG '$AGName'!"
                $joined = $true
                break
            } catch {
                LW "Join attempt $i failed: $($_.Exception.Message)"
                if ($i -lt $maxRetries) { Start-Sleep -Seconds 15 }
            }
        }

        if (-not $joined) {
            LE "Failed to join AG after $maxRetries attempts"
            exit 1
        }

        # Grant CREATE ANY DATABASE (FNZ pattern)
        try {
            Invoke-Sql "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE"
            L "GRANT CREATE ANY DATABASE - done"
        } catch {
            LW "Grant seeding failed (may already be granted): $_"
        }

        # Wait for primary to send database (primary does backup/restore/add)
        L "Waiting for database to appear via AG (up to 3 minutes)..."
        $dbReady = $false
        $dbWait = 0
        while ($dbWait -lt 180 -and -not $dbReady) {
            $dbState = Invoke-Sql @"
SELECT d.name, drs.synchronization_state_desc, drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON drs.database_id = d.database_id
WHERE drs.is_local = 1
"@ -Safe
            if ($dbState) {
                foreach ($db in @($dbState)) {
                    L "  DB '$($db.name)': $($db.synchronization_state_desc) ($($db.synchronization_health_desc))"
                }
                $synced = @($dbState | Where-Object { $_.synchronization_state_desc -in @('SYNCHRONIZED','SYNCHRONIZING') })
                if ($synced.Count -gt 0) {
                    L "Database synchronization active!"
                    $dbReady = $true
                }
            }
            if (-not $dbReady) { Start-Sleep -Seconds 10; $dbWait += 10 }
        }

        if (-not $dbReady) { LW "Database sync not confirmed within timeout - primary may still be seeding" }
    }

    L "=========================================="
    L "AG setup completed successfully on $currentNode"
    L "=========================================="
    New-Item -Path $sentinel -ItemType File -Force | Out-Null

} catch {
    LE "Error in AG setup: $_"
    $_ | Out-File "C:\Windows\Temp\create-availability-group.err.txt" -Force
    exit 1
}
