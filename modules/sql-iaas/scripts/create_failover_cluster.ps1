param(
    [Parameter(Mandatory=$false)]
    [string[]]$NodeIPs = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$ClusterIPs = @(),

    [Parameter(Mandatory=$false)]
    [string]$ClusterName = "sqlpoc-cluster",

    [Parameter(Mandatory=$false)]
    [string[]]$NodeNames = @(),

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminUsername = "clusteradmin",

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminPasswordSecure,

    [Parameter(Mandatory=$false)]
    [string]$WitnessStorageAccountName = "",

    [Parameter(Mandatory=$false)]
    [string]$WitnessStorageKeyBase64 = "",

    [Parameter(Mandatory=$false)]
    [string]$PrimaryClusterDNS = "",

    [Parameter(Mandatory=$false)]
    [string]$PrimaryClusterIP = ""
)

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\create-failover-cluster.log'
$err = 'C:\Windows\Temp\create-failover-cluster.err.txt'

# Handle comma-separated strings for array parameters (workaround for RunCommand passing single strings)
if ($NodeIPs.Count -eq 1 -and $NodeIPs[0] -like "*,*") { $NodeIPs = $NodeIPs[0] -split "," }
if ($ClusterIPs.Count -eq 1 -and $ClusterIPs[0] -like "*,*") { $ClusterIPs = $ClusterIPs[0] -split "," }
if ($NodeNames.Count -eq 1 -and $NodeNames[0] -like "*,*") { $NodeNames = $NodeNames[0] -split "," }

# Decode cluster admin password from base64
$ClusterAdminPassword = ""
if (-not [string]::IsNullOrWhiteSpace($ClusterAdminPasswordSecure)) {
    try {
        $ClusterAdminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ClusterAdminPasswordSecure))
    } catch {
        $ClusterAdminPassword = $ClusterAdminPasswordSecure
    }
}

# Logging
$script:LogLevel = "DEBUG"

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("DEBUG","INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    $levels = @{ "DEBUG"=0; "INFO"=1; "WARN"=2; "ERROR"=3 }
    if ($levels[$Level] -ge $levels[$script:LogLevel]) {
        $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
        Add-Content -Path $log -Value $entry
        if ($Level -eq "ERROR") { Write-Host $entry -ForegroundColor Red }
    }
}

function L([string]$m) { Write-Log -Message $m -Level "INFO" }
function LD([string]$m) { Write-Log -Message $m -Level "DEBUG" }
function LW([string]$m) { Write-Log -Message $m -Level "WARN" }
function LE([string]$m) { Write-Log -Message $m -Level "ERROR" }

LD "ClusterAdminUsername = $ClusterAdminUsername"
LD "NodeIPs = $($NodeIPs -join ', ')"
LD "NodeNames = $($NodeNames -join ', ')"
LD "ClusterIPs = $($ClusterIPs -join ', ')"

if (-not [string]::IsNullOrWhiteSpace($PrimaryClusterDNS)) {
    LD "DR Configuration: PrimaryClusterDNS = $PrimaryClusterDNS"
}
if (-not [string]::IsNullOrWhiteSpace($PrimaryClusterIP)) {
    LD "DR Configuration: PrimaryClusterIP = $PrimaryClusterIP"
}

function ValidateInputs {
    L "Validating inputs"
    $requiredParams = @{
        "NodeIPs" = $NodeIPs
        "ClusterIPs" = $ClusterIPs
        "ClusterName" = $ClusterName
        "NodeNames" = $NodeNames
    }

    foreach ($param in $requiredParams.GetEnumerator()) {
        if ($null -eq $param.Value -or ($param.Value -is [Array] -and $param.Value.Count -eq 0) -or ([string]::IsNullOrWhiteSpace($param.Value))) {
            LE "Required parameter '$($param.Key)' is empty"
            throw "$($param.Key) cannot be empty"
        }
    }

    if ($NodeIPs.Count -ne $NodeNames.Count) {
        throw "NodeIPs count ($($NodeIPs.Count)) must match NodeNames count ($($NodeNames.Count))"
    }

    if (-not [string]::IsNullOrWhiteSpace($ClusterAdminUsername)) {
        if ([string]::IsNullOrWhiteSpace($ClusterAdminPassword)) {
             LE "ClusterAdminPassword is empty. Secure parameter length: $(if ($ClusterAdminPasswordSecure) { $ClusterAdminPasswordSecure.Length } else { 'null' })"
             throw "ClusterAdminUsername ('$ClusterAdminUsername') was provided but ClusterAdminPassword is empty."
        }
    }

    L "All inputs validated successfully"
}

