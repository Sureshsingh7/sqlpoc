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
        # Try to install NuGet and dbatools with timeout (may require internet access)
        LD "Attempting to install NuGet provider and dbatools (timeout: 2 minutes)"
        
        $job = Start-Job -ScriptBlock {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
            Install-Module dbatools -Force -Scope AllUsers -AllowClobber -SkipPublisherCheck -ErrorAction Stop
        }
        
        $completed = Wait-Job $job -Timeout 120
        if ($null -eq $completed) {
            Stop-Job $job
            Remove-Job $job -Force
            LW "NuGet/dbatools installation timed out (no internet or network issue). Skipping Always On enablement."
            LW "You can enable Always On manually later if needed."
            return
        }
        
        $jobError = Receive-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force
        
        if ($jobError) {
            LW "Failed to install dbatools: $jobError"
            LW "Skipping Always On enablement - you can enable it manually later."
            return
        }

        Import-Module dbatools -Force -ErrorAction Stop

        LD "Enabling Always On via dbatools"
        Enable-DbaAgHadr -SqlInstance $env:COMPUTERNAME -Force -Confirm:$false

        LD "Waiting 30s for SQL Server restart"
        Start-Sleep -Seconds 30
        L "Always On enabled on $env:COMPUTERNAME"
    } catch {
        LW "Failed to enable Always On: $_"
        LW "This is non-critical - you can enable Always On manually later if needed"
        $_ | Out-File -FilePath $err -Append
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