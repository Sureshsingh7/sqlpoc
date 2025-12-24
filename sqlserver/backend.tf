terraform {
  backend "azurerm" {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.sqlserver.tfstate"
    use_msi              = true
  }
}
