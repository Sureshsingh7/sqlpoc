
resource "random_string" "witness_suffix" {
  length  = 6
  upper   = false
  special = false
}

data "azurerm_resource_group" "sql" {
  name = var.sql_resource_group_name
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
  sql_vm_map       = { for idx, name in var.sql_vm_names : name => idx }
  sql_vm_nic_names = ["sqlpoc-nic-sql-primary", "sqlpoc-nic-sql-secondary"]
}

# Cloud Witness storage account (used for WSFC quorum in a workgroup cluster).
# Org policy disables Shared Key access by default; the SecurityControl=ignore tag
# is used to bypass that policy in this PoC.
module "witness_blob_dns" {
  source  = "Azure/avm-res-network-privatednszone/azurerm"
  version = "0.4.4"

  domain_name = "privatelink.blob.core.windows.net"
  parent_id   = data.azurerm_resource_group.sql.id
  tags        = local.tags

  virtual_network_links = {
    sql_vnet = {
      name               = "link-blob-sql-vnet"
      virtual_network_id = data.terraform_remote_state.network.outputs.sql_vnet_id
      autoregistration   = false
    }
  }
}

module "witness_storage" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.6.7"

  name                            = "stsqlw${random_string.witness_suffix.result}"
  resource_group_name             = var.sql_resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true

  tags = merge(local.tags, {
    SecurityControl = var.witness_storage_security_control_tag_value
  })

  private_endpoints = {
    witness_blob = {
      name                          = "pep-witness-blob"
      subnet_resource_id            = data.terraform_remote_state.network.outputs.pep_subnet_id
      subresource_name              = "blob"
      private_dns_zone_resource_ids = [module.witness_blob_dns.resource_id]
    }
  }
}

# Host the disk setup script in the existing TFSTATE storage account/container.
# Terraform itself should not manage uploads/RBAC here because the runner identity
# typically lacks `storageAccounts/read` and `Microsoft.Authorization/roleAssignments/*`
# on the TFSTATE resource group.
#
# Instead, the GitHub Actions workflow uploads the script and generates a short-lived
# *user delegation SAS* (Azure AD) which is passed to Terraform via `TF_VAR_disk_setup_sas`.
locals {
  tfstate_resource_group_name  = "rg-fnz-poc-tfstate-se"
  tfstate_storage_account_name = "stfnzpocdj522c"
  tfstate_container_name       = "tfstate"

  disk_setup_blob_name = "scripts/disk_setup.ps1"
  disk_setup_blob_url  = "https://${local.tfstate_storage_account_name}.blob.core.windows.net/${local.tfstate_container_name}/${local.disk_setup_blob_name}"

  # The workflow provides a user-delegation SAS without a leading '?'.
  disk_setup_file_uri = "${local.disk_setup_blob_url}?${var.disk_setup_sas}"

  # Used to force a settings diff so CustomScriptExtension re-runs when the script changes.
  disk_setup_sha = filesha256("${path.module}/disk_setup.ps1")
}

