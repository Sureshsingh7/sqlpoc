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
$sentinel = 'C:\Windows\Temp\.cluster-setup-completed'

# FAST idempotency check - if sentinel file exists, we're done
if (Test-Path $sentinel) {
    Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [OK] Cluster setup already completed (sentinel file exists) - exiting"
    Write-Host "Cluster setup already completed - exiting"
    exit 0
}

# Smart detection: if cluster already exists, create sentinel and exit (handles transition from old code)
try {
    Import-Module FailoverClusters -ErrorAction SilentlyContinue
    $existingCluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue 2>$null
    if ($existingCluster) {
        Write-Host "Cluster '$ClusterName' already exists - creating sentinel and exiting"
        Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [OK] Cluster already configured - creating sentinel file and exiting"
        New-Item -Path $sentinel -ItemType File -Force | Out-Null
        exit 0
    }
} catch {
    # If cluster check fails, continue with normal setup
}

# Handle comma-separated strings for array parameters (workaround for RunCommand passing single strings)
if ($NodeIPs.Count -eq 1 -and $NodeIPs[0] -like "*,*") { $NodeIPs = $NodeIPs[0] -split "," }
if ($ClusterIPs.Count -eq 1 -and $ClusterIPs[0] -like "*,*") { $ClusterIPs = $ClusterIPs[0] -split "," }
if ($NodeNames.Count -eq 1 -and $NodeNames[0] -like "*,*") { $NodeNames = $NodeNames[0] -split "," }

# Decode cluster admin password from base64 (passed as string to suppress warnings/avoid plain text args)
$ClusterAdminPassword = ""
if (-not [string]::IsNullOrWhiteSpace($ClusterAdminPasswordSecure)) {
    try {
        $ClusterAdminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ClusterAdminPasswordSecure))
    } catch {
        # Fallback if not valid base64 or conversion failed
        $ClusterAdminPassword = $ClusterAdminPasswordSecure
    }
}

# Logging levels: DEBUG, INFO, WARN, ERROR
$script:LogLevel = "DEBUG"  # Set to INFO in production

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

# Shorthand aliases for logging
function L([string]$m) { Write-Log -Message $m -Level "INFO" }
function LD([string]$m) { Write-Log -Message $m -Level "DEBUG" }
function LW([string]$m) { Write-Log -Message $m -Level "WARN" }
function LE([string]$m) { Write-Log -Message $m -Level "ERROR" }

# Log script parameters
LD "ClusterAdminUsername = $ClusterAdminUsername"
LD "NodeIPs = $($NodeIPs -join ', ')"
LD "NodeNames = $($NodeNames -join ', ')"
LD "ClusterIPs = $($ClusterIPs -join ', ')"

# Log DR parameters if provided
if (-not [string]::IsNullOrWhiteSpace($PrimaryClusterDNS)) {
    LD "PrimaryClusterDNS = $PrimaryClusterDNS"
}
if (-not [string]::IsNullOrWhiteSpace($PrimaryClusterIP)) {
    LD "PrimaryClusterIP = $PrimaryClusterIP"
}

# Log DR parameters if provided (original location - keeping for backwards compatibility)
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

