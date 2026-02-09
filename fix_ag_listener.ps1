# Fix AG Listener - Configure listener for DNN cluster with proper network settings
# This script addresses the "no public cluster network" error when creating AG listeners

param(
    [string]$AGName = "poc-ha-AG",
    [string]$ListenerName = "poc-ha-listener",
    [string]$ListenerIP1 = "10.10.0.6",
    [string]$ListenerSubnet1 = "255.255.255.192",
    [string]$ListenerIP2 = "10.10.0.68",
    [string]$ListenerSubnet2 = "255.255.255.192",
    [int]$ListenerPort = 1433
)

function Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
}

Log "Starting AG Listener fix for DNN cluster..."

# First, ensure cluster networks are configured correctly
Log "Configuring cluster networks to allow client connectivity..."
try {
    $networks = Get-ClusterNetwork
    foreach ($network in $networks) {
        if ($network.Name -like "*Cluster Network*") {
            Log "Network: $($network.Name), Current Role: $($network.Role)"
            # Ensure network role is ClusterAndClient (3)
            if ($network.Role -ne "ClusterAndClient") {
                $network.Role = "ClusterAndClient"
                Log "Updated $($network.Name) role to ClusterAndClient"
            }
        }
    }
} catch {
    Log "Warning: Could not configure cluster networks: $_"
}

# Check if AG exists
Log "Checking if AG '$AGName' exists..."
try {
    $query = "SELECT name FROM sys.availability_groups WHERE name = '$AGName'"
    $result = Invoke-Sqlcmd -ServerInstance "localhost" -TrustServerCertificate -Query $query -ErrorAction Stop
    
    if (-not $result) {
        Log "ERROR: AG '$AGName' does not exist"
        exit 1
    }
    Log "AG '$AGName' found"
} catch {
    Log "ERROR checking AG: $_"
    exit 1
}

# Check if listener already exists
Log "Checking for existing listener..."
try {
    $query = "SELECT dns_name FROM sys.availability_group_listeners WHERE dns_name = '$ListenerName'"
    $listener = Invoke-Sqlcmd -ServerInstance "localhost" -TrustServerCertificate -Query $query -ErrorAction SilentlyContinue
    
    if ($listener) {
        Log "Listener '$ListenerName' already exists - dropping it first..."
        $dropListenerSQL = @"
USE master;
ALTER AVAILABILITY GROUP [$AGName]
REMOVE LISTENER '$ListenerName';
"@
        Invoke-Sqlcmd -ServerInstance "localhost" -TrustServerCertificate -Query $dropListenerSQL -ErrorAction Stop
        Start-Sleep -Seconds 5
        Log "Existing listener dropped"
    }
} catch {
    Log "Note: No existing listener to remove or error checking: $_"
}

# Method 1: Try creating listener with explicit subnet specification
Log "Attempting to create listener with explicit network configuration..."
try {
    # Build SQL command to create listener with both IPs
    $createListenerSQL = @"
USE master;
ALTER AVAILABILITY GROUP [$AGName]
ADD LISTENER  '$ListenerName' (
    WITH IP (
        ('$ListenerIP1', '$ListenerSubnet1'),
        ('$ListenerIP2', '$ListenerSubnet2')
    ),
    PORT = $ListenerPort
);
"@
    
    Log "Executing listener creation SQL..."
    Log "SQL: $createListenerSQL"
    Invoke-Sqlcmd -ServerInstance "localhost" -TrustServerCertificate -Query $createListenerSQL -QueryTimeout 120 -ErrorAction Stop
    Log "SUCCESS: Listener '$ListenerName' created successfully!"
    
    # Verify listener
    Start-Sleep -Seconds 5
    $verifySQL = "SELECT dns_name, port FROM sys.availability_group_listeners WHERE dns_name = '$ListenerName'"
    $listenerInfo = Invoke-Sqlcmd -ServerInstance "localhost" -TrustServerCertificate -Query $verifySQL
    if ($listenerInfo) {
        Log "Listener verified:"
        Log "  DNS Name: $($listenerInfo.dns_name)"
        Log "  Port: $($listenerInfo.port)"
        
        # Get IP addresses
        $ipSQL = @"
SELECT l.dns_name, ip.ip_address, ip.ip_subnet_mask  
FROM sys.availability_group_listener_ip_addresses ip
JOIN sys.availability_group_listeners l ON ip.listener_id = l.listener_id
WHERE l.dns_name = '$ListenerName'
"@
        $ips = Invoke-Sqlcmd -ServerInstance "localhost" -TrustServerCertificate -Query $ipSQL
        foreach ($ip in $ips) {
            Log "  IP: $($ip.ip_address) / $($ip.ip_subnet_mask)"
        }
    }
    
    exit 0
} catch {
    Log "ERROR creating listener (Method 1): $_"
}

# Method 2: Try with DHCP (let cluster assign IPs automatically)
Log "Method 1 failed. Attempting DHCP-based listener..."
try {
    $createListenerDHCP = @"
USE master;
ALTER AVAILABILITY GROUP [$AGName]
ADD LISTENER '$ListenerName' (
    WITH DHCP,
    PORT = $ListenerPort
);
"@
    
    Invoke-Sqlcmd -ServerInstance "localhost" -TrustServerCertificate -Query $createListenerDHCP -QueryTimeout 120 -ErrorAction Stop
    Log "SUCCESS: Listener created with DHCP!"
    exit 0
} catch {
    Log "ERROR creating listener (Method 2 - DHCP): $_"
}

# Method 3: Create listener with single IP (primary subnet only)
Log "Method 2 failed. Attempting single-IP listener (primary subnet)..."
try {
    $createListenerSingleIP = @"
USE master;
ALTER AVAILABILITY GROUP [$AGName]
ADD LISTENER '$ListenerName' (
    WITH IP (('$ListenerIP1', '$ListenerSubnet1')),
    PORT = $ListenerPort
);
"@
    
    Invoke-Sqlcmd -ServerInstance "localhost" -TrustServerCertificate -Query $createListenerSingleIP -QueryTimeout 120 -ErrorAction Stop
    Log "SUCCESS: Listener created with single IP (primary subnet)!"
    Log "Note: Multi-subnet failover will require MultiSubnetFailover=True in connection strings"
    exit 0
} catch {
    Log "ERROR creating listener (Method 3 - Single IP): $_"
}

Log "ERROR: All listener creation methods failed"
Log "Manual intervention required - check cluster network configuration"
Log "Try: Get-ClusterNetwork | Set-ClusterNetwork -Role ClusterAndClient"
exit 1
