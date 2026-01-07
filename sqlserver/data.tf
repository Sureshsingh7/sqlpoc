# Fetch outputs from DC module for domain join
data "terraform_remote_state" "dc" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.dc.tfstate"
    use_azuread_auth     = true
    use_msi              = true
  }
}

# Fetch outputs from network module
data "terraform_remote_state" "network" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.network.tfstate"
    use_azuread_auth     = true
    use_msi              = true
  }
}

# Fetch outputs from ops module for Key Vault
data "terraform_remote_state" "ops" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.ops.tfstate"
    use_azuread_auth     = true
    use_msi              = true
  }
}

# Fetch DC1 admin password from Key Vault
data "azurerm_key_vault_secret" "dc_admin_password" {
  name         = "dc-1-local-admin"
  key_vault_id = data.terraform_remote_state.ops.outputs.ops_key_vault_id
}
