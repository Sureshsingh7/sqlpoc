
# Generate single password for both SQL VM admin accounts
resource "random_password" "sql_vm_admin" {
  length  = 32
  special = true
}

resource "random_string" "witness_suffix" {
  length  = 6
  upper   = false
  special = false
}

# Store SQL VM admin password in Key Vault
resource "azurerm_key_vault_secret" "sql_vm_admin_password" {
  name         = "sql-vm-admin-password"
  value        = random_password.sql_vm_admin.result
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id

  content_type = "SQL Server VM local admin password (shared for primary and secondary)"
}

# Cloud Witness storage account (used for WSFC quorum in a workgroup cluster).
# Org policy disables Shared Key access by default; the SecurityControl=ignore tag
# is used to bypass that policy in this PoC.
resource "azurerm_storage_account" "witness" {
  name                     = "stsqlw${random_string.witness_suffix.result}"
  resource_group_name      = var.sql_resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  shared_access_key_enabled     = true
  allow_nested_items_to_be_public = false
  min_tls_version               = "TLS1_2"

  tags = merge(local.tags, {
    SecurityControl = var.witness_storage_security_control_tag_value
  })
}

# Private DNS zone for Storage Blob (Cloud Witness)
resource "azurerm_private_dns_zone" "witness_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.sql_resource_group_name

  tags = local.tags
}

# Link private DNS zone to SQL VNet
resource "azurerm_private_dns_zone_virtual_network_link" "witness_blob_sql_vnet" {
  name                  = "link-blob-sql-vnet"
  resource_group_name   = var.sql_resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.witness_blob.name
  virtual_network_id    = data.terraform_remote_state.network.outputs.sql_vnet_id

  tags = local.tags
}

# Private Endpoint for witness storage account (Blob)
resource "azurerm_private_endpoint" "witness_blob" {
  name                = "pep-witness-blob"
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  subnet_id           = data.terraform_remote_state.network.outputs.pep_subnet_id

  private_service_connection {
    name                           = "psc-witness-blob"
    private_connection_resource_id = azurerm_storage_account.witness.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  tags = local.tags

  private_dns_zone_group {
    name                 = "blob-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.witness_blob.id]
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

# SQL Server VM network interfaces with static IPs and accelerated networking
resource "azurerm_network_interface" "sql_vm" {
  count                          = local.sql_vm_count
  name                           = count.index == 0 ? "sqlpoc-nic-sql-primary" : "sqlpoc-nic-sql-secondary"
  location                       = var.location
  resource_group_name            = var.sql_resource_group_name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = count.index == 0 ? data.terraform_remote_state.network.outputs.sql_subnet_sql1_id : data.terraform_remote_state.network.outputs.sql_subnet_sql2_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.sql_private_ips[count.index]
  }

  tags = local.tags
}

# Windows Server VMs configured for SQL Server failover clustering
resource "azurerm_windows_virtual_machine" "sql_vm" {
  count                                                  = local.sql_vm_count
  name                                                   = var.sql_vm_names[count.index]
  location                                               = var.location
  resource_group_name                                    = var.sql_resource_group_name
  size                                                   = var.vm_size
  zone                                                   = var.availability_zones[count.index % length(var.availability_zones)]
  bypass_platform_safety_checks_on_user_schedule_enabled = true
  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform"
  admin_username                                         = var.sql_admin_username
  admin_password                                         = random_password.sql_vm_admin.result

  network_interface_ids = [
    azurerm_network_interface.sql_vm[count.index].id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [
      os_disk[0].name,
      admin_password
    ]
  }

  depends_on = [
    azurerm_network_interface.sql_vm,
    azurerm_key_vault_secret.sql_vm_admin_password
  ]
}

# Separate cluster creation resource that can run on already deployed VMs
# REMOVED - Using local-exec provisioner instead

# Managed disks for SQL Server data, log, and tempdb volumes
resource "azurerm_managed_disk" "sql_disk" {
  for_each             = local.all_disks_map
  name                 = each.value.name
  location             = var.location
  resource_group_name  = var.sql_resource_group_name
  storage_account_type = each.value.storage_type
  create_option        = "Empty"
  disk_size_gb         = each.value.disk_size_gb
  zone                 = var.availability_zones[each.value.vm_index % length(var.availability_zones)]

  tags = local.tags
}

# Attach data disks to SQL Server VMs
resource "azurerm_virtual_machine_data_disk_attachment" "sql_disk_attach" {
  for_each           = local.all_disks_map
  managed_disk_id    = azurerm_managed_disk.sql_disk[each.key].id
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm[each.value.vm_index].id
  lun                = each.value.lun
  caching            = "ReadOnly"
}

# Custom script to format and configure disks
resource "azurerm_virtual_machine_extension" "sql_disk_setup" {
  count                      = local.sql_vm_count
  name                       = "configure-sql-disks"
  virtual_machine_id         = azurerm_windows_virtual_machine.sql_vm[count.index].id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    fileUris         = [local.disk_setup_file_uri]
    commandToExecute = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$ErrorActionPreference='Stop'; $diskSetupSha='${local.disk_setup_sha}'; $root='C:\\Packages\\Plugins\\Microsoft.Compute.CustomScriptExtension'; $p=Get-ChildItem -Path $root -Recurse -Filter disk_setup.ps1 -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if(-not $p){ throw 'disk_setup.ps1 not found in CustomScriptExtension downloads'; }; & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $p.FullName\""
  })

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.sql_disk_attach,
  ]
}

# SQL IaaS Agent Extension - SQL Server configuration only (no storage config)
resource "azurerm_mssql_virtual_machine" "sql_vm" {
  count                            = local.sql_vm_count
  virtual_machine_id               = azurerm_windows_virtual_machine.sql_vm[count.index].id
  sql_license_type                 = "PAYG"
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_password = random_password.sql_vm_admin.result
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
  }

  depends_on = [
    azurerm_windows_virtual_machine.sql_vm,
    azurerm_virtual_machine_extension.sql_disk_setup
  ]
}

# Future: Failover Clustering Configuration
# Uncomment and configure once VMs are domain-joined and basic SQL setup is complete