function ConfigureVMPrerequisites {
    L "Configuring VM prerequisites"

    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $domainName = "sqlpoc.local"

    for ($i = 0; $i -lt $NodeIPs.Count; $i++) {
        $ip = $NodeIPs[$i]
        $name = $NodeNames[$i]
        $entry = "$ip`t$name.$domainName`t$name"

        # Check if entry exists with correct IP; update if IP has changed
        $existingLine = Select-String -Path $hostsFile -Pattern "\s$([regex]::Escape($name))\b" -ErrorAction SilentlyContinue
        if ($existingLine) {
            if ($existingLine.Line -notmatch "^\s*$([regex]::Escape($ip))\s") {
                LD "Updating hosts entry for $name (IP changed to $ip)"
                $content = Get-Content $hostsFile | ForEach-Object {
                    if ($_ -match "\s$([regex]::Escape($name))\b" -and $_ -notmatch "^\s*#") { $entry } else { $_ }
                }
                Set-Content -Path $hostsFile -Value $content -Force
            } else {
                LD "Hosts entry for $name already correct"
            }
        } else {
            LD "Adding hosts entry: $entry"
            Add-Content -Path $hostsFile -Value $entry
        }
    }

    LD "Setting NV Domain to $domainName"
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\services\Tcpip\Parameters" -Name "NV Domain" -Value $domainName -Force

    LD "Setting LocalAccountTokenFilterPolicy for remote admin"
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "LocalAccountTokenFilterPolicy" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null

    LD "Configuring ICMP firewall rule"
    $existingRule = netsh advfirewall firewall show rule name="Allow ICMPv4" 2>$null
    if ($LASTEXITCODE -ne 0) {
        netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4 dir=in action=allow | Out-Null
    }

    LD "Installing Failover Clustering feature"
    Import-Module ServerManager
    $feature = Get-WindowsFeature -Name Failover-Clustering -ErrorAction SilentlyContinue
    if ($null -eq $feature -or -not $feature.Installed) {
        Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools | Out-Null
        L "Failover Clustering installed"
    } else {
        LD "Failover Clustering already installed"
    }

    LD "Configuring WinRM for Workgroup Auth"
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue | Out-Null
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
    Restart-Service WinRM

    LD "Creating WinRM Firewall rule for cluster node subnet connectivity"
    if ($NodeIPs.Count -gt 0) {
        $ruleName = "Allow_WinRM_Cluster_Nodes"
        Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue

        New-NetFirewallRule -Name $ruleName `
            -DisplayName "Allow WinRM from Cluster Nodes" `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort 5985,5986 `
            -RemoteAddress $NodeIPs `
            -Profile Any `
            -ErrorAction Stop | Out-Null
        LD "Firewall rule '$ruleName' created for IPs: $($NodeIPs -join ', ')"
    }

    # Create firewall rule for HADR endpoint (port 5022) and SMB (445)
    $hadrRuleName = "SQL AG Endpoint 5022"
    if (-not (Get-NetFirewallRule -DisplayName $hadrRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $hadrRuleName `
            -Direction Inbound -Protocol TCP -LocalPort 5022 `
            -Action Allow -Profile Any `
            -Description "Allow SQL Server AG mirroring endpoint" `
            -ErrorAction Stop | Out-Null
        LD "Firewall rule '$hadrRuleName' created"
    }

    $smbRuleName = "Allow SMB for Cert Exchange"
    if (-not (Get-NetFirewallRule -DisplayName $smbRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $smbRuleName `
            -Direction Inbound -Protocol TCP -LocalPort 445 `
            -Action Allow -Profile Any -RemoteAddress $NodeIPs `
            -Description "Allow SMB between cluster nodes for certificate exchange" `
            -ErrorAction Stop | Out-Null
        LD "Firewall rule '$smbRuleName' created"
    }

    L "VM prerequisites configured"
}

function ConfigureHostsFile {
    LD "Configuring cluster hosts file entries"

    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
    if ($null -eq $hostsContent) { $hostsContent = "" }

    foreach ($clusterIP in $ClusterIPs) {
        $line = "$clusterIP`t$ClusterName"
        if ($hostsContent -notmatch [regex]::Escape($clusterIP)) {
            LD "Adding hosts entry: $line"
            Add-Content -Path $hostsFile -Value $line -Force
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PrimaryClusterIP) -and -not [string]::IsNullOrWhiteSpace($PrimaryClusterDNS)) {
        $line = "$PrimaryClusterIP`t$PrimaryClusterDNS"
        if ($hostsContent -notmatch [regex]::Escape($PrimaryClusterIP)) {
            LD "Adding DR hosts entry: $line"
            Add-Content -Path $hostsFile -Value $line -Force
        }
    }

    ipconfig /flushdns | Out-Null
    LD "Hosts file configured, DNS cache flushed"
}

