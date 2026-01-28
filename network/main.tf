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
  bastion_name     = "${var.ops_name_prefix}-bastion"

  nat_gateway_pip_name = "${var.ops_name_prefix}-pip-natgw"
  nat_gateway_name     = "${var.ops_name_prefix}-natgw"

  sql_nat_gateway_pip_name = "${var.sql_name_prefix}-pip-natgw"
  sql_nat_gateway_name     = "${var.sql_name_prefix}-natgw"

  nsg_sql1_name   = "${var.sql_name_prefix}-nsg-sql1"
  nsg_sql2_name   = "${var.sql_name_prefix}-nsg-sql2"
  nsg_runner_name = "${var.ops_name_prefix}-nsg-runner"

  nsg_sql1_rules = {
    rdp_from_bastion = {
      name                       = "Allow-RDP-From-Bastion"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefix      = var.subnet_bastion_prefix
      destination_address_prefix = var.sql_subnet_sql1_prefix
    }
    wsfc_heartbeat = {
      name                       = "Allow-WSFC-Heartbeat"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "3343"
      source_address_prefix      = var.sql_subnet_sql2_prefix
      destination_address_prefix = var.sql_subnet_sql1_prefix
    }
    ag_endpoint = {
      name                       = "Allow-AG-Endpoint"
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "5022"
      source_address_prefix      = var.sql_subnet_sql2_prefix
      destination_address_prefix = var.sql_subnet_sql1_prefix
    }
    rpc_smb = {
      name                       = "Allow-RPC-SMB"
      priority                   = 130
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_ranges    = ["135", "445"]
      source_address_prefix      = var.sql_subnet_sql2_prefix
      destination_address_prefix = var.sql_subnet_sql1_prefix
    }
    dnn = {
      name                       = "Allow-DNN"
      priority                   = 140
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "7002"
      source_address_prefix      = var.sql_subnet_sql2_prefix
      destination_address_prefix = var.sql_subnet_sql1_prefix
    }
    rpc_dynamic = {
      name                       = "Allow-RPC-Dynamic"
      priority                   = 150
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "49152-65535"
      source_address_prefix      = var.sql_subnet_sql2_prefix
      destination_address_prefix = var.sql_subnet_sql1_prefix
    }
    outbound_kms = {
      name                       = "Allow-Outbound-KMS"
      priority                   = 100
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "1688"
      source_address_prefix      = var.sql_subnet_sql1_prefix
      destination_address_prefix = "AzureCloud"
    }
    outbound_https = {
      name                       = "Allow-Outbound-HTTPS"
      priority                   = 110
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = var.sql_subnet_sql1_prefix
      destination_address_prefix = "Internet"
    }
  }

  nsg_sql2_rules = {
    rdp_from_bastion = {
      name                       = "Allow-RDP-From-Bastion"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefix      = var.subnet_bastion_prefix
      destination_address_prefix = var.sql_subnet_sql2_prefix
    }
    wsfc_heartbeat = {
      name                       = "Allow-WSFC-Heartbeat"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "3343"
      source_address_prefix      = var.sql_subnet_sql1_prefix
      destination_address_prefix = var.sql_subnet_sql2_prefix
    }
    ag_endpoint = {
      name                       = "Allow-AG-Endpoint"
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "5022"
      source_address_prefix      = var.sql_subnet_sql1_prefix
      destination_address_prefix = var.sql_subnet_sql2_prefix
    }
    rpc_smb = {
      name                       = "Allow-RPC-SMB"
      priority                   = 130
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_ranges    = ["135", "445"]
      source_address_prefix      = var.sql_subnet_sql1_prefix
      destination_address_prefix = var.sql_subnet_sql2_prefix
    }
    dnn = {
      name                       = "Allow-DNN"
      priority                   = 140
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "7002"
      source_address_prefix      = var.sql_subnet_sql1_prefix
      destination_address_prefix = var.sql_subnet_sql2_prefix
    }
    rpc_dynamic = {
      name                       = "Allow-RPC-Dynamic"
      priority                   = 150
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "49152-65535"
      source_address_prefix      = var.sql_subnet_sql1_prefix
      destination_address_prefix = var.sql_subnet_sql2_prefix
    }
    outbound_kms = {
      name                       = "Allow-Outbound-KMS"
      priority                   = 100
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "1688"
      source_address_prefix      = var.sql_subnet_sql2_prefix
      destination_address_prefix = "AzureCloud"
    }
    outbound_https = {
      name                       = "Allow-Outbound-HTTPS"
      priority                   = 110
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = var.sql_subnet_sql2_prefix
      destination_address_prefix = "Internet"
    }
  }

  nsg_runner_rules = {
    ssh_from_bastion = {
      name                       = "Allow-SSH-From-Bastion"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = var.subnet_bastion_prefix
      destination_address_prefix = var.ops_subnet_runner_prefix
    }
    rdp_from_bastion = {
      name                       = "Allow-RDP-From-Bastion"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefix      = var.subnet_bastion_prefix
      destination_address_prefix = var.ops_subnet_runner_prefix
    }
    outbound_https = {
      name                       = "Allow-Outbound-HTTPS"
      priority                   = 100
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = var.ops_subnet_runner_prefix
      destination_address_prefix = "Internet"
    }
  }

  # --- DR Locals ---
  dr_sql_vnet_name = "${var.sql_name_prefix}-dr-vnet"
  
  dr_nsg_sql1_name   = "${var.sql_name_prefix}-dr-nsg-sql1"
  dr_nsg_sql2_name   = "${var.sql_name_prefix}-dr-nsg-sql2"

  dr_snet_sql1_name = "${var.sql_name_prefix}-dr-snet-sql1"
  dr_snet_sql2_name = "${var.sql_name_prefix}-dr-snet-sql2"
  dr_snet_pep_name  = "${var.sql_name_prefix}-dr-snet-pep"

  # DR NSG Rules (mirror Primary but using DR prefixes)
  # Keeping it simple: Allow Bastion to DR as well (via Peering)
  dr_nsg_sql1_rules = {
    rdp_from_bastion = {
      name                       = "Allow-RDP-From-Bastion"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefix      = var.subnet_bastion_prefix # Access from Primary Bastion
      destination_address_prefix = var.dr_sql_subnet_sql1_prefix
    }
    # Allow traffic from Primary to DR (for AG seeding/replication if direct) and DR-to-DR heartbeat
    # For Setup, we generally allow communication between all cluster nodes.
    # Simplified: Allow intra-subnet and cross-region node communication.
    inter_region_sql = {
      name                       = "Allow-Primary-SQL-Inbound"
      priority                   = 105
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = var.sql_vnet_address_space[0] # From Primary VNet
      destination_address_prefix = "*"
    }
    wsfc_heartbeat = {
      name                       = "Allow-WSFC-Heartbeat-DR"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "3343"
      source_address_prefix      = var.dr_sql_subnet_sql2_prefix
      destination_address_prefix = var.dr_sql_subnet_sql1_prefix
    }
  }

  dr_nsg_sql2_rules = {
    rdp_from_bastion = {
      name                       = "Allow-RDP-From-Bastion"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefix      = var.subnet_bastion_prefix
      destination_address_prefix = var.dr_sql_subnet_sql2_prefix
    }
    inter_region_sql = {
      name                       = "Allow-Primary-SQL-Inbound"
      priority                   = 105
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = var.sql_vnet_address_space[0]
      destination_address_prefix = "*"
    }
    wsfc_heartbeat = {
      name                       = "Allow-WSFC-Heartbeat-DR"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "3343"
      source_address_prefix      = var.dr_sql_subnet_sql1_prefix
      destination_address_prefix = var.dr_sql_subnet_sql2_prefix
    }
  }
}

