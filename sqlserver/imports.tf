# DR Resources Import Blocks
# These import existing DR resources into Terraform state to avoid recreation

# Random suffix for witness storage account naming
import {
  to = module.sql_cluster_dr[0].random_string.witness_suffix
  id = "c4b9dy"
}

# VMs (use [0] count index)
import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql01"].azurerm_windows_virtual_machine.this[0]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql01"
}

import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql02"].azurerm_windows_virtual_machine.this[0]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql02"
}

# Network Interfaces
import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql01"].azurerm_network_interface.virtualmachine_network_interfaces["sql_nic"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/networkInterfaces/poc-ha-dr-sql01-nic"
}

import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql02"].azurerm_network_interface.virtualmachine_network_interfaces["sql_nic"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/networkInterfaces/poc-ha-dr-sql02-nic"
}

# Managed Disks - Data
import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql01"].azurerm_managed_disk.this["poc-ha-dr-sql01-data"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/disks/poc-ha-dr-sql01-data"
}

import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql02"].azurerm_managed_disk.this["poc-ha-dr-sql02-data"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/disks/poc-ha-dr-sql02-data"
}

# Managed Disks - Log
import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql01"].azurerm_managed_disk.this["poc-ha-dr-sql01-log"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/disks/poc-ha-dr-sql01-log"
}

import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql02"].azurerm_managed_disk.this["poc-ha-dr-sql02-log"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/disks/poc-ha-dr-sql02-log"
}

# Managed Disks - TempDB
import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql01"].azurerm_managed_disk.this["poc-ha-dr-sql01-tempdb"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/disks/poc-ha-dr-sql01-tempdb"
}

import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql02"].azurerm_managed_disk.this["poc-ha-dr-sql02-tempdb"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/disks/poc-ha-dr-sql02-tempdb"
}

# Disk Attachments - Data
import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql01"].azurerm_virtual_machine_data_disk_attachment.this_windows["poc-ha-dr-sql01-data"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql01/dataDisks/poc-ha-dr-sql01-data"
}

import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql02"].azurerm_virtual_machine_data_disk_attachment.this_windows["poc-ha-dr-sql02-data"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql02/dataDisks/poc-ha-dr-sql02-data"
}

# Disk Attachments - Log
import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql01"].azurerm_virtual_machine_data_disk_attachment.this_windows["poc-ha-dr-sql01-log"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql01/dataDisks/poc-ha-dr-sql01-log"
}

import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql02"].azurerm_virtual_machine_data_disk_attachment.this_windows["poc-ha-dr-sql02-log"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql02/dataDisks/poc-ha-dr-sql02-log"
}

# Disk Attachments - TempDB
import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql01"].azurerm_virtual_machine_data_disk_attachment.this_windows["poc-ha-dr-sql01-tempdb"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql01/dataDisks/poc-ha-dr-sql01-tempdb"
}

