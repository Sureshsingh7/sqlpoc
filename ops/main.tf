locals {
  tags = merge(
    {
      "project" = "SQLPOC"
    },
    var.tags
  )
}

data "azurerm_resource_group" "ops" {
  name = var.ops_resource_group_name
}

resource "azurerm_network_interface" "runner" {
  name                = "nic-gh-runner"
  location            = data.azurerm_resource_group.ops.location
  resource_group_name = data.azurerm_resource_group.ops.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.terraform_remote_state.network.outputs.ops_subnet_runner_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "runner" {
  name                = "vm-gh-runner"
  resource_group_name = data.azurerm_resource_group.ops.name
  location            = data.azurerm_resource_group.ops.location
  size                = "Standard_B2ms"

  admin_username = var.vm_admin_username
  network_interface_ids = [
    azurerm_network_interface.runner.id
  ]

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  identity {
    type = "UserAssigned"
    identity_ids = [
      var.terraform_uami_resource_id
    ]
  }
}

# -----------------------------------------------------------------------------
# Windows jumpbox (reachable via Azure Bastion)
# -----------------------------------------------------------------------------

resource "random_password" "jumpbox" {
  count   = var.enable_jumpbox ? 1 : 0
  length  = 32
  special = true
}

resource "azurerm_network_interface" "jumpbox" {
  count               = var.enable_jumpbox ? 1 : 0
  name                = "nic-jumpbox"
  location            = data.azurerm_resource_group.ops.location
  resource_group_name = data.azurerm_resource_group.ops.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.terraform_remote_state.network.outputs.ops_subnet_runner_id
    private_ip_address_allocation = "Dynamic"
  }

  tags = local.tags
}

resource "azurerm_windows_virtual_machine" "jumpbox" {
  count               = var.enable_jumpbox ? 1 : 0
  name                = var.jumpbox_name
  resource_group_name = data.azurerm_resource_group.ops.name
  location            = data.azurerm_resource_group.ops.location
  size                = var.jumpbox_size

  admin_username = var.vm_admin_username
  admin_password = random_password.jumpbox[0].result

  network_interface_ids = [
    azurerm_network_interface.jumpbox[0].id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# Store the jumpbox local admin password in the OPS Key Vault for break-glass.
resource "azurerm_key_vault_secret" "jumpbox_admin_password" {
  count        = var.enable_jumpbox ? 1 : 0
  name         = "${var.jumpbox_name}-local-admin"
  value        = random_password.jumpbox[0].result
  key_vault_id = azurerm_key_vault.ops.id
  content_type = "Jumpbox local admin password (break-glass)"
}

# Enable Azure AD login on Windows so you can sign in via Bastion without needing the local password.
resource "azurerm_virtual_machine_extension" "jumpbox_aad_login" {
  count                      = var.enable_jumpbox ? 1 : 0
  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.jumpbox[0].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_role_assignment" "jumpbox_vm_admin_login" {
  count                = (var.enable_jumpbox && var.manage_role_assignments) ? 1 : 0
  scope                = azurerm_windows_virtual_machine.jumpbox[0].id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = var.suresh_principal_id

  depends_on = [azurerm_virtual_machine_extension.jumpbox_aad_login]
}

resource "azurerm_key_vault" "ops" {
  name                       = "kv-fnz-poc-se"
  location                   = var.location
  resource_group_name        = var.ops_resource_group_name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 30

  access_policy {
    tenant_id = var.tenant_id
    object_id = var.terraform_uami_principal_id

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
    ]
  }

}

resource "azurerm_role_assignment" "kv_tf_secrets_officer" {
  count                = var.manage_role_assignments ? 1 : 0
  scope                = azurerm_key_vault.ops.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.terraform_uami_principal_id
}


resource "azurerm_role_assignment" "kv_suresh_reader" {
  count                = var.manage_role_assignments ? 1 : 0
  scope                = azurerm_key_vault.ops.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.suresh_principal_id
}

# Private DNS Zone for Key Vault
resource "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = data.azurerm_resource_group.ops.name

  tags = local.tags
}

# Link Private DNS Zone for Key Vault to OPS VNet
resource "azurerm_private_dns_zone_virtual_network_link" "kv_ops_vnet" {
  name                  = "link-kv-ops-vnet"
  resource_group_name   = data.azurerm_resource_group.ops.name
  private_dns_zone_name = azurerm_private_dns_zone.kv.name
  virtual_network_id    = data.terraform_remote_state.network.outputs.ops_vnet_id

  tags = local.tags
}

# Private Endpoint for Key Vault
resource "azurerm_private_endpoint" "kv_pep" {
  name                = "pep-kv-fnz-poc"
  location            = data.azurerm_resource_group.ops.location
  resource_group_name = data.azurerm_resource_group.ops.name
  subnet_id           = data.terraform_remote_state.network.outputs.pep_subnet_id

  private_service_connection {
    name                           = "psc-kv-fnz-poc"
    private_connection_resource_id = azurerm_key_vault.ops.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  tags = local.tags

  private_dns_zone_group {
    name                 = "kv-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
}

