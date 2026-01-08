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
  scope                = azurerm_key_vault.ops.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.terraform_uami_principal_id
}


resource "azurerm_role_assignment" "kv_suresh_reader" {
  scope                = azurerm_key_vault.ops.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.suresh_principal_id
}

# Role Assignment for Terraform Identity on TF State Storage Account
resource "azurerm_role_assignment" "tfstate_sa_reader" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/rg-fnz-poc-tfstate-se/providers/Microsoft.Storage/storageAccounts/stfnzpocdj522c"
  role_definition_name = "Reader"
  principal_id         = var.terraform_uami_principal_id
}

# ============================================================================
# Private DNS Zones for Key Vault and Blob Storage
# ============================================================================

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

# ============================================================================
# Private DNS Zone for Blob Storage
# ============================================================================

# Private DNS Zone for Blob Storage
resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = data.azurerm_resource_group.ops.name

  tags = local.tags
}

# Link Private DNS Zone for Blob to OPS VNet
resource "azurerm_private_dns_zone_virtual_network_link" "blob_ops_vnet" {
  name                  = "link-blob-ops-vnet"
  resource_group_name   = data.azurerm_resource_group.ops.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
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

# data "azurerm_storage_account" "tfstate_sa" {
#   name                = "stfnzpocdj522c"
#   resource_group_name = "rg-fnz-poc-tfstate-se"
# }

resource "azurerm_private_endpoint" "storage_account_pep" {
  name                = "pep-state-sa-fnz-poc"
  location            = data.azurerm_resource_group.ops.location
  resource_group_name = data.azurerm_resource_group.ops.name
  subnet_id           = data.terraform_remote_state.network.outputs.pep_subnet_id

  private_service_connection {
    name                           = "psc-blob-fnz-poc"
    private_connection_resource_id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-tfstate-se/providers/Microsoft.Storage/storageAccounts/stfnzpocdj522c"
    is_manual_connection           = false
    subresource_names              = ["Blob"]
  }

  private_dns_zone_group {
    name                 = "blob-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }

  tags = local.tags
}


