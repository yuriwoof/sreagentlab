#!/usr/bin/env bash
# =============================================================================
# fix-iis.sh – Run only after run-chaos.sh stop iis and terminal cancellation.
# Fallback when Chaos automatic service restoration fails; targets vmNames[0].
# =============================================================================
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
preflight
load_deployment
VM_NAME="$(resource_name vmNames 0)"
warn "Use only after the IIS experiment has finished/cancelled; a running fault can stop IIS again."
RESULT="$(az vm run-command invoke --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --command-id RunPowerShellScript --scripts '
$ErrorActionPreference = "Stop"
Set-Service -Name W3SVC -StartupType Automatic
Start-Service -Name W3SVC
if ((Get-Service W3SVC).Status -ne "Running") { throw "W3SVC did not start" }
$response = Invoke-WebRequest -Uri "http://localhost/health.htm" -UseBasicParsing -TimeoutSec 30
if ($response.StatusCode -ne 200) { throw "IIS HTTP health check failed" }
Write-Output "IIS_RECOVERY_HTTP_200"
' --output json)" || die "RunPowerShellScript invocation failed."
printf '%s' "$RESULT" | python3 -c '
import json,sys
entries=json.load(sys.stdin)["value"]
if not any("StdOut" in e.get("code","") and "IIS_RECOVERY_HTTP_200" in e.get("message","") for e in entries):
    sys.exit("Guest did not confirm IIS HTTP 200; inspect VM Run Command result.")
if any("StdErr" in e.get("code","") and e.get("message","").strip() for e in entries):
    sys.exit("Guest reported an error; inspect VM Run Command result.")
' || die "IIS recovery verification failed."
ok "W3SVC Automatic/Running and local HTTP 200 confirmed; verify external health."
verify_commands
