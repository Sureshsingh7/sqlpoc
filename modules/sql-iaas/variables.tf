variable "resource_group_name" {
  description = "Specifies the resource group where the SQL IaaS resources are deployed. Decided by ADF."
  type        = string
}

variable "location" {
  description = "Azure Region."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for naming all resources to ensure uniqueness and alignment with FNZ naming conventions."
  type        = string
}

variable "is_ha" {
  description = "Determines whether the deployment is High Availability: false -> single-VM dev/test, true -> multi-VMs Always On AG"
  type        = bool
  default     = false
}

variable "is_dr" {
  description = "Indicates if the module is being deployed in the DR region."
  type        = bool
  default     = false
}

variable "vm_sku" {
  description = "Defines virtual machine size/SKU for SQL nodes."
  type        = string
}

variable "subnet_ids" {
  description = "List of Subnet IDs for SQL VMs. First one is used for single-subnet design."
  type        = list(string)
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID for private endpoints (witness storage, etc.). If not provided, uses first subnet from subnet_ids."
  type        = string
  default     = ""
}

variable "availability_zones" {
  description = "For HA deployments: zones to be used. Typically inferred from is_ha. But can be overwritten if the desired SKUs are not available in all zones."
  type        = list(number)
  default     = [1, 2, 3]
}

variable "dr_primary_nodes" {
  description = "List of SQL nodes in primary region to allow DAG creation during DR deployment. Required when is_dr = true"
  type        = list(string)
  default     = []
}

# --- Distributed Availability Group (DAG) ---

variable "enable_dag" {
  description = "Enable Distributed Availability Group linking this cluster's AG to a primary AG. Only used with is_dr = true."
  type        = bool
  default     = false
}

variable "dag_name" {
  description = "Name of the Distributed Availability Group (e.g. 'poc-ha-DAG')"
  type        = string
  default     = ""
}

variable "primary_ag_name" {
  description = "Name of the primary Availability Group to link via DAG (e.g. 'poc-ha-AG')"
  type        = string
  default     = ""
}

variable "primary_ag_listener_ip" {
  description = "ILB frontend IP of the primary AG listener (used as LISTENER_URL for DAG)"
  type        = string
  default     = ""
}

variable "primary_ag_primary_replica" {
  description = "Hostname of the primary AG's primary replica (for remote SQL management during DAG setup)"
  type        = string
  default     = ""
}

variable "primary_ag_node_ips" {
  description = "Map of primary AG node hostnames to their private IPs (for hosts file + cert exchange during DAG setup)"
  type        = map(string)
  default     = {}
}

variable "primary_sql_admin_password" {
  description = "SQL admin password for the primary cluster (for remote SQL connections during DAG setup)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sql_admin_username" {
  description = "Local Administrator username for the SQL VMs."
  type        = string
  default     = "sqladmin"
}

variable "sql_vm_admin_password" {
  description = "Password for the Local Administrator."
  type        = string
  sensitive   = true
}

variable "cluster_local_admin_username" {
  description = "Username for the cluster local admin account used for WSFC."
  type        = string
  default     = "clusteradmin"
}

variable "image_publisher" {
  type    = string
  default = "MicrosoftSQLServer"
}

variable "image_offer" {
  type    = string
  default = "sql2025-ws2025"
}

variable "image_sku" {
  type    = string
  default = "enterprise-gen2"
}

variable "image_version" {
  type    = string
  default = "latest"
}

variable "tags" {
  description = "Map of tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "data_disk_size_gb" {
  type    = number
  default = 256
}

variable "data_disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "log_disk_size_gb" {
  type    = number
  default = 128
}

variable "log_disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "tempdb_disk_size_gb" {
  type    = number
  default = 128
}

variable "tempdb_disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "failover_cluster_name" {
  description = "Name of the Failover Cluster."
  type        = string
  default     = "sql-cluster"
}

variable "vnet_id" {
  description = "VNet ID for Private DNS linking."
  type        = string
}

variable "dns_zone_name" {
  description = "Private DNS Zone name for the cluster (e.g. sql.fnz.local)."
  type        = string
  default     = "sql.internal"
}

variable "dns_zone_resource_group_name" {
  description = "Resource group containing the shared Private DNS zone. Zone is created in the network layer and linked to all SQL VNets."
  type        = string
}

variable "user_assigned_identity_ids" {
  description = "List of User Assigned Identity IDs to assign to the VMs."
  type        = list(string)
  default     = []
}

variable "sql_vm_user_assigned_identity_client_id" {
  description = "Client ID of the user-assigned managed identity for Azure authentication"
  type        = string
  default     = ""
}

variable "witness_storage_security_control_tag" {
  description = "Value for the SecurityControl tag on witness storage account to bypass org policy that disables key access."
  type        = string
  default     = "ignore"
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault used to store/retrieve HADR certificates."
  type        = string
  default     = ""
}

variable "remote_key_vault_name" {
  description = "Name of the remote (primary) Key Vault for cross-cluster DAG cert exchange. Only needed when enable_dag = true."
  type        = string
  default     = ""
}

