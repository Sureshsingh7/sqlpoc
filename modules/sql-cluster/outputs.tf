output "sql_vm_ids" {
  description = "IDs of the deployed SQL Server VMs"
  value       = { for name, vm in module.sql_vm : name => vm.resource_id }
}

output "witness_storage_account_name" {
  value       = var.enable_failover_cluster ? module.witness_storage[0].name : null
  description = "Storage account name used for WSFC Cloud Witness"
}

output "cluster_name" {
  value       = var.enable_failover_cluster ? var.failover_cluster_name : null
  description = "Name of the specified failover cluster"
}

output "cluster_ips" {
  description = "Map of VM names to their cluster IPs"
  value       = { for name, vm in var.sql_vms : name => vm.cluster_ip if vm.cluster_ip != "" }
}

output "sql_vm_private_ips" {
  description = "Map of VM names to their private IPs"
  value       = { for name, vm in var.sql_vms : name => vm.private_ip }
}
