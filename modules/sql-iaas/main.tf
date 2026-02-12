resource "random_string" "witness_suffix" {
  length  = 6
  upper   = false
  special = false
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  # Determine VM names and count based on HA/DR flags
  is_ha_dr_deployment = var.is_ha
  vm_count            = local.is_ha_dr_deployment ? 2 : 1

  # Naming convention: {prefix}-sql-{01,02} for Primary (legacy), {prefix}-sql{01,02} for DR (compact)
  vm_separator = var.is_dr ? "" : "-"
  vm_names     = [for i in range(1, local.vm_count + 1) : "${var.name_prefix}-sql${local.vm_separator}${format("%02d", i)}"]
  vm_map       = { for idx, name in local.vm_count > 0 ? range(local.vm_count) : [] : local.vm_names[idx] => idx }

  # Storage configuration
  disks_per_vm = [
    { name_suffix = "data", disk_size_gb = var.data_disk_size_gb, storage_type = var.data_disk_type, lun = 0 },
    { name_suffix = "log", disk_size_gb = var.log_disk_size_gb, storage_type = var.log_disk_type, lun = 1 },
    { name_suffix = "tempdb", disk_size_gb = var.tempdb_disk_size_gb, storage_type = var.tempdb_disk_type, lun = 2 }
  ]

  all_disks = flatten([
    for vm_idx in range(local.vm_count) : [
      for disk in local.disks_per_vm : {
        key          = "${local.vm_names[vm_idx]}-${disk.name_suffix}"
        vm_index     = vm_idx
        vm_name      = local.vm_names[vm_idx]
        name         = "${local.vm_names[vm_idx]}-${disk.name_suffix}"
        disk_size_gb = disk.disk_size_gb
        storage_type = disk.storage_type
        lun          = disk.lun
      }
    ]
  ])
  all_disks_map = { for disk in local.all_disks : disk.key => disk }
}

# --- Cloud Witness (Storage + DNS) ---
# Created only for HA deployments (Primary or DR)
# Ideally one per cluster. The DR deployment will create its own for the DR cluster if separate.
module "witness_blob_dns" {
  count   = var.is_ha ? 1 : 0
  source  = "Azure/avm-res-network-privatednszone/azurerm"
  version = "0.4.4"

  domain_name = "privatelink.blob.core.windows.net"
  parent_id   = data.azurerm_resource_group.this.id
  tags        = var.tags

  virtual_network_links = {
    sql_vnet = {
      name               = "link-blob-${var.name_prefix}"
      virtual_network_id = var.vnet_id
      autoregistration   = false
    }
  }
}

module "witness_storage" {
  count   = var.is_ha ? 1 : 0
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.6.7"

  name                            = "st${replace(var.name_prefix, "-", "")}wt${random_string.witness_suffix.result}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false

  tags = merge(var.tags, {
    SecurityControl = var.witness_storage_security_control_tag
  })

  private_endpoints = {
    witness_blob = {
      name                          = "${var.name_prefix}-witness-pe"
      subnet_resource_id            = var.private_endpoint_subnet_id != "" ? var.private_endpoint_subnet_id : var.subnet_ids[0]
      subresource_name              = "blob"
      private_dns_zone_resource_ids = [module.witness_blob_dns[0].resource_id]
    }
  }
}

# --- Virtual Machines ---
module "sql_vm" {
  for_each = local.vm_map
  source   = "Azure/avm-res-compute-virtualmachine/azurerm"
  version  = "0.20.0"

  name                = each.key
  location            = var.location
  resource_group_name = var.resource_group_name

  # Distribute across zones if provided, otherwise null (let Azure decide or single zone)
  zone = length(var.availability_zones) > 0 ? var.availability_zones[each.value % length(var.availability_zones)] : null

  os_type  = "Windows"
  sku_size = var.vm_sku

  managed_identities = {
    system_assigned            = false
    user_assigned_resource_ids = toset(var.user_assigned_identity_ids)
  }

  patch_assessment_mode                                  = "AutomaticByPlatform"
  patch_mode                                             = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true
  encryption_at_host_enabled                             = false

  network_interfaces = {
    sql_nic = {
      name                           = "${each.key}-nic"
      accelerated_networking_enabled = true
      ip_configurations = {
        primary = {
          name                          = "internal"
          private_ip_address_allocation = "Dynamic"
          private_ip_subnet_resource_id = var.subnet_ids[each.value % length(var.subnet_ids)]
          is_primary_ipconfiguration    = true
        }
      }
    }
  }

