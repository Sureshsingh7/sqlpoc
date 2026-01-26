terraform {
  backend "azurerm" {
    key              = "sqlpoc.ops.tfstate"
    use_azuread_auth = true
    use_msi          = true
  }
}
