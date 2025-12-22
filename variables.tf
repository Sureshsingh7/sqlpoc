
variable "location" {
  description = "Azure region"
  type        = string
}

variable "ops_resource_group_name" {
  description = "Resource group for operational resources (runner, bastion, etc.)"
  type        = string
}

variable "sql_resource_group_name" {
  description = "Resource group for SQL resources (DC, SQL VM)"
  type = string
}

variable "github_repo_url" {
  description = "GitHub repository URL"
  type        = string
}

variable "github_runner_token" {
  description = "Registration token for GitHub Actions runner"
  type        = string
  sensitive   = true
}

variable "vm_admin_username" {
  description = "Admin username for runner VM"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for Bastion access"
  type        = string
}
