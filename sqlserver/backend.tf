terraform {
  backend "azurerm" {
    key              = "sqlpoc.sqlserver.tfstate"
    use_azuread_auth = true
  }
}
