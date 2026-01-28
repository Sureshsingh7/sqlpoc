
location = "swedencentral"

sql_resource_group_name = "rg-fnz-poc-sql-se"
sql_name_prefix         = "sqlpoc"
sql_vnet_address_space  = ["10.10.0.0/24"]
sql_subnet_sql1_prefix  = "10.10.0.0/26"
sql_subnet_sql2_prefix  = "10.10.0.64/26"
sql_subnet_pep_prefix   = "10.10.0.128/27"

ops_resource_group_name  = "rg-fnz-poc-ops-se"
ops_name_prefix          = "opspoc"
ops_vnet_address_space   = ["10.20.0.0/24"]
ops_subnet_runner_prefix = "10.20.0.0/26"
subnet_bastion_prefix    = "10.20.0.64/26"

tags = {
  project = "SQLPOC"
}

# Subscription ID where Network resources are deployed
subscription_id = "51595cc9-4191-4785-a757-15e45165d2a4"
# DR Configuration
is_dr_enabled              = true
dr_location                = "swedensouth"
dr_sql_resource_group_name = "rg-fnz-poc-sql-dr-ss"

