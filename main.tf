
module "network" {
  source   = "./network"
  location = var.location
  ops_resource_group_name = var.ops_resource_group_name
  sql_resource_group_name = var.sql_resource_group_name
  # other inputs...
}

module "ops" {
  source = "./ops"

  location                    = var.location
  ops_resource_group_name      = var.ops_resource_group_name

  ops_subnet_runner_id         = module.network.ops_subnet_runner_id

  github_repo_url              = var.github_repo_url
  github_runner_token          = var.github_runner_token
  vm_admin_username            = var.vm_admin_username
  ssh_public_key               = var.ssh_public_key
}