  account_credentials = {
    admin_credentials = {
      username                           = var.sql_admin_username
      password                           = var.sql_vm_admin_password
      generate_admin_password_or_ssh_key = false
    }
  }

  os_disk = {
    name                 = "${each.key}-os"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128
  }

  source_image_reference = {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  data_disk_managed_disks = {
    for disk_key, disk in local.all_disks_map : disk_key => {
      name                 = disk.name
      storage_account_type = disk.storage_type
      create_option        = "Empty"
      disk_size_gb         = disk.disk_size_gb
      lun                  = disk.lun
      caching              = "ReadOnly"
    } if disk.vm_name == each.key
  }

  tags = var.tags
}

# --- SQL IaaS Extension ---
resource "azurerm_mssql_virtual_machine" "sql_vm" {
  for_each                         = local.vm_map
  virtual_machine_id               = module.sql_vm[each.key].resource_id
  sql_license_type                 = "PAYG"
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_password = var.sql_vm_admin_password
  sql_connectivity_update_username = var.sql_admin_username

  sql_instance {
    collation                            = "SQL_Latin1_General_CP1_CI_AS"
    max_dop                              = 0
    min_server_memory_mb                 = 0
    max_server_memory_mb                 = 12288
    adhoc_workloads_optimization_enabled = true
    instant_file_initialization_enabled  = true
  }

  auto_patching {
    day_of_week                            = "Sunday"
    maintenance_window_duration_in_minutes = 60
    maintenance_window_starting_hour       = 2
  }

  tags       = var.tags
  depends_on = [module.sql_vm]
}

# --- Load Balancer (Internal) ---
# Only for HA deployments
# VNN configuration requires 1 frontend IP per subnet
resource "azurerm_lb" "sql_lb" {
  count               = var.is_ha ? 1 : 0
  name                = "${var.name_prefix}-ilb"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"

  # Frontend IP for first subnet
  frontend_ip_configuration {
    name                          = "LoadBalancerFrontEnd-Subnet1"
    subnet_id                     = var.subnet_ids[0]
    private_ip_address_allocation = "Dynamic"
  }

  # Frontend IP for second subnet (for VNN listener)
  dynamic "frontend_ip_configuration" {
    for_each = length(var.subnet_ids) > 1 ? [1] : []
    content {
      name                          = "LoadBalancerFrontEnd-Subnet2"
      subnet_id                     = var.subnet_ids[1]
      private_ip_address_allocation = "Dynamic"
    }
  }

  tags = var.tags
}

resource "azurerm_lb_backend_address_pool" "sql_lb_backend" {
  count           = var.is_ha ? 1 : 0
  loadbalancer_id = azurerm_lb.sql_lb[0].id
  name            = "SqlBackendPool"
}

resource "azurerm_lb_backend_address_pool_address" "sql_nodes" {
  for_each                = var.is_ha ? local.vm_map : {}
  name                    = each.key
  backend_address_pool_id = azurerm_lb_backend_address_pool.sql_lb_backend[0].id
  virtual_network_id      = var.vnet_id
  ip_address              = module.sql_vm[each.key].virtual_machine_azurerm.private_ip_address
}

resource "azurerm_lb_probe" "sql_probe" {
  count               = var.is_ha ? 1 : 0
  loadbalancer_id     = azurerm_lb.sql_lb[0].id
  name                = "SqlProbe"
  port                = 59999
  protocol            = "Tcp"
  interval_in_seconds = 5
  number_of_probes    = 2
}

# Load balancing rules for SQL port 1433 on both frontend IPs
resource "azurerm_lb_rule" "sql_rule_1433_subnet1" {
  count                          = var.is_ha ? 1 : 0
  loadbalancer_id                = azurerm_lb.sql_lb[0].id
  name                           = "SqlListener-1433-Subnet1"
  protocol                       = "Tcp"
  frontend_port                  = 1433
  backend_port                   = 1433
  frontend_ip_configuration_name = "LoadBalancerFrontEnd-Subnet1"
  probe_id                       = azurerm_lb_probe.sql_probe[0].id
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.sql_lb_backend[0].id]
  floating_ip_enabled            = true
}

