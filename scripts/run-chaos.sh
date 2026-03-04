#!/usr/bin/env bash
# =============================================================================
# run-chaos.sh – Start a Chaos Studio experiment
# Usage: ./scripts/run-chaos.sh [cpu|memory|nginx]
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sreagentlab}"
PREFIX="${PREFIX:-srelab}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCENARIO="${1:-cpu}"

case "$SCENARIO" in
  cpu)
    EXPERIMENT_NAME="${PREFIX}-cpu-pressure-exp"
    info "Starting CPU Pressure experiment (95% for 10 min)..."
    ;;
  memory)
    EXPERIMENT_NAME="${PREFIX}-memory-pressure-exp"
    info "Starting Memory Pressure experiment (90% for 10 min)..."
    ;;
  nginx)
    EXPERIMENT_NAME="${PREFIX}-stop-nginx-exp"
    info "Starting nginx Stop Service experiment (5 min)..."
    ;;
  *)
    err "Unknown scenario: $SCENARIO"
    echo "Usage: $0 [cpu|memory|nginx]"
    exit 1
    ;;
esac

# Start the experiment
info "Experiment: $EXPERIMENT_NAME"
info "Resource Group: $RESOURCE_GROUP"

az rest \
  --method post \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Chaos/experiments/${EXPERIMENT_NAME}/start?api-version=2024-01-01" \
  --output json

ok "Experiment '$EXPERIMENT_NAME' started!"
echo ""
info "Monitor the experiment:"
echo "  az rest --method get \\"
echo "    --url \"https://management.azure.com/subscriptions/\$(az account show --query id -o tsv)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Chaos/experiments/${EXPERIMENT_NAME}/executions?api-version=2024-01-01\""
echo ""
info "Monitor VM CPU in Azure Monitor:"
echo "  https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv 2>/dev/null || echo '<SUB_ID>')/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/${PREFIX}-vm/metrics"
echo ""
