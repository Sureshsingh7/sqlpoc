# Import blocks for existing SQL VM resources
# These allow Terraform to import resources that were created but timed out before state was written
# After successful import, this file can be deleted

import {
  to = azurerm_mssql_virtual_machine.sql_vm[0]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-se/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sql-primary"
}

import {
  to = azurerm_mssql_virtual_machine.sql_vm[1]
  id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-se/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sql-secondary"
}