resource "azurerm_lb_rule" "sql_rule_1433_subnet2" {
  count                          = var.is_ha && length(var.subnet_ids) > 1 ? 1 : 0
  loadbalancer_id                = azurerm_lb.sql_lb[0].id
  name                           = "SqlListener-1433-Subnet2"
  protocol                       = "Tcp"
  frontend_port                  = 1433
  backend_port                   = 1433
  frontend_ip_configuration_name = "LoadBalancerFrontEnd-Subnet2"
  probe_id                       = azurerm_lb_probe.sql_probe[0].id
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.sql_lb_backend[0].id]
  floating_ip_enabled            = true
}

# Load balancing rules for AlwaysOn port 5022 on both frontend IPs
resource "azurerm_lb_rule" "sql_rule_5022_subnet1" {
  count                          = var.is_ha ? 1 : 0
  loadbalancer_id                = azurerm_lb.sql_lb[0].id
  name                           = "AlwaysOn-5022-Subnet1"
  protocol                       = "Tcp"
  frontend_port                  = 5022
  backend_port                   = 5022
  frontend_ip_configuration_name = "LoadBalancerFrontEnd-Subnet1"
  probe_id                       = azurerm_lb_probe.sql_probe[0].id
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.sql_lb_backend[0].id]
  floating_ip_enabled            = true
}

resource "azurerm_lb_rule" "sql_rule_5022_subnet2" {
  count                          = var.is_ha && length(var.subnet_ids) > 1 ? 1 : 0
  loadbalancer_id                = azurerm_lb.sql_lb[0].id
  name                           = "AlwaysOn-5022-Subnet2"
  protocol                       = "Tcp"
  frontend_port                  = 5022
  backend_port                   = 5022
  frontend_ip_configuration_name = "LoadBalancerFrontEnd-Subnet2"
  probe_id                       = azurerm_lb_probe.sql_probe[0].id
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.sql_lb_backend[0].id]
  floating_ip_enabled            = true
}

# --- Private DNS Zone for Cluster VNN ---
module "sql_dns" {
  count   = var.is_ha ? 1 : 0
  source  = "Azure/avm-res-network-privatednszone/azurerm"
  version = "0.4.4"

  domain_name = var.dns_zone_name
  parent_id   = data.azurerm_resource_group.this.id
  tags        = var.tags

  virtual_network_links = {
    sql_vnet = {
      name               = "link-sql-vnet-${var.name_prefix}"
      virtual_network_id = var.vnet_id
      autoregistration   = false
    }
  }
}

# DNS A record for cluster listener (VNN) points to both frontend IPs
resource "azurerm_private_dns_a_record" "cluster_listener" {
  count               = var.is_ha ? 1 : 0
  name                = var.failover_cluster_name
  zone_name           = var.dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records = length(var.subnet_ids) > 1 ? [
    azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address,
    azurerm_lb.sql_lb[0].frontend_ip_configuration[1].private_ip_address
  ] : [azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address]

  depends_on = [module.sql_dns]
}

# DNS A records for individual VMs (for inter-node communication)
resource "azurerm_private_dns_a_record" "sql_vm" {
  for_each            = var.is_ha ? local.vm_map : {}
  name                = each.key
  zone_name           = var.dns_zone_name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [module.sql_vm[each.key].virtual_machine_azurerm.private_ip_address]

  depends_on = [module.sql_dns]
}


# --- VM Extensions (Disk Setup & Cluster Setup) ---

resource "azurerm_virtual_machine_run_command" "disk_setup" {
  for_each = local.vm_map

  name               = "disk-setup"
  location           = var.location
  virtual_machine_id = module.sql_vm[each.key].resource_id

  source {
    script = file("${path.module}/scripts/disk_setup.ps1")
  }

  parameter {
    name  = "NodeIPs"
    value = var.is_ha ? join(",", [for name in local.vm_names : module.sql_vm[name].virtual_machine_azurerm.private_ip_address]) : ""
  }

  parameter {
    name  = "NodeNames"
    value = var.is_ha ? join(",", local.vm_names) : ""
  }

  parameter {
    name  = "ClusterName"
    value = var.is_ha ? var.failover_cluster_name : ""
  }

  parameter {
    name = "ClusterIPs"
    value = var.is_ha ? (length(var.subnet_ids) > 1 ? join(",", [
      azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address,
      azurerm_lb.sql_lb[0].frontend_ip_configuration[1].private_ip_address
    ]) : azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address) : ""
  }

  parameter {
    name  = "ClusterAdminUsername"
    value = var.is_ha ? var.cluster_local_admin_username : ""
  }

  parameter {
    name  = "ClusterAdminPasswordSecure"
    value = var.is_ha ? base64encode(var.sql_vm_admin_password) : ""
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "10m"
  }

  tags = var.tags
}

