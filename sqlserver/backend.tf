terraform {
  backend "azurerm" {
    subscription_id      = "51595cc9-4191-4785-a757-15e45165d2a4"
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.sqlserver.tfstate"
    use_msi              = true
  }
}
