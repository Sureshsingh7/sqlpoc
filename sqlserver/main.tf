
data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.network.tfstate"
    use_msi              = var.use_msi
  }
}

data "terraform_remote_state" "ops" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.ops.tfstate"
    use_msi              = var.use_msi
  }
}

data "azurerm_key_vault_secret" "sql_vm_admin" {
  name         = "sql-vm-admin-password"
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id
}

locals {
  sql_vm_admin_password = try(
    data.terraform_remote_state.ops.outputs.sql_vm_admin_password,
    data.azurerm_key_vault_secret.sql_vm_admin.value
  )
}

module "sql_cluster" {
  source = "../modules/sql-cluster"

  resource_group_name         = var.sql_resource_group_name
  location                    = var.location
  vm_size                     = var.vm_size
  enable_failover_cluster     = var.enable_failover_cluster
  manage_disk_setup_extension = var.manage_disk_setup_extension

  subnet_id_primary          = data.terraform_remote_state.network.outputs.sql_subnet_sql1_id
  subnet_id_secondary        = data.terraform_remote_state.network.outputs.sql_subnet_sql2_id
  subnet_id_private_endpoint = data.terraform_remote_state.network.outputs.pep_subnet_id
  vnet_id                    = data.terraform_remote_state.network.outputs.sql_vnet_id

  sql_admin_username           = var.sql_admin_username
  sql_vm_admin_password        = local.sql_vm_admin_password
  cluster_local_admin_username = var.cluster_local_admin_username

  sql_vm_user_assigned_identity_ids       = var.sql_vm_user_assigned_identity_ids
  sql_vm_user_assigned_identity_client_id = var.sql_vm_user_assigned_identity_client_id

  # SAS tokens for scripts (scripts must be hosted in the location module expects)
  disk_setup_sas       = var.disk_setup_sas
  failover_cluster_sas = var.failover_cluster_sas

  sql_vm_names       = var.sql_vm_names
  sql_private_ips    = var.sql_private_ips
  cluster_ips        = var.cluster_ips
  availability_zones = var.availability_zones
  tags               = var.tags

  # Storage Config
  os_disk_type                               = var.os_disk_type
  os_disk_size_gb                            = var.os_disk_size_gb
  data_disk_type                             = var.data_disk_type
  data_disk_count                            = var.data_disk_count
  data_disk_size_gb                          = var.data_disk_size_gb
  log_disk_type                              = var.log_disk_type
  log_disk_size_gb                           = var.log_disk_size_gb
  tempdb_disk_type                           = var.tempdb_disk_type
  tempdb_disk_size_gb                        = var.tempdb_disk_size_gb
  witness_storage_security_control_tag_value = var.witness_storage_security_control_tag_value

  # Image Config
  image_publisher      = var.image_publisher
  image_offer          = var.image_offer
  image_sku            = var.image_sku
  image_version        = var.image_version
  enable_sql_extension = var.enable_sql_extension

  failover_cluster_name = var.failover_cluster_name

  # DR Configuration (Optional)
  # primary_cluster_dns = ...
  # primary_cluster_ip = ...
}