resource "azurerm_virtual_machine_run_command" "cluster_setup" {
  for_each = var.is_ha ? local.vm_map : {}

  name               = "failover-cluster-setup"
  location           = var.location
  virtual_machine_id = module.sql_vm[each.key].resource_id
  depends_on         = [azurerm_virtual_machine_run_command.disk_setup]

  source {
    script = file("${path.module}/scripts/create_failover_cluster.ps1")
  }

  # NOTE: These are base64-encoded and passed as regular parameters because
  # protected_parameter values are not persisted in state and are not reliably
  # re-delivered on run command updates (e.g. after import).
  parameter {
    name  = "ClusterAdminPasswordSecure"
    value = base64encode(var.sql_vm_admin_password)
  }

  parameter {
    name  = "WitnessStorageKeyBase64"
    value = base64encode(module.witness_storage[0].resource.primary_access_key)
  }

  # Pass ALL node IPs and Names to each node so they know their peers
  parameter {
    name  = "NodeIPs"
    value = join(",", [for name in local.vm_names : module.sql_vm[name].virtual_machine_azurerm.private_ip_address])
  }

  parameter {
    name  = "NodeNames"
    value = join(",", local.vm_names)
  }

  parameter {
    name  = "ClusterName"
    value = var.failover_cluster_name
  }

  parameter {
    name  = "ClusterAdminUsername"
    value = var.cluster_local_admin_username
  }

  parameter {
    name  = "WitnessStorageAccountName"
    value = module.witness_storage[0].name
  }

  parameter {
    name = "ClusterIPs"
    value = length(var.subnet_ids) > 1 ? join(",", [
      azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address,
      azurerm_lb.sql_lb[0].frontend_ip_configuration[1].private_ip_address
    ]) : azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }

  tags = merge(var.tags, {
    script_hash = md5(file("${path.module}/scripts/create_failover_cluster.ps1"))
  })
}

# HADR Endpoint Configuration (runs on all nodes)
# Uses SMB (UNC paths) for certificate exchange between nodes
resource "azurerm_virtual_machine_run_command" "hadr_endpoint_setup" {
  for_each = var.is_ha ? local.vm_map : {}

  name               = "hadr-endpoint-setup-v14"
  location           = var.location
  virtual_machine_id = module.sql_vm[each.key].resource_id
  depends_on         = [azurerm_virtual_machine_run_command.cluster_setup]

  source {
    script = file("${path.module}/scripts/configure_hadr_endpoints.ps1")
  }

  parameter {
    name  = "AllNodeNames"
    value = join(",", local.vm_names)
  }

  parameter {
    name  = "CurrentNodeName"
    value = each.key
  }

  parameter {
    name  = "EndpointPort"
    value = "5022"
  }

  parameter {
    name  = "SqlAdminUsername"
    value = var.sql_admin_username
  }

  parameter {
    name  = "SqlAdminPassword"
    value = var.sql_vm_admin_password
  }

  parameter {
    name  = "ClusterAdminUsername"
    value = var.cluster_local_admin_username
  }

  parameter {
    name  = "ClusterAdminPassword"
    value = var.sql_vm_admin_password
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "10m"
  }

  tags = merge(var.tags, {
    script_hash = md5(file("${path.module}/scripts/configure_hadr_endpoints.ps1"))
  })
}