# Locals for naming and organization
locals {
  sql_vm_count = length(var.sql_vm_names)

  # Calculate subnet parameters for dynamic IP allocation
  sql1_prefix_length    = tonumber(split("/", data.terraform_remote_state.network.outputs.sql_subnet_sql1_address_prefix)[1])
  sql2_prefix_length    = tonumber(split("/", data.terraform_remote_state.network.outputs.sql_subnet_sql2_address_prefix)[1])
  sql1_max_usable_index = pow(2, 32 - local.sql1_prefix_length) - 5
  sql2_max_usable_index = pow(2, 32 - local.sql2_prefix_length) - 5

  # Dynamic host index allocation (percentage-based for subnet size flexibility)
  primary_vm_host_index        = max(10, floor(local.sql1_max_usable_index * 0.15))
  secondary_vm_host_index      = max(10, floor(local.sql2_max_usable_index * 0.15))
  cluster_primary_host_index   = max(20, floor(local.sql1_max_usable_index * 0.30))
  cluster_secondary_host_index = max(20, floor(local.sql2_max_usable_index * 0.45))

  # Compute VM and cluster IPs from subnet CIDR blocks
  primary_vm_ip        = cidrhost(data.terraform_remote_state.network.outputs.sql_subnet_sql1_address_prefix, local.primary_vm_host_index)
  secondary_vm_ip      = cidrhost(data.terraform_remote_state.network.outputs.sql_subnet_sql2_address_prefix, local.secondary_vm_host_index)
  cluster_primary_ip   = cidrhost(data.terraform_remote_state.network.outputs.sql_subnet_sql1_address_prefix, local.cluster_primary_host_index)
  cluster_secondary_ip = cidrhost(data.terraform_remote_state.network.outputs.sql_subnet_sql2_address_prefix, local.cluster_secondary_host_index)

  tags = merge(
    {
      "project"   = "SQLPOC"
      "component" = "SQLServerVM"
      "tier"      = "Database"
    },
  )

  # Disk configuration for SQL Server
  disks_per_vm = [
    { name_suffix = "data-01", disk_size_gb = var.data_disk_size_gb, storage_type = var.data_disk_type, lun = 0 },
    { name_suffix = "log-01", disk_size_gb = var.log_disk_size_gb, storage_type = var.log_disk_type, lun = 1 },
    { name_suffix = "tempdb-01", disk_size_gb = var.tempdb_disk_size_gb, storage_type = var.tempdb_disk_type, lun = 2 }
  ]

  # Flatten to create all disks across all VMs
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

# SQL Server VMs configured for SQL Server failover clustering
module "sql_vm" {
  for_each = local.sql_vm_map
  source   = "Azure/avm-res-compute-virtualmachine/azurerm"
  version  = "0.20.0"

  name                = each.key
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  zone                = var.availability_zones[each.value % length(var.availability_zones)]

  os_type  = "Windows"
  sku_size = var.vm_size

  # Azure Compute can reject updates on some images unless this flag is enabled.
  # See error: BypassPlatformSafetyChecksOnUserSchedule cannot be set to false.
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
          private_ip_subnet_resource_id = each.value == 0 ? data.terraform_remote_state.network.outputs.sql_subnet_sql1_id : data.terraform_remote_state.network.outputs.sql_subnet_sql2_id
          is_primary_ipconfiguration    = true
        }
      }
    }
  }

  account_credentials = {
    admin_credentials = {
      username                           = var.sql_admin_username
      password                           = local.sql_vm_admin_password
      generate_admin_password_or_ssh_key = false
    }
  }

  os_disk = {
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
    system_assigned = true
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

  extensions = {
    configure_sql_disks = {
      name                       = "configure-sql-disks"
      publisher                  = "Microsoft.Compute"
      type                       = "CustomScriptExtension"
      type_handler_version       = "1.10"
      auto_upgrade_minor_version = true
      settings = jsonencode({
        fileUris         = [local.disk_setup_file_uri]
        commandToExecute = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$ErrorActionPreference='Stop'; $diskSetupSha='${local.disk_setup_sha}'; $root='C:\\Packages\\Plugins\\Microsoft.Compute.CustomScriptExtension'; $p=Get-ChildItem -Path $root -Recurse -Filter disk_setup.ps1 -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if(-not $p){ throw 'disk_setup.ps1 not found in CustomScriptExtension downloads'; }; & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $p.FullName\""
      })
    }
  }

  tags = local.tags
}

# SQL IaaS Agent Extension - SQL Server configuration only (no storage config)
resource "azurerm_mssql_virtual_machine" "sql_vm" {
  for_each                         = var.enable_sql_extension ? local.sql_vm_map : {}
  virtual_machine_id               = module.sql_vm[each.key].resource_id
  sql_license_type                 = "PAYG"
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_password = local.sql_vm_admin_password
  sql_connectivity_update_username = var.sql_admin_username

  # SQL Server instance configuration
  sql_instance {
    collation                            = "SQL_Latin1_General_CP1_CI_AS"
    max_dop                              = 0
    min_server_memory_mb                 = 0
    max_server_memory_mb                 = 12288 # 12GB for D4s_v4 (16GB RAM), leaves 4GB for OS
    adhoc_workloads_optimization_enabled = true
    instant_file_initialization_enabled  = true
  }

  # Automated patching configuration
  auto_patching {
    day_of_week                            = "Sunday"
    maintenance_window_duration_in_minutes = 60
    maintenance_window_starting_hour       = 2
  }

  tags = local.tags

  timeouts {
    create = "240m"
    update = "240m"
    delete = "480m"
  }

  # Terraform requires static references in depends_on. Depending on the module map
  # ensures VMs and their extensions are created before SQL IaaS registration.
  depends_on = [module.sql_vm]
}

# Future: Failover Clustering Configuration
# Uncomment and configure once VMs are domain-joined and basic SQL setup is complete
