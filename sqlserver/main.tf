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

# SQL IaaS Agent Extension - handles disk creation, formatting, and SQL Server configuration
resource "azurerm_mssql_virtual_machine" "sql_vm" {
  count                            = local.sql_vm_count
  virtual_machine_id               = azurerm_windows_virtual_machine.sql_vm[count.index].id
  sql_license_type                 = "PAYG"
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_connectivity_update_password = random_password.sql_vm[count.index].result
  sql_connectivity_update_username = var.sql_admin_username

  # Automated disk creation and SQL Server storage configuration
  storage_configuration {
    disk_type             = "NEW"
    storage_workload_type = "OLTP"

    # Data disks configuration
    data_settings {
      default_file_path = "F:\\Data"
      luns              = [0]
    }

    # Log disks configuration
    log_settings {
      default_file_path = "G:\\Log"
      luns              = [1]
    }

    # TempDB configuration
    temp_db_settings {
      default_file_path = "T:\\TempDB"
      luns              = [2]
    }
  }

  # SQL Server instance configuration
  sql_instance {
    collation                            = "SQL_Latin1_General_CP1_CI_AS"
    max_dop                              = 0 # 0 = SQL Server decides based on CPU cores
    max_server_memory_mb                 = 2147483647 # 0 = SQL Server manages memory dynamically
    min_server_memory_mb                 = 0
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
    create = "120m"
    update = "120m"
  }

  depends_on = [azurerm_windows_virtual_machine.sql_vm]
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
