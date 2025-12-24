
# Generate random passwords for SQL VM admin accounts
resource "random_password" "sql_vm" {
  count   = length(var.sql_vm_names)
  length  = 32
  special = true
}

# Store SQL VM admin passwords in Key Vault
resource "azurerm_key_vault_secret" "sql_vm_admin_password" {
  count        = length(var.sql_vm_names)
  name         = "sql-${var.sql_vm_names[count.index]}-local-admin"
  value        = random_password.sql_vm[count.index].result
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id

  content_type = "SQL Server VM local admin password"
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
    var.tags
  )
}

# Network interfaces for SQL VMs
resource "azurerm_network_interface" "sql_vm" {
  count               = local.sql_vm_count
  name                = "nic-${var.sql_vm_names[count.index]}"
  location            = var.location
  resource_group_name = var.sql_resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.terraform_remote_state.network.outputs.sql_subnet_sql1_id
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

  admin_username = var.sql_admin_username
  admin_password = random_password.sql_vm[count.index].result

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

  depends_on = [azurerm_network_interface.sql_vm]
}

# # SQL Server data disks (Premium SSD for production)
# resource "azurerm_managed_disk" "sql_data_disk" {
#   count                = local.sql_vm_count * var.data_disk_count
#   name                 = "${var.sql_vm_names[floor(count.index / var.data_disk_count)]}-datadisk-${(count.index % var.data_disk_count) + 1}"
#   location             = var.location
#   resource_group_name  = var.sql_resource_group_name
#   storage_account_type = var.data_disk_type
#   create_option        = "Empty"
#   disk_size_gb         = var.data_disk_size_gb

#   tags = local.tags
# }

# resource "azurerm_virtual_machine_data_disk_attachment" "sql_data_disk_attach" {
#   count              = local.sql_vm_count * var.data_disk_count
#   managed_disk_id    = azurerm_managed_disk.sql_data_disk[count.index].id
#   virtual_machine_id = azurerm_windows_virtual_machine.sql_vm[floor(count.index / var.data_disk_count)].id
#   lun                = (count.index % var.data_disk_count)
#   caching            = "ReadOnly"
# }

# # SQL Server backup disks
# resource "azurerm_managed_disk" "sql_backup_disk" {
#   count                = local.sql_vm_count
#   name                 = "${var.sql_vm_names[count.index]}-backupdisk"
#   location             = var.location
#   resource_group_name  = var.sql_resource_group_name
#   storage_account_type = var.backup_disk_type
#   create_option        = "Empty"
#   disk_size_gb         = var.backup_disk_size_gb

#   tags = local.tags
# }

# resource "azurerm_virtual_machine_data_disk_attachment" "sql_backup_disk_attach" {
#   count              = local.sql_vm_count
#   managed_disk_id    = azurerm_managed_disk.sql_backup_disk[count.index].id
#   virtual_machine_id = azurerm_windows_virtual_machine.sql_vm[count.index].id
#   lun                = var.data_disk_count
#   caching            = "ReadOnly"
# }

# # SQL Server IaaS Agent Extension (optional but recommended)
# resource "azurerm_mssql_virtual_machine" "sql_vm_extension" {
#   count                           = var.enable_sql_extension ? local.sql_vm_count : 0
#   virtual_machine_id              = azurerm_windows_virtual_machine.sql_vm[count.index].id
#   sql_license_type                = "PAYG" # PAYG | AHUB (Azure Hybrid Use Benefit)
#   sql_connectivity_update_enabled = true
#   sql_connectivity_port           = 1433

#   depends_on = [azurerm_virtual_machine_data_disk_attachment.sql_backup_disk_attach]
# }
