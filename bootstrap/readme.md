
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
cd sqltfpoc/bootstrap

terraform init
terraform apply
.\output.local.env.ps1

Then in each folder

# Always first
.\..\bootstrap\output.local.env.ps1

terraform init -reconfigure `
  -backend-config="resource_group_name=$env:TFSTATE_RESOURCE_GROUP" `
  -backend-config="storage_account_name=$env:TFSTATE_STORAGE_ACCOUNT" `
  -backend-config="container_name=$env:TFSTATE_CONTAINER" `
  -backend-config="key=$env:TFSTATE_KEY"