function ValidateNodeConnectivity {
    L "Validating network connectivity"
    $maxRetries = 6
    $retryDelay = 10

    $NodeNames | ForEach-Object {
        $nodeName = $_
        $reachable = $false
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            if (Test-Connection -ComputerName $nodeName -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                LD "Node $nodeName is reachable (attempt $attempt)"
                $reachable = $true
                break
            }
            if ($attempt -lt $maxRetries) {
                LW "Cannot reach node $nodeName (attempt $attempt/$maxRetries), retrying in ${retryDelay}s..."
                Start-Sleep -Seconds $retryDelay
            }
        }
        if (-not $reachable) {
            LE "Cannot reach node: $nodeName after $maxRetries attempts"
            throw "Cannot reach $nodeName"
        }
    }
    L "All nodes are reachable"
}

function CreateClusterAdminLocal {
    param(
        [string]$Username,
        [string]$Password
    )

    L "Creating local cluster admin user '$Username' on $env:COMPUTERNAME"

    try {
        $existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
        if ($existingUser) {
            LD "User '$Username' already exists locally"
            $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
            Set-LocalUser -Name $Username -Password $securePassword -ErrorAction Stop
        } else {
            $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
            New-LocalUser -Name $Username -Password $securePassword -FullName "Cluster Admin User" -Description "User for failover cluster operations" -PasswordNeverExpires -ErrorAction Stop
            L "User '$Username' created locally"
        }

        $adminGroup = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$Username" }
        if (-not $adminGroup) {
            Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction Stop
            L "User '$Username' added to Administrators group"
        } else {
            LD "User '$Username' already in Administrators group"
        }
        return $true
    } catch {
        LE "Failed to create/update local admin user: $_"
        throw
    }
}

function WaitForOtherNodes {
    param(
        [string[]]$Nodes,
        [string[]]$NodeIPs,
        [string]$Username,
        [string]$Password
    )

    $localName = $env:COMPUTERNAME
    $otherNodes = $Nodes | Where-Object { $_ -ne $localName }

    if ($otherNodes.Count -eq 0) { return }

    L "Waiting for other nodes to be ready: $($otherNodes -join ', ')"

    $nodeIpMap = @{}
    for ($i = 0; $i -lt $Nodes.Count; $i++) {
        if ($i -lt $NodeIPs.Count) {
            $nodeIpMap[$Nodes[$i]] = $NodeIPs[$i]
        }
    }

    $securePwd = ConvertTo-SecureString $Password -AsPlainText -Force

    foreach ($node in $otherNodes) {
        $ready = $false
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastError = $null

        $target = if ($nodeIpMap.ContainsKey($node)) { $nodeIpMap[$node] } else { $node }
        LD "Checking connectivity to node '$node' via target '$target'"

        while ($sw.Elapsed.TotalMinutes -lt 10) {
            try {
                $cred = New-Object System.Management.Automation.PSCredential("$node\$Username", $securePwd)
                $res = Invoke-Command -ComputerName $target -Credential $cred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop

                if ($res -eq $node) {
                    LD "Node $node is ready and accessible with cluster admin credentials"
                    $ready = $true
                    break
                }
            } catch {
                $lastError = $_
                if ([int]$sw.Elapsed.TotalSeconds % 60 -lt 15) {
                     Write-Host "Waiting for $node ($target)... Last error: $($_.Exception.Message)"
                }
            }
            Start-Sleep -Seconds 15
        }

        if (-not $ready) {
            $errMsg = "Timeout waiting for node $node ($target). Last error: $($lastError | Out-String)"
            LE $errMsg
            throw $errMsg
        }
    }
}

