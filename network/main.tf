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

  sql_snet_sql1_name = "${var.sql_name_prefix}-snet-sql1"
  sql_snet_sql2_name = "${var.sql_name_prefix}-snet-sql2"
  sql_snet_pep_name  = "${var.sql_name_prefix}-snet-pep"

  ops_snet_runner_name  = "${var.ops_name_prefix}-snet-runner"
  ops_snet_bastion_name = "AzureBastionSubnet"

  bastion_pip_name = "${var.ops_name_prefix}-pip-bastion"
  bastion_name     = "${var.ops_name_prefix}-vnet-bastion"

  nat_gateway_pip_name = "${var.ops_name_prefix}-pip-natgw"
  nat_gateway_name     = "${var.ops_name_prefix}-natgw"

  sql_nat_gateway_pip_name = "${var.sql_name_prefix}-pip-natgw"
  sql_nat_gateway_name     = "${var.sql_name_prefix}-natgw"

  nsg_sql1_name   = "${var.sql_name_prefix}-nsg-sql1"
  nsg_sql2_name   = "${var.sql_name_prefix}-nsg-sql2"
  nsg_runner_name = "${var.ops_name_prefix}-nsg-runner"

  # DR Locals
  dr_sql_vnet_name = "${var.sql_name_prefix}-dr-vnet"

  dr_nsg_sql1_name = "${var.sql_name_prefix}-dr-nsg-sql1"
  dr_nsg_sql2_name = "${var.sql_name_prefix}-dr-nsg-sql2"

  dr_snet_sql1_name = "${var.sql_name_prefix}-dr-snet-sql1"
  dr_snet_sql2_name = "${var.sql_name_prefix}-dr-snet-sql2"
  dr_snet_pep_name  = "${var.sql_name_prefix}-dr-snet-pep"

  dr_nat_gateway_pip_name = "${var.sql_name_prefix}-dr-pip-natgw"
  dr_nat_gateway_name     = "${var.sql_name_prefix}-dr-natgw"
}

data "azurerm_resource_group" "sql" {
  name = var.sql_resource_group_name
}

