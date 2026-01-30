
data "azurerm_key_vault_secret" "sql_vm_admin" {
  name         = "sql-vm-admin-password"
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id
}

locals {
  sql_vm_admin_password = try(
    data.terraform_remote_state.ops.outputs.sql_vm_admin_password,
    data.azurerm_key_vault_secret.sql_vm_admin.value
  )

  # DR password: use DR Key Vault secret if DR enabled, otherwise use primary password
  dr_sql_vm_admin_password = var.enable_dr ? data.azurerm_key_vault_secret.dr_sql_vm_admin[0].value : local.sql_vm_admin_password

  # DR cluster admin username: use override if provided, otherwise use primary username  
  dr_cluster_local_admin_username = var.dr_cluster_local_admin_username != "" ? var.dr_cluster_local_admin_username : var.cluster_local_admin_username
}

module "sql_cluster" {
  source = "../modules/sql-iaas"

  resource_group_name = var.sql_resource_group_name
  location            = var.location
  name_prefix         = var.sql_name_prefix

  is_ha = var.enable_failover_cluster
  is_dr = false

  vm_sku = var.vm_size

  subnet_ids = [
    data.terraform_remote_state.network.outputs.sql_subnet_sql1_id
  ]
  vnet_id = data.terraform_remote_state.network.outputs.sql_vnet_id

  sql_admin_username           = var.sql_admin_username
  sql_vm_admin_password        = local.sql_vm_admin_password
  cluster_local_admin_username = var.cluster_local_admin_username
  user_assigned_identity_ids   = var.sql_vm_user_assigned_identity_ids

  # Disk configuration
  data_disk_size_gb   = var.data_disk_size_gb
  data_disk_type      = var.data_disk_type
  log_disk_size_gb    = var.log_disk_size_gb
  log_disk_type       = var.log_disk_type
  tempdb_disk_size_gb = var.tempdb_disk_size_gb
  tempdb_disk_type    = var.tempdb_disk_type

  # Image configuration
  image_publisher = var.image_publisher
  image_offer     = var.image_offer
  image_sku       = var.image_sku
  image_version   = var.image_version

  failover_cluster_name = var.failover_cluster_name
  dns_zone_name         = "sql.internal"

  tags = var.tags
}

module "sql_cluster_dr" {
  count  = var.enable_dr ? 1 : 0
  source = "../modules/sql-iaas"

  resource_group_name = var.dr_sql_resource_group_name
  location            = var.dr_location
  name_prefix         = "${var.sql_name_prefix}-dr"

  is_ha = true
  is_dr = true

  dr_primary_nodes = module.sql_cluster.sql_vm_names

  vm_sku = var.vm_size

  subnet_ids = [
    data.terraform_remote_state.network.outputs.dr_sql_subnet_sql1_id
  ]
  vnet_id = data.terraform_remote_state.network.outputs.dr_sql_vnet_id

  sql_admin_username           = var.sql_admin_username
  sql_vm_admin_password        = local.dr_sql_vm_admin_password
  cluster_local_admin_username = local.dr_cluster_local_admin_username
  user_assigned_identity_ids   = var.sql_vm_user_assigned_identity_ids

  # Disk configuration
  data_disk_size_gb   = var.data_disk_size_gb
  data_disk_type      = var.data_disk_type
  log_disk_size_gb    = var.log_disk_size_gb
  log_disk_type       = var.log_disk_type
  tempdb_disk_size_gb = var.tempdb_disk_size_gb
  tempdb_disk_type    = var.tempdb_disk_type

  # Image configuration
  image_publisher = var.image_publisher
  image_offer     = var.image_offer
  image_sku       = var.image_sku
  image_version   = var.image_version

  failover_cluster_name = "${var.failover_cluster_name}-dr"
  dns_zone_name         = "sql.internal"

  tags = merge(
    { for k, v in var.tags : k => v if lower(k) != "environment" },
    { environment = "dr" }
  )
}
