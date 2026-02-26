
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
  count  = var.deploy_primary ? 1 : 0
  source = "../modules/sql-iaas"

  resource_group_name = var.sql_resource_group_name
  location            = var.location
  name_prefix         = var.sql_name_prefix

  is_ha = var.enable_failover_cluster
  is_dr = false

  vm_sku = var.vm_size

  subnet_ids = [
    data.terraform_remote_state.network.outputs.sql_subnet_sql1_id,
    data.terraform_remote_state.network.outputs.sql_subnet_sql2_id
  ]
  private_endpoint_subnet_id = data.terraform_remote_state.network.outputs.pep_subnet_id
  vnet_id                    = data.terraform_remote_state.network.outputs.sql_vnet_id

  sql_admin_username                      = var.sql_admin_username
  sql_vm_admin_password                   = local.sql_vm_admin_password
  cluster_local_admin_username            = var.cluster_local_admin_username
  user_assigned_identity_ids              = var.sql_vm_user_assigned_identity_ids
  sql_vm_user_assigned_identity_client_id = var.sql_vm_user_assigned_identity_client_id

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

  failover_cluster_name                = var.failover_cluster_name
  dns_zone_name                        = "sql.internal"
  dns_zone_resource_group_name         = data.terraform_remote_state.network.outputs.sql_dns_zone_resource_group_name
  witness_storage_security_control_tag = var.witness_storage_security_control_tag_value

  key_vault_name = data.terraform_remote_state.ops.outputs.ops_key_vault_name

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

  # Get primary nodes from either the primary module (if deploying both) or remote state (if DR-only)
  dr_primary_nodes = var.deploy_primary ? module.sql_cluster[0].sql_vm_names : (
    length(data.terraform_remote_state.primary_ha) > 0 ? keys(data.terraform_remote_state.primary_ha[0].outputs.sql_vm_ids) : []
  )

  # --- Distributed Availability Group (DAG) ---
  enable_dag = var.enable_dag

  dag_name        = var.enable_dag ? "${var.sql_name_prefix}-DAG" : ""
  primary_ag_name = var.enable_dag ? "${var.sql_name_prefix}-AG" : ""

  primary_ag_listener_ip = var.enable_dag ? split(",", (
    var.deploy_primary ? module.sql_cluster[0].load_balancer_ip : (
      length(data.terraform_remote_state.primary_ha) > 0 ? data.terraform_remote_state.primary_ha[0].outputs.load_balancer_ip : ""
    )
  ))[0] : ""

  primary_ag_primary_replica = var.enable_dag ? (
    var.deploy_primary ? module.sql_cluster[0].ag_primary_replica : (
      length(data.terraform_remote_state.primary_ha) > 0 ? sort(keys(data.terraform_remote_state.primary_ha[0].outputs.sql_vm_ids))[0] : ""
    )
  ) : ""

  primary_ag_node_ips = var.enable_dag ? (
    var.deploy_primary ? module.sql_cluster[0].sql_vm_ips : (
      length(data.terraform_remote_state.primary_ha) > 0 ? data.terraform_remote_state.primary_ha[0].outputs.sql_vm_private_ips : {}
    )
  ) : {}

  primary_sql_admin_password = var.enable_dag ? local.sql_vm_admin_password : ""

  vm_sku = var.vm_size

  subnet_ids = [
    data.terraform_remote_state.network.outputs.dr_sql_subnet_sql1_id,
    data.terraform_remote_state.network.outputs.dr_sql_subnet_sql2_id
  ]
  private_endpoint_subnet_id = data.terraform_remote_state.network.outputs.dr_pep_subnet_id
  vnet_id                    = data.terraform_remote_state.network.outputs.dr_sql_vnet_id

  sql_admin_username                      = var.sql_admin_username
  sql_vm_admin_password                   = local.dr_sql_vm_admin_password
  cluster_local_admin_username            = local.dr_cluster_local_admin_username
  user_assigned_identity_ids              = var.sql_vm_user_assigned_identity_ids
  sql_vm_user_assigned_identity_client_id = var.sql_vm_user_assigned_identity_client_id

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

  failover_cluster_name                = "${var.failover_cluster_name}-dr"
  dns_zone_name                        = "sql.internal"
  dns_zone_resource_group_name         = data.terraform_remote_state.network.outputs.sql_dns_zone_resource_group_name
  witness_storage_security_control_tag = var.witness_storage_security_control_tag_value

  key_vault_name        = var.enable_dr ? data.terraform_remote_state.ops.outputs.dr_key_vault_name : ""
  remote_key_vault_name = var.enable_dag ? data.terraform_remote_state.ops.outputs.ops_key_vault_name : ""

  tags = merge(
    var.tags,
    {
      environment = "dr"
      dr_enabled  = "true"
    }
  )
}
