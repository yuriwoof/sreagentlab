#!/usr/bin/env bash
# =============================================================================
# run-chaos.sh – [start|status|stop] [cpu|memory|iis|diskio]
# A scenario alone means start; no arguments means start cpu.
# =============================================================================
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ACTION=start
case "${1:-}" in start|status|stop) ACTION="$1"; shift ;; esac
SCENARIO="${1:-cpu}"
[[ $# -le 1 ]] || die "Usage: $0 [start|status|stop] [cpu|memory|iis|diskio]"
case "$SCENARIO" in cpu|memory|iis|diskio) ;; *) die "Unknown scenario '$SCENARIO' (cpu, memory, iis, diskio)." ;; esac
preflight
load_deployment
EXPERIMENT_NAME="$(resource_name experimentNames "$SCENARIO")"
URL="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Chaos/experiments/$EXPERIMENT_NAME"
case "$ACTION" in
  start)
    az rest --method post --url "$URL/start?api-version=2024-01-01" --output json || die "Chaos start failed."
    ok "Start request accepted: $EXPERIMENT_NAME (check status)."
    ;;
  stop)
    az rest --method post --url "$URL/cancel?api-version=2024-01-01" --output json || die "Chaos cancellation failed."
    warn "Cancellation accepted, not confirmed recovered. Wait for terminal execution status and verify."
    [[ "$SCENARIO" != iis ]] || info "If automatic restoration fails after cancellation completes: bash scripts/fix-iis.sh"
    ;;
  status)
    NEXT="$URL/executions?api-version=2024-01-01"
    SEEN=$'\n'
    while [[ -n "$NEXT" ]]; do
      [[ "$NEXT" == "$URL/executions?"* && "$SEEN" != *$'\n'"$NEXT"$'\n'* ]] || die "Unsafe or repeated execution pagination URL."
      SEEN+="$NEXT"$'\n'
      PAGE="$(az rest --method get --url "$NEXT" --output json)" || die "Cannot read Chaos executions."
      printf '%s' "$PAGE" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d["value"],list); print(json.dumps(d["value"],indent=2))'
      NEXT="$(printf '%s' "$PAGE" | python3 -c 'import json,sys; d=json.load(sys.stdin); n=d.get("nextLink") or ""; assert isinstance(n,str); print(n)')"
    done
    ;;
esac
printf '  bash %q status %q\n' "$REPO_ROOT/scripts/run-chaos.sh" "$SCENARIO"
verify_commands
