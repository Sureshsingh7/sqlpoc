# SQL IaaS Module

This module deploys SQL Server IaaS instances in Azure, supporting Single-VM (Dev/Test non-HA), Multi-VM HA (High Availability), and Multi-VM DR (Disaster Recovery) scenarios.

It is designed to be consumed by Azure Data Factory (ADF) pipelines or other automation tools.

## Features

- **Single-VM Deployment:** Deploys a standalone SQL Server VM.
- **High Availability (HA):** Deploys 2 VMs in a Windows Server Failover Cluster (WSFC) with an Internal Load Balancer (ILB) and Cloud Witness.
- **Availability Zones:** Supports deploying nodes across Availability Zones.
- **VNN Architecture:** Uses a single subnet with an Internal Load Balancer and Private DNS for the cluster Virtual Network Name (VNN).
- **Idempotent:** Safe to re-run.

## Usage

### Single VM (Dev)

```hcl
module "sql_dev" {
  source              = "./modules/sql-iaas"
  resource_group_name = "rg-dev-sql"
  location            = "swedencentral"
  name_prefix         = "dev"
  is_ha               = false
  vm_sku              = "Standard_D4s_v5"
  subnet_id           = data.azurerm_subnet.example.id
  vnet_id             = data.azurerm_virtual_network.example.id
  sql_vm_admin_password = "SecretPassword123!"
}
```

### HA Cluster (Prod Primary)

```hcl
module "sql_prod_ha" {
  source              = "./modules/sql-iaas"
  resource_group_name = "rg-prod-sql"
  location            = "swedencentral"
  name_prefix         = "prod-primary"
  is_ha               = true
  vm_sku              = "Standard_D8s_v5"
  subnet_id           = data.azurerm_subnet.primary.id
  vnet_id             = data.azurerm_virtual_network.primary.id
  failover_cluster_name = "sql-cluster-pri"
  sql_vm_admin_password = "SecretPassword123!"
}
```

## Inputs

| Name | Type | Description | Default |
|------|------|-------------|---------|
| `resource_group_name` | string | Resource group name | |
| `location` | string | Azure region | |
| `name_prefix` | string | Prefix for resources | |
| `is_ha` | bool | Enable High Availability (Cluster + ILB) | `false` |
| `is_dr` | bool | Enable DR configuration (future DAG linking) | `false` |
| `vm_sku` | string | VM Size | |
| `subnet_id` | string | Subnet ID for the VMs | |
| `vnet_id` | string | VNet ID for Private DNS linking | |
| `failover_cluster_name` | string | Name of the WSFC | `"sql-cluster"` |
| `availability_zones` | list(number) | Availability Zones to distribute VMs | `[1, 2, 3]` |

## Outputs

| Name | Description |
|------|-------------|
| `sql_vm_ids` | Map of VM IDs |
| `sql_vm_ips` | Map of VM Private IPs |
| `load_balancer_ip` | IP of the Cluster Listener (HA only) |

## Architecture Notes

- **Network:** The module assumes a "VNN" (Virtual Network Name) approach where the Cluster Name corresponds to the Frontend IP of an Internal Load Balancer (Standard SKU).
- **DNS:** A Private DNS Zone is created/linked to ensure the Cluster Name resolves to the ILB IP within the VNet.
- **Authentication:** Nodes use local accounts for clustering (Workgroup Cluster). A local `clusteradmin` user is created on each node.
- **WinRM:** Firewalls are configured to allow WinRM traffic between nodes for cluster setup orchestration.
