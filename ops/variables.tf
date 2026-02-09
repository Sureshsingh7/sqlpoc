variable "subscription_id" {
  type        = string
  description = "Azure Subscription ID for OPS resources"
}

variable "ops_resource_group_name" {
  type        = string
  description = "Resource group where OPS workloads (runner) are deployed"
}

variable "location" {
  type = string
}

variable "vm_admin_username" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "tags" {
  type        = map(string)
  description = "Extra tags"
  default     = {}
}

variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
}

variable "terraform_uami_principal_id" {
  description = "Principal ID of the Managed Identity used by Terraform"
  type        = string
}

variable "terraform_uami_resource_id" {
  description = "Resource ID of the Managed Identity used by Terraform"
  type        = string
}

variable "suresh_principal_id" {
  description = "AAD Object ID of Suresh"
  type        = string
}

variable "enable_jumpbox" {
  description = "Whether to deploy a Windows jumpbox VM in OPS for Bastion access"
  type        = bool
  default     = false
}

variable "jumpbox_name" {
  description = "Name of the Windows jumpbox VM"
  type        = string
  default     = "vm-jumpbox"
}

variable "jumpbox_size" {
  description = "Azure VM size for the jumpbox"
  type        = string
  default     = "Standard_B2ms"
}

variable "manage_role_assignments" {
  description = "Whether Terraform should create Azure RBAC role assignments (requires Microsoft.Authorization/roleAssignments/write)"
  type        = bool
  default     = false
}

variable "install_ssms_sas" {
  type        = string
  description = "SAS token for downloading install_ssms.ps1 from the TFSTATE storage container"
  sensitive   = true
  default     = ""
}

# --- DR Configuration ---

variable "enable_dr" {
  description = "Whether to create DR Key Vault resources"
  type        = bool
  default     = false
}

variable "dr_location" {
  description = "Azure region for DR Key Vault (e.g., swedencentral)"
  type        = string
  default     = ""
}

variable "dr_resource_group_name" {
  description = "Resource group name for DR resources"
  type        = string
  default     = ""
}

variable "kv_private_dns_zone" {
  type        = string
  description = "Private DNS Zone for Key Vault (e.g., privatelink.vaultcore.azure.net)"
  default     = "privatelink.vaultcore.azure.net"
}
