# Fetch outputs from network module
data "terraform_remote_state" "network" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.network.tfstate"
    use_azuread_auth     = true
    use_msi              = var.use_msi
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
    use_msi              = var.use_msi
  }
}

# TODO: Add DR ops remote state when DR Key Vault is deployed
# For now, DR will use the PRIMARY Key Vault password
# This is not ideal for true DR but acceptable for POC
# data "terraform_remote_state" "ops_dr" {
#   count   = var.enable_dr ? 1 : 0
#   backend = "azurerm"
#   config = {
#     resource_group_name  = "rg-fnz-poc-tfstate-se"
#     storage_account_name = "stfnzpocdj522c"
#     container_name       = "tfstate"
#     key                  = "sqlpoc.ops-dr.tfstate"
#     use_azuread_auth     = true
#     use_msi              = var.use_msi
#   }
# }