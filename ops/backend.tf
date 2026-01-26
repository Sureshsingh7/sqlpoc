terraform {
  backend "azurerm" {
    key = "sqlpoc.ops.tfstate"
  }
}
