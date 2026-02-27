# Security Posture — SQL IaaS Module for FNZ

This document describes the network, identity, and platform security requirements
that FNZ must provision in their environment to host the **SQL IaaS module**
(`modules/sql-iaas/`). The module is self-contained — it creates VMs, disks, ILB,
cloud witness storage (with Private Endpoint), AG, and optionally DAG. FNZ provides
the surrounding infrastructure.

---

## Responsibility Boundary

| Component | Owner | Notes |
|---|---|---|
| VNet / Subnets / NSGs | **FNZ** | Managed in FNZ ADO repo |
| Key Vaults | **FNZ** | One per region, PE-only |
| Private DNS Zones | **FNZ** | `privatelink.vaultcore.azure.net`, `privatelink.blob.core.windows.net` |
| VNet Peering (DR) | **FNZ** | Primary ↔ DR VNet |
| **SQL IaaS Module** | **Delivered** | `modules/sql-iaas/` — VMs, disks, ILB, witness storage, AG, DAG |

---

## 1. NSG Rules — Required Port Matrix

Each SQL subnet must have its **own NSG** (not a shared one). All rules should use
explicit subnet CIDRs as source/destination — never `VirtualNetwork` or `*`.

### Intra-Cluster (between SQL subnets in the same region)

| Port | Protocol | Purpose | Direction |
|------|----------|---------|-----------|
| 5022 | TCP | HADR endpoint (AG replication) | Bidirectional |
| 1433 | TCP | SQL Server (AG seeding, internal queries) | Bidirectional |
| 445 | TCP | SMB (PowerShell remote file copy during setup) | Bidirectional |
| 5985–5986 | TCP | WinRM (PowerShell Remoting for cluster/AG config) | Bidirectional |
| 3343 | UDP + TCP | WSFC cluster heartbeat | Bidirectional |

### Cross-Region (Primary ↔ DR — DAG only)

| Port | Protocol | Purpose | Direction |
|------|----------|---------|-----------|
| 5022 | TCP | DAG replication | Bidirectional |
| 1433 | TCP | DAG seeding + remote SQL management | Bidirectional |
| 445 | TCP | SMB (cert exchange during DAG setup) | Bidirectional |

> **Note:** Cross-region rules should be **conditional** — only provisioned when the
> DR cluster exists. Source/destination should be the remote VNet CIDR, not a broad range.

### Load Balancer & Platform

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 59999 | TCP | `AzureLoadBalancer` | ILB health probe for AG listener |
| 443 | TCP | SQL subnets → Internet (or service tags) | IMDS, Key Vault PE resolution, Azure extensions |
| 1688 | TCP | SQL subnets → `AzureCloud` | KMS Windows activation |

### Management Access

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 3389 | TCP | Bastion subnet CIDR | RDP via Azure Bastion |

> **Production hardening:** Port 445 (SMB) is only required during initial cluster
> setup and DAG configuration. Consider removing it post-deployment or using a
> JIT (Just-In-Time) NSG rule that is enabled only during provisioning runs.

---

## 2. Key Vault

One Key Vault per region, used for HADR certificate exchange between SQL nodes.

| Requirement | Detail |
|---|---|
| Public network access | **Disabled** (`public_network_access_enabled = false`) |
| Private Endpoint | In a dedicated PEP subnet with `privatelink.vaultcore.azure.net` DNS zone |
| Soft-delete | **Enabled** (default in Azure since 2021) |
| Purge protection | **Enabled** — certs are used for 5-year HADR endpoint authentication |
| UAMI access | SQL VM's User-Assigned Managed Identity needs **Get** + **Set** secret permissions |
| Cross-region DAG | DR UAMI must read secrets from the primary KV (and vice versa) — grant cross-KV access |

### Secrets Stored

| Secret Name Pattern | Content | Lifecycle |
|---|---|---|
| `hadr-cert-<hostname>` | Base64 public certificate (.cer) | Created during HADR setup, read by partner nodes |
| `sql-vm-admin-password` | SQL admin credential | Set at deployment time |

---

## 3. Cloud Witness Storage Account

The module creates one storage account per cluster for WSFC Cloud Witness.
FNZ must allow this pattern in their Azure Policy:

| Requirement | Detail |
|---|---|
| Public network access | **Disabled** (`public_network_access_enabled = false`) |
| Private Endpoint | Blob PE in dedicated PEP subnet with `privatelink.blob.core.windows.net` DNS zone |
| Shared access key | **Enabled** — WSFC `Set-ClusterQuorum -CloudWitness` requires access keys (no Entra ID support) |
| TLS version | **1.2 minimum** (set by module) |
| `allow_nested_items_to_be_public` | **false** (set by module) |
| Replication | LRS is sufficient (witness is a small blob) |
| Key rotation | Rotate periodically; after rotation, update via `Set-ClusterQuorum -CloudWitness` on each cluster |
| SecurityControl tag | Module tags the account to bypass org policies that block key access — FNZ should whitelist this tag value |

---

## 4. Private Endpoint Subnets

| Requirement | Detail |
|---|---|
| Dedicated PEP subnet | One per region (e.g., `/27`), hosts KV PE + Cloud Witness PE |
| NSG | No NSG on PEP subnet, or NSG with explicit Allow for PE traffic |
| Private DNS Zones | `privatelink.vaultcore.azure.net` and `privatelink.blob.core.windows.net` — linked to all SQL VNets |

---

## 5. VNet Peering (DAG / Cross-Region)

Required only when Distributed Availability Group (DR) is enabled.

