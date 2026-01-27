param(
    [Parameter(Mandatory=$false)]
    [string]$VM1PrivateIP = "10.10.0.10",

    [Parameter(Mandatory=$false)]
    [string]$VM2PrivateIP = "10.10.0.74",

    [Parameter(Mandatory=$false)]
    [string]$ClusterPrimaryIP = "10.10.0.12",

    [Parameter(Mandatory=$false)]
    [string]$ClusterSecondaryIP = "10.10.0.76",

    [Parameter(Mandatory=$false)]
    [string]$ClusterName = "sqlpoc-cluster",

    [Parameter(Mandatory=$false)]
    [string]$VM1Name = "sql-mirror-vm1",

    [Parameter(Mandatory=$false)]
    [string]$VM2Name = "sql-mirror-vm2",

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminUsername = "clusteradmin",

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminPasswordBase64 = "",

    [Parameter(Mandatory=$false)]
    [string]$WitnessStorageAccountName = "",

    [Parameter(Mandatory=$false)]
    [string]$WitnessStorageKeyBase64 = ""
)

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\create-failover-cluster.log'
$err = 'C:\Windows\Temp\create-failover-cluster.err.txt'

# Decode cluster admin password from base64 if provided
$ClusterAdminPassword = ""
if (-not [string]::IsNullOrWhiteSpace($ClusterAdminPasswordBase64)) {
    try {
        $ClusterAdminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ClusterAdminPasswordBase64))
    } catch {
        $ClusterAdminPassword = $ClusterAdminPasswordBase64
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
LD "ClusterAdminPasswordBase64 length = $($ClusterAdminPasswordBase64.Length)"
LD "WitnessStorageAccountName = $WitnessStorageAccountName"
LD "VM1PrivateIP = $VM1PrivateIP, VM2PrivateIP = $VM2PrivateIP"
LD "ClusterPrimaryIP = $ClusterPrimaryIP, ClusterSecondaryIP = $ClusterSecondaryIP"

function ValidateInputs {
    L "Validating inputs"
    $requiredParams = @{
        "VM1PrivateIP" = $VM1PrivateIP
        "VM2PrivateIP" = $VM2PrivateIP
        "ClusterPrimaryIP" = $ClusterPrimaryIP
        "ClusterSecondaryIP" = $ClusterSecondaryIP
        "ClusterName" = $ClusterName
        "VM1Name" = $VM1Name
        "VM2Name" = $VM2Name
    }

    foreach ($param in $requiredParams.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($param.Value)) {
            LE "Required parameter '$($param.Key)' is empty"
            throw "$($param.Key) cannot be empty"
        }
        LD "$($param.Key) = $($param.Value)"
    }
    L "All inputs validated successfully"
}