data "azurerm_resource_group" "ops" {
  name = var.ops_resource_group_name
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

resource "azurerm_subnet" "sql_sql1" {
  name                 = local.sql_snet_sql1_name
  resource_group_name  = var.sql_resource_group_name
  virtual_network_name = azurerm_virtual_network.sql.name
  address_prefixes     = [var.sql_subnet_sql1_prefix]
}

resource "azurerm_subnet" "sql_sql2" {
  name                 = local.sql_snet_sql2_name
  resource_group_name  = var.sql_resource_group_name
  virtual_network_name = azurerm_virtual_network.sql.name
  address_prefixes     = [var.sql_subnet_sql2_prefix]
}

resource "azurerm_subnet" "pep_snet" {
  name                 = local.sql_snet_pep_name
  resource_group_name  = var.sql_resource_group_name
  virtual_network_name = azurerm_virtual_network.sql.name
  address_prefixes     = [var.sql_subnet_pep_prefix]

  private_endpoint_network_policies = "Enabled"
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
  service_endpoints    = ["Microsoft.Storage"]
}

resource "azurerm_subnet" "ops_bastion" {
  name                 = local.ops_snet_bastion_name
  resource_group_name  = var.ops_resource_group_name
  virtual_network_name = azurerm_virtual_network.ops.name
  address_prefixes     = [var.subnet_bastion_prefix]
}

# -----------------------------------------------------------------------------
# Peering (Global)
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "ops_to_sql" {
  name                         = "${local.ops_vnet_name}-to-${local.sql_vnet_name}"
  resource_group_name          = var.ops_resource_group_name
  virtual_network_name         = azurerm_virtual_network.ops.name
  remote_virtual_network_id    = azurerm_virtual_network.sql.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "sql_to_ops" {
  name                         = "${local.sql_vnet_name}-to-${local.ops_vnet_name}"
  resource_group_name          = var.sql_resource_group_name
  virtual_network_name         = azurerm_virtual_network.sql.name
  remote_virtual_network_id    = azurerm_virtual_network.ops.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# -----------------------------------------------------------------------------
# NSGs
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "nsg_sql1" {
  name                = local.nsg_sql1_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  tags                = local.tags
}

resource "azurerm_network_security_group" "nsg_sql2" {
  name                = local.nsg_sql2_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  tags                = local.tags
}

resource "azurerm_network_security_group" "nsg_runner" {
  name                = local.nsg_runner_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  tags                = local.tags
}

# -----------------------------------------------------------------------------
# NSG Associations
# -----------------------------------------------------------------------------
resource "azurerm_subnet_network_security_group_association" "sql1" {
  subnet_id                 = azurerm_subnet.sql_sql1.id
  network_security_group_id = azurerm_network_security_group.nsg_sql1.id
}

resource "azurerm_subnet_network_security_group_association" "sql2" {
  subnet_id                 = azurerm_subnet.sql_sql2.id
  network_security_group_id = azurerm_network_security_group.nsg_sql2.id
}

resource "azurerm_subnet_network_security_group_association" "runner" {
  subnet_id                 = azurerm_subnet.ops_runner.id
  network_security_group_id = azurerm_network_security_group.nsg_runner.id
}

# -----------------------------------------------------------------------------
# NSG Rules (Existing)
# -----------------------------------------------------------------------------

# --- SQL1 ---
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
  network_security_group_name = azurerm_network_security_group.nsg_sql1.name
}

resource "azurerm_network_security_rule" "outbound_https_sql1" {
  name                        = "Allow-Outbound-HTTPS"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.sql_subnet_sql1_prefix
  destination_address_prefix  = "Internet"
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.nsg_sql1.name
}

resource "azurerm_network_security_rule" "outbound_kms_sql1" {
  name                        = "Allow-Outbound-KMS"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1688"
  source_address_prefix       = var.sql_subnet_sql1_prefix
  destination_address_prefix  = "AzureCloud"
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.nsg_sql1.name
}

resource "azurerm_network_security_rule" "wsfc_heartbeat_sql1" {
  name                        = "Allow-WSFC-Heartbeat"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "3343"
  source_address_prefix       = var.sql_subnet_sql2_prefix
  destination_address_prefix  = var.sql_subnet_sql1_prefix
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.nsg_sql1.name
}

# --- SQL2 ---
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
  network_security_group_name = azurerm_network_security_group.nsg_sql2.name
}

resource "azurerm_network_security_rule" "outbound_https_sql2" {
  name                        = "Allow-Outbound-HTTPS"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.sql_subnet_sql2_prefix
  destination_address_prefix  = "Internet"
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.nsg_sql2.name
}

resource "azurerm_network_security_rule" "outbound_kms_sql2" {
  name                        = "Allow-Outbound-KMS"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1688"
  source_address_prefix       = var.sql_subnet_sql2_prefix
  destination_address_prefix  = "AzureCloud"
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.nsg_sql2.name
}

resource "azurerm_network_security_rule" "wsfc_heartbeat_sql2" {
  name                        = "Allow-WSFC-Heartbeat"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "3343"
  source_address_prefix       = var.sql_subnet_sql1_prefix
  destination_address_prefix  = var.sql_subnet_sql2_prefix
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.nsg_sql2.name
}

# --- Runner ---
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
  network_security_group_name = azurerm_network_security_group.nsg_runner.name
}

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
  network_security_group_name = azurerm_network_security_group.nsg_runner.name
}

# --- Cross-Region Rules (Primary) ---
resource "azurerm_network_security_rule" "allow_dr_inbound_sql1" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-DR-Inbound"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.dr_sql_vnet_address_space[0]
  destination_address_prefix  = var.sql_subnet_sql1_prefix
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.nsg_sql1.name
}

resource "azurerm_network_security_rule" "allow_dr_inbound_sql2" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-DR-Inbound"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.dr_sql_vnet_address_space[0]
  destination_address_prefix  = var.sql_subnet_sql2_prefix
  resource_group_name         = var.sql_resource_group_name
  network_security_group_name = azurerm_network_security_group.nsg_sql2.name
}