# Availability Group Setup (runs on ALL nodes)
# Primary creates AG and waits for secondaries; secondaries poll primary and join locally.
# This is more robust than the old approach (primary joining secondaries remotely).
resource "azurerm_virtual_machine_run_command" "ag_setup" {
  for_each = var.is_ha ? local.vm_map : {}

  name               = "availability-group-setup-v24"
  location           = var.location
  virtual_machine_id = module.sql_vm[each.key].resource_id
  depends_on         = [azurerm_virtual_machine_run_command.hadr_endpoint_setup]

  source {
    script = file("${path.module}/scripts/create_availability_group.ps1")
  }

  parameter {
    name  = "AGName"
    value = "${var.name_prefix}-AG"
  }

  parameter {
    name  = "ListenerName"
    value = "${var.name_prefix}-listener"
  }

  parameter {
    name = "ListenerIPs"
    value = length(var.subnet_ids) > 1 ? join(",", [
      azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address,
      azurerm_lb.sql_lb[0].frontend_ip_configuration[1].private_ip_address
    ]) : azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address
  }

  parameter {
    name  = "PrimaryReplica"
    value = local.vm_names[0]
  }

  parameter {
    name  = "SecondaryReplicas"
    value = join(",", slice(local.vm_names, 1, length(local.vm_names)))
  }

  parameter {
    name  = "ListenerPort"
    value = "1433"
  }

  parameter {
    name  = "ProbePort"
    value = "59999"
  }

  parameter {
    name  = "SqlAdminUsername"
    value = var.sql_admin_username
  }

  parameter {
    name  = "SqlAdminPassword"
    value = var.sql_vm_admin_password
  }

  parameter {
    name  = "ClusterAdminUsername"
    value = var.cluster_local_admin_username
  }

  parameter {
    name  = "ClusterAdminPassword"
    value = var.sql_vm_admin_password
  }

  parameter {
    name  = "IsDAGTarget"
    value = var.enable_dag ? "true" : "false"
  }

  parameter {
    name  = "SeedingMode"
    value = var.enable_dag ? "AUTOMATIC" : "MANUAL"
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }

  tags = merge(var.tags, {
    script_hash = md5(file("${path.module}/scripts/create_availability_group.ps1"))
  })
}

# --- Distributed Availability Group (DAG) Setup ---
# Runs on ALL DR nodes for cross-cluster certificate exchange.
# Only the DR primary node creates/joins the DAG.
resource "azurerm_virtual_machine_run_command" "dag_setup" {
  for_each = var.enable_dag ? local.vm_map : {}

  name               = "dag-setup-v2"
  location           = var.location
  virtual_machine_id = module.sql_vm[each.key].resource_id
  depends_on         = [azurerm_virtual_machine_run_command.ag_setup]

  source {
    script = file("${path.module}/scripts/configure_dag.ps1")
  }

  parameter {
    name  = "DAGName"
    value = var.dag_name
  }

  parameter {
    name  = "LocalAGName"
    value = "${var.name_prefix}-AG"
  }

  parameter {
    name  = "LocalListenerIP"
    value = azurerm_lb.sql_lb[0].frontend_ip_configuration[0].private_ip_address
  }

  parameter {
    name  = "LocalPrimaryReplica"
    value = local.vm_names[0]
  }

  parameter {
    name  = "RemoteAGName"
    value = var.primary_ag_name
  }

  parameter {
    name  = "RemoteListenerIP"
    value = var.primary_ag_listener_ip
  }

  parameter {
    name  = "RemotePrimaryReplica"
    value = var.primary_ag_primary_replica
  }

  parameter {
    name  = "RemoteNodeNames"
    value = join(",", sort(keys(var.primary_ag_node_ips)))
  }

  parameter {
    name  = "RemoteNodeIPs"
    value = join(",", [for name in sort(keys(var.primary_ag_node_ips)) : var.primary_ag_node_ips[name]])
  }

  parameter {
    name  = "SqlAdminUsername"
    value = var.sql_admin_username
  }

  parameter {
    name  = "LocalSqlPassword"
    value = var.sql_vm_admin_password
  }

  parameter {
    name  = "RemoteSqlPassword"
    value = var.primary_sql_admin_password
  }

  parameter {
    name  = "LocalClusterAdminUsername"
    value = var.cluster_local_admin_username
  }

  parameter {
    name  = "RemoteClusterAdminUsername"
    value = "clusteradmin"
  }

  parameter {
    name  = "RemoteClusterAdminPassword"
    value = var.primary_sql_admin_password
  }

  parameter {
    name  = "LocalNodeNames"
    value = join(",", local.vm_names)
  }

  parameter {
    name  = "LocalNodeIPs"
    value = join(",", [for name in local.vm_names : module.sql_vm[name].virtual_machine_azurerm.private_ip_address])
  }

  parameter {
    name  = "EndpointPort"
    value = "5022"
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }

  tags = merge(var.tags, {
    script_hash = md5(file("${path.module}/scripts/configure_dag.ps1"))
  })
}