import {
  to = module.sql_cluster_dr[0].module.sql_vm["poc-ha-dr-sql02"].azurerm_virtual_machine_data_disk_attachment.this_windows["poc-ha-dr-sql02-tempdb"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql02/dataDisks/poc-ha-dr-sql02-tempdb"
}

# SQL IaaS Extension
import {
  to = module.sql_cluster_dr[0].azurerm_mssql_virtual_machine.sql_vm["poc-ha-dr-sql01"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.SqlVirtualMachine/SqlVirtualMachines/poc-ha-dr-sql01"
}

import {
  to = module.sql_cluster_dr[0].azurerm_mssql_virtual_machine.sql_vm["poc-ha-dr-sql02"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.SqlVirtualMachine/SqlVirtualMachines/poc-ha-dr-sql02"
}

# Load Balancer
import {
  to = module.sql_cluster_dr[0].azurerm_lb.sql_lb[0]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/loadBalancers/poc-ha-dr-ilb"
}

# Witness Storage Account
import {
  to = module.sql_cluster_dr[0].module.witness_storage[0].azurerm_storage_account.this
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Storage/storageAccounts/stpochadrwtc4b9dy"
}

# Witness Storage Private Endpoint
import {
  to = module.sql_cluster_dr[0].module.witness_storage[0].azurerm_private_endpoint.this["witness_blob"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/privateEndpoints/poc-ha-dr-witness-pe"
}

# Private DNS Zone - Blob (azapi_resource)
import {
  to = module.sql_cluster_dr[0].module.witness_blob_dns[0].azapi_resource.private_dns_zone
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
}

# Private DNS Zone - SQL.internal (azapi_resource)
import {
  to = module.sql_cluster_dr[0].module.sql_dns[0].azapi_resource.private_dns_zone
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/privateDnsZones/sql.internal"
}

# Virtual Network Link - Blob DNS Zone
import {
  to = module.sql_cluster_dr[0].module.witness_blob_dns[0].module.virtual_network_links["sql_vnet"].azapi_resource.private_dns_zone_network_link
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net/virtualNetworkLinks/link-blob-poc-ha-dr"
}

# Virtual Network Link - SQL DNS Zone
import {
  to = module.sql_cluster_dr[0].module.sql_dns[0].module.virtual_network_links["sql_vnet"].azapi_resource.private_dns_zone_network_link
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/privateDnsZones/sql.internal/virtualNetworkLinks/link-sql-vnet-poc-ha-dr"
}

# DNS A Record - Cluster Listener
import {
  to = module.sql_cluster_dr[0].azurerm_private_dns_a_record.cluster_listener[0]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/privateDnsZones/sql.internal/A/sqlpoc-ha-cl-dr"
}

# DNS A Records - SQL VMs
import {
  to = module.sql_cluster_dr[0].azurerm_private_dns_a_record.sql_vm["poc-ha-dr-sql01"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/privateDnsZones/sql.internal/A/poc-ha-dr-sql01"
}

import {
  to = module.sql_cluster_dr[0].azurerm_private_dns_a_record.sql_vm["poc-ha-dr-sql02"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/privateDnsZones/sql.internal/A/poc-ha-dr-sql02"
}

# Load Balancer Backend Pool
import {
  to = module.sql_cluster_dr[0].azurerm_lb_backend_address_pool.sql_lb_backend[0]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/loadBalancers/poc-ha-dr-ilb/backendAddressPools/SqlBackendPool"
}

# Load Balancer Backend Pool Addresses
import {
  to = module.sql_cluster_dr[0].azurerm_lb_backend_address_pool_address.sql_nodes["poc-ha-dr-sql01"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/loadBalancers/poc-ha-dr-ilb/backendAddressPools/SqlBackendPool/addresses/poc-ha-dr-sql01"
}

import {
  to = module.sql_cluster_dr[0].azurerm_lb_backend_address_pool_address.sql_nodes["poc-ha-dr-sql02"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/loadBalancers/poc-ha-dr-ilb/backendAddressPools/SqlBackendPool/addresses/poc-ha-dr-sql02"
}

# Load Balancer Probe
import {
  to = module.sql_cluster_dr[0].azurerm_lb_probe.sql_probe[0]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/loadBalancers/poc-ha-dr-ilb/probes/SqlProbe"
}

# Load Balancer Rule
import {
  to = module.sql_cluster_dr[0].azurerm_lb_rule.sql_rule[0]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Network/loadBalancers/poc-ha-dr-ilb/loadBalancingRules/SqlListenerRule"
}

# VM Run Commands - Disk Setup
import {
  to = module.sql_cluster_dr[0].azurerm_virtual_machine_run_command.disk_setup["poc-ha-dr-sql01"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql01/runCommands/disk-setup"
}

import {
  to = module.sql_cluster_dr[0].azurerm_virtual_machine_run_command.disk_setup["poc-ha-dr-sql02"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql02/runCommands/disk-setup"
}

# VM Run Commands - Cluster Setup
import {
  to = module.sql_cluster_dr[0].azurerm_virtual_machine_run_command.cluster_setup["poc-ha-dr-sql01"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql01/runCommands/failover-cluster-setup"
}

import {
  to = module.sql_cluster_dr[0].azurerm_virtual_machine_run_command.cluster_setup["poc-ha-dr-sql02"]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.Compute/virtualMachines/poc-ha-dr-sql02/runCommands/failover-cluster-setup"
}
