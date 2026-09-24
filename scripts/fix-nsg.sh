#!/usr/bin/env bash
# =============================================================================
# fix-nsg.sh – Remove ONLY the manual rule; use run-chaos.sh stop nsg for Chaos.
# =============================================================================
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
preflight
load_deployment
load_nsg_rules
STATE="$(manual_rule_state fix)" || die "NSG preflight failed."
if [[ "$STATE" == missing ]]; then
  info "Manual deny is absent; no change."
else
  az network nsg rule delete --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    -n ManualDenyAppGatewayHTTP --output none || die "Failed to delete manual deny."
  ok "Manual deny removed."
fi
info "ChaosDenyAppGatewayHTTP is never deleted here. Use run-chaos.sh stop nsg and wait for recovery."
verify_commands