function EnableSqlAlwaysOn {
    L "Enabling SQL Server Always On"

    # Check if already enabled
    try {
        Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue 2>$null
        $hadrEnabled = Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS HadrEnabled" -ErrorAction SilentlyContinue
        if ($hadrEnabled -and $hadrEnabled.HadrEnabled -eq 1) {
            L "Always On is already enabled"
            return
        }
    } catch {
        LD "Could not check current HADR status: $_"
    }

    # Method 1: Try Enable-SqlAlwaysOn from SQLPS module (built-in)
    try {
        L "Attempting to enable Always On via Enable-SqlAlwaysOn (SQLPS)..."
        Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue 2>$null
        Enable-SqlAlwaysOn -ServerInstance localhost -Force -NoServiceRestart -ErrorAction Stop
        L "Always On enabled via SQLPS - restarting SQL Server..."
        Restart-Service -Name MSSQLSERVER -Force -ErrorAction Stop
        Start-Sleep -Seconds 30
        L "Always On enabled on $env:COMPUTERNAME"
        return
    } catch {
        LW "Enable-SqlAlwaysOn (SQLPS) failed: $_"
    }

    # Method 2: dbatools
    try {
        L "Attempting to enable Always On via dbatools..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module dbatools -Force -Scope AllUsers -AllowClobber -SkipPublisherCheck -ErrorAction SilentlyContinue
        Import-Module dbatools -Force
        Enable-DbaAgHadr -SqlInstance $env:COMPUTERNAME -Force -Confirm:$false
        Start-Sleep -Seconds 30
        L "Always On enabled on $env:COMPUTERNAME (via dbatools)"
        return
    } catch {
        LW "dbatools method failed: $_"
    }

    # Method 3: Direct registry
    try {
        L "Attempting to enable Always On via registry..."
        $sqlInstances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL" -ErrorAction Stop
        $instanceName = $sqlInstances.MSSQLSERVER
        if (-not $instanceName) { throw "Could not find SQL Server instance name in registry" }

        $hadrPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\MSSQLServer\HADR"
        if (-not (Test-Path $hadrPath)) { New-Item -Path $hadrPath -Force | Out-Null }
        Set-ItemProperty -Path $hadrPath -Name "HADR_Enabled" -Value 1 -Type DWord -ErrorAction Stop
        L "Registry HADR_Enabled set to 1 - restarting SQL Server..."
        Restart-Service -Name MSSQLSERVER -Force -ErrorAction Stop
        Start-Sleep -Seconds 30
        L "Always On enabled on $env:COMPUTERNAME (via registry)"
        return
    } catch {
        LW "Registry method failed: $_"
    }

    LE "All methods to enable Always On failed"
    throw "Failed to enable Always On on $env:COMPUTERNAME"
}

function CheckClusterExists {
    param([string]$Name)

    LD "Checking if cluster '$Name' exists"
    try {
        $currentCluster = Get-Cluster -ErrorAction SilentlyContinue
        if ($null -ne $currentCluster) {
            L "Node is part of cluster: $($currentCluster.Name)"
            if ($currentCluster.Name -eq $Name) {
                return $true
            } else {
                LE "Node is already part of different cluster '$($currentCluster.Name)'"
                throw "Node is already part of different cluster '$($currentCluster.Name)'"
            }
        }
    } catch [System.Management.Automation.CommandNotFoundException] {
        LD "Get-Cluster cmdlet not available"
    }
    return $false
}

function CreateFailoverCluster {
    L "Creating failover cluster '$ClusterName'"

    $scriptDir = "C:\ClusterSetup"
    $resultFile = "$scriptDir\cluster-result.txt"
    $errorFile = "$scriptDir\cluster-error.txt"
    $taskName = "CreateCluster_Task"

    if (-not (Test-Path $scriptDir)) {
        New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
    }
    Remove-Item $resultFile, $errorFile -Force -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($ClusterAdminUsername) -or [string]::IsNullOrWhiteSpace($ClusterAdminPassword)) {
        LE "Cluster admin credentials required for scheduled task"
        return $false
    }

    $fullUsername = "$env:COMPUTERNAME\$ClusterAdminUsername"
    LD "Using credentials: $fullUsername"

    $clusterScript = "$scriptDir\cluster-startup.ps1"
    @"
`$log = '$scriptDir\cluster-startup.log'
Add-Content -Path `$log -Value ((Get-Date -Format o) + " Running as: `$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)")

