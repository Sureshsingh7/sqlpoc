
data "azurerm_resource_group" "ops" {
  name = var.ops_resource_group_name
}

resource "azurerm_network_interface" "runner" {
  name                = "nic-gh-runner"
  location            = data.azurerm_resource_group.ops.location
  resource_group_name = data.azurerm_resource_group.ops.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.terraform_remote_state.network.outputs.ops_subnet_runner_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "runner" {
  name                = "vm-gh-runner"
  resource_group_name = data.azurerm_resource_group.ops.name
  location            = data.azurerm_resource_group.ops.location
  size                = "Standard_B2ms"

  admin_username = var.vm_admin_username
  network_interface_ids = [
    azurerm_network_interface.runner.id
  ]

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(
    templatefile("${path.module}/runner-cloudinit.yaml", {
      github_repo_url     = var.github_repo_url
      github_runner_token = var.github_runner_token
      vm_admin_username   = var.vm_admin_username
    })
  )
}