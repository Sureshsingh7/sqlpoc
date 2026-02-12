param(
    [Parameter(Mandatory=$true)]
    [string]$DAGName,

    [Parameter(Mandatory=$true)]
    [string]$LocalAGName,

    [Parameter(Mandatory=$true)]
    [string]$LocalListenerIP,

    [Parameter(Mandatory=$true)]
    [string]$LocalPrimaryReplica,

    [Parameter(Mandatory=$true)]
    [string]$RemoteAGName,

    [Parameter(Mandatory=$true)]
    [string]$RemoteListenerIP,

    [Parameter(Mandatory=$true)]
    [string]$RemotePrimaryReplica,

    [Parameter(Mandatory=$true)]
    [string]$RemoteNodeNames,

    [Parameter(Mandatory=$true)]
    [string]$RemoteNodeIPs,

    [Parameter(Mandatory=$true)]
    [string]$SqlAdminUsername,

    [Parameter(Mandatory=$true)]
    [string]$LocalSqlPassword,

    [Parameter(Mandatory=$true)]
    [string]$RemoteSqlPassword,

    [Parameter(Mandatory=$false)]
    [string]$LocalClusterAdminUsername = "clusteradmin",

    [Parameter(Mandatory=$false)]
    [string]$RemoteClusterAdminUsername = "clusteradmin",

    [Parameter(Mandatory=$false)]
    [string]$RemoteClusterAdminPassword = "",

    [Parameter(Mandatory=$false)]
    [string]$LocalNodeNames = "",

    [Parameter(Mandatory=$false)]
    [string]$LocalNodeIPs = "",

    [Parameter(Mandatory=$false)]
    [int]$EndpointPort = 5022
)

<#
.SYNOPSIS
    Configures a Distributed Availability Group (DAG) between two independent AG clusters.
    This script runs on ALL DR cluster nodes:
      - ALL nodes: exchange HADR certificates with primary cluster nodes
      - PRIMARY node only: CREATE DAG on remote primary AG, JOIN DAG on local DR AG
.DESCRIPTION
    DAG links two independent AGs (each with their own WSFC cluster) for cross-cluster
    disaster recovery. Unlike a traditional DR replica, DAGs support:
      - Independent clusters (different domains, workgroups, or regions)
      - Cascading HA within each cluster
      - Automatic seeding of databases across clusters
.NOTES
    Pre-requisites:
      - Both AGs must be fully configured and healthy
      - VNet peering between primary and DR networks
      - Port 5022 (HADR) and 445 (SMB) open between clusters
      - Port 1433 open for remote SQL management
#>

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\configure-dag.log'
$sentinel = 'C:\Windows\Temp\.dag-setup-completed'

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

#region SQL Helpers

function Invoke-LocalSql {
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$Timeout = 30,
        [switch]$Safe
    )
    try {
        return Invoke-Sqlcmd -Query $Query -ServerInstance $env:COMPUTERNAME `
            -Username $SqlAdminUsername -Password $LocalSqlPassword `
            -TrustServerCertificate -QueryTimeout $Timeout -ErrorAction Stop
    } catch {
        if ($Safe) { return $null }
        throw
    }
}

function Invoke-RemoteSql {
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$Server,
        [int]$Timeout = 30,
        [switch]$Safe
    )
    try {
        return Invoke-Sqlcmd -Query $Query -ServerInstance $Server `
            -Username $SqlAdminUsername -Password $RemoteSqlPassword `
            -TrustServerCertificate -QueryTimeout $Timeout -ErrorAction Stop
    } catch {
        if ($Safe) { return $null }
        throw
    }
}

#endregion

# Resolve defaults
if ([string]::IsNullOrWhiteSpace($RemoteClusterAdminPassword)) {
    $RemoteClusterAdminPassword = $RemoteSqlPassword
}

