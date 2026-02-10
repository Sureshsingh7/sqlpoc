output "sql_vm_ids" {
  description = "IDs of the created SQL VMs."
  value       = { for k, v in module.sql_vm : k => v.resource_id }
}

output "sql_vm_names" {
  description = "Names of the created SQL VMs."
  value       = keys(module.sql_vm)
}

output "sql_vm_ips" {
  description = "Private IPs of the SQL VMs."
  value       = { for k, v in module.sql_vm : k => v.virtual_machine_azurerm.private_ip_address }
}

output "load_balancer_ip" {
  description = "Frontend IP(s) of the Internal Load Balancer (Listener IP). Returns first IP for single subnet, or comma-separated IPs for multi-subnet VNN."
  value = var.is_ha ? join(",", azurerm_lb.sql_lb[0].frontend_ip_configuration[*].private_ip_address) : null
}

output "cluster_name" {
  description = "Name of the Failover Cluster."
  value       = var.failover_cluster_name
}

output "witness_storage_account_name" {
  description = "Name of the Witness Storage Account."
  value       = var.is_ha ? module.witness_storage[0].name : null
}