try {
    `$existing = Get-Cluster -ErrorAction SilentlyContinue
    if (`$existing) {
        Add-Content -Path `$log -Value "Cluster already exists: `$(`$existing.Name)"
        "ALREADY_EXISTS:`$(`$existing.Name)" | Out-File '$resultFile' -Force
        exit 0
    }

    Add-Content -Path `$log -Value "Creating cluster '$ClusterName' with nodes '$($NodeNames -join "','")'..."
    `$c = New-Cluster -Name '$ClusterName' -Node @('$($NodeNames -join "','")') -AdministrativeAccessPoint DNS -StaticAddress @('$($ClusterIPs -join "','")') -NoStorage -Force -ErrorAction Stop
    Add-Content -Path `$log -Value "SUCCESS: Cluster `$(`$c.Name) created"
    "SUCCESS:`$(`$c.Name)" | Out-File '$resultFile' -Force
} catch {
    Add-Content -Path `$log -Value "ERROR: `$_"
    `$_ | Out-File '$errorFile' -Force
    exit 1
}
"@ | Out-File -FilePath $clusterScript -Force -Encoding UTF8

    LD "Cluster script created: $clusterScript"

    try { $null = schtasks /delete /tn $taskName /f 2>&1 } catch { }

    $futureTime = (Get-Date).AddMinutes(1).ToString("HH:mm")
    LD "Task: $taskName, Script: $clusterScript, Time: $futureTime, User: $fullUsername"

    $cmdLine = "schtasks /create /tn $taskName /tr `"powershell.exe -ExecutionPolicy Bypass -File $clusterScript`" /sc once /st $futureTime /ru $fullUsername /rp `"$ClusterAdminPassword`" /rl highest /f"
    $createResult = cmd /c $cmdLine 2>&1
    $createExitCode = $LASTEXITCODE

    LD "schtasks create exit=$createExitCode result=$createResult"

    if ($createExitCode -ne 0) {
        LE "Failed to create scheduled task"
        return $false
    }

    L "Running scheduled task"
    $runResult = schtasks /run /tn $taskName 2>&1
    LD "schtasks run result: $runResult"

    L "Waiting 60s for cluster creation"
    Start-Sleep -Seconds 60

    $maxWait = 300
    $waited = 0
    while ($waited -lt $maxWait) {
        $taskStatus = (schtasks /query /tn $taskName /fo csv 2>$null | ConvertFrom-Csv).Status
        LD "Task status: $taskStatus (${waited}s elapsed)"

        if ($taskStatus -ne "Running") { break }
        if (Test-Path $resultFile) { LD "Result file found"; break }
        if (Test-Path $errorFile) { LD "Error file found"; break }

        Start-Sleep -Seconds 10
        $waited += 10
    }

    $taskInfo = schtasks /query /tn $taskName /v /fo csv 2>$null | ConvertFrom-Csv
    LD "Task completed: LastRun=$($taskInfo.'Last Run Time'), Result=$($taskInfo.'Last Result')"

    try { $null = schtasks /delete /tn $taskName /f 2>&1 } catch { }

    if (Test-Path $resultFile) {
        $res = Get-Content $resultFile -Raw
        LD "Result: $res"
        if ($res -match 'SUCCESS|ALREADY_EXISTS') { return $true }
    }

    if (Test-Path $errorFile) {
        LE "Cluster error: $(Get-Content $errorFile -Raw)"
    }

    $cluster = Get-Cluster -ErrorAction SilentlyContinue
    if ($cluster -and $cluster.Name -eq $ClusterName) {
        L "Cluster verified: $($cluster.Name)"
        return $true
    }

    LE "Cluster creation failed"
    return $false
}

function DisplayClusterInfo {
    param([string]$Name)

    try {
        $cluster = Get-Cluster -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Name }
        if ($cluster) {
            L "Cluster: $($cluster.Name), State: $($cluster.State)"
            Get-ClusterNode | ForEach-Object { L "  Node: $($_.Name), State: $($_.State)" }
        } else {
            LW "Cluster '$Name' not found"
        }
    } catch {
        LE "Error displaying cluster info: $_"
    }
}

function ConfigureCloudWitness {
    L "Configuring Cloud Witness"

    if ([string]::IsNullOrWhiteSpace($WitnessStorageAccountName) -or [string]::IsNullOrWhiteSpace($WitnessStorageKeyBase64)) {
        LD "Cloud Witness parameters not provided, skipping"
        return $false
    }

    try {
        $witnessKey = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($WitnessStorageKeyBase64))

        $cluster = Get-Cluster -ErrorAction SilentlyContinue
        if ($null -eq $cluster) {
            LW "No cluster found, cannot configure Cloud Witness"
            return $false
        }

        LD "Storage account: $WitnessStorageAccountName"

        # Validate storage account key
        if ([string]::IsNullOrWhiteSpace($witnessKey) -or $witnessKey.Length -lt 20) {
            LE "Storage account key is invalid or empty"
            throw "Storage account key access validation failed"
        }

        # Wait for private endpoint DNS propagation
        L "Waiting 60s for private endpoint DNS to stabilize"
        Start-Sleep -Seconds 60

        $fqdn = "$WitnessStorageAccountName.blob.core.windows.net"
        $resolved = Resolve-DnsName $fqdn -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "10.*" }
        if ($resolved) {
            LD "DNS resolved to private IP: $($resolved.IPAddress)"
        } else {
            LW "DNS did not resolve to private IP, Cloud Witness may fail"
        }

        Set-ClusterQuorum -CloudWitness -AccountName $WitnessStorageAccountName -AccessKey $witnessKey -ErrorAction Stop

        L "Cloud Witness configured"
        return $true
    } catch {
        LE "Failed to configure Cloud Witness: $_"
        return $false
    }
}

