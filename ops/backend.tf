terraform {
  backend "azurerm" {
    key              = "sqlpoc.ops.tfstate"
    use_azuread_auth = true
  }
}
