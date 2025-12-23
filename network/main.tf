locals {
  tags = merge(
    {
      "project" = "SQLPOC"
    },
    var.tags
  )

  # Names
  sql_vnet_name = "${var.sql_name_prefix}-vnet"
  ops_vnet_name = "${var.ops_name_prefix}-vnet"

  sql_snet_dc_name   = "${var.sql_name_prefix}-snet-dc"
  sql_snet_sql1_name = "${var.sql_name_prefix}-snet-sql1"
  sql_snet_sql2_name = "${var.sql_name_prefix}-snet-sql2"

  ops_snet_runner_name  = "${var.ops_name_prefix}-snet-runner"
  ops_snet_bastion_name = "AzureBastionSubnet"

  bastion_pip_name = "${var.ops_name_prefix}-pip-bastion"
  bastion_name     = "${var.ops_name_prefix}-bastion"

  nat_gateway_pip_name = "${var.ops_name_prefix}-pip-natgw"
  nat_gateway_name     = "${var.ops_name_prefix}-natgw"

  nsg_dc_name     = "${var.sql_name_prefix}-nsg-dc"
  nsg_sql1_name   = "${var.sql_name_prefix}-nsg-sql1"
  nsg_sql2_name   = "${var.sql_name_prefix}-nsg-sql2"
  nsg_runner_name = "${var.ops_name_prefix}-nsg-runner"
}

