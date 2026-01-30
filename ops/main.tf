locals {
  tags = merge(
    {
      "project" = "SQLPOC"
    },
    var.tags
  )

  # Storage constants for script download (copied from sqlserver/main.tf)
  tfstate_resource_group_name  = "rg-fnz-poc-tfstate-se"
  tfstate_storage_account_name = "stfnzpocdj522c"
  tfstate_container_name       = "tfstate"

  install_ssms_blob_name = "scripts/install_ssms.ps1"
  install_ssms_blob_url  = "https://${local.tfstate_storage_account_name}.blob.core.windows.net/${local.tfstate_container_name}/${local.install_ssms_blob_name}"
  install_ssms_file_uri  = var.install_ssms_sas != "" ? "${local.install_ssms_blob_url}?${var.install_ssms_sas}" : local.install_ssms_blob_url
  install_ssms_sha       = filesha256("${path.module}/install_ssms.ps1")

  kv_secrets = merge(
    {
      sql_vm_admin = {
        name         = "sql-vm-admin-password"
        content_type = "SQL Server VM local admin password (shared for primary and secondary)"
      }
    },
    var.enable_jumpbox ? {
      jumpbox_admin = {
        name         = "${var.jumpbox_name}-local-admin"
        content_type = "Jumpbox local admin password (break-glass)"
      }
    } : {}
  )

  kv_secrets_value = merge(
    {
      sql_vm_admin = random_password.sql_vm_admin.result
    },
    var.enable_jumpbox ? {
      jumpbox_admin = random_password.jumpbox[0].result
    } : {}
  )

  jumpbox_extensions = {
    aad_login = {
      name                       = "AADLoginForWindows"
      publisher                  = "Microsoft.Azure.ActiveDirectory"
      type                       = "AADLoginForWindows"
      type_handler_version       = "1.0"
      auto_upgrade_minor_version = true
    }
    install_ssms = {
      name                       = "install_ssms"
      publisher                  = "Microsoft.Compute"
      type                       = "CustomScriptExtension"
      type_handler_version       = "1.10"
      auto_upgrade_minor_version = true
      settings = jsonencode({
        timestamp = local.install_ssms_sha
      })
      protected_settings = jsonencode({
        commandToExecute = "powershell.exe -ExecutionPolicy Unrestricted -EncodedCommand ${textencodebase64(file("${path.module}/install_ssms.ps1"), "UTF-16LE")}"
      })
    }
  }

  jumpbox_role_assignments = var.manage_role_assignments ? {
    vm_admin_login = {
      role_definition_id_or_name = "Virtual Machine Administrator Login"
      principal_id               = var.suresh_principal_id
      description                = "Allow AAD admin login via Bastion"
    }
  } : {}
}

data "azurerm_resource_group" "ops" {
  name = var.ops_resource_group_name
}

resource "random_password" "sql_vm_admin" {
  length  = 32
  special = true
}

resource "random_password" "dr_sql_vm_admin" {
  count   = var.enable_dr ? 1 : 0
  length  = 32
  special = true
}

# -----------------------------------------------------------------------------
# Windows jumpbox (reachable via Azure Bastion)
# -----------------------------------------------------------------------------

resource "random_password" "jumpbox" {
  count   = var.enable_jumpbox ? 1 : 0
  length  = 32
  special = true
}

# -----------------------------------------------------------------------------
# Private DNS Zone for Key Vault (PRIMARY)
# -----------------------------------------------------------------------------
module "kv_private_dns" {
  source  = "Azure/avm-res-network-privatednszone/azurerm"
  version = "0.4.4"

  domain_name = "privatelink.vaultcore.azure.net"
  parent_id   = data.azurerm_resource_group.ops.id
  tags        = local.tags

  virtual_network_links = {
    ops_vnet = {
      name               = "link-kv-ops-vnet"
      virtual_network_id = data.terraform_remote_state.network.outputs.ops_vnet_id
      autoregistration   = false
    }
  }
}

# -----------------------------------------------------------------------------
# Private DNS Zone for Key Vault (DR)
# -----------------------------------------------------------------------------
module "kv_private_dns_dr" {
  count   = var.enable_dr ? 1 : 0
  source  = "Azure/avm-res-network-privatednszone/azurerm"
  version = "0.4.4"

  domain_name = "privatelink.vaultcore.azure.net"
  parent_id   = data.azurerm_resource_group.ops.id
  tags        = merge(local.tags, { environment = "dr" })

  virtual_network_links = {
    ops_vnet = {
      name               = "link-kv-dr-ops-vnet"
      virtual_network_id = data.terraform_remote_state.network.outputs.ops_vnet_id
      autoregistration   = false
    }
    dr_vnet = {
      name               = "link-kv-dr-sql-vnet"
      virtual_network_id = data.terraform_remote_state.network.outputs.dr_sql_vnet_id
      autoregistration   = false
    }
  }
}

