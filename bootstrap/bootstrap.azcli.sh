
#!/usr/bin/env bash
set -euo pipefail

# ===========
# Config
# ===========
LOCATION="${LOCATION:-centralus}"

# Terraform state backend (shared-ish)
BOOTSTRAP_RG="${BOOTSTRAP_RG:-rg-fnz-poc-tfstate}"
TFSTATE_CONTAINER="${TFSTATE_CONTAINER:-tfstate}"
TFSTATE_KEY="${TFSTATE_KEY:-fnz-poc.tfstate}"

# Workload resources (your PoC resources live here)
WORKLOAD_RG="${WORKLOAD_RG:-rg-fnz-poc-workload}"

# User Assigned Managed Identity (for future pipeline/agent usage)
UAMI_NAME="${UAMI_NAME:-uami-fnz-poc-tf}"

# Where to write the generated env file
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ENV="${OUT_DIR}/output.local.env"

# ===========
# Pre-flight
# ===========
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found in PATH."; exit 1; }

echo "Checking Azure login context..."
SUB_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
TENANT_ID="$(az account show --query tenantId -o tsv 2>/dev/null || true)"

if [[ -z "${SUB_ID}" || -z "${TENANT_ID}" ]]; then
  echo "ERROR: Not logged into Azure CLI. Run: az login"
  exit 1
fi

echo "Subscription: ${SUB_ID}"
echo "Tenant:       ${TENANT_ID}"
echo "Location:     ${LOCATION}"

# Storage account name must be globally unique, 3-24 chars, lowercase letters & digits only.
# Use a short random suffix.
RAND_SUFFIX="$(openssl rand -hex 3 | tr '[:upper:]' '[:lower:]')"
TFSTATE_SA="${TFSTATE_SA:-stfnzpoc${RAND_SUFFIX}}"

echo "TF State SA:  ${TFSTATE_SA}"
echo

# ===========
# 1) Create backend RG + Storage Account + Container
# ===========
echo "Creating/ensuring backend resource group: ${BOOTSTRAP_RG}"
az group create -n "${BOOTSTRAP_RG}" -l "${LOCATION}" 1>/dev/null

echo "Creating storage account (if not exists): ${TFSTATE_SA}"
# If already exists, this will error. We'll check first.
if ! az storage account show -g "${BOOTSTRAP_RG}" -n "${TFSTATE_SA}" >/dev/null 2>&1; then
  az storage account create \
    -g "${BOOTSTRAP_RG}" \
    -n "${TFSTATE_SA}" \
    -l "${LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    1>/dev/null
else
  echo "Storage account already exists: ${TFSTATE_SA}"
fi

echo "Creating/ensuring blob container: ${TFSTATE_CONTAINER} (Entra auth)"
# auth-mode login = uses your az login token, no keys
az storage container create \
  --name "${TFSTATE_CONTAINER}" \
  --account-name "${TFSTATE_SA}" \
  --auth-mode login \
  1>/dev/null

# ===========
# 2) Create workload RG
# ===========
echo "Creating/ensuring workload resource group: ${WORKLOAD_RG}"
az group create -n "${WORKLOAD_RG}" -l "${LOCATION}" 1>/dev/null

# ===========
# 3) Create UAMI
# ===========
echo "Creating/ensuring UAMI: ${UAMI_NAME}"
if ! az identity show -g "${WORKLOAD_RG}" -n "${UAMI_NAME}" >/dev/null 2>&1; then
  az identity create -g "${WORKLOAD_RG}" -n "${UAMI_NAME}" -l "${LOCATION}" 1>/dev/null
else
  echo "UAMI already exists: ${UAMI_NAME}"
fi

UAMI_CLIENT_ID="$(az identity show -g "${WORKLOAD_RG}" -n "${UAMI_NAME}" --query clientId -o tsv)"
UAMI_PRINCIPAL_ID="$(az identity show -g "${WORKLOAD_RG}" -n "${UAMI_NAME}" --query principalId -o tsv)"
UAMI_ID="$(az identity show -g "${WORKLOAD_RG}" -n "${UAMI_NAME}" --query id -o tsv)"

