terraform {
  backend "azurerm" {
    key              = "sqlpoc.network.tfstate"
    use_azuread_auth = true
    use_msi          = false
  }
}