# -----------------------------------------------------------------------------
# PRIMARY Key Vault (with private endpoint)
# -----------------------------------------------------------------------------
module "ops_kv" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.10.2"

  name                          = "kv-fnz-poc-se"
  location                      = var.location
  resource_group_name           = var.ops_resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  purge_protection_enabled      = true
  soft_delete_retention_days    = 30
  public_network_access_enabled = true
  network_acls                  = null
  tags                          = local.tags

  role_assignments = var.manage_role_assignments ? {
    terraform_secrets_officer = {
      role_definition_id_or_name = "Key Vault Secrets Officer"
      principal_id               = var.terraform_uami_principal_id
    }
    suresh_secrets_user = {
      role_definition_id_or_name = "Key Vault Secrets User"
      principal_id               = var.suresh_principal_id
    }
  } : {}

  secrets       = local.kv_secrets
  secrets_value = local.kv_secrets_value

  private_endpoints = {
    kv_pep = {
      name                          = "pep-kv-fnz-poc"
      subnet_resource_id            = data.terraform_remote_state.network.outputs.pep_subnet_id
      subresource_name              = "vault"
      private_dns_zone_resource_ids = [module.kv_private_dns.resource_id]
    }
  }
}

# -----------------------------------------------------------------------------
# DR Key Vault (with private endpoint in DR region)
# -----------------------------------------------------------------------------
data "azurerm_resource_group" "dr" {
  count = var.enable_dr ? 1 : 0
  name  = var.dr_resource_group_name
}

module "ops_kv_dr" {
  count   = var.enable_dr ? 1 : 0
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.10.2"

  name                          = "kv-fnz-poc-dr-swc"
  location                      = var.dr_location
  resource_group_name           = var.dr_resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  purge_protection_enabled      = true
  soft_delete_retention_days    = 30
  public_network_access_enabled = true
  network_acls                  = null
  tags                          = merge(local.tags, { environment = "dr" })

  role_assignments = var.manage_role_assignments ? {
    terraform_secrets_officer = {
      role_definition_id_or_name = "Key Vault Secrets Officer"
      principal_id               = var.terraform_uami_principal_id
    }
    suresh_secrets_user = {
      role_definition_id_or_name = "Key Vault Secrets User"
      principal_id               = var.suresh_principal_id
    }
  } : {}

  secrets = {
    dr_sql_vm_admin = {
      name         = "dr-sql-vm-admin-password"
      content_type = "DR SQL Server VM local admin password"
    }
  }

  secrets_value = {
    dr_sql_vm_admin = random_password.dr_sql_vm_admin[0].result
  }

  private_endpoints = {
    kv_dr_pep = {
      name                          = "pep-kv-fnz-poc-dr"
      subnet_resource_id            = data.terraform_remote_state.network.outputs.dr_pep_subnet_id
      subresource_name              = "vault"
      private_dns_zone_resource_ids = [module.kv_private_dns_dr[0].resource_id]
    }
  }
}

# -----------------------------------------------------------------------------
# Runner VM (Linux)
# -----------------------------------------------------------------------------
module "runner_vm" {
  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "0.20.0"

  name                = "vm-gh-runner"
  location            = data.azurerm_resource_group.ops.location
  resource_group_name = data.azurerm_resource_group.ops.name
  zone                = null

  os_type  = "Linux"
  sku_size = "Standard_B2ms"

  network_interfaces = {
    runner_nic = {
      name = "nic-gh-runner"
      ip_configurations = {
        primary = {
          name                          = "internal"
          private_ip_address_allocation = "Dynamic"
          private_ip_subnet_resource_id = data.terraform_remote_state.network.outputs.ops_subnet_runner_id
          is_primary_ipconfiguration    = true
        }
      }
    }
  }

  account_credentials = {
    admin_credentials = {
      username                           = var.vm_admin_username
      ssh_keys                           = [var.ssh_public_key]
      generate_admin_password_or_ssh_key = false
    }
    password_authentication_disabled = true
  }

  source_image_reference = {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  managed_identities = {
    user_assigned_resource_ids = [var.terraform_uami_resource_id]
  }

  encryption_at_host_enabled = false

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Jumpbox VM (Windows)
# -----------------------------------------------------------------------------
module "jumpbox_vm" {
  count   = var.enable_jumpbox ? 1 : 0
  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "0.20.0"

  name                = var.jumpbox_name
  location            = data.azurerm_resource_group.ops.location
  resource_group_name = data.azurerm_resource_group.ops.name
  zone                = null

  os_type  = "Windows"
  sku_size = var.jumpbox_size

  network_interfaces = {
    jumpbox_nic = {
      name = "nic-jumpbox"
      ip_configurations = {
        primary = {
          name                          = "internal"
          private_ip_address_allocation = "Dynamic"
          private_ip_subnet_resource_id = data.terraform_remote_state.network.outputs.ops_subnet_runner_id
          is_primary_ipconfiguration    = true
        }
      }
    }
  }

  account_credentials = {
    admin_credentials = {
      username                           = var.vm_admin_username
      password                           = random_password.jumpbox[0].result
      generate_admin_password_or_ssh_key = false
    }
  }

  source_image_reference = {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }

  managed_identities = {
    system_assigned = true
  }

  extensions                 = local.jumpbox_extensions
  role_assignments           = local.jumpbox_role_assignments
  encryption_at_host_enabled = false

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  tags = local.tags
}

