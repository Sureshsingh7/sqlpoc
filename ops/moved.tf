moved {
  from = azurerm_key_vault.ops
  to   = module.ops_kv.azurerm_key_vault.this
}

moved {
  from = azurerm_private_endpoint.kv_pep
  to   = module.ops_kv.azurerm_private_endpoint.this["kv_pep"]
}

moved {
  from = azurerm_network_interface.runner
  to   = module.runner_vm.azurerm_network_interface.virtualmachine_network_interfaces["runner_nic"]
}

# The AVM module logic for VM resource naming might vary, but usually it's this.
# If the previous state had it at root, we move it here.
moved {
  from = azurerm_linux_virtual_machine.runner
  to   = module.runner_vm.azurerm_linux_virtual_machine.this[0]
}

moved {
  from = azurerm_network_interface.jumpbox[0]
  to   = module.jumpbox_vm[0].azurerm_network_interface.virtualmachine_network_interfaces["jumpbox_nic"]
}

moved {
  from = azurerm_windows_virtual_machine.jumpbox[0]
  to   = module.jumpbox_vm[0].azurerm_windows_virtual_machine.this[0]
}

# Extension moves (best effort, extensions are volatile anyway)
moved {
  from = azurerm_virtual_machine_extension.jumpbox_aad_login[0]
  to   = module.jumpbox_vm[0].module.extension["aad_login"].azurerm_virtual_machine_extension.this
}
