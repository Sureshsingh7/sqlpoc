resource "random_password" "dc" {
  count   = 2
  length  = 32
  special = true
}

resource "azurerm_key_vault_secret" "dc_admin_password" {
  count        = 2
  name         = "dc-${count.index + 1}-local-admin"
  value        = random_password.dc[count.index].result
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id

  content_type = "Windows DC local admin password"
}

resource "azurerm_network_interface" "dc" {
  count               = length(var.dc_names)
  name                = "nic-${var.dc_names[count.index]}"
  location            = var.location
  resource_group_name = var.sql_resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.terraform_remote_state.network.outputs.sql_subnet_dc_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "dc" {
  count               = length(var.dc_names)
  name                = var.dc_names[count.index]
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  size                = var.vm_size

  zone = var.zones[count.index]

  admin_username = var.domain_admin_username
  admin_password = random_password.dc[count.index].result

  network_interface_ids = [
    azurerm_network_interface.dc[count.index].id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-azure-edition"
    version   = "latest"
  }
  patch_mode = "AutomaticByPlatform"
}
