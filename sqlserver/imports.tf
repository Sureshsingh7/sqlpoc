// One-time recovery imports
//
// If a previous apply created VM extensions outside of Terraform state (or a
// run crashed after Azure created them), Terraform will fail with:
//   "... already exists - to be managed via Terraform this resource needs to be imported"
//
// These imports pull the existing extensions into state so Terraform can update
// and re-run them.

import {
	to = azurerm_virtual_machine_extension.sql_disk_setup[0]
	id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.sql_resource_group_name}/providers/Microsoft.Compute/virtualMachines/${var.sql_vm_names[0]}/extensions/configure-sql-disks"
}

import {
	to = azurerm_virtual_machine_extension.sql_disk_setup[1]
	id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.sql_resource_group_name}/providers/Microsoft.Compute/virtualMachines/${var.sql_vm_names[1]}/extensions/configure-sql-disks"
}
