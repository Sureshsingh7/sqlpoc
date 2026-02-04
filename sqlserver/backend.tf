
terraform {
  backend "azurerm" {
    key              = "sqlserver-dev-ha.tfstate"
    use_azuread_auth = true
  }
}
