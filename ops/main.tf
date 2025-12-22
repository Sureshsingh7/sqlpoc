
module "network" {
  source                  = "./network"
  location                = var.location
  ops_resource_group_name = var.ops_resource_group_name
  sql_resource_group_name = var.sql_resource_group_name
  # other inputs...
}

resource "azurerm_resource_group" "runner" {
  name     = var.ops_resource_group_name
  location = var.location
}

resource "azurerm_network_interface" "runner" {
  name                = "nic-gh-runner"
  location            = azurerm_resource_group.runner.location
  resource_group_name = azurerm_resource_group.runner.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.ops_subnet_runner_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.runner.id
  }
}

resource "azurerm_linux_virtual_machine" "runner" {
  name                = "vm-gh-runner"
  resource_group_name = azurerm_resource_group.runner.name
  location            = azurerm_resource_group.runner.location
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