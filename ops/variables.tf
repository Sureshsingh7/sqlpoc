
variable "ops_resource_group_name" {
  type        = string
  description = "Resource group where OPS workloads (runner) are deployed"
}

variable "location" {
  type = string
}

variable "ops_subnet_runner_id" {
  type        = string
  description = "Runner subnet ID from network module"
}

variable "github_repo_url" {
  type = string
}

variable "github_runner_token" {
  type      = string
  sensitive = true
}

variable "vm_admin_username" {
  type = string
}

variable "ssh_public_key" {
  type = string
}