# DR Resources Import Blocks
# These import existing DR resources into Terraform state to avoid recreation

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

# Note: Nested AVM module resources (DNS zones, disk attachments, private endpoints) 
# will be imported automatically when running terraform apply
