
Bootstrap guarantees the following environment variables:

- ARM_SUBSCRIPTION_ID
- ARM_TENANT_ID

Terraform backend:
- TFSTATE_RESOURCE_GROUP
- TFSTATE_STORAGE_ACCOUNT
- TFSTATE_CONTAINER
- TFSTATE_KEY

Platform defaults:
- TF_LOCATION
- OPS_RESOURCE_GROUP_NAME

Identities:
- UAMI_CLIENT_ID
- UAMI_PRINCIPAL_ID

How to use?

git clone https://github.com/syguemgh/sqltfpoc
cd sqltfpoc

# Load environment context
.\bootstrap\bootstrap-context.ps1

# Network
cd network
terraform init -reconfigure
terraform plan

# Ops
cd ..\ops
terraform init -reconfigure
terraform plan

# DC
cd ..\dc
terraform init -reconfigure
terraform plan

# SQL
cd ..\sql
terraform init -reconfigure
terraform plan