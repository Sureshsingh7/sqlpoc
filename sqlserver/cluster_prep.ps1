param(
  [Parameter(Mandatory=$true)][string]$PrimaryName,
  [Parameter(Mandatory=$true)][string]$PrimaryIp,
  [Parameter(Mandatory=$true)][string]$SecondaryName,
  [Parameter(Mandatory=$true)][string]$SecondaryIp,
  [Parameter(Mandatory=$true)][string]$DnsSuffix,
  [Parameter(Mandatory=$true)][string]$LocalAdminUser,
  [Parameter(Mandatory=$true)][string]$LocalAdminPasswordB64
)

$ErrorActionPreference = 'Stop'

function Ensure-HostsEntry {
  param([string]$Ip,[string]$Name,[string]$Suffix)
  $hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
  $fqdn = "$Name.$Suffix"

  $pattern = "(^|\s)${Name}(\s|$)|(^|\s)${fqdn}(\s|$)"
  if (Select-String -Path $hostsPath -Pattern $pattern -Quiet) {
    return
  }

  $line = "$Ip`t$fqdn`t$Name"
  Add-Content -Path $hostsPath -Value $line
}

function Ensure-LocalAdminUser {
  param([string]$User,[string]$Password)

  $existing = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
  if (-not $existing) {
    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    New-LocalUser -Name $User -Password $secure -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
  }

  try {
    Add-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction SilentlyContinue | Out-Null
  } catch {
    # best-effort
  }
}

function Ensure-FirewallIcmp {
  # Idempotent-ish: only add if not present
  $rule = Get-NetFirewallRule -DisplayName 'Allow ICMPv4' -ErrorAction SilentlyContinue
  if (-not $rule) {
    netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4 dir=in action=allow | Out-Null
  }
}

function Ensure-ClusterFeature {
  $feature = Get-WindowsFeature -Name Failover-Clustering
  if (-not $feature.Installed) {
    Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools | Out-Null
  }
}

# 1) Ensure both nodes resolve each other (workgroup cluster)
Ensure-HostsEntry -Ip $PrimaryIp -Name $PrimaryName -Suffix $DnsSuffix
Ensure-HostsEntry -Ip $SecondaryIp -Name $SecondaryName -Suffix $DnsSuffix

# 2) Optional: set NV Domain (helps some tools form FQDNs)
try {
  Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\services\Tcpip\Parameters' -Name 'NV Domain' -Value $DnsSuffix -Force
} catch {
  # best-effort
}

# 3) Allow remote admin with local accounts (UAC token filtering)
try {
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -PropertyType DWord -Force | Out-Null
} catch {
  # best-effort
}

# 4) Create local cluster admin user
$localAdminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LocalAdminPasswordB64))
Ensure-LocalAdminUser -User $LocalAdminUser -Password $localAdminPassword

# 5) Enable ICMP (handy for cluster troubleshooting)
Ensure-FirewallIcmp

# 6) Install WSFC feature + tools
Ensure-ClusterFeature

Set-Service ClusSvc -StartupType Automatic
Start-Service ClusSvc
Get-Service ClusSvc | Format-List Status,StartType | Write-Host

Write-Host 'Cluster prep complete.'