data "azurerm_resource_group" "sql" {
  name = var.sql_resource_group_name
}

data "azurerm_resource_group" "ops" {
  name = var.ops_resource_group_name
}

# -----------------------------------------------------------------------------
# NSGs
# -----------------------------------------------------------------------------
module "nsg_sql1" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "0.5.1"

  name                = local.nsg_sql1_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  security_rules      = local.nsg_sql1_rules
  tags                = local.tags
}

module "nsg_sql2" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "0.5.1"

  name                = local.nsg_sql2_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name
  security_rules      = local.nsg_sql2_rules
  tags                = local.tags
}

module "nsg_runner" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "0.5.1"

  name                = local.nsg_runner_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  security_rules      = local.nsg_runner_rules
  tags                = local.tags
}

# -----------------------------------------------------------------------------
# SQL VNET (workload)
# -----------------------------------------------------------------------------
module "sql_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.17.1"

  parent_id     = data.azurerm_resource_group.sql.id
  name          = local.sql_vnet_name
  location      = var.location
  address_space = var.sql_vnet_address_space
  tags          = local.tags

  subnets = {
    sql1 = {
      name                            = local.sql_snet_sql1_name
      address_prefix                  = var.sql_subnet_sql1_prefix
      default_outbound_access_enabled = false
      network_security_group          = { id = module.nsg_sql1.resource_id }
    }
    sql2 = {
      name                            = local.sql_snet_sql2_name
      address_prefix                  = var.sql_subnet_sql2_prefix
      default_outbound_access_enabled = false
      network_security_group          = { id = module.nsg_sql2.resource_id }
    }
    pep = {
      name                              = local.sql_snet_pep_name
      address_prefix                    = var.sql_subnet_pep_prefix
      default_outbound_access_enabled   = false
      private_endpoint_network_policies = "Enabled"
    }
  }
}

