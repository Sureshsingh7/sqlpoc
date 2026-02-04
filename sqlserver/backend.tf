
terraform {
  backend "azurerm" {
    # Configure backend during init with:
    # terraform init -backend-config="env/backend-dev-ha.tfbackend"
    # or
    # terraform init -backend-config="env/backend-dev-ha-dr.tfbackend"
    use_azuread_auth = true
  }
}
