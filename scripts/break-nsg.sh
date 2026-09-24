#!/usr/bin/env bash
# =============================================================================
# break-nsg.sh – Block App Gateway HTTP with the reserved manual lab rule.
# =============================================================================
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
preflight
load_deployment
load_nsg_rules
STATE="$(manual_rule_state break)" || die "NSG preflight failed."
if [[ "$STATE" == present ]]; then
  info "Manual HTTP deny already present; unchanged."
else
  az network nsg rule create --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    -n ManualDenyAppGatewayHTTP --priority 100 --direction Inbound --access Deny --protocol Tcp \
    --source-address-prefixes "$(output appGwSubnetPrefix)" --source-port-ranges '*' \
    --destination-address-prefixes "$(output vmSubnetPrefix)" --destination-port-ranges 80 --output none ||
    die "Failed to create manual deny."
  ok "Manual HTTP deny created."
fi
verify_commands
