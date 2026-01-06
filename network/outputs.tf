
output "sql_vnet_id" {
  value = azurerm_virtual_network.sql.id
}

output "sql_vnet_name" {
  value = azurerm_virtual_network.sql.name
}

output "sql_subnet_sql1_id" {
  value = azurerm_subnet.sql_sql1.id
}

output "sql_subnet_sql2_id" {
  value = azurerm_subnet.sql_sql2.id
}

output "pep_subnet_id" {
  value = azurerm_subnet.pep_snet.id
}

output "ops_vnet_id" {
  value = azurerm_virtual_network.ops.id
}

output "ops_vnet_name" {
  value = azurerm_virtual_network.ops.name
}

output "ops_subnet_runner_id" {
  value = azurerm_subnet.ops_runner.id
}

output "ops_subnet_bastion_id" {
  value = azurerm_subnet.ops_bastion.id
}

output "bastion_id" {
  value = azurerm_bastion_host.this.id
}

output "bastion_public_ip_id" {
  value = azurerm_public_ip.bastion.id
}

output "bastion_public_ip_address" {
  value = azurerm_public_ip.bastion.ip_address
}

output "nsg_sql1_id" {
  value = azurerm_network_security_group.sql1.id
}

output "nsg_sql2_id" {
  value = azurerm_network_security_group.sql2.id
}

output "nsg_runner_id" {
  value = azurerm_network_security_group.runner.id
}

output "peering_ops_to_sql_id" {
  value = azurerm_virtual_network_peering.ops_to_sql.id
}

output "peering_sql_to_ops_id" {
  value = azurerm_virtual_network_peering.sql_to_ops.id
}