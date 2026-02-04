# VNN Architecture Implementation

## Overview

Implemented the 2-subnet Virtual Network Name (VNN) architecture for SQL Server Always On based on customer requirements.

## Network Design

### Subnet Layout (Per Region)

```
Primary Region (Sweden Central):
├── SQL Subnet 1 → SQL-01 (poc-ha-sql-01)
└── SQL Subnet 2 → SQL-02 (poc-ha-sql-02)

DR Region (Sweden Central DR):
├── SQL Subnet 1 → DR-SQL-01 (poc-ha-dr-sql01)
└── SQL Subnet 2 → DR-SQL-02 (poc-ha-dr-sql02)
```

## Load Balancer Configuration

### Frontend IP Configurations

The Internal Load Balancer is configured with **2 frontend IPs** (one per subnet):

- **LoadBalancerFrontEnd-Subnet1**: Dynamic IP from SQL Subnet 1
- **LoadBalancerFrontEnd-Subnet2**: Dynamic IP from SQL Subnet 2

### Load Balancing Rules

**Four rules are created** to support VNN listener:

| Rule Name | Frontend IP | Port | Protocol | Floating IP |
|-----------|-------------|------|----------|-------------|
| SqlListener-1433-Subnet1 | Subnet1 | 1433 | TCP | ✅ Enabled |
| SqlListener-1433-Subnet2 | Subnet2 | 1433 | TCP | ✅ Enabled |
| AlwaysOn-5022-Subnet1 | Subnet1 | 5022 | TCP | ✅ Enabled |
| AlwaysOn-5022-Subnet2 | Subnet2 | 5022 | TCP | ✅ Enabled |

**Key Configuration:**
- **Floating IP**: MUST be enabled (critical for VNN)
- **Health Probe**: Port 59999
- **Backend Pool**: All SQL VMs in the same backend pool

## Cluster IP Configuration

### VNN Probe Port Setup

After cluster creation, **both IP address resources** are configured with:

```powershell
$probePort = 59999
$ipResource | Set-ClusterParameter -Multiple @{
    "Address"              = $ip           # 10.x.x.x
    "ProbePort"            = 59999         # Azure LB health probe port
    "SubnetMask"           = "255.255.255.255"
    "Network"              = $network      # Cluster network name
    "OverrideAddressMatch" = 1
    "EnableDhcp"           = 0
}
```

### Configuration Steps (Automated)

1. Cluster is created with both IP addresses
2. `ConfigureVnnProbePort` function identifies IP address resources
3. Each IP resource is configured with probe port and proper settings
4. IP resources are restarted to apply changes
5. Load Balancer can now route traffic correctly

## DNS Configuration

The cluster listener DNS A record (`sqlpoc-ha-cl.sql.internal`) points to **both frontend IPs**:

```terraform
records = length(var.subnet_ids) > 1 ? [
  azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address,
  azurerm_lb.sql_lb[0].frontend_ip_configuration[1].private_ip_address
] : [azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address]
```

## Code Changes Summary

### Module: sql-iaas

**main.tf**:
- Added dynamic frontend IP configuration for second subnet
- Created 4 load balancing rules (1433 and 5022 on both frontends)
- Changed `enable_floating_ip` to `floating_ip_enabled` (non-deprecated)
- Updated cluster IP parameter passing to include both IPs

**scripts/create_failover_cluster.ps1**:
- Added `ConfigureVnnProbePort` function
- Automatically configures both cluster IP resources after creation
- Restarts IP resources to apply configuration

**outputs.tf**:
- Updated `load_balancer_ip` to return comma-separated IPs when multiple frontends exist

### Root Module: sqlserver

**main.tf**:
- Updated both `module.sql_cluster` and `module.sql_cluster_dr` to pass 2 subnets:
  ```terraform
  subnet_ids = [
    data.terraform_remote_state.network.outputs.sql_subnet_sql1_id,
    data.terraform_remote_state.network.outputs.sql_subnet_sql2_id
  ]
  ```

**imports.tf**:
- Commented out old `SqlListenerRule` import (will be destroyed)
- New rules will be created on next deployment

## Deployment Impact

### For Existing Deployments

When applying this change to **existing infrastructure**:

1. **Load Balancer Changes**:
   - Old rule `SqlListenerRule` will be **destroyed**
   - 4 new rules will be **created**
   - Load balancer will have **1 additional frontend IP** added

2. **Cluster Configuration**:
   - Run command `cluster_setup` will be **updated** to configure VNN probe port
   - Existing cluster IPs will be reconfigured (requires restart)

3. **DNS**:
   - Cluster listener DNS A record will be **updated** with second IP

### For New Deployments

- All 4 load balancing rules created from scratch
- Both frontend IPs configured automatically
- VNN probe port configuration applied during cluster setup

## Validation

### Verify Load Balancer Configuration

```powershell
# Check frontend IPs
az network lb show --name poc-ha-ilb --resource-group rg-fnz-poc-sql-se `
  --query "frontendIPConfigurations[].{name:name, privateIP:privateIPAddress}"

# Check load balancing rules
az network lb rule list --lb-name poc-ha-ilb --resource-group rg-fnz-poc-sql-se `
  --query "[].{name:name, frontendPort:frontendPort, floatingIP:enableFloatingIP}"
```

### Verify Cluster IP Configuration

```powershell
# Check cluster IP resources
Get-ClusterResource | Where-Object ResourceType -eq "IP Address" | `
  Get-ClusterParameter | Where-Object Name -in "Address","ProbePort","SubnetMask"
```

Expected output:
```
Object          : SQLAG1_10.x.x.x
Name            : ProbePort
Value           : 59999

Object          : SQLAG1_10.x.x.x
Name            : SubnetMask
Value           : 255.255.255.255
```

## References

- Customer Confluence Document: VNN Listener Setup
- Azure Documentation: [Configure load balancer for AlwaysOn AG](https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/availability-group-load-balancer-portal-configure)

## Migration Notes

### From Single-Subnet to 2-Subnet

If migrating from old single-subnet design:

1. ✅ Network module already has both subnets configured
2. ✅ Root module now passes both subnet IDs
3. ⚠️ Existing load balancer rule will be replaced (brief downtime)
4. ⚠️ Cluster IPs will be reconfigured (cluster restart required)

### Rollback Plan

If issues occur:
1. Revert to previous commit
2. Run `terraform apply` to restore single-subnet configuration
3. Old `SqlListenerRule` will be recreated
4. Cluster configuration will revert to previous state

## Production Readiness

✅ **Configuration validated**: `terraform validate` passes
✅ **Floating IP enabled**: Required for VNN
✅ **Health probe configured**: Port 59999
✅ **Cluster automation**: VNN probe port automatically configured
✅ **Documentation complete**: This file + inline comments

🔒 **Safety features**:
- State file isolation (primary/DR separate)
- `deploy_primary=false` prevents primary destruction during DR deployment
- Idempotent cluster configuration (sentinel file prevents re-runs)
