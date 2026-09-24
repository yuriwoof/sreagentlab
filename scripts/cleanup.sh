#!/usr/bin/env bash
# =============================================================================
# cleanup.sh – Confirm lab RG deletion and its precisely scoped subscription export.
# Does not remove other diagnostic settings or broad/stale role assignments.
# =============================================================================
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
preflight
load_deployment
activity_context
STATE="$(activity_state cleanup)" || die "Cannot safely identify lab diagnostics; nothing deleted."
warn "Permanently delete RG '$RESOURCE_GROUP' (VMs, App Gateway, NAT, SRE Agent, workspace and all other resources)."
warn "Downloaded live report HTML snapshots are local files and are not deleted by this script."
warn "Subscription '$SUBSCRIPTION_ID': delete ONLY '$DIAGNOSTIC_NAME' if it targets '$LAW_ID' (currently $STATE)."
read -rp "Type the resource group name to confirm BOTH deletions: " CONFIRM
[[ "$CONFIRM" == "$RESOURCE_GROUP" ]] || { info "Aborted."; exit 0; }
# Re-read after confirmation; do not delete a setting repointed while waiting.
activity_context
STATE="$(activity_state cleanup)" || die "Diagnostic scope changed; nothing deleted."
if [[ "$STATE" == present ]]; then
  az rest --method delete --url "$DIAGNOSTIC_URL/$DIAGNOSTIC_NAME?api-version=2021-05-01-preview" --output none ||
    die "Diagnostic deletion failed; resource group was not deleted."
  ok "Matching lab subscription diagnostic setting deleted."
else
  info "Lab diagnostic setting absent; other subscription settings untouched."
fi
az group delete --subscription "$SUBSCRIPTION_ID" --name "$RESOURCE_GROUP" --yes --no-wait ||
  die "Resource group deletion request failed."
ok "Resource group deletion initiated, not completed."
printf '  az group exists --subscription %q --name %q\n' "$SUBSCRIPTION_ID" "$RESOURCE_GROUP"
