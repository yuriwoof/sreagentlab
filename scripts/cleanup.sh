#!/usr/bin/env bash
# =============================================================================
# cleanup.sh – Delete all resources created by the SRE Agent Lab
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sreagentlab}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
warn "This will permanently delete ALL resources in resource group: $RESOURCE_GROUP"
read -rp "Are you sure? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  info "Aborted."
  exit 0
fi

info "Deleting resource group '$RESOURCE_GROUP'..."
az group delete --name "$RESOURCE_GROUP" --yes --no-wait

ok "Resource group deletion initiated (running in background)."
info "Check status: az group show -n $RESOURCE_GROUP --query properties.provisioningState -o tsv"
echo ""