function ValidateNodeConnectivity {
    L "Validating network connectivity (waiting for other nodes to be up and firewall rules applied)"

    # Wait up to 20 minutes for checks to pass
    $timeout = New-TimeSpan -Minutes 20
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($node in $NodeNames) {
        if ($node -eq $env:COMPUTERNAME) { continue }

        $connected = $false
        while ($sw.Elapsed -lt $timeout) {
            if (Test-Connection -ComputerName $node -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                LD "Node $node is reachable (ICMP)"
                $connected = $true
                break
            }

            if ($sw.Elapsed.Seconds % 30 -eq 0) {
                 LD "Waiting for node $node to be reachable (ICMP)... ($([math]::Round($sw.Elapsed.TotalSeconds))s elapsed)"
            }
            Start-Sleep -Seconds 5
        }

        if (-not $connected) {
            LE "Timeout waiting for ping response from node: $node"
            throw "Cannot reach node: $node (ICMP timeout)"
        }
    }
    L "All nodes are reachable"
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

    # Map Names to IPs for connection reliability
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

        # Use IP if available to avoid DNS/Kerberos issues in workgroup
        $target = $node
        if ($nodeIpMap.ContainsKey($node)) {
            $target = $nodeIpMap[$node]
        }
        LD "Checking connectivity to node '$node' via target '$target'"

        while ($sw.Elapsed.TotalMinutes -lt 10) {
            try {
                # We use the ClusterAdmin credentials to verify the user exists on the remote node and remote remoting is working
                $cred = New-Object System.Management.Automation.PSCredential("$node\$Username", $securePwd)

                # Check if we can run a command on the remote node
                $res = Invoke-Command -ComputerName $target -Credential $cred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop

                if ($res -eq $node) {
                    LD "Node $node is ready and accessible with cluster admin credentials"
                    $ready = $true
                    break
                }
            } catch {
                $lastError = $_
                # Log periodically to console to aid troubleshooting in Azure
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

    try {
        # Install NuGet and dbatools with timeout (requires internet access)
        LD "Installing NuGet provider and dbatools (timeout: 2 minutes)"

        $job = Start-Job -ScriptBlock {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
            Install-Module dbatools -Force -Scope AllUsers -AllowClobber -SkipPublisherCheck -ErrorAction Stop
        }

        $completed = Wait-Job $job -Timeout 120
        if ($null -eq $completed) {
            Stop-Job $job
            Remove-Job $job -Force
            LW "NuGet/dbatools installation timed out after 2 minutes"
            LW "This typically means VMs don't have internet access to PowerShell Gallery"
            LW "Always On can be enabled manually later using: Enable-SqlAlwaysOn -ServerName localhost -Force"
            return $false
        }

        $jobError = $job.ChildJobs[0].Error
        Remove-Job $job -Force

        if ($jobError) {
            LW "Failed to install dbatools: $($jobError | Out-String)"
            LW "Always On can be enabled manually later using: Enable-SqlAlwaysOn -ServerName localhost -Force"
            return $false
        }

        Import-Module dbatools -Force -ErrorAction Stop

        LD "Enabling Always On via dbatools"
        Enable-DbaAgHadr -SqlInstance $env:COMPUTERNAME -Force -Confirm:$false

        LD "Waiting 30s for SQL Server restart"
        Start-Sleep -Seconds 30
        L "Always On enabled on $env:COMPUTERNAME"
        return $true
    } catch {
        LW "Failed to enable Always On: $_"
        LW "Always On can be enabled manually later using: Enable-SqlAlwaysOn -ServerName localhost -Force"
        $_ | Out-File -FilePath $err -Append
        return $false
    }
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
    LD "Using credentials: $fullUsername)"

    # Create cluster script that will be executed by scheduled task
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
        
        # Validate storage account key access is enabled
        L "Validating storage account key access..."
        if ([string]::IsNullOrWhiteSpace($witnessKey) -or $witnessKey.Length -lt 20) {
            LE "Storage account key is invalid or empty - key access may be disabled"
            LE "Ensure 'Allow storage account key access' is enabled and SecurityControl tag is set to bypass policy"
            throw "Storage account key access validation failed"
        }
        LD "Storage account key validation passed"

        # Wait for private endpoint DNS propagation
        L "Waiting 60s for private endpoint DNS to stabilize"
        Start-Sleep -Seconds 60

        # Verify DNS resolves to private IP before attempting
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

function ConfigureVnnProbePort {
    param([string[]]$ClusterIPAddresses)

    L "Configuring VNN Listener with Azure Load Balancer Probe Port"

    if ($ClusterIPAddresses.Count -eq 0) {
        LW "No cluster IP addresses provided, skipping VNN configuration"
        return $false
    }

    try {
        $probePort = 59999
        L "Probe port: $probePort"

        # Get all IP address resources for the cluster
        $ipResources = Get-ClusterResource | Where-Object { $_.ResourceType -eq "IP Address" }

        foreach ($ip in $ClusterIPAddresses) {
            L "Configuring cluster IP: $ip"

            # Find the IP resource that matches this address
            $ipResource = $ipResources | Where-Object {
                $addr = ($_ | Get-ClusterParameter -Name Address -ErrorAction SilentlyContinue).Value
                $addr -eq $ip
            }

            if ($null -eq $ipResource) {
                LW "IP resource not found for address $ip, skipping"
                continue
            }

            L "Found IP resource: $($ipResource.Name) for address $ip"

            # Get the network for this IP
            $network = ($ipResource | Get-ClusterParameter -Name Network -ErrorAction SilentlyContinue).Value
            if ([string]::IsNullOrWhiteSpace($network)) {
                LW "Could not determine network for IP $ip"
                continue
            }

            LD "Network: $network"

            # Configure the IP resource for Azure Load Balancer VNN
            L "Setting cluster parameters for IP $ip..."
            $ipResource | Set-ClusterParameter -Multiple @{
                "Address"              = $ip
                "ProbePort"            = $probePort
                "SubnetMask"           = "255.255.255.255"
                "Network"              = $network
                "OverrideAddressMatch" = 1
                "EnableDhcp"           = 0
            } -ErrorAction Stop

            L "Cluster IP $ip configured successfully"

            # Restart the IP resource to apply changes
            L "Restarting IP resource $($ipResource.Name)..."
            try {
                Stop-ClusterResource -Name $ipResource.Name -ErrorAction Stop
                Start-Sleep -Seconds 5
                Start-ClusterResource -Name $ipResource.Name -ErrorAction Stop
                L "IP resource $($ipResource.Name) restarted"
            } catch {
                LW "Failed to restart IP resource $($ipResource.Name): $_"
            }
        }

        L "VNN Listener configuration completed"
        return $true
    } catch {
        LE "Failed to configure VNN: $_"
        $_ | Out-File -FilePath $err -Append
        return $false
    }
}

function Main {
    L "========== Failover Cluster Setup =========="
    L "Host: $env:COMPUTERNAME | Cluster: $ClusterName"

    ValidateInputs
    # VM Prerequisites and Hosts files are now configured in disk_setup.ps1
    # We still validate connectivity explicitly
    ValidateNodeConnectivity

    EnableSqlAlwaysOn

    # We designate the first node in NodeNames as the "Primary" which performs clustering
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
        # Even if exists, we might need to do DR config tasks here in the future
        return
    }

    if (CreateFailoverCluster) {
        L "Cluster created successfully"
        DisplayClusterInfo -Name $ClusterName

        # Configure VNN with Azure Load Balancer probe port
        if ($ClusterIPs.Count -gt 0) {
            if (-not (ConfigureVnnProbePort -ClusterIPAddresses $ClusterIPs)) {
                LW "VNN probe port configuration failed, manual configuration may be required"
            }
        }

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

    # Create sentinel file to mark completion
    New-Item -Path $sentinel -ItemType File -Force | Out-Null
    L "[OK] Cluster setup completed - sentinel file created"

    exit 0
} catch {
    $errorMsg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] $($_ | Out-String)"
    Add-Content -Path $err -Value $errorMsg
    if ($_.ScriptStackTrace) { Add-Content -Path $err -Value $_.ScriptStackTrace }
    LE "Script failed: $_"
    exit 1
}