output "ops_key_vault_id" {
  value = azurerm_key_vault.ops.id
}

output "kv_private_endpoint_id" {
  value = azurerm_private_endpoint.kv_pep.id
}

output "jumpbox_vm_id" {
  value       = try(azurerm_windows_virtual_machine.jumpbox[0].id, null)
  description = "Resource ID of the Windows jumpbox VM (null if disabled)"
}

output "jumpbox_private_ip" {
  value       = try(azurerm_network_interface.jumpbox[0].private_ip_address, null)
  description = "Private IP of the Windows jumpbox VM (null if disabled)"
}
