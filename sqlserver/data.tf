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