function ConfigureVMPrerequisites {
    L "Configuring VM prerequisites"

    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $domainName = "sqlpoc.local"

    @(
        @{ IP = $VM1PrivateIP; Name = $VM1Name },
        @{ IP = $VM2PrivateIP; Name = $VM2Name }
    ) | ForEach-Object {
        $entry = "$($_.IP)`t$($_.Name).$domainName`t$($_.Name)"
        if (-not (Select-String -Path $hostsFile -Pattern $_.Name -Quiet)) {
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

    L "VM prerequisites configured"
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

function ConfigureHostsFile {
    LD "Configuring cluster hosts file entries"

    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
    if ($null -eq $hostsContent) { $hostsContent = "" }

    @($ClusterPrimaryIP, $ClusterSecondaryIP) | ForEach-Object {
        $line = "$_`t$ClusterName"
        if ($hostsContent -notmatch [regex]::Escape($_)) {
            LD "Adding hosts entry: $line"
            Add-Content -Path $hostsFile -Value $line -Force
        }
    }

    ipconfig /flushdns | Out-Null
    LD "Hosts file configured, DNS cache flushed"
}

function ValidateNodeConnectivity {
    L "Validating network connectivity"
    @($VM1Name, $VM2Name) | ForEach-Object {
        if (-not (Test-Connection -ComputerName $_ -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
            LE "Cannot reach node: $_"
            throw "Cannot reach $_"
        }
        LD "Node $_ is reachable"
    }
    L "All nodes are reachable"
}

function CreateLocalAdminUser {
    param(
        [string]$ComputerName,
        [string]$Username,
        [string]$Password,
        [bool]$IsLocal = $false
    )

    LD "Creating local admin user '$Username' on $ComputerName (IsLocal=$IsLocal)"

    if ($IsLocal) {
        try {
            $existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
            if ($existingUser) {
                LD "User '$Username' already exists locally"
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
            LE "Failed to create local admin user: $_"
            throw
        }
    } else {
        try {
            if ([string]::IsNullOrWhiteSpace($ClusterAdminUsername) -or [string]::IsNullOrWhiteSpace($ClusterAdminPassword)) {
                LW "Cluster admin credentials not provided for remote user creation"
                return $false
            }

            $secureAdminPwd = ConvertTo-SecureString $ClusterAdminPassword -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential("$ComputerName\$ClusterAdminUsername", $secureAdminPwd)

            $scriptBlock = {
                param($Username, $Password)
                try {
                    $existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
                    if ($existingUser) { return "EXISTS" }

                    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
                    New-LocalUser -Name $Username -Password $securePassword -FullName "Cluster Admin User" -Description "User for failover cluster operations" -PasswordNeverExpires -ErrorAction Stop
                    Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction Stop
                    return "SUCCESS"
                } catch {
                    return "ERROR: $_"
                }
            }

            $result = Invoke-Command -ComputerName $ComputerName -Credential $cred -ScriptBlock $scriptBlock -ArgumentList $Username, $Password -ErrorAction Stop
            LD "Remote user creation on ${ComputerName}: $result"
            return ($result -match 'SUCCESS|EXISTS')
        } catch {
            LW "Failed to create user on ${ComputerName}: $_"
            return $false
        }
    }
}

function CreateClusterAdminOnBothVMs {
    L "Creating cluster admin user on both VMs"

    if ([string]::IsNullOrWhiteSpace($ClusterAdminUsername) -or [string]::IsNullOrWhiteSpace($ClusterAdminPassword)) {
        LW "Cluster admin credentials not provided, skipping user creation"
        return $false
    }

    $currentHostname = $env:COMPUTERNAME
    $localVMName = $currentHostname
    if ($currentHostname -eq $VM1Name) { $localVMName = $VM1Name }
    elseif ($currentHostname -eq $VM2Name) { $localVMName = $VM2Name }

    $remoteVMName = $VM1Name
    if ($currentHostname -eq $VM1Name) { $remoteVMName = $VM2Name }

    LD "Current=$currentHostname, Local=$localVMName, Remote=$remoteVMName"

    $localResult = CreateLocalAdminUser -ComputerName $localVMName -Username $ClusterAdminUsername -Password $ClusterAdminPassword -IsLocal $true
    $remoteResult = CreateLocalAdminUser -ComputerName $remoteVMName -Username $ClusterAdminUsername -Password $ClusterAdminPassword -IsLocal $false

    if ($localResult) { L "Cluster admin user ready on local VM" }
    if ($remoteResult) { L "Cluster admin user ready on remote VM" }

    return ($localResult -and $remoteResult)
}

function EnableSqlAlwaysOn {
    L "Enabling SQL Server Always On"

    try {
        LD "Installing NuGet provider"
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

        LD "Installing dbatools module"
        Install-Module dbatools -Force -Scope AllUsers -AllowClobber -SkipPublisherCheck -ErrorAction SilentlyContinue
        Import-Module dbatools -Force

        LD "Enabling Always On via dbatools"
        Enable-DbaAgHadr -SqlInstance $env:COMPUTERNAME -Force -Confirm:$false

        LD "Waiting 30s for SQL Server restart"
        Start-Sleep -Seconds 30
        L "Always On enabled on $env:COMPUTERNAME"
    } catch {
        LE "Failed to enable Always On: $_"
        throw
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

    Add-Content -Path `$log -Value "Creating cluster '$ClusterName' with nodes '$VM1Name','$VM2Name'..."
    `$c = New-Cluster -Name '$ClusterName' -Node @('$VM1Name','$VM2Name') -AdministrativeAccessPoint DNS -StaticAddress @('$ClusterPrimaryIP','$ClusterSecondaryIP') -NoStorage -Force -ErrorAction Stop
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
    L "Host: $env:COMPUTERNAME | Primary: $VM1Name | Cluster: $ClusterName"

    ValidateInputs
    ConfigureVMPrerequisites
    ConfigureHostsFile
    ValidateNodeConnectivity
    CreateClusterAdminOnBothVMs
    EnableSqlAlwaysOn

    if ($env:COMPUTERNAME -ne $VM1Name) {
        L "Secondary VM setup completed"
        return
    }

    L "Primary VM - creating cluster"

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