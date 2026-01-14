terraform {
  backend "azurerm" {
    key              = "sqlpoc.sqlserver-mirror.tfstate"
    use_azuread_auth = true
    use_msi          = true
  }
}