# -----------------------------------------------------------------------------
# OPS VNET (bastion + runner)
# -----------------------------------------------------------------------------
module "ops_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.17.1"

  parent_id     = data.azurerm_resource_group.ops.id
  name          = local.ops_vnet_name
  location      = var.location
  address_space = var.ops_vnet_address_space
  tags          = local.tags

  subnets = {
    runner = {
      name                            = local.ops_snet_runner_name
      address_prefix                  = var.ops_subnet_runner_prefix
      default_outbound_access_enabled = false
      network_security_group          = { id = module.nsg_runner.resource_id }
    }
    bastion = {
      name                            = local.ops_snet_bastion_name
      address_prefix                  = var.subnet_bastion_prefix
      default_outbound_access_enabled = true
    }
  }

  peerings = {
    ops_to_sql = {
      name                                 = "${local.ops_vnet_name}-to-${local.sql_vnet_name}"
      remote_virtual_network_resource_id   = module.sql_vnet.resource_id
      allow_virtual_network_access         = true
      allow_forwarded_traffic              = true
      create_reverse_peering               = true
      reverse_name                         = "${local.sql_vnet_name}-to-${local.ops_vnet_name}"
      reverse_allow_virtual_network_access = true
      reverse_allow_forwarded_traffic      = true
    }
  }
}

# -----------------------------------------------------------------------------
# Bastion (Standard) in OPS VNet
# -----------------------------------------------------------------------------
module "bastion_pip" {
  source  = "Azure/avm-res-network-publicipaddress/azurerm"
  version = "0.2.0"

  name                = local.bastion_pip_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

module "bastion" {
  source  = "Azure/avm-res-network-bastionhost/azurerm"
  version = "0.9.0"

  name      = local.bastion_name
  location  = var.location
  parent_id = data.azurerm_resource_group.ops.id
  sku       = "Standard"

  copy_paste_enabled     = true
  file_copy_enabled      = false
  tunneling_enabled      = false
  ip_connect_enabled     = false
  shareable_link_enabled = false

