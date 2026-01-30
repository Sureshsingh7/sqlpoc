
# Bootstrap Setup Guide

## Overview

Bootstrap creates the foundational Azure resources needed for Terraform-managed SQL infrastructure:

- **Backend**: Resource Group + Storage Account + tfstate container
- **Resource Groups**: SQL (primary), SQL DR, OPS
- **Identity**: User Assigned Managed Identity (UAMI) for Terraform
- **RBAC**: Contributor role on all resource groups, Storage Blob Data Contributor on tfstate container

## Prerequisites

- Azure CLI installed (`az`)
- PowerShell 7+
- Azure subscription with appropriate permissions

## Step 1: Run Bootstrap

```powershell
cd bootstrap
.\bootstrap.ps1
```

This creates:
- `rg-fnz-poc-tfstate-se` - Terraform state storage
- `rg-fnz-poc-sql-se` - PRIMARY SQL resources
- `rg-fnz-poc-sql-dr-swc` - DR SQL resources (swedencentral)
- `rg-fnz-poc-ops-se` - OPS resources (Key Vault, runner, jumpbox)
- `uami-fnz-poc-tf-se` - Terraform Managed Identity
- `output.local.env.ps1` - Environment variables

## Step 2: Load Environment Context

```powershell
. .\output.local.env.ps1
```

This sets environment variables for Terraform backend configuration.

## Step 3: Deploy Infrastructure in Order

### 3.1 Network (PRIMARY + DR VNets, Peerings, NSGs)

```powershell
cd ..\network
terraform init -reconfigure
terraform plan -out=tfplan
terraform apply tfplan
```

### 3.2 OPS (Key Vaults: PRIMARY + DR, Runner VM, Jumpbox)

**Step 1: Deploy PRIMARY Key Vault**

Via GitHub Actions:
```
Workflow: terraform-ops
Preset: primary
```

Or locally:
```powershell
cd ..\ops
terraform init -reconfigure
terraform plan -out=tfplan
terraform apply tfplan
```

**Step 2: Grant UAMI Access to PRIMARY Key Vault**

```powershell
cd ..\bootstrap
.\grant-keyvault-access.ps1
```

**Step 3: Deploy DR Key Vault (when needed)**

Via GitHub Actions:
```
Workflow: terraform-ops
Preset: primary-dr
```

Or locally:
```powershell
cd ..\ops
terraform plan -var="enable_dr=true" -out=tfplan
terraform apply tfplan
```

**Important:** The `primary-dr` preset uses targeted apply to ONLY deploy DR Key Vault resources. It will not touch the existing PRIMARY Key Vault, avoiding unnecessary updates and RBAC errors.

**Step 4: Grant UAMI Access to DR Key Vault**

```powershell
cd ..\bootstrap
.\grant-keyvault-access.ps1
```

The script automatically detects both PRIMARY and DR Key Vaults and grants access to any that exist.

### 3.3 SQL Server (PRIMARY HA + DR)

```powershell
cd ..\sqlserver

# Deploy PRIMARY HA SQL VMs
terraform init -reconfigure
terraform plan -var-file="env/dev-ha.tfvars" -out=tfplan
terraform apply tfplan

# Deploy DR SQL VMs
terraform plan -var-file="env/dev-ha-dr.tfvars" -out=tfplan
terraform apply tfplan
```

## Environment Variables

Bootstrap guarantees the following environment variables:

**Azure Context:**
- `ARM_SUBSCRIPTION_ID`
- `ARM_TENANT_ID`

**Terraform Backend:**
- `TFSTATE_RESOURCE_GROUP`
- `TFSTATE_STORAGE_ACCOUNT`
- `TFSTATE_CONTAINER`
- `TFSTATE_KEY`

**Platform Defaults:**
- `TF_LOCATION`
- `TF_SQL_RG`
- `TF_SQL_DR_RG`
- `TF_SQL_DR_LOCATION`
- `TF_OPS_RG`

**Identities:**
- `TF_UAMI_NAME`
- `TF_UAMI_CLIENT_ID`
- `TF_UAMI_PRINCIPAL_ID`
- `TF_UAMI_RESOURCE_ID`

## Key Vault Architecture

### PRIMARY Key Vault (`kv-fnz-poc-se`)
- Location: swedencentral
- Resource Group: `rg-fnz-poc-ops-se`
- Secret: `sql-vm-admin-password` (PRIMARY SQL VMs)

### DR Key Vault (`kv-fnz-poc-dr-swc`)
- Location: swedencentral
- Resource Group: `rg-fnz-poc-sql-dr-swc`
- Secret: `dr-sql-vm-admin-password` (DR SQL VMs)

**Critical:** DR and PRIMARY use **separate passwords** stored in **separate Key Vaults** for proper DR isolation.

## Troubleshooting

### Key Vault Access Denied
If sqlserver deployment fails with Key Vault access errors:

**Root Cause:** The Terraform UAMI doesn't have "Key Vault Secrets User" role on the Key Vaults.

**Solution:** Run the grant access script:
```powershell
.\bootstrap\grant-keyvault-access.ps1
```

This grants the UAMI read access to both PRIMARY and DR Key Vaults. The UAMI cannot grant itself this permission (requires User Access Administrator or Owner role).

**Verification:**
```powershell
# Check PRIMARY Key Vault
az role assignment list --scope /subscriptions/.../resourceGroups/rg-fnz-poc-ops-se/providers/Microsoft.KeyVault/vaults/kv-fnz-poc-se

# Check DR Key Vault (if deployed)
az role assignment list --scope /subscriptions/.../resourceGroups/rg-fnz-poc-sql-dr-swc/providers/Microsoft.KeyVault/vaults/kv-fnz-poc-dr-swc
```

### DR Key Vault Not Found
Ensure ops module has been deployed with `enable_dr = true` in `ops/terraform.tfvars`.

### RBAC Delays
Azure RBAC assignments can take 5-10 minutes to propagate. Wait and retry if you see permission errors immediately after bootstrap.

## Next Steps

After bootstrap and infrastructure deployment:
1. Configure SQL Server Always On Availability Groups
2. Set up VNet peering health monitoring
3. Configure Azure Bastion for jumpbox access
4. Deploy application workloads