# -----------------------------------------------------------------------------
# SQL VNET (workload)
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "sql" {
  name                = local.sql_vnet_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  address_space       = var.sql_vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "sql_dc" {
  name                            = local.sql_snet_dc_name
  resource_group_name             = var.sql_resource_group_name
  virtual_network_name            = azurerm_virtual_network.sql.name
  address_prefixes                = [var.sql_subnet_dc_prefix]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "sql_sql1" {
  name                            = local.sql_snet_sql1_name
  resource_group_name             = var.sql_resource_group_name
  virtual_network_name            = azurerm_virtual_network.sql.name
  address_prefixes                = [var.sql_subnet_sql1_prefix]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "sql_sql2" {
  name                            = local.sql_snet_sql2_name
  resource_group_name             = var.sql_resource_group_name
  virtual_network_name            = azurerm_virtual_network.sql.name
  address_prefixes                = [var.sql_subnet_sql2_prefix]
  default_outbound_access_enabled = false
}

# -----------------------------------------------------------------------------
# OPS VNET (bastion + runner)
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "ops" {
  name                = local.ops_vnet_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  address_space       = var.ops_vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "ops_runner" {
  name                 = local.ops_snet_runner_name
  resource_group_name  = var.ops_resource_group_name
  virtual_network_name = azurerm_virtual_network.ops.name
  address_prefixes     = [var.ops_subnet_runner_prefix]
}

resource "azurerm_subnet" "ops_bastion" {
  name                            = local.ops_snet_bastion_name
  resource_group_name             = var.ops_resource_group_name
  virtual_network_name            = azurerm_virtual_network.ops.name
  address_prefixes                = [var.subnet_bastion_prefix]
  default_outbound_access_enabled = true
}

# -----------------------------------------------------------------------------
# VNet Peering (OPS <-> SQL)
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "ops_to_sql" {
  name                      = "${local.ops_vnet_name}-to-${local.sql_vnet_name}"
  resource_group_name       = var.ops_resource_group_name
  virtual_network_name      = azurerm_virtual_network.ops.name
  remote_virtual_network_id = azurerm_virtual_network.sql.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "sql_to_ops" {
  name                      = "${local.sql_vnet_name}-to-${local.ops_vnet_name}"
  resource_group_name       = var.sql_resource_group_name
  virtual_network_name      = azurerm_virtual_network.sql.name
  remote_virtual_network_id = azurerm_virtual_network.ops.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# -----------------------------------------------------------------------------
# Bastion (Standard) in OPS VNet
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "bastion" {
  name                = local.bastion_pip_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name

  allocation_method = "Static"
  sku               = "Standard"

  tags = local.tags
}

resource "azurerm_bastion_host" "this" {
  name                = local.bastion_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  sku                 = "Standard"

  # Portal-only UX knobs
  copy_paste_enabled     = true
  file_copy_enabled      = false
  tunneling_enabled      = false
  ip_connect_enabled     = false
  shareable_link_enabled = false

  ip_configuration {
    name                 = "bastion-ipcfg"
    subnet_id            = azurerm_subnet.ops_bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# NAT Gateway for outbound connectivity from subnets
# -----------------------------------------------------------------------------

resource "azurerm_public_ip" "nat" {
  name                = local.nat_gateway_pip_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "ops" {
  name                = local.nat_gateway_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "ops" {
  nat_gateway_id       = azurerm_nat_gateway.ops.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "runner" {
  subnet_id      = azurerm_subnet.ops_runner.id
  nat_gateway_id = azurerm_nat_gateway.ops.id
}

# -----------------------------------------------------------------------------
# NSGs (attach to DC / SQL1 / SQL2 / Runner)
# NOTE: We intentionally do NOT attach an NSG to AzureBastionSubnet here.
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "dc" {
  name                = local.nsg_dc_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  tags                = local.tags
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_network_security_group" "sql1" {
  name                = local.nsg_sql1_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  tags                = local.tags
}

resource "azurerm_network_security_group" "sql2" {
  name                = local.nsg_sql2_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  tags                = local.tags
}

resource "azurerm_network_security_group" "runner" {
  name                = local.nsg_runner_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  tags                = local.tags
}

# RDP from Bastion subnet -> DC and SQL subnets
resource "azurerm_network_security_rule" "rdp_to_dc_from_bastion" {
  name                        = "Allow-RDP-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.subnet_bastion_prefix
  destination_address_prefix  = var.sql_subnet_dc_prefix
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
}

resource "azurerm_network_security_rule" "rdp_to_sql1_from_bastion" {
  name                        = "Allow-RDP-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.subnet_bastion_prefix
  destination_address_prefix  = var.sql_subnet_sql1_prefix
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.sql1.name
}

resource "azurerm_network_security_rule" "rdp_to_sql2_from_bastion" {
  name                        = "Allow-RDP-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.subnet_bastion_prefix
  destination_address_prefix  = var.sql_subnet_sql2_prefix
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.sql2.name
}

# SSH from Bastion subnet -> Runner subnet (Linux runner)
resource "azurerm_network_security_rule" "ssh_to_runner_from_bastion" {
  name                        = "Allow-SSH-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.subnet_bastion_prefix
  destination_address_prefix  = var.ops_subnet_runner_prefix
  resource_group_name         = var.ops_resource_group_name
  network_security_group_name = azurerm_network_security_group.runner.name
}

# (Optional) Outbound 443 for runner
resource "azurerm_network_security_rule" "runner_outbound_https" {
  name                        = "Allow-Outbound-HTTPS"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.ops_subnet_runner_prefix
  destination_address_prefix  = "Internet"
  resource_group_name         = var.ops_resource_group_name
  network_security_group_name = azurerm_network_security_group.runner.name
}

# DC NSG rules for AD traffic
resource "azurerm_network_security_rule" "dc_inbound_ad" {
  name              = "Allow-AD-Inbound"
  priority          = 110
  direction         = "Inbound"
  access            = "Allow"
  protocol          = "*"
  source_port_range = "*"
  destination_port_ranges = [
    "53",         # DNS
    "88",         # Kerberos
    "135",        # RPC
    "389",        # LDAP
    "445",        # SMB
    "464",        # Kerberos pw change
    "636",        # LDAPS
    "3268",       # Global Catalog
    "3269",       # GC SSL
    "9389",       # ADWS
    "49152-65535" # RPC dynamic
  ]
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
}

resource "azurerm_network_security_rule" "dc_outbound_internal" {
  name                        = "Allow-Internal-Outbound"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
}

# Associate NSGs to subnets
resource "azurerm_subnet_network_security_group_association" "dc" {
  subnet_id                 = azurerm_subnet.sql_dc.id
  network_security_group_id = azurerm_network_security_group.dc.id
}

resource "azurerm_subnet_network_security_group_association" "sql1" {
  subnet_id                 = azurerm_subnet.sql_sql1.id
  network_security_group_id = azurerm_network_security_group.sql1.id
}

resource "azurerm_subnet_network_security_group_association" "sql2" {
  subnet_id                 = azurerm_subnet.sql_sql2.id
  network_security_group_id = azurerm_network_security_group.sql2.id
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.ops_runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}