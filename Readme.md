
# SQLPOC — SQL Server HA & HADR on Azure (IaC)

Terraform + PowerShell automation for deploying SQL Server Always On Availability Groups with optional cross-cluster Distributed Availability Groups (DAG) on Azure VMs. Fully domain-free (workgroup cluster), certificate-authenticated, and ILB-backed.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Folder Structure](#folder-structure)
3. [Environment Variants](#environment-variants)
4. [Deployment Workflow](#deployment-workflow)
   - [Step 1 — Disk Setup](#step-1--disk-setup)
   - [Step 2 — Windows Failover Cluster](#step-2--windows-failover-cluster)
   - [Step 3 — HADR Endpoint & Certificates](#step-3--hadr-endpoint--certificates)
   - [Step 4 — Availability Group](#step-4--availability-group)
   - [Step 5 — Distributed Availability Group (DAG)](#step-5--distributed-availability-group-dag)
5. [VNN Listener & Azure ILB Architecture](#vnn-listener--azure-ilb-architecture)
6. [Certificate Management](#certificate-management)
7. [Environment Management & State Isolation](#environment-management--state-isolation)
8. [Prerequisites](#prerequisites)
9. [Quick Start](#quick-start)
10. [Validation & Troubleshooting](#validation--troubleshooting)
11. [Git Hygiene](#git-hygiene)

---

## Architecture Overview

```
┌─────────────────────── Primary Region (Sweden Central) ──────────────────────┐
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐    │
│   │  Windows Failover Cluster: sqlpoc-ha-cl                            │    │
│   │  Cloud Witness: Azure Storage Account                              │    │
│   │                                                                    │    │
│   │  ┌───────────────────┐     ┌───────────────────┐                   │    │
│   │  │  poc-ha-sql-01    │     │  poc-ha-sql-02    │                   │    │
│   │  │  Subnet 1 / AZ 1 │◄───►│  Subnet 2 / AZ 2 │                   │    │
│   │  │  10.10.0.10       │     │  10.10.0.11       │                   │    │
│   │  └────────┬──────────┘     └────────┬──────────┘                   │    │
│   │           │   AG: poc-ha-AG (Synchronous Commit)                   │    │
│   │           │   Listener: poc-ha-listener:1433                       │    │
│   │           └──────────┬──────────────┘                              │    │
│   └──────────────────────┼──────────────────────────────────────────────┘    │
│                          │                                                   │
│              ┌───────────┴───────────┐                                       │
│              │  Azure Internal LB    │                                       │
│              │  Frontend 1: 10.10.0.6│                                       │
│              │  Frontend 2: 10.10.0.68│                                      │
│              │  Probe: TCP/59999     │                                       │
│              └───────────┬───────────┘                                       │
└──────────────────────────┼───────────────────────────────────────────────────┘
                           │
                  DAG (Async Commit, Automatic Seeding)
                           │
┌──────────────────────────┼───────────────────────────────────────────────────┐
│                          │        DR Region                                  │
│              ┌───────────┴───────────┐                                       │
│              │  Azure Internal LB    │                                       │
│              │  (DR Frontends)       │                                       │
│              └───────────┬───────────┘                                       │
│                          │                                                   │
│   ┌──────────────────────┼──────────────────────────────────────────────┐    │
│   │  Windows Failover Cluster: sqlpoc-ha-dr-cl                         │    │
│   │                                                                    │    │
│   │  ┌───────────────────┐     ┌───────────────────┐                   │    │
│   │  │  poc-ha-dr-sql-01 │     │  poc-ha-dr-sql-02 │                   │    │
│   │  │  DR Subnet 1      │◄───►│  DR Subnet 2      │                   │    │
│   │  └───────────────────┘     └───────────────────┘                   │    │
│   │           AG: poc-ha-dr-AG (Synchronous Commit)                    │    │
│   └────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Workgroup Cluster** (no AD) | Eliminates domain controller dependency; uses local `clusteradmin` accounts |
| **Certificate-based HADR auth** | No AD-DS required for endpoint authentication between replicas |
| **Key Vault certificate exchange** | Certs stored as secrets in Azure Key Vault; nodes upload/download via Managed Identity — no SMB/port 445 required |
| **Manual database seeding** | Primary controls when databases join the AG (backup → copy → restore WITH NORECOVERY) |
| **Azure ILB with Floating IP** | Provides Virtual Network Name (VNN) to clients without DNS updates on failover |
| **Separate state files per variant** | DR can be deployed/destroyed independently without affecting primary HA |
| **Idempotent scripts with sentinels** | Each step writes a sentinel file; re-runs are no-ops unless sentinel is removed |
| **Automatic DAG seeding** | Databases from primary AG automatically replicate to DR AG via DAG |

---

## Folder Structure

```
SQLPOC/
├── bootstrap/           # Bootstrap scripts (state storage, identity prereqs)
├── network/             # VNets, subnets, NSGs, Bastion (state: sqlpoc.network.tfstate)
├── ops/                 # GitHub Runner layer (state: sqlpoc.ops.tfstate)
├── sqlserver/           # SQL VM layer — main deployment entry point
│   ├── env/             # Per-environment .tfvars and .tfbackend files
│   │   ├── dev.tfvars / backend-dev.tfbackend
│   │   ├── dev-ha.tfvars / backend-dev-ha.tfbackend
│   │   └── dev-ha-dr.tfvars / backend-dev-ha-dr.tfbackend
│   ├── main.tf          # Root module calling modules/sql-iaas
│   ├── switch-env.ps1   # Switch local Terraform backend between environments
│   └── ...
├── modules/
│   └── sql-iaas/        # Reusable Terraform module
│       ├── main.tf      # VMs, ILB, DNS, Run Commands (orchestration)
│       ├── variables.tf
│       ├── outputs.tf
│       └── scripts/     # PowerShell scripts executed via Run Commands
│           ├── disk_setup.ps1
│           ├── create_failover_cluster.ps1
│           ├── configure_hadr_endpoints.ps1
│           ├── create_availability_group.ps1
│           └── configure_dag.ps1
├── Validate-Deployment.ps1
├── Validate-DAG-Replication.ps1
├── Test-DAG-BulkReplication.ps1
└── PRE_DEPLOY_CHECKLIST.md
```

---

## Environment Variants

| Variant | Nodes | Cluster | AG | DAG | State File | Use Case |
|---------|-------|---------|----|----|-----------|----------|
| **dev** | 1 VM | No | No | No | `sqlserver-dev.tfstate` | Single-VM testing |
| **dev-ha** | 2 VMs | Yes | Yes | No | `sqlserver-dev-ha.tfstate` | HA within one region |
| **dev-ha-dr** | 2+2 VMs | Yes (×2) | Yes (×2) | Yes | `sqlserver-dev-ha-dr.tfstate` | Full HA + cross-cluster DR |

### dev-ha (HA only)

Deploys a single Windows Failover Cluster with two SQL Server nodes, an Availability Group, and an ILB-backed VNN listener. All replicas use **synchronous commit** with **manual failover**.

```hcl
enable_failover_cluster = true
deploy_primary          = true   # (default)
enable_dr               = false
enable_dag              = false
```

### dev-ha-dr (HA + Disaster Recovery)

Deploys a **second** independent cluster in a DR region, creates its own AG, then links both AGs via a Distributed Availability Group (DAG) with **asynchronous commit** and **automatic seeding**.

> The primary HA must already be deployed (via `dev-ha`). The DR state reads primary outputs via `data.terraform_remote_state.primary_ha`.

```hcl
deploy_primary = false   # Don't re-create primary resources
enable_dr      = true    # Deploy DR VMs + cluster + AG
enable_dag     = true    # Create DAG linking primary ↔ DR
```

---

## Deployment Workflow

All steps are executed automatically by Terraform via `azurerm_virtual_machine_run_command` resources. Each step depends on the previous one and writes a **sentinel file** to ensure idempotency.

```
disk_setup ──► cluster_setup ──► hadr_endpoint_setup ──► ag_setup ──► dag_setup
                                                                      (if enable_dag)
```

### Step 1 — Disk Setup

**Script:** `modules/sql-iaas/scripts/disk_setup.ps1`
**Sentinel:** `C:\Windows\Temp\.disk-setup-completed`

Configures dedicated storage volumes and SQL Server paths:

| Drive | Purpose | SQL Path |
|-------|---------|----------|
| F: | Data | `F:\SQLData` |
| G: | Logs | `G:\SQLLogs` |
| T: | TempDB | `T:\SQLTempDB` |
| S: | Backups | `S:\SQLBackups` (or `C:\SQLBackups`) |

Also:
- Creates the `clusteradmin` local user on every node
- Grants `clusteradmin` full admin privileges
- Creates the `C:\Certificates` directory (local staging for Key Vault–mediated cert exchange; see [Certificate Management](#certificate-management))

> **Post-setup cleanup:** Once all HADR endpoints and DAG are established, `C:\Certificates` can be deleted from every node. SQL Server imports certs into its internal store — the on-disk `.cer` files are never referenced again. If you ever need to re-run a step (by removing its sentinel), the scripts will regenerate and re-exchange the certificates automatically.

---

### Step 2 — Windows Failover Cluster

**Script:** `modules/sql-iaas/scripts/create_failover_cluster.ps1`
**Sentinel:** `C:\Windows\Temp\.cluster-setup-completed`

#### What It Does

1. **Installs Failover Clustering** Windows feature on all nodes
2. **Configures networking:**
   - Updates `/etc/hosts` (hosts file) with all node IPs
   - Enables PSRemoting + WinRM with TrustedHosts
   - Sets `LocalAccountTokenFilterPolicy` for remote admin access
   - Opens ICMPv4 firewall rule
3. **Creates the WSFC cluster:**
   - Runs `New-Cluster` via a Scheduled Task (under `clusteradmin` credentials)
   - Cluster name: e.g. `sqlpoc-ha-cl`
   - Static IPs from each subnet
   - Administrative Access Point: `DNS`
   - No shared storage (`-NoStorage`)
4. **Configures Cloud Witness:**
   - Sets quorum to Azure Storage Account witness
   - Storage account provisioned by Terraform with private endpoint (no public access)
   ```powershell
   Set-ClusterQuorum -CloudWitness `
     -AccountName $WitnessStorageAccountName `
     -AccessKey $witnessKey
   ```

---

### Step 3 — HADR Endpoint & Certificates

**Script:** `modules/sql-iaas/scripts/configure_hadr_endpoints.ps1`
**Sentinel:** `C:\Windows\Temp\.hadr-endpoint-configured`

This is the critical security step that enables encrypted communication between replicas without Active Directory.

#### 3a. Master Key & Certificate Creation

On **every** node:

```sql
-- Create Database Master Key
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong-password>';

-- Create local certificate (valid 5 years)
CREATE CERTIFICATE [<NodeName>_HADR_Cert]
  WITH SUBJECT = '<NodeName> HADR Certificate',
  EXPIRY_DATE = '20310101';
```

#### 3b. Certificate Backup & Upload to Key Vault

Each node backs up its certificate to `C:\Certificates\` and uploads it to Azure Key Vault:

```sql
BACKUP CERTIFICATE [<NodeName>_HADR_Cert]
  TO FILE = 'C:\Certificates\<NodeName>_HADR_Cert.cer';
```

The certificate file is then uploaded as a base64-encoded secret to Key Vault:

```
Key Vault: kv-fnz-poc-se
Secret name: hadr-cert-<nodename>   (lowercase)
Content type: application/x-certificate
```

Certificates are exchanged between nodes via **Azure Key Vault** (using VM Managed Identity for authentication):

```
Node 1                        Key Vault                      Node 2
  │                              │                              │
  ├── Backup local cert          │                              │
  ├── Upload to KV ─────────►    │                              │
  │                              │    ◄──────── Upload to KV ───┤
  │                              │                              ├── Backup local cert
  ├── Download Node 2 cert  ◄────┤                              │
  │                              ├────► Download Node 1 cert ───┤
  ▼                              │                              ▼
  Import Node 2 cert                                  Import Node 1 cert
```

The script polls Key Vault for up to 5 minutes waiting for the partner certificate to become available.

#### 3c. Certificate Import & Login Grant

On each node, import the partner's certificate and grant HADR endpoint access:

```sql
-- Create certificate from partner's backup
CREATE CERTIFICATE [<PartnerNode>_Imported_Cert]
  FROM FILE = 'C:\Certificates\<PartnerNode>_HADR_Cert.cer';

-- Create a login mapped to that certificate
CREATE LOGIN [<PartnerNode>_HADR_Login]
  FROM CERTIFICATE [<PartnerNode>_Imported_Cert];

-- Grant CONNECT on the HADR endpoint
GRANT CONNECT ON ENDPOINT::[HADR_Endpoint] TO [<PartnerNode>_HADR_Login];
```

#### 3d. HADR Endpoint Creation

```sql
CREATE ENDPOINT [HADR_Endpoint]
  STATE = STARTED
  AS TCP (LISTENER_PORT = 5022)
  FOR DATABASE_MIRRORING (
    AUTHENTICATION = CERTIFICATE [<NodeName>_HADR_Cert],
    ENCRYPTION = REQUIRED ALGORITHM AES,
    ROLE = ALL
  );
```

---

### Step 4 — Availability Group

**Script:** `modules/sql-iaas/scripts/create_availability_group.ps1`
**Sentinel:** `C:\Windows\Temp\.ag-setup-completed`

#### 4a. Enable Always On

Enables SQL Server Always On on every node (tries multiple methods for robustness):
1. `Enable-SqlAlwaysOn` (SQLPS module)
2. `Enable-DbaAgHadr` (dbatools)
3. Direct registry modification as fallback

Restarts SQL Server service after enabling.

#### 4b. Create Empty AG

The AG is created **without databases initially** — databases are added via manual seeding:

```sql
CREATE AVAILABILITY GROUP [poc-ha-AG]
WITH (CLUSTER_TYPE = WSFC)
FOR REPLICA ON
  N'poc-ha-sql-01' WITH (
      ENDPOINT_URL   = N'TCP://poc-ha-sql-01.sql.internal:5022',
      FAILOVER_MODE  = MANUAL,
      AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
      SEEDING_MODE   = MANUAL
  ),
  N'poc-ha-sql-02' WITH (
      ENDPOINT_URL   = N'TCP://poc-ha-sql-02.sql.internal:5022',
      FAILOVER_MODE  = MANUAL,
      AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
      SEEDING_MODE   = MANUAL
  );
```

#### 4c. Secondary Joins & Database Seeding

1. Secondary nodes join the AG independently
2. Primary creates a test database (`TestDB`) with FULL recovery model
3. **Manual seeding** (backup → SMB copy → restore):
   ```powershell
   # On Primary:
   BACKUP DATABASE [TestDB] TO DISK = 'C:\SQLBackups\TestDB_AG_Init.bak'
   BACKUP LOG     [TestDB] TO DISK = 'C:\SQLBackups\TestDB_AG_Init.trn'
   # Copy to secondary via \\Secondary\C$\SQLBackups\

   # On Secondary:
   RESTORE DATABASE [TestDB] FROM DISK = '...\TestDB_AG_Init.bak'
     WITH NORECOVERY, REPLACE, ...
   RESTORE LOG [TestDB] FROM DISK = '...\TestDB_AG_Init.trn'
     WITH NORECOVERY

   # On Primary — add DB to AG:
   ALTER AVAILABILITY GROUP [poc-ha-AG] ADD DATABASE [TestDB]
   ```

#### 4d. Create VNN Listener

Multi-subnet listener with ILB frontend IPs:

```sql
ALTER AVAILABILITY GROUP [poc-ha-AG]
ADD LISTENER 'poc-ha-listener' (
    WITH IP (
        ('10.10.0.6',  '255.255.255.255'),
        ('10.10.0.68', '255.255.255.255')
    ),
    PORT = 1433
);
```

Then configures cluster IP resources with the ILB probe port (see [VNN Architecture](#vnn-listener--azure-ilb-architecture) below).

---

### Step 5 — Distributed Availability Group (DAG)

**Script:** `modules/sql-iaas/scripts/configure_dag.ps1`
**Sentinel:** `C:\Windows\Temp\.dag-setup-completed`
**Only runs when:** `enable_dag = true`

#### 5a. Prerequisites

- **Shared Private DNS zone** (`sql.internal`) linked to both primary and DR VNets
- TCP 5022 (HADR) and TCP 1433 (SQL) open between clusters
- Both clusters must have their AGs fully operational
- Both Key Vaults (primary `kv-fnz-poc-se` and DR `kv-fnz-poc-dr-swc`) accessible by VM Managed Identities

#### 5b. Cross-Cluster Certificate Exchange

DR nodes upload their certs to the **DR Key Vault** and download primary node certs from the **primary Key Vault**. Remote primary nodes download DR certs from the DR Key Vault via Managed Identity.

```
DR Node              DR Key Vault          Primary Key Vault         Primary Node
  │                      │                       │                       │
  ├── Upload cert ──────►│                       │◄────── Upload cert ───┤
  │                      │                       │                       │
  ├── Download ◄─────────┼───────────────────────┤                       │
  │   primary certs      │                       │                       │
  │                      │           Download ───┼──────────────────────►│
  │                      │           DR certs     │                       │
  ▼                      │                       │                       ▼
  Import + grant                                                Import + grant
```

#### 5c. DAG Creation

**On the Remote Primary** (primary cluster's primary node):

```sql
CREATE AVAILABILITY GROUP [poc-ha-DAG]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
  N'poc-ha-AG' WITH (
      LISTENER_URL        = N'TCP://poc-ha-sql-01.sql.internal:5022',
      AVAILABILITY_MODE   = ASYNCHRONOUS_COMMIT,
      FAILOVER_MODE       = MANUAL,
      SEEDING_MODE        = AUTOMATIC
  ),
  N'poc-ha-dr-AG' WITH (
      LISTENER_URL        = N'TCP://poc-ha-dr-sql-01.sql.internal:5022',
      AVAILABILITY_MODE   = ASYNCHRONOUS_COMMIT,
      FAILOVER_MODE       = MANUAL,
      SEEDING_MODE        = AUTOMATIC
  );
```

**On the Local DR Primary** (DR cluster's primary node):

```sql
ALTER AVAILABILITY GROUP [poc-ha-DAG]
JOIN
AVAILABILITY GROUP ON
  N'poc-ha-AG' WITH ( ... same params ... ),
  N'poc-ha-dr-AG' WITH ( ... same params ... );
```

#### 5d. Automatic Seeding

After the DAG is joined, the DR primary grants permission and databases replicate automatically:

```sql
ALTER AVAILABILITY GROUP [poc-ha-dr-AG] GRANT CREATE ANY DATABASE;
```

No manual backup/restore needed — DAG automatic seeding handles it.

---

## VNN Listener & Azure ILB Architecture

> See also: `sqlserver/VNN-ARCHITECTURE.md` for the full technical deep-dive.

### Why ILB + Floating IP?

Azure does not support gratuitous ARP, so traditional VNN failover mechanisms do not work. Instead, an **Internal Load Balancer** with **Floating IP** (Direct Server Return) handles routing:

### Load Balancer Configuration

| Component | Details |
|-----------|---------|
| **Frontend IP 1** | Dynamic IP from SQL Subnet 1 (e.g. `10.10.0.6`) |
| **Frontend IP 2** | Dynamic IP from SQL Subnet 2 (e.g. `10.10.0.68`) |
| **Backend Pool** | All SQL VMs (both subnets) |
| **Health Probe** | TCP port **59999**, 5s interval, 2 probes threshold |
| **LB Rules** | Port 1433 (SQL) + Port 5022 (HADR) on both frontends, Floating IP enabled |

### Cluster Resource Configuration

After the listener is created, the cluster IP resources are configured for Azure ILB compatibility:

```powershell
# For each listener IP resource:
Set-ClusterParameter -Multiple @{
    "Address"              = "10.10.0.6"        # ILB frontend IP
    "ProbePort"            = 59999              # Azure health probe port
    "SubnetMask"           = "255.255.255.255"  # /32 — critical for floating IP
    "OverrideAddressMatch" = 1
    "EnableDhcp"           = 0
}
```

### How Failover Works

1. ILB sends TCP probe on port **59999** to all backend VMs
2. Only the **current primary replica** responds to the probe
3. ILB routes SQL traffic (1433) and HADR traffic (5022) to the responding node
4. On failover, the new primary starts responding → ILB re-routes automatically
5. Clients connect to the **listener DNS name** (e.g. `poc-ha-listener.sql.internal`) which resolves to both frontend IPs

### DNS Records (Private DNS Zone: `sql.internal`)

| Record | IPs |
|--------|-----|
| `sqlpoc-ha-cl` (cluster name) | Both frontend IPs |
| `poc-ha-listener` (AG listener) | Both frontend IPs |
| `poc-ha-sql-01` (node 1) | Node 1 private IP |
| `poc-ha-sql-02` (node 2) | Node 2 private IP |

---

## Certificate Management

### Certificate Lifecycle

| Phase | Location | Certificate Name | Purpose |
|-------|----------|-----------------|---------|
| **Creation** | Each node locally | `<NodeName>_HADR_Cert` | Signs HADR endpoint traffic |
| **Backup** | `C:\Certificates\<NodeName>_HADR_Cert.cer` | File export for upload |
| **Upload** | Azure Key Vault secret `hadr-cert-<nodename>` | Base64-encoded cert stored centrally |
| **Download** | Partner node pulls from Key Vault | Retrieved via Managed Identity |
| **Import** | Partner node | `<PartnerNode>_Imported_Cert` | Validates partner identity |
| **Login** | Partner node | `<PartnerNode>_HADR_Login` | SQL login mapped to cert, granted CONNECT |

### Intra-Cluster vs Cross-Cluster Exchange

- **Intra-cluster** (Step 3): Both nodes upload to the **same** Key Vault; each downloads the partner's cert from that vault
- **Cross-cluster for DAG** (Step 5): DR nodes upload to **DR Key Vault**, download from **primary Key Vault** (and vice versa)

### Key Vault Layout

| Key Vault | Secrets | Used By |
|-----------|---------|---------|
| `kv-fnz-poc-se` (primary) | `hadr-cert-poc-ha-sql-01`, `hadr-cert-poc-ha-sql-02`, `sql-vm-admin-password` | Primary cluster + DR nodes (for DAG cert download) |
| `kv-fnz-poc-dr-swc` (DR) | `hadr-cert-poc-ha-dr-sql-01`, `hadr-cert-poc-ha-dr-sql-02`, `dr-sql-vm-admin-password` | DR cluster + Primary nodes (for DAG cert download) |

### Certificate Expiry

Certificates are created with a **5-year expiry**. Plan for rotation before expiry.

---

## Environment Management & State Isolation

### State File Strategy

Each environment variant uses a **separate Terraform state file** in the same Azure Storage Account:

```
stfnzpocdj522c/tfstate/
├── sqlserver-dev.tfstate        # Single VM
├── sqlserver-dev-ha.tfstate     # Primary HA cluster
└── sqlserver-dev-ha-dr.tfstate  # DR cluster + DAG
```

**Why?** The DR infrastructure is fully independent. It can be deployed or destroyed without touching the primary HA. The DR state reads primary outputs via `data.terraform_remote_state.primary_ha`.

### Switching Environments Locally

```powershell
# Switch to HA
.\sqlserver\switch-env.ps1 -Environment dev-ha
terraform plan -var-file="env/dev-ha.tfvars" -var="use_msi=false"

# Switch to DR
.\sqlserver\switch-env.ps1 -Environment dev-ha-dr
terraform plan -var-file="env/dev-ha-dr.tfvars" -var="use_msi=false"
```

### Deployment Order

```
1. Deploy network/     (VNets, subnets, NSGs, Bastion, peerings)
2. Deploy ops/         (GitHub Runner, optional)
3. Deploy sqlserver/   with dev-ha.tfvars     → Primary HA cluster
4. Deploy sqlserver/   with dev-ha-dr.tfvars  → DR cluster + DAG
```

> Step 4 requires Step 3 to be complete. The DR state reads primary cluster outputs.

---

## Prerequisites

- **PowerShell 7**
- **Terraform** (latest)
- **Azure CLI** logged in (`az login`) with correct subscription selected
- **Environment variables** set before `terraform init`:
  - `TFSTATE_RESOURCE_GROUP`
  - `TFSTATE_STORAGE_ACCOUNT`
  - `TFSTATE_CONTAINER`

---

## Quick Start

### Deploy HA Only

```powershell
cd .\sqlserver

# Set backend config
$backend = @(
  "resource_group_name=$env:TFSTATE_RESOURCE_GROUP",
  "storage_account_name=$env:TFSTATE_STORAGE_ACCOUNT",
  "container_name=$env:TFSTATE_CONTAINER"
)

# Initialize with HA backend
terraform init -reconfigure `
  @($backend | ForEach-Object { "-backend-config=$_" }) `
  -backend-config="env/backend-dev-ha.tfbackend"

# Plan and apply
terraform plan -var-file="env/dev-ha.tfvars" -var="use_msi=false" -out tfplan
terraform apply tfplan
```

### Add DR (after HA is deployed)

```powershell
# Re-initialize with DR backend (separate state file)
terraform init -reconfigure `
  @($backend | ForEach-Object { "-backend-config=$_" }) `
  -backend-config="env/backend-dev-ha-dr.tfbackend"

# Plan and apply
terraform plan -var-file="env/dev-ha-dr.tfvars" -var="use_msi=false" -out tfplan
terraform apply tfplan
```

---

## Validation & Troubleshooting

### Post-Deployment Validation

```powershell
# Validate HA deployment (cluster, AG, listener, certs)
.\Validate-Deployment.ps1

# Validate DAG replication (inserts marker row, polls DR)
.\Validate-DAG-Replication.ps1 `
  -PrimaryNode "poc-ha-sql-01.sql.internal" `
  -DRNodes @("poc-ha-dr-sql01.sql.internal","poc-ha-dr-sql02.sql.internal") `
  -PrimarySqlPassword "<password>" `
  -DrSqlPassword "<password>"

# Bulk replication test
.\Test-DAG-BulkReplication.ps1
```

### What Validate-Deployment Checks

- SQL Server service has cluster permissions (`NT SERVICE\MSSQLSERVER`)
- Cluster is visible via `sys.dm_hadr_cluster`
- HADR endpoint exists and is STARTED (`sys.endpoints`)
- Certificates are present (local + partner)
- AG exists with expected number of replicas
- Replicas are in SYNCHRONIZED state
- Listener responds on port 1433

### Forcing a Re-run of a Specific Step

Each step is idempotent via sentinel files. To re-run a step:

```powershell
# 1. Remove the sentinel on the target node(s)
Invoke-Command -ComputerName poc-ha-sql-01 -ScriptBlock {
    Remove-Item C:\Windows\Temp\.ag-setup-completed -Force
}

# 2. Re-apply the specific Terraform resource
terraform apply -auto-approve `
  -var-file="env/dev-ha.tfvars" `
  -target='module.sqlserver.azurerm_virtual_machine_run_command.ag_setup'
```

### Sentinel Files Reference

| Sentinel | Step |
|----------|------|
| `.disk-setup-completed` | Disk/volume configuration |
| `.cluster-setup-completed` | WSFC cluster creation |
| `.hadr-endpoint-configured` | Certificate exchange + endpoint |
| `.ag-setup-completed` | AG creation + listener |
| `.dag-setup-completed` | DAG creation (DR only) |

---

## Git Hygiene

Do **NOT** commit:
- `.terraform/`
- `*.tfstate*`
- `*tfplan*`
- `output.local.env.ps1`, `.env*`, backups

`.gitignore` should cover these.