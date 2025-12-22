
data "terraform_remote_state" "network" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.network.tfstate"
    use_azuread_auth     = true
  }
}
