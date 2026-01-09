# Generate random passwords for SQL VM admin accounts
resource "random_password" "sql_vm" {
  count   = length(var.sql_vm_names)
  length  = 32
  special = true
}

# Store SQL VM admin passwords in Key Vault
resource "azurerm_key_vault_secret" "sql_vm_admin_password" {
  count        = length(var.sql_vm_names)
  name         = "${var.sql_vm_names[count.index]}-local-admin"
  value        = random_password.sql_vm[count.index].result
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id

  content_type = "SQL Server VM local admin password"
}

# Host the disk setup script in the existing TFSTATE storage account/container.
# This avoids account keys / SAS (which are blocked by policy) and uses Azure AD instead.
locals {
  tfstate_resource_group_name  = "rg-fnz-poc-tfstate-se"
  tfstate_storage_account_name = "stfnzpocdj522c"
  tfstate_container_name       = "tfstate"

  disk_setup_blob_name = "scripts/disk_setup.ps1"
  disk_setup_blob_url  = "https://${local.tfstate_storage_account_name}.blob.core.windows.net/${local.tfstate_container_name}/${local.disk_setup_blob_name}"

  tfstate_container_scope = "/subscriptions/${var.subscription_id}/resourceGroups/${local.tfstate_resource_group_name}/providers/Microsoft.Storage/storageAccounts/${local.tfstate_storage_account_name}/blobServices/default/containers/${local.tfstate_container_name}"

  disk_setup_download_one_liner = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$u='${local.disk_setup_blob_url}';$o='C:\\Windows\\Temp\\disk_setup.ps1';$tok=(Invoke-RestMethod -Headers @{Metadata='true'} -Method GET -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F').access_token;$h=@{Authorization=('Bearer '+$tok);'x-ms-version'='2019-12-12';'x-ms-date'=(Get-Date).ToUniversalTime().ToString('R')};for($i=1;$i -le 12;$i++){try{Invoke-WebRequest -UseBasicParsing -Headers $h -Uri $u -OutFile $o;break}catch{if($i -eq 12){throw};Start-Sleep -Seconds 10}};& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $o"
  disk_setup_command_to_execute = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"${local.disk_setup_download_one_liner}\""
}

resource "azurerm_storage_blob" "disk_setup" {
  name                   = local.disk_setup_blob_name
  storage_account_name   = local.tfstate_storage_account_name
  storage_container_name = local.tfstate_container_name
  type                   = "Block"
  source                 = "${path.module}/disk_setup.ps1"
}

# Locals for naming and organization
locals {
  sql_vm_count = length(var.sql_vm_names)
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

# Allow each SQL VM's managed identity to read the disk setup script blob.
resource "azurerm_role_assignment" "sql_vm_tfstate_blob_reader" {
  count                = local.sql_vm_count
  scope                = local.tfstate_container_scope
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_windows_virtual_machine.sql_vm[count.index].identity[0].principal_id
}

# Network interfaces for SQL VMs
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

# SQL Server VMs
resource "azurerm_windows_virtual_machine" "sql_vm" {
  count               = local.sql_vm_count
  name                = var.sql_vm_names[count.index]
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  size                = var.vm_size
  zone                = var.availability_zones[count.index % length(var.availability_zones)]

  admin_username = var.sql_admin_username
  admin_password = random_password.sql_vm[count.index].result

  network_interface_ids = [
    azurerm_network_interface.sql_vm[count.index].id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
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

  depends_on = [azurerm_network_interface.sql_vm]
}

# Create data disks for SQL Server
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
    commandToExecute = local.disk_setup_command_to_execute
  })

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.sql_disk_attach,
    azurerm_storage_blob.disk_setup,
    azurerm_role_assignment.sql_vm_tfstate_blob_reader,
  ]
}

# SQL IaaS Agent Extension - SQL Server configuration only (no storage config)
resource "azurerm_mssql_virtual_machine" "sql_vm" {
  count                            = local.sql_vm_count
  virtual_machine_id               = azurerm_windows_virtual_machine.sql_vm[count.index].id
  sql_license_type                 = "PAYG"
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_password = random_password.sql_vm[count.index].result
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
    create = "90m"
    update = "90m"
  }

  depends_on = [
    azurerm_windows_virtual_machine.sql_vm,
    azurerm_virtual_machine_extension.sql_disk_setup
  ]
}

# Future: Failover Clustering Configuration
# Uncomment and configure once VMs are domain-joined and basic SQL setup is complete

# resource "azurerm_virtual_machine_extension" "sql_cluster_setup" {
#   count                      = local.sql_vm_count
#   name                       = "sql-cluster-setup-${count.index + 1}"
#   virtual_machine_id         = azurerm_windows_virtual_machine.sql_vm[count.index].id
#   publisher                  = "Microsoft.Compute"
#   type                       = "CustomScriptExtension"
#   type_handler_version       = "1.10"
#   auto_upgrade_minor_version = true
#
#   protected_settings = jsonencode({
#     commandToExecute = "powershell -Command \"$ErrorActionPreference='Stop'; Write-Host 'Installing WSFC...'; Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools; if ('${var.sql_vm_names[count.index]}' -eq '${var.sql_vm_names[0]}') { Write-Host 'Primary node: Creating failover cluster...'; Start-Sleep -Seconds 120; New-Cluster -Name sqlpoc-cluster -Node '${var.sql_vm_names[0]}','${var.sql_vm_names[1]}' -StaticAddress 10.10.0.20 -NoStorage -Force }; Write-Host 'Cluster setup complete'\""
#   })
#
#   depends_on = [azurerm_mssql_virtual_machine.sql_vm]
# }
