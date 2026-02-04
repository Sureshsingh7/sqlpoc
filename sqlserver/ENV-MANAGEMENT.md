# SQL Server Infrastructure - Environment Management

## State File Strategy

Each deployment variant uses its own Terraform state file to prevent conflicts:

| Environment | tfvars file | Backend config | State file |
|------------|-------------|----------------|------------|
| Non-HA | `env/dev.tfvars` | `env/backend-dev.tfbackend` | `sqlserver-dev.tfstate` |
| HA Only | `env/dev-ha.tfvars` | `env/backend-dev-ha.tfbackend` | `sqlserver-dev-ha.tfstate` |
| HA + DR | `env/dev-ha-dr.tfvars` | `env/backend-dev-ha-dr.tfbackend` | `sqlserver-dev-ha-dr.tfstate` |

## Switching Between Environments

**Option 1: Use the helper script (Recommended)**
```powershell
.\switch-env.ps1 -Environment dev-ha
.\switch-env.ps1 -Environment dev-ha-dr
```

**Option 2: Manual init**
```powershell
# For HA deployment
terraform init -reconfigure -backend-config="env/backend-dev-ha.tfbackend"
terraform plan -var-file="env/dev-ha.tfvars" -var="use_msi=false"

# For HA+DR deployment
terraform init -reconfigure -backend-config="env/backend-dev-ha-dr.tfbackend"
terraform plan -var-file="env/dev-ha-dr.tfvars" -var="use_msi=false"
```

## State File Isolation

**Why separate state files?**
- HA and HA+DR are different infrastructure topologies
- Prevents accidental destruction when switching tfvars files
- Each state file tracks its own resource lifecycle
- Clear separation of concerns

**Important:** Always run `terraform init -reconfigure` with the correct backend config before running plan/apply when switching environments!

## Current Deployment Status

- **HA (dev-ha)**: Being recreated (accidentally destroyed)
- **HA+DR (dev-ha-dr)**: Ready to deploy with imports

## Recovery Steps for HA

Since HA was accidentally destroyed, you have two options:

1. **Let it complete recreation** - The infrastructure will be rebuilt identically
2. **Import from DR state** - If you want to avoid downtime, the current resources can be imported

Check the current apply status and let it complete, or cancel and reimport if needed.
