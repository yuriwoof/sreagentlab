#!/usr/bin/env bash
# =============================================================================
# enable-activity-log.sh – Opt-in subscription Activity Log export (separate RBAC).
# LOCATION defaults to japaneast; deployment/diagnostic name is deterministic per RG.
# =============================================================================
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
preflight
load_deployment
activity_context
STATE="$(activity_state enable)" || die "Activity Log preflight failed."
info "Exporting this subscription's Activity Log to $LAW_ID; existing lab setting: $STATE."
az deployment sub create --subscription "$SUBSCRIPTION_ID" --name "$DIAGNOSTIC_NAME" --location "$LOCATION" \
  --template-file "$REPO_ROOT/modules/activity-log.bicep" \
  --parameters "lawId=$LAW_ID" "diagnosticSettingName=$DIAGNOSTIC_NAME" --output none ||
  die "Activity Log deployment failed (requires subscription diagnostic-setting permissions)."
ok "Activity Log export configured: $DIAGNOSTIC_NAME"
