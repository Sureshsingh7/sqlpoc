output "ops_key_vault_id" {
  value = azurerm_key_vault.ops.id
}

output "kv_private_endpoint_id" {
  value = azurerm_private_endpoint.kv_pep.id
}

output "kv_private_endpoint_network_interface_ids" {
  value = azurerm_private_endpoint.kv_pep.network_interface_ids
}