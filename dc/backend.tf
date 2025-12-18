terraform {
  backend "azurerm" {
    key              = "sqlpoc.dc.tfstate"
    use_azuread_auth = true
  }
}
