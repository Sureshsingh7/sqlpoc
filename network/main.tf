
data "azurerm_resource_group" "sql" {
  name = var.sql_resource_group_name
}

locals {
  tags = merge(
    {
      project = "SQLPOC"
    },
    var.tags
  )
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name_prefix}-vnet-01"
  location            = data.azurerm_resource_group.sql.location
  resource_group_name = data.azurerm_resource_group.sql.name
  address_space       = var.vnet_address_space
  tags                = local.tags
}

# --- Subnets ---
resource "azurerm_subnet" "dc" {
  name                 = "${var.name_prefix}-snet-dc"
  resource_group_name  = data.azurerm_resource_group.sql.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_dc_prefix]
}

resource "azurerm_subnet" "sql" {
  name                 = "${var.name_prefix}-snet-sql"
  resource_group_name  = data.azurerm_resource_group.sql.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_sql_prefix]
}

# Bastion subnet MUST be named exactly AzureBastionSubnet
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = data.azurerm_resource_group.sql.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_bastion_prefix]
}

# --- NSGs ---
resource "azurerm_network_security_group" "dc" {
  name                = "${var.name_prefix}-nsg-dc"
  location            = data.azurerm_resource_group.sql.location
  resource_group_name = data.azurerm_resource_group.sql.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "sql" {
  name                = "${var.name_prefix}-nsg-sql"
  location            = data.azurerm_resource_group.sql.location
  resource_group_name = data.azurerm_resource_group.sql.name
  tags                = local.tags
}

# --- Rules: Bastion -> DC/SQL for RDP ---
resource "azurerm_network_security_rule" "rdp_to_dc_from_bastion" {
  name                        = "Allow-RDP-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.subnet_bastion_prefix
  destination_address_prefix  = var.subnet_dc_prefix
  resource_group_name         = data.azurerm_resource_group.sql.name
  network_security_group_name = azurerm_network_security_group.dc.name
}

resource "azurerm_network_security_rule" "rdp_to_sql_from_bastion" {
  name                        = "Allow-RDP-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.subnet_bastion_prefix
  destination_address_prefix  = var.subnet_sql_prefix
  resource_group_name         = data.azurerm_resource_group.sql.name
  network_security_group_name = azurerm_network_security_group.sql.name
}

# --- Rules: DC <-> SQL (simple PoC) ---
# Keep it broad for PoC; tighten later to AD ports + SQL ports when you wire domain join + AG.
resource "azurerm_network_security_rule" "allow_dc_to_sql" {
  name                        = "Allow-DC-to-SQL"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.subnet_dc_prefix
  destination_address_prefix  = var.subnet_sql_prefix
  resource_group_name         = data.azurerm_resource_group.sql.name
  network_security_group_name = azurerm_network_security_group.sql.name
}

resource "azurerm_network_security_rule" "allow_sql_to_dc" {
  name                        = "Allow-SQL-to-DC"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.subnet_sql_prefix
  destination_address_prefix  = var.subnet_dc_prefix
  resource_group_name         = data.azurerm_resource_group.sql.name
  network_security_group_name = azurerm_network_security_group.dc.name
}

# --- Associate NSGs to subnets (NOT on AzureBastionSubnet for PoC) ---
resource "azurerm_subnet_network_security_group_association" "dc" {
  subnet_id                 = azurerm_subnet.dc.id
  network_security_group_id = azurerm_network_security_group.dc.id
}

resource "azurerm_subnet_network_security_group_association" "sql" {
  subnet_id                 = azurerm_subnet.sql.id
  network_security_group_id = azurerm_network_security_group.sql.id
}

# --- Bastion Standard ---
resource "azurerm_public_ip" "bastion" {
  name                = "${var.name_prefix}-pip-bastion"
  location            = data.azurerm_resource_group.sql.location
  resource_group_name = data.azurerm_resource_group.sql.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "this" {
  name                = "${var.name_prefix}-bastion"
  location            = data.azurerm_resource_group.sql.location
  resource_group_name = data.azurerm_resource_group.sql.name
  sku                 = "Standard"
  tags                = local.tags

  ip_configuration {
    name                 = "bastion-ipcfg"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

output "vnet_id" { value = azurerm_virtual_network.this.id }
output "subnet_dc_id" { value = azurerm_subnet.dc.id }
output "subnet_sql_id" { value = azurerm_subnet.sql.id }
output "subnet_bastion_id" { value = azurerm_subnet.bastion.id }
output "nsg_dc_id" { value = azurerm_network_security_group.dc.id }
output "nsg_sql_id" { value = azurerm_network_security_group.sql.id }
output "bastion_id" { value = azurerm_bastion_host.this.id }