# Fetch outputs from network module
data "terraform_remote_state" "network" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.network.tfstate"
    use_azuread_auth     = true
    use_msi              = var.use_msi
  }
}

# Fetch outputs from ops module for Key Vault
data "terraform_remote_state" "ops" {
  backend = "azurerm"

  config = {
    resource_group_name  = "rg-fnz-poc-tfstate-se"
    storage_account_name = "stfnzpocdj522c"
    container_name       = "tfstate"
    key                  = "sqlpoc.ops.tfstate"
    use_azuread_auth     = true
    use_msi              = var.use_msi
  }
}

# DR Key Vault lookup (pulled from ops remote state outputs)
data "azurerm_key_vault" "dr_ops" {
  count               = var.enable_dr ? 1 : 0
  name                = data.terraform_remote_state.ops.outputs.dr_key_vault_name
  resource_group_name = var.dr_sql_resource_group_name
  
  depends_on = [data.terraform_remote_state.ops]
}

data "azurerm_key_vault_secret" "dr_sql_vm_admin" {
  count        = var.enable_dr ? 1 : 0
  name         = "dr-sql-vm-admin-password"
  key_vault_id = data.azurerm_key_vault.dr_ops[0].id
  
  depends_on = [data.azurerm_key_vault.dr_ops]
}