# -----------------------------------------------------------------------------
# Bastion Host
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "bastion" {
  name                = local.bastion_pip_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "this" {
  name                = local.bastion_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  sku                 = "Standard"

  # Standard features
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
# NAT Gateways
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = local.nat_gateway_pip_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "ops" {
  name                    = local.nat_gateway_name
  location                = var.location
  resource_group_name     = var.ops_resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "ops" {
  nat_gateway_id       = azurerm_nat_gateway.ops.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "runner" {
  subnet_id      = azurerm_subnet.ops_runner.id
  nat_gateway_id = azurerm_nat_gateway.ops.id
}


resource "azurerm_public_ip" "sql_nat" {
  name                = local.sql_nat_gateway_pip_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "sql" {
  name                    = local.sql_nat_gateway_name
  location                = var.location
  resource_group_name     = var.sql_resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "sql" {
  nat_gateway_id       = azurerm_nat_gateway.sql.id
  public_ip_address_id = azurerm_public_ip.sql_nat.id
}

resource "azurerm_subnet_nat_gateway_association" "sql1" {
  subnet_id      = azurerm_subnet.sql_sql1.id
  nat_gateway_id = azurerm_nat_gateway.sql.id
}

resource "azurerm_subnet_nat_gateway_association" "sql2" {
  subnet_id      = azurerm_subnet.sql_sql2.id
  nat_gateway_id = azurerm_nat_gateway.sql.id
}

# -----------------------------------------------------------------------------
# DR Resources (Conditional)
# -----------------------------------------------------------------------------

# Use existing resource group for DR (created by bootstrap)
data "azurerm_resource_group" "dr_sql" {
  count = var.is_dr_enabled ? 1 : 0
  name  = var.dr_sql_resource_group_name
}

resource "azurerm_virtual_network" "dr_sql" {
  count               = var.is_dr_enabled ? 1 : 0
  name                = local.dr_sql_vnet_name
  location            = var.dr_location
  resource_group_name = data.azurerm_resource_group.dr_sql[0].name
  address_space       = var.dr_sql_vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "dr_sql_sql1" {
  count                = var.is_dr_enabled ? 1 : 0
  name                 = local.dr_snet_sql1_name
  resource_group_name  = data.azurerm_resource_group.dr_sql[0].name
  virtual_network_name = azurerm_virtual_network.dr_sql[0].name
  address_prefixes     = [var.dr_sql_subnet_sql1_prefix]
}

resource "azurerm_subnet" "dr_sql_sql2" {
  count                = var.is_dr_enabled ? 1 : 0
  name                 = local.dr_snet_sql2_name
  resource_group_name  = data.azurerm_resource_group.dr_sql[0].name
  virtual_network_name = azurerm_virtual_network.dr_sql[0].name
  address_prefixes     = [var.dr_sql_subnet_sql2_prefix]
}

resource "azurerm_subnet" "dr_sql_pep" {
  count                             = var.is_dr_enabled ? 1 : 0
  name                              = local.dr_snet_pep_name
  resource_group_name               = data.azurerm_resource_group.dr_sql[0].name
  virtual_network_name              = azurerm_virtual_network.dr_sql[0].name
  address_prefixes                  = [var.dr_sql_subnet_pep_prefix]
  private_endpoint_network_policies = "Enabled"
}

# DR NAT Gateway for internet access (dbatools, Windows Updates, etc.)
resource "azurerm_public_ip" "dr_sql_nat" {
  count               = var.is_dr_enabled ? 1 : 0
  name                = local.dr_nat_gateway_pip_name
  location            = var.dr_location
  resource_group_name = data.azurerm_resource_group.dr_sql[0].name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "dr_sql" {
  count               = var.is_dr_enabled ? 1 : 0
  name                = local.dr_nat_gateway_name
  location            = var.dr_location
  resource_group_name = data.azurerm_resource_group.dr_sql[0].name
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "dr_sql" {
  count                = var.is_dr_enabled ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.dr_sql[0].id
  public_ip_address_id = azurerm_public_ip.dr_sql_nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "dr_sql_sql1" {
  count          = var.is_dr_enabled ? 1 : 0
  subnet_id      = azurerm_subnet.dr_sql_sql1[0].id
  nat_gateway_id = azurerm_nat_gateway.dr_sql[0].id
}

resource "azurerm_subnet_nat_gateway_association" "dr_sql_sql2" {
  count          = var.is_dr_enabled ? 1 : 0
  subnet_id      = azurerm_subnet.dr_sql_sql2[0].id
  nat_gateway_id = azurerm_nat_gateway.dr_sql[0].id
}

# DR Peerings
resource "azurerm_virtual_network_peering" "dr_to_primary" {
  count                        = var.is_dr_enabled ? 1 : 0
  name                         = "${local.dr_sql_vnet_name}-to-${local.sql_vnet_name}"
  resource_group_name          = data.azurerm_resource_group.dr_sql[0].name
  virtual_network_name         = azurerm_virtual_network.dr_sql[0].name
  remote_virtual_network_id    = azurerm_virtual_network.sql.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "primary_to_dr" {
  count                        = var.is_dr_enabled ? 1 : 0
  name                         = "${local.sql_vnet_name}-to-${local.dr_sql_vnet_name}"
  resource_group_name          = var.sql_resource_group_name
  virtual_network_name         = azurerm_virtual_network.sql.name
  remote_virtual_network_id    = azurerm_virtual_network.dr_sql[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "dr_to_ops" {
  count                        = var.is_dr_enabled ? 1 : 0
  name                         = "${local.dr_sql_vnet_name}-to-${local.ops_vnet_name}"
  resource_group_name          = data.azurerm_resource_group.dr_sql[0].name
  virtual_network_name         = azurerm_virtual_network.dr_sql[0].name
  remote_virtual_network_id    = azurerm_virtual_network.ops.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "ops_to_dr" {
  count                        = var.is_dr_enabled ? 1 : 0
  name                         = "${local.ops_vnet_name}-to-${local.dr_sql_vnet_name}"
  resource_group_name          = var.ops_resource_group_name
  virtual_network_name         = azurerm_virtual_network.ops.name
  remote_virtual_network_id    = azurerm_virtual_network.dr_sql[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# DR NSGs
resource "azurerm_network_security_group" "dr_nsg_sql1" {
  count               = var.is_dr_enabled ? 1 : 0
  name                = local.dr_nsg_sql1_name
  location            = var.dr_location
  resource_group_name = data.azurerm_resource_group.dr_sql[0].name
  tags                = local.tags
}

resource "azurerm_network_security_group" "dr_nsg_sql2" {
  count               = var.is_dr_enabled ? 1 : 0
  name                = local.dr_nsg_sql2_name
  location            = var.dr_location
  resource_group_name = data.azurerm_resource_group.dr_sql[0].name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "dr_sql1" {
  count                     = var.is_dr_enabled ? 1 : 0
  subnet_id                 = azurerm_subnet.dr_sql_sql1[0].id
  network_security_group_id = azurerm_network_security_group.dr_nsg_sql1[0].id
}

resource "azurerm_subnet_network_security_group_association" "dr_sql2" {
  count                     = var.is_dr_enabled ? 1 : 0
  subnet_id                 = azurerm_subnet.dr_sql_sql2[0].id
  network_security_group_id = azurerm_network_security_group.dr_nsg_sql2[0].id
}

# DR NSG Rules

# --- DR SQL1 Rules ---

resource "azurerm_network_security_rule" "dr_rdp_to_sql1_from_bastion" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-RDP-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.subnet_bastion_prefix
  destination_address_prefix  = var.dr_sql_subnet_sql1_prefix
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql1[0].name
}

resource "azurerm_network_security_rule" "dr_outbound_https_sql1" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-Outbound-HTTPS"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.dr_sql_subnet_sql1_prefix
  destination_address_prefix  = "Internet"
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql1[0].name
}

resource "azurerm_network_security_rule" "dr_outbound_kms_sql1" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-Outbound-KMS"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1688"
  source_address_prefix       = var.dr_sql_subnet_sql1_prefix
  destination_address_prefix  = "AzureCloud"
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql1[0].name
}

resource "azurerm_network_security_rule" "dr_wsfc_heartbeat_sql1" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-WSFC-Heartbeat"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "3343"
  source_address_prefix       = var.dr_sql_subnet_sql2_prefix
  destination_address_prefix  = var.dr_sql_subnet_sql1_prefix
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql1[0].name
}

resource "azurerm_network_security_rule" "dr_primary_inbound_sql1" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-Primary-Inbound"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*" # Allow full communication for mirroring/AG
  source_address_prefix       = var.sql_vnet_address_space[0]
  destination_address_prefix  = var.dr_sql_subnet_sql1_prefix
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql1[0].name
}

# --- DR SQL2 Rules ---

resource "azurerm_network_security_rule" "dr_rdp_to_sql2_from_bastion" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-RDP-From-Bastion"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.subnet_bastion_prefix
  destination_address_prefix  = var.dr_sql_subnet_sql2_prefix
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql2[0].name
}

resource "azurerm_network_security_rule" "dr_outbound_https_sql2" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-Outbound-HTTPS"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.dr_sql_subnet_sql2_prefix
  destination_address_prefix  = "Internet"
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql2[0].name
}

resource "azurerm_network_security_rule" "dr_outbound_kms_sql2" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-Outbound-KMS"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1688"
  source_address_prefix       = var.dr_sql_subnet_sql2_prefix
  destination_address_prefix  = "AzureCloud"
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql2[0].name
}

resource "azurerm_network_security_rule" "dr_wsfc_heartbeat_sql2" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-WSFC-Heartbeat"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "3343"
  source_address_prefix       = var.dr_sql_subnet_sql1_prefix
  destination_address_prefix  = var.dr_sql_subnet_sql2_prefix
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql2[0].name
}

resource "azurerm_network_security_rule" "dr_primary_inbound_sql2" {
  count                       = var.is_dr_enabled ? 1 : 0
  name                        = "Allow-Primary-Inbound"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*" # Allow full communication for mirroring/AG
  source_address_prefix       = var.sql_vnet_address_space[0]
  destination_address_prefix  = var.dr_sql_subnet_sql2_prefix
  resource_group_name         = data.azurerm_resource_group.dr_sql[0].name
  network_security_group_name = azurerm_network_security_group.dr_nsg_sql2[0].name
}


