```powershell
param(
    [Parameter(Mandatory=$false)]
    [string[]]$NodeIPs = @(),

    [Parameter(Mandatory=$false)]
    [string]$ClusterIP = "",

    [Parameter(Mandatory=$false)]
    [string]$ClusterName = "sql-cluster",

    [Parameter(Mandatory=$false)]
    [string[]]$NodeNames = @(),

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminUsername = "clusteradmin",

    [Parameter(Mandatory=$false)]
    [string]$ClusterAdminPasswordSecure,

    [Parameter(Mandatory=$false)]
    [string]$WitnessStorageAccountName = "",

    [Parameter(Mandatory=$false)]
    [string]$WitnessStorageKeyBase64 = ""
)

$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\create-failover-cluster.log'
$err = 'C:\Windows\Temp\create-failover-cluster.err.txt'

# Handle comma-separated strings for array parameters
if ($NodeIPs.Count -eq 1 -and $NodeIPs[0] -like "*,*") { $NodeIPs = $NodeIPs[0] -split "," }
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
LD "ClusterIP = $ClusterIP"

function ValidateInputs {
    L "Validating inputs"
    if ($NodeIPs.Count -eq 0 -or $NodeNames.Count -eq 0) {
        throw "NodeIPs and NodeNames cannot be empty"
    }

    if ($NodeIPs.Count -ne $NodeNames.Count) {
        throw "NodeIPs count ($($NodeIPs.Count)) must match NodeNames count ($($NodeNames.Count))"
    }
    L "All inputs validated successfully"
}

function ConfigureVMPrerequisites {
    L "Configuring VM prerequisites"

    # In single subnet/VNN setup, we don't rely on hosts file as much if DNS is working,
    # but we might still add peer entries for safety if DNS propagation is slow initially.
    # We depend on Azure Private DNS or AD DNS.
    
    LD "Setting LocalAccountTokenFilterPolicy for remote admin"
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "LocalAccountTokenFilterPolicy" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null

    LD "Installing Failover Clustering feature"
    Import-Module ServerManager
    $feature = Get-WindowsFeature -Name Failover-Clustering -ErrorAction SilentlyContinue
    if ($null -eq $feature -or -not $feature.Installed) {
        Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools | Out-Null
        L "Failover Clustering installed"
    }

    LD "Configuring WinRM for Workgroup Auth"
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue | Out-Null
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
    Restart-Service WinRM

    # WinRM Firewall Rule for Cluster Nodes (even in single subnet, sometimes public profile blocks)
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
    
    L "VM prerequisites configured"
}

function CreateClusterAdminLocal {
    param([string]$Username, [string]$Password)
    L "Creating local cluster admin user '$Username'"
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if ($existingUser) {
        Set-LocalUser -Name $Username -Password $securePassword -ErrorAction Stop
    } else {
        New-LocalUser -Name $Username -Password $securePassword -FullName "Cluster Admin User" -PasswordNeverExpires -ErrorAction Stop
    }
    Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction SilentlyContinue
}

function WaitForOtherNodes {
    param([string[]]$Nodes, [string[]]$NodeIPs, [string]$Username, [string]$Password)
    $localName = $env:COMPUTERNAME
    $otherNodes = $Nodes | Where-Object { $_ -ne $localName }
    if ($otherNodes.Count -eq 0) { return }

    L "Waiting for other nodes: $($otherNodes -join ', ')"
    $nodeIpMap = @{}
    for ($i = 0; $i -lt $Nodes.Count; $i++) { if ($i -lt $NodeIPs.Count) { $nodeIpMap[$Nodes[$i]] = $NodeIPs[$i] } }
    $securePwd = ConvertTo-SecureString $Password -AsPlainText -Force

    foreach ($node in $otherNodes) {
        $ready = $false
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $target = if ($nodeIpMap.ContainsKey($node)) { $nodeIpMap[$node] } else { $node }
        
        while ($sw.Elapsed.TotalMinutes -lt 10) {
            try {
                $cred = New-Object System.Management.Automation.PSCredential("$node\$Username", $securePwd)
                $res = Invoke-Command -ComputerName $target -Credential $cred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
                if ($res -eq $node) {
                    LD "Node $node ($target) is ready"
                    $ready = $true
                    break
                }
            } catch {
                if ([int]$sw.Elapsed.TotalSeconds % 60 -lt 15) { Write-Host "Waiting for $node... $($_.Exception.Message)" }
            }
            Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "Timeout waiting for node $node" }
    }
}

function CreateFailoverCluster {
    L "Creating failover cluster '$ClusterName'"
    
    $scriptDir = "C:\ClusterSetup"
    New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
    $resultFile = "$scriptDir\cluster-result.txt"
    $errorFile = "$scriptDir\cluster-error.txt"
    Remove-Item $resultFile, $errorFile -Force -ErrorAction SilentlyContinue
    
    $fullUsername = "$env:COMPUTERNAME\$ClusterAdminUsername"
    $clusterScript = "$scriptDir\cluster-startup.ps1"
    
    # -------------------------------------------------------------------------
    # Script running as ClusterAdmin on Primary Node
    # -------------------------------------------------------------------------
    @"
`$log = '$scriptDir\cluster-startup.log'
`$nodes = @('$($NodeNames -join "','")')

function L([string]`$m){ Add-Content -Path `$log -Value ((Get-Date -Format o) + " " + `$m) }