  ip_configuration = {
    name                 = "bastion-ipcfg"
    subnet_id            = module.ops_vnet.subnets["bastion"].resource_id
    public_ip_address_id = module.bastion_pip.resource_id
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# NAT Gateway for outbound connectivity from subnets
# -----------------------------------------------------------------------------
module "ops_nat_gateway" {
  source  = "Azure/avm-res-network-natgateway/azurerm"
  version = "0.2.1"

  name                = local.nat_gateway_name
  location            = var.location
  resource_group_name = var.ops_resource_group_name

  public_ips = {
    ops_nat = {
      name = local.nat_gateway_pip_name
    }
  }

  subnet_associations = {
    runner = {
      resource_id = module.ops_vnet.subnets["runner"].resource_id
    }
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# NAT Gateway for SQL VNet outbound connectivity
# -----------------------------------------------------------------------------
module "sql_nat_gateway" {
  source  = "Azure/avm-res-network-natgateway/azurerm"
  version = "0.2.1"

  name                = local.sql_nat_gateway_name
  location            = var.location
  resource_group_name = var.sql_resource_group_name

  public_ips = {
    sql_nat = {
      name = local.sql_nat_gateway_pip_name
    }
  }

  subnet_associations = {
    sql1 = {
      resource_id = module.sql_vnet.subnets["sql1"].resource_id
    }
    sql2 = {
      resource_id = module.sql_vnet.subnets["sql2"].resource_id
    }
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# DR Resources (Conditional)
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "dr_sql" {
  count    = var.is_dr_enabled ? 1 : 0
  name     = var.dr_sql_resource_group_name
  location = var.dr_location
  tags     = local.tags
}

module "dr_nsg_sql1" {
  count   = var.is_dr_enabled ? 1 : 0
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "0.5.1"

  name                = local.dr_nsg_sql1_name
  location            = var.dr_location
  resource_group_name = azurerm_resource_group.dr_sql[0].name
  security_rules      = local.dr_nsg_sql1_rules
  tags                = local.tags
}

module "dr_nsg_sql2" {
  count   = var.is_dr_enabled ? 1 : 0
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "0.5.1"

  name                = local.dr_nsg_sql2_name
  location            = var.dr_location
  resource_group_name = azurerm_resource_group.dr_sql[0].name
  security_rules      = local.dr_nsg_sql2_rules
  tags                = local.tags
}

module "dr_sql_vnet" {
  count   = var.is_dr_enabled ? 1 : 0
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.17.1"

  parent_id     = azurerm_resource_group.dr_sql[0].id
  name          = local.dr_sql_vnet_name
  location      = var.dr_location
  address_space = var.dr_sql_vnet_address_space
  tags          = local.tags

  subnets = {
    sql1 = {
      name                            = local.dr_snet_sql1_name
      address_prefix                  = var.dr_sql_subnet_sql1_prefix
      default_outbound_access_enabled = true
      network_security_group          = { id = module.dr_nsg_sql1[0].resource_id }
    }
    sql2 = {
      name                            = local.dr_snet_sql2_name
      address_prefix                  = var.dr_sql_subnet_sql2_prefix
      default_outbound_access_enabled = true
      network_security_group          = { id = module.dr_nsg_sql2[0].resource_id }
    }
    pep = {
      name                              = local.dr_snet_pep_name
      address_prefix                    = var.dr_sql_subnet_pep_prefix
      default_outbound_access_enabled   = false
      private_endpoint_network_policies = "Enabled"
    }
  }

  peerings = {
    # Peering with Primary SQL VNet (Global Peering)
    dr_to_primary = {
      name                                 = "${local.dr_sql_vnet_name}-to-${local.sql_vnet_name}"
      remote_virtual_network_resource_id   = module.sql_vnet.resource_id
      allow_virtual_network_access         = true
      allow_forwarded_traffic              = true
      create_reverse_peering               = true
      reverse_name                         = "${local.sql_vnet_name}-to-${local.dr_sql_vnet_name}"
      reverse_allow_virtual_network_access = true
      reverse_allow_forwarded_traffic      = true
    }
    # Peering with OPS VNet (for Bastion/Mgmt access from Primary region)
    dr_to_ops = {
      name                                 = "${local.dr_sql_vnet_name}-to-${local.ops_vnet_name}"
      remote_virtual_network_resource_id   = module.ops_vnet.resource_id
      allow_virtual_network_access         = true
      allow_forwarded_traffic              = true
      create_reverse_peering               = true
      reverse_name                         = "${local.ops_vnet_name}-to-${local.dr_sql_vnet_name}"
      reverse_allow_virtual_network_access = true
      reverse_allow_forwarded_traffic      = true
    }
  }
}