| Requirement | Detail |
|---|---|
| Peering | Primary VNet ↔ DR VNet, bidirectional |
| `allow_forwarded_traffic` | **true** |
| Non-overlapping CIDRs | Primary and DR VNets must not overlap |
| DNS resolution | Both VNets must resolve each other's Private DNS zones |

---

## 6. Private DNS Zone — Cluster Names

The module uses Azure Private DNS for cluster name resolution (domain-independent WSFC).

| Requirement | Detail |
|---|---|
| Zone name | Configurable (default: `sql.internal`) |
| Linked VNets | All VNets that need to reach SQL (SQL VNet, OPS VNet, DR VNet) |
| Records | A-records for cluster nodes, created by module |
| `NV Domain` registry key | Set on each SQL VM to match the DNS zone name |

---

## 7. Identity & RBAC

| Requirement | Detail |
|---|---|
| User-Assigned Managed Identity (UAMI) | One per region, assigned to all SQL VMs in that region |
| UAMI → Key Vault | `Key Vault Secrets Officer` role (or access policy: Get + Set secrets) |
| No public IPs | SQL VMs have zero public IPs — management via Bastion or ADO self-hosted runner only |
| SQL authentication | Local SQL admin with password from Key Vault. Module uses SQL auth internally for AG/DAG configuration |
| Cluster admin | Separate local account (`clusteradmin`) created on each node for WSFC operations |

---

## 8. Windows Firewall (Managed by Module)

The module scripts automatically configure Windows Firewall on each SQL VM.
FNZ does **not** need to configure this — listed for awareness/audit:

| Rule | Port | Scope |
|---|---|---|
| `WinRM-HTTPS-In` | 5986 | Partner node IPs only |
| `SQL-Replication` | 5022 | Any (NSG provides outer boundary) |
| `MSSQL` | 1433 | Any (NSG provides outer boundary) |
| `SMB-In` | 445 | Partner node IPs only |
| `ILB-HealthProbe` | 59999 | Any (only Azure LB will send probes) |

All IP-scoped rules are automatically calculated from the cluster node list.

### DNS Registration Noise Suppression

Domain-independent (workgroup) clusters generate Event Log warnings because the
Cluster Name resource attempts AD-style dynamic DNS registration, which always fails
(Azure Private DNS handles name resolution instead). The module automatically
suppresses this noise after cluster creation by configuring the writable parameters
on the "Cluster Name" and AG listener Network Name resources:

**Cluster Name resource:**

| Parameter | Value | Effect |
|---|---|---|
| `RegisterAllProvidersIP` | 0 | Only register the owning node's IP (fewer registration attempts) |
| `HostRecordTTL` | 300 | 5-minute TTL (reduces DNS refresh cycle from 20min to 5min) |

**AG listener Network Name resource(s):**

| Parameter | Value | Effect |
|---|---|---|
| `RegisterAllProvidersIP` | 0 | Only register the owning node's IP |
| `PublishPTRRecords` | 0 | Skip reverse DNS (PTR) registration |
| `HostRecordTTL` | 300 | 5-minute TTL |

> **Note:** `StatusDNS` and `StatusNetBIOS` are read-only status fields on the
> Cluster Name resource — they report registration outcome but cannot be configured.
> The above writable parameters reduce the frequency and scope of registration
> attempts, which minimises the resulting Event Log noise.

This reduces Event IDs 1196, 1069, 1127 (FailoverClustering) that are otherwise
logged repeatedly on every registration retry cycle.

---

## 9. Production Hardening Recommendations

These are not required for the module to function, but are recommended for
production environments:

| Item | Recommendation | Priority |
|---|---|---|
| Encryption at host | Set `encryption_at_host_enabled = true` (requires compatible VM SKU) | **High** |
| Premium disks | Switch from `Standard_LRS` to `Premium_LRS` or `PremiumV2_LRS` for data and log disks | **High** |
| Microsoft Defender for SQL | Enable on all SQL VM resources | **High** |
| NSG Flow Logs | Enable on all SQL subnet NSGs → Log Analytics / Storage Account | **High** |
| Certificate expiry monitoring | HADR certs expire after 5 years — alert via Azure Monitor or runbook | **Medium** |
| DMK password in Key Vault | Store Database Master Key password as a Key Vault secret | **Medium** |
| Azure Policy enforcement | Deny public endpoints on KV + storage, require PE, require TLS 1.2, require disk encryption | **Medium** |
| Accelerated Networking | Already enabled in module — ensure production VM SKUs support it | **Low** |
| Remove SMB post-setup | Delete port 445 NSG rules after initial deployment completes | **Low** |

---

## 10. Module Input Variables (Security-Relevant)

These variables must be provided by FNZ's calling Terraform configuration:

```hcl
# Networking (FNZ-managed)
subnet_ids                 = ["<sql-subnet-1-id>", "<sql-subnet-2-id>"]
private_endpoint_subnet_id = "<pep-subnet-id>"
vnet_id                    = "<sql-vnet-id>"

# DNS
dns_zone_name                = "sql.internal"        # or FNZ's chosen zone
dns_zone_resource_group_name = "<rg-with-dns-zone>"

# Identity
user_assigned_identity_ids              = ["<uami-resource-id>"]
sql_vm_user_assigned_identity_client_id = "<uami-client-id>"

# Key Vault
key_vault_name        = "<primary-kv-name>"
remote_key_vault_name = "<dr-kv-name>"       # only for DAG

# Credentials
sql_vm_admin_password      = "<from-kv-secret>"
primary_sql_admin_password = "<from-kv-secret>"  # only for DAG

# Cloud Witness
witness_storage_security_control_tag = "<policy-bypass-tag-value>"
```

---

*Generated from SQL IaaS POC module — February 2026*