echo "UAMI clientId:    ${UAMI_CLIENT_ID}"
echo "UAMI principalId: ${UAMI_PRINCIPAL_ID}"
echo

# ===========
# 4) RBAC assignments
# ===========
echo "Assigning RBAC: UAMI -> Contributor on workload RG"
WORKLOAD_RG_ID="$(az group show -n "${WORKLOAD_RG}" --query id -o tsv)"

# role assignment is idempotent-ish if we check first
if ! az role assignment list --assignee-object-id "${UAMI_PRINCIPAL_ID}" --scope "${WORKLOAD_RG_ID}" \
  --query "[?roleDefinitionName=='Contributor'] | length(@)" -o tsv | grep -q "^1$"; then
  az role assignment create \
    --assignee-object-id "${UAMI_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "${WORKLOAD_RG_ID}" \
    1>/dev/null
else
  echo "Contributor role already assigned on workload RG."
fi

echo "Assigning RBAC: UAMI -> Storage Blob Data Contributor on tfstate container scope"
# Container scope resource ID
TFSTATE_CONTAINER_SCOPE="/subscriptions/${SUB_ID}/resourceGroups/${BOOTSTRAP_RG}/providers/Microsoft.Storage/storageAccounts/${TFSTATE_SA}/blobServices/default/containers/${TFSTATE_CONTAINER}"

if ! az role assignment list --assignee-object-id "${UAMI_PRINCIPAL_ID}" --scope "${TFSTATE_CONTAINER_SCOPE}" \
  --query "[?roleDefinitionName=='Storage Blob Data Contributor'] | length(@)" -o tsv | grep -q "^1$"; then
  az role assignment create \
    --assignee-object-id "${UAMI_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" \
    --scope "${TFSTATE_CONTAINER_SCOPE}" \
    1>/dev/null
else
  echo "Storage Blob Data Contributor already assigned on tfstate container."
fi

# ===========
# 5) Write bootstrap/output.local.env
# ===========
echo "Writing: ${OUT_ENV}"
cat > "${OUT_ENV}" <<EOF
# Generated by bootstrap.sh - do not commit
export ARM_SUBSCRIPTION_ID="${SUB_ID}"
export ARM_TENANT_ID="${TENANT_ID}"

# Terraform remote state backend
export TFSTATE_RESOURCE_GROUP="${BOOTSTRAP_RG}"
export TFSTATE_STORAGE_ACCOUNT="${TFSTATE_SA}"
export TFSTATE_CONTAINER="${TFSTATE_CONTAINER}"
export TFSTATE_KEY="${TFSTATE_KEY}"

# Workload defaults
export TF_LOCATION="${LOCATION}"
export TF_WORKLOAD_RESOURCE_GROUP="${WORKLOAD_RG}"

# UAMI (for future CI/CD or running Terraform from an Azure-hosted agent)
export TF_UAMI_NAME="${UAMI_NAME}"
export TF_UAMI_ID="${UAMI_ID}"
export TF_UAMI_CLIENT_ID="${UAMI_CLIENT_ID}"
export TF_UAMI_PRINCIPAL_ID="${UAMI_PRINCIPAL_ID}"

# Optional convenience TF_VAR exports (only if your Terraform variables match these names)
# export TF_VAR_location="\${TF_LOCATION}"
# export TF_VAR_workload_rg_name="\${TF_WORKLOAD_RESOURCE_GROUP}"
EOF

echo
echo "Bootstrap complete ✅"
echo "Next:"
echo "  source bootstrap/output.local.env"
echo "  # then terraform init using backend-config (recommended):"
echo "  terraform init -reconfigure \\"
echo "    -backend-config=\"resource_group_name=\${TFSTATE_RESOURCE_GROUP}\" \\"
echo "    -backend-config=\"storage_account_name=\${TFSTATE_STORAGE_ACCOUNT}\" \\"
echo "    -backend-config=\"container_name=\${TFSTATE_CONTAINER}\" \\"
