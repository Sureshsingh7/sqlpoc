
# SQLPOC

Terraform + bootstrap scripts for FNZ SQL VM PoC.

## Folders
- `bootstrap/` : bootstrap scripts (creates prereqs like state storage/identity depending on your setup)
- `network/` : VNets (SQL&Ops) + subnets + NSGs + Bastion (state key: `sqlpoc.network.tfstate`)
- `ops/` : GitHub Runner layer (state key: `sqlpoc.ops.tfstate`)
- `dc/` : Domain Controller layer (state key: `sqlpoc.dc.tfstate`)
- `sqlserver/` : SQL VM layer (state key: `sqlpoc.sqlserver.tfstate`)

## Prereqs
- PowerShell 7
- Terraform
- Azure CLI logged in (`az login`) + correct subscription selected

## Git hygiene (important)
Do NOT commit:
- `.terraform/`
- `*.tfstate*`
- `*tfplan*`
- `output.local.env.ps1`, `.env*`, backups

`.gitignore` should cover these.

## Backend env vars (expected)
Set these in your shell before running `terraform init`:
- `TFSTATE_RESOURCE_GROUP`
- `TFSTATE_STORAGE_ACCOUNT`
- `TFSTATE_CONTAINER`

(Each folder pins its own backend `key` in `backend.tf`.)

## Quick start (per module)
Example for `network/` (same pattern for `dc/` and `sqlserver/`):

```powershell
cd .\network

$backend = @(
  "resource_group_name=$env:TFSTATE_RESOURCE_GROUP",
  "storage_account_name=$env:TFSTATE_STORAGE_ACCOUNT",
  "container_name=$env:TFSTATE_CONTAINER"
)

terraform init -reconfigure @($backend | ForEach-Object { "-backend-config=$_" })
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan