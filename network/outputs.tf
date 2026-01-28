
output "sql_vnet_id" {
  value = module.sql_vnet.resource_id
}

output "sql_vnet_name" {
  value = module.sql_vnet.name
}

output "sql_subnet_sql1_id" {
  value = module.sql_vnet.subnets["sql1"].resource_id
}

output "sql_subnet_sql2_id" {
  value = module.sql_vnet.subnets["sql2"].resource_id
}

output "pep_subnet_id" {
  value = module.sql_vnet.subnets["pep"].resource_id
}

output "ops_vnet_id" {
  value = module.ops_vnet.resource_id
}

output "ops_vnet_name" {
  value = module.ops_vnet.name
}

output "ops_subnet_runner_id" {
  value = module.ops_vnet.subnets["runner"].resource_id
}

output "ops_subnet_bastion_id" {
  value = module.ops_vnet.subnets["bastion"].resource_id
}

output "bastion_id" {
  value = module.bastion.resource_id
}

output "bastion_public_ip_id" {
  value = module.bastion_pip.resource_id
}

output "bastion_public_ip_address" {
  value = module.bastion_pip.public_ip_address
}

output "nsg_sql1_id" {
  value = module.nsg_sql1.resource_id
}

output "nsg_sql2_id" {
  value = module.nsg_sql2.resource_id
}

output "nsg_runner_id" {
  value = module.nsg_runner.resource_id
}

output "peering_ops_to_sql_id" {
  value = try(module.ops_vnet.peerings["ops_to_sql"].resource_id, null)
}

output "peering_sql_to_ops_id" {
  value = try(module.ops_vnet.peerings["ops_to_sql"].reverse_resource_id, null)
}

output "sql_subnet_sql1_address_prefix" {
  value = var.sql_subnet_sql1_prefix
}
# DR Outputs
output "dr_sql_vnet_id" {
  value = var.is_dr_enabled ? module.dr_sql_vnet[0].resource_id : null
}

output "dr_sql_subnet_sql1_id" {
  value = var.is_dr_enabled ? module.dr_sql_vnet[0].subnets["sql1"].resource_id : null
}

output "dr_sql_subnet_sql2_id" {
  value = var.is_dr_enabled ? module.dr_sql_vnet[0].subnets["sql2"].resource_id : null
}

output "dr_pep_subnet_id" {
  value = var.is_dr_enabled ? module.dr_sql_vnet[0].subnets["pep"].resource_id : null
}

output "dr_sql_vnet_address_space" {
  value = var.is_dr_enabled ? var.dr_sql_vnet_address_space : null
}
output "sql_subnet_sql2_address_prefix" {
  value = var.sql_subnet_sql2_prefix
}