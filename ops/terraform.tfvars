location                = "swedencentral"
ops_resource_group_name = "rg-fnz-poc-ops-se"

# VM admin account (used only for Bastion access)
vm_admin_username = "azureuser"

# SSH public key used via Bastion
ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDOfJrLXX3pY9gmFSlgh5v8O/gEo2O8W/HDRdHb7do9OJAf1cvi6pYUYRr9vpcyFaN4rqMVqHpyCDD2pwvPzx751+OafN+MbV46tOPhzzfvCS0fH8dqgaW5kuiDehSkG0BkFqiY0TcQpnhXM3j0uwWf2utZkaFlispe28deWeYCfENs/EzUeo7gPrHXj+RoduvTeeRVZE8p3JazTqSygp1upyGJHYPHXlViVlhVgRLvgcOC+S8Q9wKS6XY9ovLDJGhYnj+DB+eCjFegkPeV65lenW6O/gv9C3McBw2kFcUfkVH0nCfQcp9Ix+DyVEUDLiZAhwK3i0MCLTlR5rkzf9UX0ZlAz3qzoslQxr2efUfN3wET5/Qqp1XO5qLrakTAW6NeZwhMuUgXiK/M4jY/Spradp1fgF7fYTTUDCWI55wTjrsxqTOHz9WzUdsML5yE/RQhJiZGmMm1cAsBFA6Hc5bnlRE8IuwnbeFrp3tVsKHyhFxs20uGoaCNPzQBoiyEc0x7+cXrmdcl5r3JZ+gUOtH4M+KtFGurICqZ/gomvjOKBxgzbs/l78TpjHwbnDuolFVvHN/67ZY4p/YTYLOMc/erBprQks8wRvhaWHOzR7sXKa1l6KismWG+hXA7kgE8aqPdPzyezvKARzZXO+hoHIvqnBRYCVVU+YXsZDEoZ5Owgw== fnz-github-runner"

# Subscription ID where OPS resources are deployed
subscription_id = "51595cc9-4191-4785-a757-15e45165d2a4"

# Tenant ID where resources are deployed
tenant_id = "0ebb4727-213e-46b9-8c4a-6611a5f157b0"

# tags definition
tags = {
  project = "SQLPOC"
}

# Suresh's AAD Object ID
suresh_principal_id = "8c5994da-67b7-4844-b484-026d2e6c3a4a"

# Managed Identity Principal ID used by Terraform
terraform_uami_principal_id = "2680641f-e875-4270-aa05-246cdef65d17"

# Managed Identity Resource ID used by Terraform (assigned to runner VM)
# Get this from bootstrap output: $env:TF_UAMI_RESOURCE_ID
terraform_uami_resource_id = "/subscriptions/51595cc9-4191-4785-a757-15e45165d2a4/resourceGroups/rg-fnz-poc-sql-se/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-fnz-poc-tf-se"

# Windows jumpbox (connect via Azure Bastion)
enable_jumpbox = true
jumpbox_name   = "vm-jumpbox"
jumpbox_size   = "Standard_B2ms"

# The Terraform identity needs 'User Access Administrator' or 'Owner' to create RBAC role assignments.
# Keep this off unless that permission is granted.
manage_role_assignments = false