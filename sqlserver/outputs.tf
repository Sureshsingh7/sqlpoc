# output "sql_vm_ids" {
#   description = "IDs of the deployed SQL Server VMs"
#   value       = azurerm_windows_virtual_machine.sql_vm[*].id
# }

# output "sql_vm_names" {
#   description = "Names of the deployed SQL Server VMs"
#   value       = var.sql_vm_names
# }

# output "sql_vm_private_ips" {
#   description = "Private IP addresses of SQL Server VMs"
#   value       = var.sql_private_ips
# }

# output "sql_vm_nic_ids" {
#   description = "Network interface IDs of SQL VMs"
#   value       = azurerm_network_interface.sql_vm[*].id
# }

# output "sql_vm_admin_password_secrets" {
#   description = "Key Vault secret IDs containing SQL VM admin passwords"
#   value       = azurerm_key_vault_secret.sql_vm_admin_password[*].id
#   sensitive   = true
# }

# output "sql_subnet_id" {
#   description = "SQL1 subnet ID where VMs are deployed"
#   value       = data.terraform_remote_state.network.outputs.sql_subnet_sql1_id
# }

# output "network_nsg_id" {
#   description = "Network Security Group ID for SQL1 subnet"
#   value       = data.terraform_remote_state.network.outputs.nsg_sql1_id
# }

output "ops_key_vault_id" {
  value       = data.terraform_remote_state.ops.outputs.ops_key_vault_id
  description = "Key Vault resource ID from ops remote state (used by workflows to fetch secrets)"
}

output "witness_storage_account_name" {
  value       = module.sql_cluster.witness_storage_account_name
  description = "Storage account name used for WSFC Cloud Witness"
}

output "cluster_name" {
  value       = module.sql_cluster.cluster_name
  description = "Name of the specified failover cluster"
}

output "cluster_primary_ip" {
  value = module.sql_cluster.cluster_primary_ip
}

output "cluster_secondary_ip" {
  value = module.sql_cluster.cluster_secondary_ip
}

