
# SQLPOC — FNZ SQL VM PoC (Network + DC + SQL Server)

This repository contains the Infrastructure-as-Code (Terraform) and bootstrap scripts used to stand up a **SQL VM Proof of Concept** in Azure with:
- A **network baseline** (VNet, 3× /26 subnets, NSGs, Bastion)
- A **Domain Controller** layer (planned in `dc/`)
- A **SQL Server VM** layer (planned in `sqlserver/`)

The repo is split into **separate Terraform root modules** to keep blast-radius small and enable parallel work across collaborators (e.g., Syphax for networking + Suresh for compute).

---

## Repository layout

```text
SQLPOC/
├─ bootstrap/                 # one-time bootstrap scripts (state storage, identities, env outputs)
│  ├─ bootstrap.ps1
│  ├─ bootstrap.azcli.sh
│  ├─ output.local.env.ps1.example   # template only (DO NOT commit real output.local.env.ps1)
│  └─ README.md (optional)
│
├─ network/                   # Terraform root module #1 (remote state: sqlpoc.network.tfstate)
│  ├─ backend.tf              # backend "azurerm" (key pinned here)
│  ├─ providers.tf / versions.tf
│  ├─ variables.tf
│  ├─ network.tf
│  └─ terraform.lock.hcl
│
├─ dc/                        # Terraform root module #2 (remote state: sqlpoc.dc.tfstate) – skeleton
│  ├─ backend.tf
│  ├─ providers.tf / versions.tf
│  └─ (future) main.tf / variables.tf / outputs.tf
│
├─ sqlserver/                 # Terraform root module #3 (remote state: sqlpoc.sqlserver.tfstate) – skeleton
│  ├─ backend.tf
│  ├─ providers.tf / versions.tf
│  └─ (future) main.tf / variables.tf / outputs.tf
│
├─ .github/workflows/         # CI (Terraform fmt + validate) – no backend access
├─ .gitignore                 # must ignore tfstate, .terraform/, tfplan, local env outputs
└─ README.md