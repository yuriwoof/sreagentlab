#!/usr/bin/env bash
# =============================================================================
# deploy.sh – Deploy the SRE Agent Lab environment
# =============================================================================
set -euo pipefail

# ---------- Configuration ----------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sreagentlab}"
LOCATION="${LOCATION:-eastus2}"
DEPLOYMENT_NAME="sreagentlab-$(date +%Y%m%d-%H%M%S)"
PARAMETERS_FILE="main.parameters.json"

# ---------- Colors ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- Pre-flight checks ------------------------------------------------
info "Checking prerequisites..."

if ! command -v az &>/dev/null; then
  err "Azure CLI (az) is not installed. Install it from https://aka.ms/installazurecli"
  exit 1
fi

ACCOUNT=$(az account show --query '{sub:name, id:id}' -o tsv 2>/dev/null || true)
if [[ -z "$ACCOUNT" ]]; then
  err "Not logged in to Azure. Run 'az login' first."
  exit 1
fi
ok "Logged in: $(az account show --query name -o tsv)"

# ---------- Validate parameters file -----------------------------------------
if [[ ! -f "$PARAMETERS_FILE" ]]; then
  err "Parameters file '$PARAMETERS_FILE' not found."
  err "Copy main.parameters.json and fill in your values."
  exit 1
fi

if grep -q '<YOUR_SSH_PUBLIC_KEY>' "$PARAMETERS_FILE"; then
  err "Replace <YOUR_SSH_PUBLIC_KEY> in $PARAMETERS_FILE with your actual SSH public key."
  exit 1
fi

if grep -q '<YOUR_EMAIL_ADDRESS>' "$PARAMETERS_FILE"; then
  err "Replace <YOUR_EMAIL_ADDRESS> in $PARAMETERS_FILE with your actual email."
  exit 1
fi

# ---------- Register required resource providers -----------------------------
info "Registering resource providers..."
PROVIDERS=(
  "Microsoft.Chaos"
  "Microsoft.Insights"
  "Microsoft.OperationalInsights"
  "Microsoft.Compute"
  "Microsoft.Network"
  "Microsoft.ManagedIdentity"
)

for provider in "${PROVIDERS[@]}"; do
  STATE=$(az provider show -n "$provider" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
  if [[ "$STATE" != "Registered" ]]; then
    info "  Registering $provider ..."
    az provider register -n "$provider" --wait
  fi
done
ok "All resource providers registered."

# ---------- Create resource group ---------------------------------------------
info "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none
ok "Resource group ready."

# ---------- Clean up stale role assignments -----------------------------------
# Previous failed deployments may leave role assignments whose principalId no
# longer matches.  ARM refuses to update them (RoleAssignmentUpdateNotPermitted),
# so we delete any conflicting assignments scoped to the resource group.
info "Cleaning up stale role assignments (if any)..."
STALE_IDS=$(az role assignment list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?principalName==''].id" \
  -o tsv 2>/dev/null || true)
KNOWN_IDS=$(az role assignment list \
  --resource-group "$RESOURCE_GROUP" \
  --role "Reader" \
  --query "[?contains(principalType,'ServicePrincipal')].id" \
  -o tsv 2>/dev/null || true)
ALL_IDS=$(printf '%s\n%s' "$STALE_IDS" "$KNOWN_IDS" | sort -u | grep -v '^$' || true)
if [[ -n "$ALL_IDS" ]]; then
  while IFS= read -r id; do
    info "  Removing role assignment: $id"
    az role assignment delete --ids "$id" --output none 2>/dev/null || true
  done <<< "$ALL_IDS"
  ok "Stale role assignments removed."
else
  ok "No stale role assignments found."
fi

# ---------- Deploy Bicep ------------------------------------------------------
info "Starting Bicep deployment '$DEPLOYMENT_NAME'..."
info "This may take 5-10 minutes."

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --template-file main.bicep \
  --parameters @"$PARAMETERS_FILE" \
  --output table

ok "Deployment completed successfully!"

# ---------- Print outputs -----------------------------------------------------
echo ""
info "=== Deployment Outputs ==="
az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs \
  --output table

echo ""
ok "=== Next Steps ==="
echo "  1. Set up Azure SRE Agent in the portal  → see docs/sre-agent-setup.md"
echo "  2. Run a Chaos experiment                 → see docs/demo-scenario.md"
echo "  3. Review runbook template                → see docs/runbook-template.md"
echo ""
