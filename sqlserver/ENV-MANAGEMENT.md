# SQL Server Infrastructure - Environment Management

## State File Strategy

Each deployment variant uses its own Terraform state file to prevent conflicts:

| Environment | tfvars file | Backend config | State file | deploy_primary |
|------------|-------------|----------------|------------|----------------|
| Non-HA | `env/dev.tfvars` | `env/backend-dev.tfbackend` | `sqlserver-dev.tfstate` | true (default) |
| HA Only | `env/dev-ha.tfvars` | `env/backend-dev-ha.tfbackend` | `sqlserver-dev-ha.tfstate` | true (default) |
| DR Only | `env/dev-ha-dr.tfvars` | `env/backend-dev-ha-dr.tfbackend` | `sqlserver-dev-ha-dr.tfstate` | false |

**Important**: The DR deployment (`dev-ha-dr`) sets `deploy_primary=false` to only manage DR resources,
preventing conflicts with primary HA resources managed by the `dev-ha` state file. This ensures
that deploying DR will never accidentally destroy or recreate primary production resources.

## GitHub Actions (Recommended)

The GitHub Actions workflow automatically handles backend configuration based on the deployment preset:

1. Go to: **Actions** → **terraform-sql-iaas** → **Run workflow**
2. Select **deployment_preset**:
   - `dev` - Non-HA deployment (single VM)
   - `dev-ha` - Primary HA deployment (2 VMs in primary region)
   - `dev-ha-dr` - DR HA deployment only (2 VMs in DR region)
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
# For HA deployment (Primary only)
terraform init -reconfigure `
  -backend-config="env/backend-dev-ha.tfbackend" `
  -backend-config="key=sqlserver-dev-ha.tfstate"
terraform plan -var-file="env/dev-ha.tfvars" -var="use_msi=false"

# For DR deployment (DR only - does not manage primary)
terraform init -reconfigure `
  -backend-config="env/backend-dev-ha-dr.tfbackend" `
  -backend-config="key=sqlserver-dev-ha-dr.tfstate"
terraform plan -var-file="env/dev-ha-dr.tfvars" -var="use_msi=false"
```

## State File Isolation

**Why separate state files?**
- Primary HA and DR HA are independent infrastructure components
- DR can be deployed/destroyed without affecting primary production resources
- Prevents accidental destruction when switching between environments
- Each state file tracks its own resource lifecycle
- Clear separation of concerns for production safety

**Key Architecture Decision:**
The `deploy_primary` variable controls which module is deployed. When set to `false` in
dev-ha-dr.tfvars, only the DR module (`module.sql_cluster_dr[0]`) is instantiated, keeping
primary HA resources safe from accidental changes.

**Important:**
- **GitHub Actions**: Automatically handles state isolation per deployment preset
- **Local CLI**: Always run `terraform init -reconfigure` when switching environments!

## How It Works

1. **Backend Config Files** - Store common configuration (storage account, container, resource group)
2. **Dynamic State Key** - State filename is set based on environment: `sqlserver-{env}.tfstate`
3. **Workflow Integration** - GitHub Actions reads `deployment_preset` input and applies correct backend config

## Current Deployment Status

- **Primary HA (dev-ha)**: 2 VMs deployed in primary region (rg-fnz-poc-sql-se)
- **DR (dev-ha-dr)**: Ready to deploy/update DR resources in DR region (rg-fnz-poc-sql-dr-swc)

**Note**: Primary and DR are managed by separate state files. Deploying DR will never affect primary infrastructure.

## Migration from Old Setup

If you have an existing deployment with hardcoded `backend.tf`:

1. Identify your current state file key
2. Run the appropriate `switch-env.ps1` script to reconfigure
3. Verify state with `terraform state list`

The backend.tf now uses partial configuration - all values come from backend config files
