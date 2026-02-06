# Fix AG Listener - Create listener for existing AG
# This script handles the case where AG exists but listener creation failed

param(
    [Parameter(Mandatory=$true)]
    [string]$AGName,

    [Parameter(Mandatory=$true)]
    [string]$ListenerName,

    [Parameter(Mandatory=$true)]
    [string[]]$ListenerIPs,

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
$log = 'C:\Windows\Temp\fix-ag-listener.log'

function L { param([string]$msg) "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [INFO] $msg" | Tee-Object -FilePath $log -Append | Write-Host }
function LW { param([string]$msg) "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [WARN] $msg" | Tee-Object -FilePath $log -Append | Write-Host -ForegroundColor Yellow }
function LE { param([string]$msg) "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [ERROR] $msg" | Tee-Object -FilePath $log -Append | Write-Host -ForegroundColor Red; Write-Error $msg }

try {
    L "Starting AG Listener fix for '$AGName'"
    L "Listener Name: $ListenerName"
    L "Listener IPs: $($ListenerIPs -join ', ')"
    L "Port: $ListenerPort, Probe Port: $ProbePort"

    # Check if AG exists
    L "Verifying AG exists..."
    $agCheck = Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate -Query "SELECT name FROM sys.availability_groups WHERE name = '$AGName'" -ErrorAction Stop
    if (-not $agCheck) {
        LE "Availability Group '$AGName' does not exist!"
        exit 1
    }
    L "AG '$AGName' confirmed"

    # Check if listener already exists
    L "Checking for existing listener..."
    $existingListener = Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate -Query "SELECT dns_name FROM sys.availability_group_listeners WHERE dns_name = '$ListenerName'" -ErrorAction SilentlyContinue
    
    if ($existingListener) {
        L "Listener '$ListenerName' already exists"
        
        # Verify it's configured correctly
        $listenerInfo = Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate -Query @"
SELECT l.dns_name, l.port, ip.ip_address, ip.ip_subnet_mask
FROM sys.availability_group_listeners l
LEFT JOIN sys.availability_group_listener_ip_addresses ip ON l.listener_id = ip.listener_id
WHERE l.dns_name = '$ListenerName'
"@
        
        L "Existing listener configuration:"
        $listenerInfo | ForEach-Object {
            L "  DNS: $($_.dns_name), Port: $($_.port), IP: $($_.ip_address)/$($_.ip_subnet_mask)"
        }
        
        L "Listener already configured - ensuring probe port is set..."
    } else {
        L "Listener does not exist - creating it now..."
        
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

        # Use proper subnet mask for /26 subnets
        $subnetMask = "255.255.255.192"
        
        # Try multi-IP first
        $listenerCreated = $false
        if ($ListenerIPs.Count -gt 1) {
            L "Attempting multi-subnet listener with IPs: $($ListenerIPs -join ', ')"
            try {
                $listenerSQL = "ALTER AVAILABILITY GROUP [$AGName] ADD LISTENER N'$ListenerName' (WITH IP ("
                $ipParts = @()
                foreach ($ip in $ListenerIPs) {
                    $ipParts += "(N'$ip', N'$subnetMask')"
                }
                $listenerSQL += $ipParts -join ", "
                $listenerSQL += "), PORT=$ListenerPort)"
                
                Invoke-Sqlcmd -ServerInstance localhost -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -Query $listenerSQL -QueryTimeout 120 -ErrorAction Stop
                L "Multi-subnet listener created successfully"
                $listenerCreated = $true
            } catch {
                LW "Multi-subnet listener failed: $_"
            }
        }
        
        # Fallback: Single IP
        if (-not $listenerCreated) {
            $primaryIP = $ListenerIPs[0]
            L "Attempting single-IP listener with: $primaryIP"
            try {
                $listenerSQL = "ALTER AVAILABILITY GROUP [$AGName] ADD LISTENER N'$ListenerName' (WITH IP ((N'$primaryIP', N'$subnetMask')), PORT=$ListenerPort)"
                Invoke-Sqlcmd -ServerInstance localhost -Username $SqlAdminUsername -Password $SqlAdminPassword -TrustServerCertificate -Query $listenerSQL -QueryTimeout 120 -ErrorAction Stop
                L "Single-IP listener created successfully"
                L "Note: Multi-subnet failover requires MultiSubnetFailover=True in connection strings"
                $listenerCreated = $true
            } catch {
                LE "Listener creation failed: $_"
                exit 1
            }
        }
        
        if (-not $listenerCreated) {
            LE "Failed to create listener"
            exit 1
        }
        
        L "Waiting for cluster resources to initialize..."
        Start-Sleep -Seconds 10
    }

    # Configure probe port on listener IPs
    L "Configuring Azure Load Balancer probe port ($ProbePort)..."
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
                    
                    $ipResource | Set-ClusterParameter -Multiple @{
                        "ProbePort" = $ProbePort
                        "SubnetMask" = "255.255.255.192"
                        "Network" = $network
                        "OverrideAddressMatch" = 1
                        "EnableDhcp" = 0
                    }
                    L "IP resource configured successfully"
                } catch {
                    LW "Failed to configure IP resource: $_"
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
                LW "Listener cluster resource not found"
            }
        } else {
            LW "No IP resources found for AG"
        }
    } catch {
        LW "Failed to configure probe port: $_"
    }

    # Verify final configuration
    L "Verifying listener configuration..."
    $finalCheck = Invoke-Sqlcmd -ServerInstance localhost -TrustServerCertificate -Query @"
SELECT 
    l.dns_name AS ListenerName,
    l.port AS Port,
    ip.ip_address AS IP,
    ip.ip_subnet_mask AS SubnetMask
FROM sys.availability_group_listeners l
LEFT JOIN sys.availability_group_listener_ip_addresses ip ON l.listener_id = ip.listener_id
WHERE l.dns_name = '$ListenerName'
"@

    if ($finalCheck) {
        L "SUCCESS! Listener configuration:"
        $finalCheck | ForEach-Object {
            L "  Name: $($_.ListenerName), Port: $($_.Port), IP: $($_.IP), Mask: $($_.SubnetMask)"
        }
    } else {
        LW "Listener verification failed - could not query listener info"
    }

    L "AG Listener fix completed successfully"
    exit 0

} catch {
    LE "Failed to fix AG listener: $_"
    $_ | Out-File "C:\Windows\Temp\fix-ag-listener.err.txt" -Force
    exit 1
}
