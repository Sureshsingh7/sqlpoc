output "ops_key_vault_id" {
  value = module.ops_kv.resource_id
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
