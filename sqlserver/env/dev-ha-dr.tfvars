# SQL Server Deployment - Development Environment Variables (HA + DR Variant)

# Azure context
subscription_id         = "51595cc9-4191-4785-a757-15e45165d2a4"
location                = "swedencentral"
sql_resource_group_name = "rg-fnz-poc-sql-se"

# Naming Prefix with 'ha'
sql_name_prefix = "poc-ha"

sql_admin_username = "sqladmin"

# Cluster admin username for WSFC
cluster_local_admin_username = "clusteradmin"

# VM sizing
vm_size = "Standard_D4s_v4"

# Storage configuration
os_disk_type    = "Standard_LRS"
os_disk_size_gb = 128

data_disk_type    = "Standard_LRS"
data_disk_count   = 1
data_disk_size_gb = 256

log_disk_type    = "Standard_LRS"
log_disk_size_gb = 256

tempdb_disk_type    = "Standard_LRS"
tempdb_disk_size_gb = 256

backup_disk_type    = "Standard_LRS"
backup_disk_size_gb = 512

manage_disk_setup_extension = true

# Primary HA
enable_failover_cluster = true
failover_cluster_name   = "sqlpoc-ha-cl"

# DR Configuration - deploy_primary=false because DR has its own state file.
# Primary HA outputs are read via data.terraform_remote_state.primary_ha.
deploy_primary             = false
enable_dr                  = true
enable_dag                 = true
dr_location                = "swedencentral"
dr_sql_resource_group_name = "rg-fnz-poc-sql-dr-swc"

# SQL Server image
image_publisher = "microsoftsqlserver"
image_offer     = "sql2025-ws2025"
image_sku       = "enterprise-gen2"
image_version   = "latest"

# Extensions
enable_sql_extension = true

# Keep the built-in UAMI attached to SQL VMs
sql_vm_user_assigned_identity_ids = [
  "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/Built-In-Identity-RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/Built-In-Identity-swedencentral"
]
sql_vm_user_assigned_identity_client_id = "3b14b485-187d-4f25-819b-71e9dd6945d5"

# Tags
tags = {
  environment = "dev"
  project     = "SQLPOC"
  managed_by  = "terraform"
  tier        = "database"
  ha_enabled  = "true"
}