# Parse comma-separated inputs
$RemoteNodeNameArray = @($RemoteNodeNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$RemoteNodeIPArray   = @($RemoteNodeIPs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$LocalNodeNameArray  = @($LocalNodeNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$LocalNodeIPArray    = @($LocalNodeIPs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

$currentNode = $env:COMPUTERNAME
$isPrimary   = ($currentNode -eq $LocalPrimaryReplica)

$CertPath     = "C:\Certificates"
$EndpointName = "HADR_Endpoint"

# Check if already completed
if (Test-Path $sentinel) {
    L "DAG setup already completed - exiting"
    exit 0
}

try {
    L "=========================================="
    L "Distributed Availability Group Setup"
    L "Node: $currentNode | Role: $(if ($isPrimary) {'PRIMARY'} else {'SECONDARY'})"
    L "DAG: $DAGName"
    L "Local AG: $LocalAGName (Listener: $LocalListenerIP)"
    L "Remote AG: $RemoteAGName (Listener: $RemoteListenerIP)"
    L "Remote Primary: $RemotePrimaryReplica"
    L "Remote Nodes: $($RemoteNodeNameArray -join ', ')"
    L "Remote IPs:   $($RemoteNodeIPArray -join ', ')"
    L "=========================================="

    # Ensure SqlServer module
    L "Ensuring SqlServer PowerShell module..."
    $sqlMod = Get-Module -ListAvailable -Name SqlServer -ErrorAction SilentlyContinue
    if (-not $sqlMod) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
        Install-Module -Name SqlServer -Force -AllowClobber -Scope AllUsers -SkipPublisherCheck -ErrorAction Stop
    }
    Import-Module SqlServer -ErrorAction Stop -DisableNameChecking
    L "SqlServer module loaded"

    # ================================================================
    # STEP 1: Add remote nodes to hosts file for name resolution
    # ================================================================
    L "STEP 1: Adding remote nodes to hosts file..."
    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $domainName = "sqlpoc.local"

    for ($i = 0; $i -lt $RemoteNodeNameArray.Count; $i++) {
        $ip   = $RemoteNodeIPArray[$i]
        $name = $RemoteNodeNameArray[$i]
        $entry = "$ip`t$name.$domainName`t$name"

        if (-not (Select-String -Path $hostsFile -Pattern ([regex]::Escape($name)) -Quiet)) {
            Add-Content -Path $hostsFile -Value $entry
            L "  Added: $entry"
        } else {
            L "  Already exists: $name"
        }
    }
    ipconfig /flushdns | Out-Null
    L "  DNS cache flushed"

    # ================================================================
    # STEP 2: Open firewall for remote node IPs
    # ================================================================
    L "STEP 2: Configuring firewall for cross-cluster communication..."
    $fwRuleName = "DAG Cross-Cluster"
    $remoteIPs = $RemoteNodeIPArray -join ','

    # HADR endpoint (5022)
    $rule5022 = "$fwRuleName 5022"
    Remove-NetFirewallRule -DisplayName $rule5022 -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule5022 `
        -Direction Inbound -Protocol TCP -LocalPort 5022 `
        -Action Allow -Profile Any -RemoteAddress $RemoteNodeIPArray `
        -Description "Allow HADR endpoint from primary cluster for DAG" | Out-Null
    L "  Firewall rule: $rule5022"

    # SMB (445) for cert exchange
    $rule445 = "$fwRuleName SMB"
    Remove-NetFirewallRule -DisplayName $rule445 -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule445 `
        -Direction Inbound -Protocol TCP -LocalPort 445 `
        -Action Allow -Profile Any -RemoteAddress $RemoteNodeIPArray `
        -Description "Allow SMB from primary cluster for cert exchange" | Out-Null
    L "  Firewall rule: $rule445"

    # SQL (1433) for remote management
    $rule1433 = "$fwRuleName SQL"
    Remove-NetFirewallRule -DisplayName $rule1433 -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule1433 `
        -Direction Inbound -Protocol TCP -LocalPort 1433 `
        -Action Allow -Profile Any -RemoteAddress $RemoteNodeIPArray `
        -Description "Allow SQL from primary cluster for DAG management" | Out-Null
    L "  Firewall rule: $rule1433"

    # ================================================================
    # STEP 2b: Configure remote nodes' hosts files and firewall (PRIMARY only)
    # ================================================================
    if ($isPrimary -and $LocalNodeNameArray.Count -gt 0) {
        L "STEP 2b: Configuring remote nodes for reverse connectivity..."
        $domainName = "sqlpoc.local"

        foreach ($i in 0..($RemoteNodeNameArray.Count - 1)) {
            $rName = $RemoteNodeNameArray[$i]
            $rIP   = $RemoteNodeIPArray[$i]

            L "  Configuring remote node $rName ($rIP)..."

            # Add local (DR) node entries to remote hosts file via SMB
            try {
                $uncPath = "\\$rIP\C`$"
                $netResult = cmd /c "net use $uncPath /user:$rName\$RemoteClusterAdminUsername `"$RemoteClusterAdminPassword`" 2>&1"
                if ($LASTEXITCODE -ne 0 -and $netResult -notmatch "already") {
                    LW "    SMB connect to $rName failed: $netResult"
                    continue
                }

                $remoteHosts = "$uncPath\Windows\System32\drivers\etc\hosts"
                $hostsContent = Get-Content $remoteHosts -Raw -ErrorAction Stop

                for ($j = 0; $j -lt $LocalNodeNameArray.Count; $j++) {
                    $localName = $LocalNodeNameArray[$j]
                    $localIP   = $LocalNodeIPArray[$j]
                    $entry = "$localIP`t$localName.$domainName`t$localName"

                    if ($hostsContent -notmatch [regex]::Escape($localName)) {
                        Add-Content -Path $remoteHosts -Value $entry
                        L "    Added to $rName hosts: $entry"
                    } else {
                        L "    Already in $rName hosts: $localName"
                    }
                }

                cmd /c "net use $uncPath /delete /y 2>&1" | Out-Null
            } catch {
                LW "    Failed to update hosts on ${rName}: $($_.Exception.Message)"
                cmd /c "net use $uncPath /delete /y 2>&1" | Out-Null
            }

            # Add firewall rules on remote nodes via remote SQL xp_cmdshell
            try {
                $localIPs = $LocalNodeIPArray -join ','
                $fwSql = @"
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;
EXEC xp_cmdshell 'netsh advfirewall firewall delete rule name="DAG Cross-Cluster 5022" >nul 2>&1';
EXEC xp_cmdshell 'netsh advfirewall firewall add rule name="DAG Cross-Cluster 5022" dir=in action=allow protocol=tcp localport=5022 remoteip=$localIPs';
EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;
"@
                Invoke-RemoteSql $fwSql -Server $rIP -Safe
                L "    Firewall rule added on $rName for DR IPs"
            } catch {
                LW "    Failed to add firewall on ${rName}: $($_.Exception.Message)"
            }
        }
    }

    # ================================================================
    # STEP 3: Verify local AG is healthy
    # ================================================================
    L "STEP 3: Verifying local AG '$LocalAGName' is healthy..."
    $localAG = Invoke-LocalSql "SELECT name, cluster_type_desc FROM sys.availability_groups WHERE name = '$LocalAGName'" -Safe
    if (-not $localAG) {
        LE "Local AG '$LocalAGName' not found!"
        exit 1
    }
    L "  Local AG found: $($localAG.name) (cluster_type=$($localAG.cluster_type_desc))"

    # ================================================================
    # STEP 4: Test connectivity to remote primary
    # ================================================================
    L "STEP 4: Testing connectivity to remote cluster..."
    foreach ($i in 0..($RemoteNodeNameArray.Count - 1)) {
        $rName = $RemoteNodeNameArray[$i]
        $rIP   = $RemoteNodeIPArray[$i]

        # TCP 5022
        $tcp5022 = Test-NetConnection -ComputerName $rIP -Port 5022 -WarningAction SilentlyContinue
        L "  ${rName} (${rIP}):5022 = $(if($tcp5022.TcpTestSucceeded){'OK'}else{'FAILED'})"

        # TCP 445
        $tcp445 = Test-NetConnection -ComputerName $rIP -Port 445 -WarningAction SilentlyContinue
        L "  ${rName} (${rIP}):445  = $(if($tcp445.TcpTestSucceeded){'OK'}else{'FAILED'})"

        # TCP 1433
        $tcp1433 = Test-NetConnection -ComputerName $rIP -Port 1433 -WarningAction SilentlyContinue
        L "  ${rName} (${rIP}):1433 = $(if($tcp1433.TcpTestSucceeded){'OK'}else{'FAILED'})"
    }

    # Verify remote AG exists
    $remoteAG = Invoke-RemoteSql "SELECT name FROM sys.availability_groups WHERE name = '$RemoteAGName'" -Server $RemotePrimaryReplica -Safe
    if (-not $remoteAG) {
        LE "Remote AG '$RemoteAGName' not found on $RemotePrimaryReplica!"
        exit 1
    }
    L "  Remote AG '$RemoteAGName' verified on $RemotePrimaryReplica"

    # ================================================================
    # STEP 5: Cross-cluster certificate exchange via SMB
    # ================================================================
    L "STEP 5: Exchanging HADR certificates with remote cluster..."

    $localCertName = "${currentNode}_HADR_Cert"
    $localCertFile = "$CertPath\$localCertName.cer"

    if (-not (Test-Path $localCertFile)) {
        LE "Local certificate not found: $localCertFile"
        LE "HADR endpoint setup must complete before DAG setup"
        exit 1
    }
    L "  Local cert ready: $localCertFile"

    foreach ($i in 0..($RemoteNodeNameArray.Count - 1)) {
        $rName = $RemoteNodeNameArray[$i]
        $rIP   = $RemoteNodeIPArray[$i]
        $remoteCertName = "${rName}_HADR_Cert"
        $remoteCertFile = "$CertPath\$remoteCertName.cer"

        L "  --- Certificate exchange with $rName ($rIP) ---"

        # Use IP for SMB to avoid DNS dependency
        $uncPath = "\\$rIP\C`$"
        $remoteCertFolder = "$uncPath\Certificates"

        $maxWait = 300
        $waited = 0
        $exchangeComplete = $false

        while ($waited -lt $maxWait -and -not $exchangeComplete) {
            try {
                # Connect via SMB using remote cluster admin
                $netResult = cmd /c "net use $uncPath /user:$rName\$RemoteClusterAdminUsername `"$RemoteClusterAdminPassword`" 2>&1"
                if ($LASTEXITCODE -ne 0 -and $netResult -notmatch "already") {
                    throw "SMB connect failed: $netResult"
                }

                # Ensure remote cert folder exists
                if (-not (Test-Path $remoteCertFolder)) {
                    New-Item -ItemType Directory -Path $remoteCertFolder -Force | Out-Null
                }

                # Push LOCAL cert TO remote node
                $remoteDestCert = "$remoteCertFolder\$localCertName.cer"
                if (-not (Test-Path $remoteDestCert)) {
                    Copy-Item $localCertFile $remoteDestCert -Force
                    L "    Pushed local cert to $rName"
                } else {
                    L "    Local cert already on $rName"
                }

                # Pull REMOTE cert FROM remote node
                $remoteSrcCert = "$remoteCertFolder\$remoteCertName.cer"
                if (Test-Path $remoteSrcCert) {
                    if (-not (Test-Path $remoteCertFile)) {
                        Copy-Item $remoteSrcCert $remoteCertFile -Force
                        L "    Pulled remote cert from $rName"
                    } else {
                        L "    Remote cert already local"
                    }
                    $exchangeComplete = $true
                } else {
                    L "    Remote cert not ready on $rName (${waited}/${maxWait}s)"
                }

                cmd /c "net use $uncPath /delete /y 2>&1" | Out-Null

            } catch {
                LW "    SMB error (${waited}/${maxWait}s): $($_.Exception.Message)"
                cmd /c "net use $uncPath /delete /y 2>&1" | Out-Null
            }

            if (-not $exchangeComplete) {
                Start-Sleep -Seconds 15
                $waited += 15
            }
        }

        if (-not $exchangeComplete) {
            LW "  Failed to exchange cert with $rName after ${maxWait}s - continuing"
        } else {
            L "  Certificate exchange with $rName complete"
        }
    }

    # ================================================================
    # STEP 6: Import remote certificates locally and grant CONNECT
    # ================================================================
    L "STEP 6: Importing remote certificates into local SQL Server..."

    foreach ($rName in $RemoteNodeNameArray) {
        $remoteCertName = "${rName}_HADR_Cert"
        $remoteCertFile = "$CertPath\$remoteCertName.cer"
        $importedCertName = "${rName}_DAG_Imported_Cert"
        $loginName = "${rName}_DAG_Login"

        if (-not (Test-Path $remoteCertFile)) {
            LW "  Skipping $rName - cert file not found: $remoteCertFile"
            continue
        }

        L "  Importing $remoteCertName..."
        Invoke-LocalSql "IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name='$importedCertName') CREATE CERTIFICATE [$importedCertName] FROM FILE='$remoteCertFile';" -Safe
        Invoke-LocalSql "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='$loginName') CREATE LOGIN [$loginName] FROM CERTIFICATE [$importedCertName];" -Safe
        Invoke-LocalSql "GRANT CONNECT ON ENDPOINT::[$EndpointName] TO [$loginName];" -Safe
        L "  ${rName}: cert imported, login created, CONNECT granted"
    }

    # ================================================================
    # STEP 7: Import local certs on remote primary nodes via remote SQL
    # ================================================================
    L "STEP 7: Importing local certificates on remote SQL nodes..."

    foreach ($i in 0..($RemoteNodeNameArray.Count - 1)) {
        $rName = $RemoteNodeNameArray[$i]
        $rIP   = $RemoteNodeIPArray[$i]
        $importedCertName = "${currentNode}_DAG_Imported_Cert"
        $loginName = "${currentNode}_DAG_Login"

        # The local cert was pushed to the remote node's C:\Certificates in Step 5
        $remoteCertFilePath = "C:\Certificates\$localCertName.cer"

        L "  Importing $localCertName on $rName ($rIP)..."
        try {
            Invoke-RemoteSql "IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name='$importedCertName') CREATE CERTIFICATE [$importedCertName] FROM FILE='$remoteCertFilePath';" -Server $rIP -Safe
            Invoke-RemoteSql "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='$loginName') CREATE LOGIN [$loginName] FROM CERTIFICATE [$importedCertName];" -Server $rIP -Safe
            Invoke-RemoteSql "GRANT CONNECT ON ENDPOINT::[$EndpointName] TO [$loginName];" -Server $rIP -Safe
            L "  ${rName}: local cert imported, login created, CONNECT granted"
        } catch {
            LW "  Failed to import cert on ${rName}: $($_.Exception.Message)"
        }
    }

    # ================================================================
    # STEP 8 (PRIMARY ONLY): Create and Join DAG
    # ================================================================
    if ($isPrimary) {
        L "STEP 8: Creating Distributed Availability Group (PRIMARY node)..."

        # Check if DAG already exists on remote side
        $existingDAG = Invoke-RemoteSql "SELECT name FROM sys.availability_groups WHERE name = '$DAGName'" -Server $RemotePrimaryReplica -Safe
        if ($existingDAG) {
            L "  DAG '$DAGName' already exists on remote - checking local..."
            $localDAG = Invoke-LocalSql "SELECT name FROM sys.availability_groups WHERE name = '$DAGName'" -Safe
            if ($localDAG) {
                L "  DAG already exists on both sides - setup complete"
                New-Item -Path $sentinel -ItemType File -Force | Out-Null
                exit 0
            }
            L "  DAG exists on remote but not local - will join"
        }

        # Build LISTENER_URLs using ILB frontend IPs
        # Use direct primary replica hostnames instead of ILB IPs for LISTENER_URLs.
        # ILB floating-IP rules require a health-probe responder (port 59999) which may
        # not be running, causing ILB to mark backends as unhealthy and drop 5022 traffic.
        # Direct node hostnames work reliably as long as hosts-file entries exist (Step 2b).
        $remoteListenerUrl = "TCP://${RemotePrimaryReplica}:${EndpointPort}"
        $localListenerUrl  = "TCP://${LocalPrimaryReplica}:${EndpointPort}"

        L "  Remote LISTENER_URL: $remoteListenerUrl  (direct hostname, not ILB)"
        L "  Local  LISTENER_URL: $localListenerUrl  (direct hostname, not ILB)"

        # Ensure remote primary's SQL Server properly recognises its WSFC cluster.
        # Without this cycle, DAG creation may fail with:
        #   "Always On AG replica manager is waiting for the host computer to start a WSFC cluster"
        # The cycle is safe and idempotent - it briefly restarts SQL then re-enables HADR.
        L "  Step 8a: AlwaysOn cycle on remote primary to ensure WSFC integration..."
        try {
            $alwaysOnCycleCmd = @"
Import-Module SqlServer -ErrorAction SilentlyContinue
`$svcName = 'MSSQLSERVER'
`$instanceName = `$env:COMPUTERNAME
Write-Output "Disabling AlwaysOn on `$instanceName..."
Disable-SqlAlwaysOn -ServerInstance `$instanceName -Force -ErrorAction Stop
Start-Sleep -Seconds 5
Write-Output "Re-enabling AlwaysOn on `$instanceName..."
Enable-SqlAlwaysOn -ServerInstance `$instanceName -Force -ErrorAction Stop
Start-Sleep -Seconds 10
Write-Output "AlwaysOn cycle complete on `$instanceName"
"@
            Invoke-RemoteSql "EXEC xp_cmdshell 'powershell -NoProfile -Command `"$($alwaysOnCycleCmd -replace '"','\"' -replace "`n",'; ')`"'" -Server $RemotePrimaryReplica -Timeout 120
            L "  AlwaysOn cycle completed on remote primary"
            # Wait for SQL to stabilise after restart
            Start-Sleep -Seconds 15
            # Verify AG is back online
            $remoteAGCheck = Invoke-RemoteSql "SELECT name, replica_server_name FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id WHERE ag.name = '$RemoteAGName'" -Server $RemotePrimaryReplica -Safe
            if ($remoteAGCheck) {
                L "  Remote AG '$RemoteAGName' confirmed online after AlwaysOn cycle"
            } else {
                LW "  Remote AG '$RemoteAGName' not found after cycle - may need manual check"
            }
        } catch {
            LW "  AlwaysOn cycle on remote failed: $($_.Exception.Message) - proceeding anyway"
        }

        # CREATE DAG on the remote (primary) AG's primary replica
        if (-not $existingDAG) {
            L "  Creating DAG '$DAGName' on remote primary ($RemotePrimaryReplica)..."

            $createDAGSQL = @"
CREATE AVAILABILITY GROUP [$DAGName]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
    N'$RemoteAGName' WITH (
        LISTENER_URL = N'$remoteListenerUrl',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    ),
    N'$LocalAGName' WITH (
        LISTENER_URL = N'$localListenerUrl',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    );
"@
            L "  SQL: $createDAGSQL"
            try {
                Invoke-RemoteSql $createDAGSQL -Server $RemotePrimaryReplica -Timeout 120
                L "  DAG '$DAGName' created on remote primary"
            } catch {
                LE "  Failed to create DAG on remote: $($_.Exception.Message)"
                exit 1
            }

            # Wait for DAG to propagate
            Start-Sleep -Seconds 15
        }

        # JOIN DAG on the local (DR) AG's primary replica
        L "  Joining DAG '$DAGName' on local DR AG..."

        $joinDAGSQL = @"
ALTER AVAILABILITY GROUP [$DAGName]
JOIN
AVAILABILITY GROUP ON
    N'$RemoteAGName' WITH (
        LISTENER_URL = N'$remoteListenerUrl',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    ),
    N'$LocalAGName' WITH (
        LISTENER_URL = N'$localListenerUrl',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    );
"@
        L "  SQL: $joinDAGSQL"

        $joined = $false
        $maxRetries = 12
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                Invoke-LocalSql $joinDAGSQL -Timeout 120
                L "  DAG '$DAGName' joined successfully!"
                $joined = $true
                break
            } catch {
                LW "  Join attempt $attempt/$maxRetries failed: $($_.Exception.Message)"
                if ($attempt -lt $maxRetries) { Start-Sleep -Seconds 15 }
            }
        }

        if (-not $joined) {
            LE "Failed to join DAG after $maxRetries attempts"
            exit 1
        }

        # Grant seeding permission for automatic database seeding
        L "  Granting CREATE ANY DATABASE for automatic seeding..."
        Invoke-LocalSql "ALTER AVAILABILITY GROUP [$LocalAGName] GRANT CREATE ANY DATABASE" -Safe
        L "  Seeding permission granted"

        # ================================================================
        # STEP 9: Wait for database synchronization via DAG
        # ================================================================
        L "STEP 9: Waiting for DAG database synchronization (up to 5 minutes)..."
        $syncOk = $false
        $syncWait = 0
        $syncTimeout = 300

        while ($syncWait -lt $syncTimeout -and -not $syncOk) {
            # Check DAG replica states on local
            $dagStates = Invoke-LocalSql @"
SELECT
    ag.name AS ag_name,
    r.replica_server_name,
    rs.role_desc,
    rs.connected_state_desc,
    rs.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_replicas r ON rs.replica_id = r.replica_id AND rs.group_id = r.group_id
JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
WHERE ag.name IN ('$DAGName', '$LocalAGName')
"@ -Safe

            if ($dagStates) {
                foreach ($s in @($dagStates)) {
                    L "    [$($s.ag_name)] $($s.replica_server_name): role=$($s.role_desc) connected=$($s.connected_state_desc) health=$($s.synchronization_health_desc)"
                }
            }

            # Check database replica states
            $dbStates = Invoke-LocalSql @"
SELECT
    d.name AS db_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_local
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON drs.database_id = d.database_id
WHERE drs.is_local = 1
"@ -Safe

            if ($dbStates) {
                $synced = @($dbStates | Where-Object { $_.synchronization_state_desc -in @('SYNCHRONIZED','SYNCHRONIZING') })
                foreach ($db in @($dbStates)) {
                    L "    DB '$($db.db_name)': $($db.synchronization_state_desc) ($($db.synchronization_health_desc))"
                }
                if ($synced.Count -gt 0) {
                    L "  Database synchronization active via DAG!"
                    $syncOk = $true
                }
            } else {
                L "  No database replicas yet (${syncWait}/${syncTimeout}s) - waiting for auto-seeding..."
            }

            if (-not $syncOk) {
                Start-Sleep -Seconds 15
                $syncWait += 15
            }
        }

        if ($syncOk) {
            L "DAG synchronization verified!"
        } else {
            LW "DAG synchronization not confirmed within timeout"
            LW "Auto-seeding may still be in progress - check manually"
        }

    } else {
        L "STEP 8: Skipped (SECONDARY node - DAG SQL only runs on PRIMARY)"
    }

    # ================================================================
    # COMPLETE
    # ================================================================
    L "=========================================="
    L "DAG setup completed on $currentNode"
    L "=========================================="
    New-Item -Path $sentinel -ItemType File -Force | Out-Null

} catch {
    LE "DAG setup failed: $_"
    $_ | Out-File "C:\Windows\Temp\configure-dag.err.txt" -Force
    exit 1
}
