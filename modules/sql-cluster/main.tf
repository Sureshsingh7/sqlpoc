resource "random_string" "witness_suffix" {
  length  = 6
  upper   = false
  special = false
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  sql_vm_count     = length(var.sql_vm_names)
  sql_vm_map       = { for idx, name in var.sql_vm_names : name => idx }
  sql_vm_nic_names = [for name in var.sql_vm_names : "nic-${name}"]
}

# Cloud Witness storage account (used for WSFC quorum in a workgroup cluster).
module "witness_blob_dns" {
  count   = var.enable_failover_cluster ? 1 : 0
  source  = "Azure/avm-res-network-privatednszone/azurerm"
  version = "0.4.4"

  domain_name = "privatelink.blob.core.windows.net"
  parent_id   = data.azurerm_resource_group.this.id
  tags        = var.tags

  virtual_network_links = {
    sql_vnet = {
      name               = "link-blob-sql-vnet"
      virtual_network_id = var.vnet_id
      autoregistration   = false
    }
  }
}

module "witness_storage" {
  count   = var.enable_failover_cluster ? 1 : 0
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.6.7"

  name                            = "stsqlw${random_string.witness_suffix.result}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true

  tags = merge(var.tags, {
    SecurityControl = var.witness_storage_security_control_tag_value
  })

  private_endpoints = {
    witness_blob = {
      name                          = "pep-witness-blob"
      subnet_resource_id            = var.subnet_id_private_endpoint
      subresource_name              = "blob"
      private_dns_zone_resource_ids = [module.witness_blob_dns[0].resource_id]
    }
  }
}

locals {
  # TFSTATE constants (source of scripts) - Hardcoded here as "convention", or could be passed.
  # The scripts are downloaded from here.
  # Assuming the caller guarantees these URIs exist via the SAS token provided.
  tfstate_storage_account_name = "stfnzpocdj522c"
  tfstate_container_name       = "tfstate"

  disk_setup_blob_url = "https://${local.tfstate_storage_account_name}.blob.core.windows.net/${local.tfstate_container_name}/scripts/disk_setup.ps1"
  disk_setup_file_uri = var.disk_setup_sas != "" ? "${local.disk_setup_blob_url}?${var.disk_setup_sas}" : local.disk_setup_blob_url
  disk_setup_sha      = filesha256("${path.module}/disk_setup.ps1")

  failover_cluster_blob_url = "https://${local.tfstate_storage_account_name}.blob.core.windows.net/${local.tfstate_container_name}/scripts/create_failover_cluster.ps1"
  failover_cluster_file_uri = var.failover_cluster_sas != "" ? "${local.failover_cluster_blob_url}?${var.failover_cluster_sas}" : local.failover_cluster_blob_url
  failover_cluster_sha      = filesha256("${path.module}/create_failover_cluster.ps1")

  # VM and Cluster IPs from variables
  # Support N nodes: Just reference the variables directly in the module resources

  # Disk configuration
  disks_per_vm = [
    { name_suffix = "data-01", disk_size_gb = var.data_disk_size_gb, storage_type = var.data_disk_type, lun = 0 },
    { name_suffix = "log-01", disk_size_gb = var.log_disk_size_gb, storage_type = var.log_disk_type, lun = 1 },
    { name_suffix = "tempdb-01", disk_size_gb = var.tempdb_disk_size_gb, storage_type = var.tempdb_disk_type, lun = 2 }
  ]

  all_disks = flatten([
    for vm_idx in range(local.sql_vm_count) : [
      for disk in local.disks_per_vm : {
        key          = "${var.sql_vm_names[vm_idx]}-${disk.name_suffix}"
        vm_index     = vm_idx
        name         = "${var.sql_vm_names[vm_idx]}-${disk.name_suffix}"
        disk_size_gb = disk.disk_size_gb
        storage_type = disk.storage_type
        lun          = disk.lun
      }
    ]
  ])

  all_disks_map = { for disk in local.all_disks : disk.key => disk }
}

module "sql_vm" {
  for_each = local.sql_vm_map
  source   = "Azure/avm-res-compute-virtualmachine/azurerm"
  version  = "0.20.0"

  name                = each.key
  location            = var.location
  resource_group_name = var.resource_group_name
  zone                = var.availability_zones[each.value % length(var.availability_zones)]

  os_type  = "Windows"
  sku_size = var.vm_size

  patch_assessment_mode                                  = "AutomaticByPlatform"
  patch_mode                                             = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true

