output "ops_key_vault_id" {
  value = module.ops_kv.resource_id
}

output "ops_key_vault_name" {
  value       = "kv-fnz-poc-se"
  description = "Name of the primary Key Vault"
}

output "kv_private_endpoint_id" {
  value = module.ops_kv.private_endpoints["kv_pep"].id
}

output "jumpbox_vm_id" {
  value       = try(module.jumpbox_vm[0].resource_id, null)
  description = "Resource ID of the Windows jumpbox VM (null if disabled)"
}

output "jumpbox_private_ip" {
  value       = try(module.jumpbox_vm[0].virtual_machine_azurerm.private_ip_address, null)
  description = "Private IP of the Windows jumpbox VM (null if disabled)"
}

output "sql_vm_admin_password" {
  value       = random_password.sql_vm_admin.result
  description = "SQL VM admin password generated in ops and stored in Key Vault"
  sensitive   = true
}

# --- DR Outputs ---

output "dr_key_vault_id" {
  value       = var.enable_dr ? module.ops_kv_dr[0].resource_id : null
  description = "Resource ID of the DR Key Vault (null if DR disabled)"
}

output "dr_key_vault_name" {
  value       = var.enable_dr ? "kv-fnz-poc-dr-swc" : null
  description = "Name of the DR Key Vault (null if DR disabled)"
}

output "dr_sql_vm_admin_password" {
  value       = var.enable_dr ? random_password.dr_sql_vm_admin[0].result : null
  description = "DR SQL VM admin password generated in ops and stored in DR Key Vault"
  sensitive   = true
}