function Main {
    L "========== Failover Cluster Setup =========="
    L "Host: $env:COMPUTERNAME | Cluster: $ClusterName"

    ValidateInputs

    # Early check: if this node is already in the target cluster with AlwaysOn enabled,
    # skip the full setup (idempotency for re-runs due to script content changes)
    if (CheckClusterExists -Name $ClusterName) {
        L "Cluster '$ClusterName' already exists on this node"

        # Ensure prerequisites and configs are still correct
        ConfigureVMPrerequisites
        ConfigureHostsFile

        # Ensure cluster admin exists
        if (-not [string]::IsNullOrWhiteSpace($ClusterAdminUsername)) {
            CreateClusterAdminLocal -Username $ClusterAdminUsername -Password $ClusterAdminPassword
        }

        # Ensure AlwaysOn is enabled
        EnableSqlAlwaysOn

        DisplayClusterInfo -Name $ClusterName
        L "Cluster setup already complete - idempotent pass"
        return
    }

    ConfigureVMPrerequisites
    ConfigureHostsFile
    ValidateNodeConnectivity

    # Create cluster admin on ALL nodes
    if (-not [string]::IsNullOrWhiteSpace($ClusterAdminUsername)) {
        CreateClusterAdminLocal -Username $ClusterAdminUsername -Password $ClusterAdminPassword
    }

    # Enable Always On on ALL nodes (before cluster creation, matching colleague's flow)
    EnableSqlAlwaysOn

    # Secondary nodes: done after Always On is enabled
    $primaryNode = $NodeNames[0]
    if ($env:COMPUTERNAME -ne $primaryNode) {
        L "Secondary node setup completed"
        return
    }

    L "Primary node ($primaryNode) - creating cluster"

    # Wait for secondary node(s) to have their admin user ready
    WaitForOtherNodes -Nodes $NodeNames -NodeIPs $NodeIPs -Username $ClusterAdminUsername -Password $ClusterAdminPassword

    if (CheckClusterExists -Name $ClusterName) {
        DisplayClusterInfo -Name $ClusterName
        return
    }

    if (CreateFailoverCluster) {
        L "Cluster created successfully"
        DisplayClusterInfo -Name $ClusterName

        if (-not [string]::IsNullOrWhiteSpace($WitnessStorageAccountName)) {
            if (-not (ConfigureCloudWitness)) {
                LW "Cloud Witness failed, using default quorum"
            }
        }
    } else {
        LE "Cluster creation failed"
        throw "Cluster creation failed"
    }
}

# Entry point
try {
    Remove-Item $log, $err -Force -ErrorAction SilentlyContinue
    L "Script started"
    Main
    L "Script completed successfully"
    exit 0
} catch {
    $errorMsg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] $($_ | Out-String)"
    Add-Content -Path $err -Value $errorMsg
    if ($_.ScriptStackTrace) { Add-Content -Path $err -Value $_.ScriptStackTrace }
    LE "Script failed: $_"
    exit 1
}