  encryption_at_host_enabled = false

  network_interfaces = {
    sql_nic = {
      name                           = local.sql_vm_nic_names[each.value]
      accelerated_networking_enabled = true
      ip_configurations = {
        primary = {
          name                          = "internal"
          private_ip_address_allocation = "Static"
          private_ip_address            = var.sql_private_ips[each.value]
          # Select subnet based on VM index (0 -> primary subnet, 1 -> secondary subnet)
          private_ip_subnet_resource_id = each.value == 0 ? var.subnet_id_primary : var.subnet_id_secondary
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
    name                 = "${each.key}-Os-disk"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference = {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  managed_identities = {
    system_assigned            = true
    user_assigned_resource_ids = var.sql_vm_user_assigned_identity_ids
  }

  data_disk_managed_disks = {
    for disk_key, disk in local.all_disks_map : disk_key => {
      name                 = disk.name
      storage_account_type = disk.storage_type
      create_option        = "Empty"
      disk_size_gb         = disk.disk_size_gb
      lun                  = disk.lun
      caching              = "ReadOnly"
    } if disk.vm_index == each.value
  }

  extensions = (var.manage_disk_setup_extension || var.enable_failover_cluster) ? {
    configure_sql_disks_failover_cluster = {
      name                       = "configure-sql-disks-failover-cluster"
      publisher                  = "Microsoft.Compute"
      type                       = "CustomScriptExtension"
      type_handler_version       = "1.10"
      auto_upgrade_minor_version = true
      settings = jsonencode({
        scriptsToken = "${var.manage_disk_setup_extension ? local.disk_setup_sha : "none"}-${var.enable_failover_cluster ? local.failover_cluster_sha : "none"}"
      })
      protected_settings = jsonencode({
        commandToExecute = join("", [
          "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"",
          "$ErrorActionPreference='Stop'; ",
          # Unpack and run disk_setup.ps1
          var.manage_disk_setup_extension ? join("", [
            "$diskScriptPath = '$env:TEMP\\disk_setup.ps1'; ",
            "[IO.File]::WriteAllBytes($diskScriptPath, [Convert]::FromBase64String('${base64encode(file("${path.module}/disk_setup.ps1"))}')); ",
            "& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $diskScriptPath; "
          ]) : "Write-Host 'Skipping disk_setup.ps1 (manage_disk_setup_extension=false)'; ",
          # Unpack and run create_failover_cluster.ps1
          var.enable_failover_cluster ? join("", [
            "$clusterScriptPath = '$env:TEMP\\create_failover_cluster.ps1'; ",
             "[IO.File]::WriteAllBytes($clusterScriptPath, [Convert]::FromBase64String('${base64encode(file("${path.module}/create_failover_cluster.ps1"))}')); ",
            # Construct SecureString if needed, but here we just run the file which expects base64 strings or strings
             "& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $clusterScriptPath ",
            "-NodeIPs '${join("','", var.sql_private_ips)}' ",
            "-ClusterIPs '${join("','", var.cluster_ips)}' ",
            "-ClusterName '${var.failover_cluster_name}' ",
            "-NodeNames '${join("','", var.sql_vm_names)}' ",
            "-ClusterAdminUsername '${var.cluster_local_admin_username}' ",
            "-ClusterAdminPasswordSecure '${base64encode(var.sql_vm_admin_password)}' ",
            "-WitnessStorageAccountName '${module.witness_storage[0].name}' ",
            "-WitnessStorageKeyBase64 '${base64encode(module.witness_storage[0].resource.primary_access_key)}' ",
            (var.primary_cluster_dns != "" ? "-PrimaryClusterDNS '${var.primary_cluster_dns}' " : ""),
            (var.primary_cluster_ip != "" ? "-PrimaryClusterIP '${var.primary_cluster_ip}' " : ""),
            "; "
          ]) : "Write-Host 'Skipping create_failover_cluster.ps1 (enable_failover_cluster=false)'; ",
          "\""
        ]),
        managedIdentity = var.sql_vm_user_assigned_identity_client_id != "" ? { clientId = var.sql_vm_user_assigned_identity_client_id } : {}
      })
    }
  } : {}


  tags = var.tags
}

resource "azurerm_mssql_virtual_machine" "sql_vm" {
  for_each                         = var.enable_sql_extension ? local.sql_vm_map : {}
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

  tags = var.tags

  timeouts {
    create = "240m"
    update = "240m"
    delete = "480m"
  }

  depends_on = [module.sql_vm]
}