try {
    L "Ensuring dbatools..."
    if (-not (Get-Module dbatools)) {
         Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue
         Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
         Install-Module dbatools -Force -Scope AllUsers -AllowClobber -SkipPublisherCheck -ErrorAction SilentlyContinue
         Import-Module dbatools -Force
    }

    L "Creating cluster '$ClusterName'"
    `$params = @{
        Name = '$ClusterName'
        Node = `$nodes
        NoStorage = `$true
        AdministrativeAccessPoint = 'DNS' 
        StaticAddress = '$ClusterIP'
        Force = `$true
        ErrorAction = 'Stop'
    }
    
    `$existing = Get-Cluster -Name '$ClusterName' -ErrorAction SilentlyContinue
    if (`$existing) {
         L "Cluster already exists"
    } else {
         `$c = New-Cluster @params
         L "Cluster created: `$(`$c.Name)"
    }

    # Enable AlwaysOn on ALL nodes after cluster is formed
    foreach (`$n in `$nodes) {
        L "Enabling AlwaysOn on `$n..."
        try {
             # Run locally if self, or remote via Invoke-Command if other
             if (`$n -eq `$env:COMPUTERNAME) {
                  Enable-DbaAgHadr -SqlInstance localhost -Force -Confirm:`$false
             } else {
                  # Since we are ClusterAdmin, and WinRM is open, pass current creds (implicit)
                  Invoke-Command -ComputerName `$n -ScriptBlock { 
                       Import-Module dbatools -Force; Enable-DbaAgHadr -SqlInstance localhost -Force -Confirm:`$false 
                  }
             }
             L "AlwaysOn enabled on `$n"
        } catch {
             L "Failed to enable AlwaysOn on `$n : `$(`$_.Exception.Message)"
             throw "Failed enabling AlwaysOn on `$n"
        }
    }

    "SUCCESS" | Out-File '$resultFile' -Force
} catch {
    L "ERROR: `$(`$_ | Out-String)"
    `$_ | Out-File '$errorFile' -Force
    exit 1
}
"@ | Out-File -FilePath $clusterScript -Force -Encoding UTF8

    $taskName = "CreateCluster_Task"
    $futureTime = (Get-Date).AddMinutes(1).ToString("HH:mm")
    
    # Passing password safely in batch/cmd usage is tricky with special chars.
    # We assume password complexity requirements but hopefully no double quotes.
    # 'schtasks' /rp parameter:
    schtasks /create /tn $taskName /tr "powershell.exe -ExecutionPolicy Bypass -File $clusterScript" /sc once /st $futureTime /ru $fullUsername /rp "$ClusterAdminPassword" /rl highest /f | Out-Null
    
    schtasks /run /tn $taskName | Out-Null
    
    L "Waiting for cluster creation task..."
    
    $maxWait = 600
    $waited = 0
    while ($waited -lt $maxWait) {
        if (Test-Path $resultFile) { return $true }
        if (Test-Path $errorFile) { 
             $errContent = Get-Content $errorFile -Raw
             LE "Cluster creation task failed: $errContent"
             return $false 
        }
        Start-Sleep -Seconds 10
        $waited += 10
    }
    return $false
}

function ConfigureCloudWitness {
    if ([string]::IsNullOrWhiteSpace($WitnessStorageAccountName)) { return $false }
    try {
        $witnessKey = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($WitnessStorageKeyBase64))
        Set-ClusterQuorum -CloudWitness -AccountName $WitnessStorageAccountName -AccessKey $witnessKey -ErrorAction Stop
        L "Cloud Witness configured"
        return $true
    } catch {
        LE "Failed to configure Cloud Witness: $_"
        return $false
    }
}

function Main {
    L "Starting setup"
    ValidateInputs
    ConfigureVMPrerequisites

    if (-not [string]::IsNullOrWhiteSpace($ClusterAdminUsername)) {
        CreateClusterAdminLocal -Username $ClusterAdminUsername -Password $ClusterAdminPassword
    }

    $primaryNode = $NodeNames[0]
    if ($env:COMPUTERNAME -ne $primaryNode) {
        L "Secondary node setup finished (Local Admin created, WinRM ready)"
        # Secondary waits passively for Primary to add it to cluster and enable AlwaysOn
        return
    }

    L "Primary node ($primaryNode) - orchestrating cluster"
    WaitForOtherNodes -Nodes $NodeNames -NodeIPs $NodeIPs -Username $ClusterAdminUsername -Password $ClusterAdminPassword

    if (Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue) {
        L "Cluster already exists"
        return
    }

    if (CreateFailoverCluster) {
        L "Cluster created"
        ConfigureCloudWitness
    } else {
        throw "Cluster creation failed"
    }
}

try {
    Main
    exit 0
} catch {
    LE "Script failed: $_"
    exit 1
}
```