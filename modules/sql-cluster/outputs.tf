output "sql_vm_ids" {
  description = "IDs of the deployed SQL Server VMs"
  value       = [for vm in module.sql_vm : vm.resource_id]
}

output "witness_storage_account_name" {
  value       = var.enable_failover_cluster ? module.witness_storage[0].name : null
  description = "Storage account name used for WSFC Cloud Witness"
}

output "cluster_name" {
  value       = var.enable_failover_cluster ? var.failover_cluster_name : null
  description = "Name of the specified failover cluster"
}

output "cluster_primary_ip" {
  value = var.cluster_ips[0]
}

output "cluster_secondary_ip" {
  value = var.cluster_ips[1]
}
