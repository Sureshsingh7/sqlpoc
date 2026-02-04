# SQL Server Infrastructure - Environment Management

## State File Strategy

Each deployment variant uses its own Terraform state file to prevent conflicts:

| Environment | tfvars file | Backend config | State file |
|------------|-------------|----------------|------------|
| Non-HA | `env/dev.tfvars` | `env/backend-dev.tfbackend` | `sqlserver-dev.tfstate` |
| HA Only | `env/dev-ha.tfvars` | `env/backend-dev-ha.tfbackend` | `sqlserver-dev-ha.tfstate` |
| HA + DR | `env/dev-ha-dr.tfvars` | `env/backend-dev-ha-dr.tfbackend` | `sqlserver-dev-ha-dr.tfstate` |

## GitHub Actions (Recommended)

The GitHub Actions workflow automatically handles backend configuration based on the deployment preset:

1. Go to: **Actions** → **terraform-sql-iaas** → **Run workflow**
2. Select **deployment_preset**:
   - `dev` - Non-HA deployment
   - `dev-ha` - HA deployment (2 VMs)
   - `dev-ha-dr` - HA + DR deployment (4 VMs)
3. Click **Run workflow**

The workflow will:
- Automatically load the correct backend config file
- Set the state key to `sqlserver-{preset}.tfstate`
- Apply the matching tfvars file

**No manual state management needed!**

## Local Development (CLI)

For local testing, use the helper script to switch environments safely:

**Option 1: Use the helper script (Recommended)**
```powershell
.\switch-env.ps1 -Environment dev-ha
.\switch-env.ps1 -Environment dev-ha-dr
```

**Option 2: Manual init**
```powershell
# For HA deployment
terraform init -reconfigure `
  -backend-config="env/backend-dev-ha.tfbackend" `
  -backend-config="key=sqlserver-dev-ha.tfstate"
terraform plan -var-file="env/dev-ha.tfvars" -var="use_msi=false"

# For HA+DR deployment
terraform init -reconfigure `
  -backend-config="env/backend-dev-ha-dr.tfbackend" `
  -backend-config="key=sqlserver-dev-ha-dr.tfstate"
terraform plan -var-file="env/dev-ha-dr.tfvars" -var="use_msi=false"
```

## State File Isolation

**Why separate state files?**
- HA and HA+DR are different infrastructure topologies
- Prevents accidental destruction when switching tfvars files
- Each state file tracks its own resource lifecycle
- Clear separation of concerns

**Important:** 
- **GitHub Actions**: Automatically handles state isolation per deployment preset
- **Local CLI**: Always run `terraform init -reconfigure` when switching environments!

## How It Works

1. **Backend Config Files** - Store common configuration (storage account, container, resource group)
2. **Dynamic State Key** - State filename is set based on environment: `sqlserver-{env}.tfstate`
3. **Workflow Integration** - GitHub Actions reads `deployment_preset` input and applies correct backend config

## Current Deployment Status

- **HA (dev-ha)**: Being recreated (accidentally destroyed during testing)
- **HA+DR (dev-ha-dr)**: Ready to deploy with imports

## Migration from Old Setup

If you have an existing deployment with hardcoded `backend.tf`:

1. Identify your current state file key
2. Run the appropriate `switch-env.ps1` script to reconfigure
3. Verify state with `terraform state list`

The backend.tf now uses partial configuration - all values come from backend config files
