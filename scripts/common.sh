#!/usr/bin/env bash
# =============================================================================
# common.sh – Shared lab safety checks.
# Requires Bash, Azure CLI and Python 3 (stdlib only): Linux, Cloud Shell, Git Bash.
# RESOURCE_GROUP: unset = auto-detect the single lab RG (deploy.sh uses rg-sreagentlab).
# SUBSCRIPTION_ID selects an account.
# DEPLOYMENT_NAME pins a successful main deployment; otherwise latest is selected.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Native Windows az/python need drive-qualified file paths when ARM ID conversion
# is disabled. Forward-slash drive paths also work with Git Bash filesystem tools.
native_path() {
  case "${OSTYPE:-}" in msys*|cygwin*) cygpath -m "$1" ;; *) printf '%s\n' "$1" ;; esac
}
REPO_ROOT="$(native_path "$REPO_ROOT")"
RESOURCE_GROUP_FROM_ENV="${RESOURCE_GROUP:+1}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sreagentlab}"
LOCATION="${LOCATION:-japaneast}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

preflight() {
  local mode="${1:-existing}"
  command -v az >/dev/null || die "Install Azure CLI; then run az login."
  command -v python3 >/dev/null || die "Install Python 3 (python3 on PATH); no pip packages or jq required."
  # Prevent Git Bash from translating ARM resource IDs into Windows paths.
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
    az account set --subscription "$SUBSCRIPTION_ID" || die "Cannot select subscription."
  fi
  local account
  account="$(az account show --output json)" || die "Azure login required: run az login."
  SUBSCRIPTION_ID="$(printf '%s' "$account" | json_value id)"
  [[ "$SUBSCRIPTION_ID" =~ ^[a-fA-F0-9-]{36}$ ]] || die "Account did not return a subscription ID."
  [[ -n "$RESOURCE_GROUP_FROM_ENV" || "$mode" == create ]] || detect_resource_group
  [[ "$RESOURCE_GROUP" =~ ^[a-zA-Z0-9_.()-]+$ && "$RESOURCE_GROUP" != *. ]] || die "Invalid RESOURCE_GROUP."
  info "Subscription: $SUBSCRIPTION_ID; resource group: $RESOURCE_GROUP"
}

# The CPU experiment name identifies this lab; tags are user-editable and not relied on.
detect_resource_group() {
  local experiments
  experiments="$(az resource list --subscription "$SUBSCRIPTION_ID" --resource-type Microsoft.Chaos/experiments --output json)" ||
    die "Cannot list Chaos experiments to find the lab resource group; set RESOURCE_GROUP."
  RESOURCE_GROUP="$(printf '%s' "$experiments" | python3 -c '
import json,sys
try:
    rows=json.load(sys.stdin)
    groups={}
    for r in rows:
        name,group=str(r.get("name","")),str(r.get("resourceGroup",""))
        if name.endswith("-cpu-pressure-exp") and group:
            groups.setdefault(group.lower(),group)
    if not groups: raise ValueError("No lab resource group found in this subscription; set RESOURCE_GROUP.")
    if len(groups)>1: raise ValueError("Multiple lab resource groups found ("+", ".join(sorted(groups.values()))+"); set RESOURCE_GROUP.")
    print(next(iter(groups.values())))
except (ValueError,TypeError,AttributeError) as e: sys.exit(str(e))
')" || die "Resource group detection failed; no changes made."
  info "Resource group auto-detected: $RESOURCE_GROUP (set RESOURCE_GROUP to override)."
}

json_value() {
  python3 -c '
import json,sys
try:
    value=json.load(sys.stdin)
    for key in sys.argv[1].split("."):
        value=value[int(key)] if isinstance(value,list) else value[key]
    if not isinstance(value,str) or not value.strip() or any(ord(c)<32 for c in value):
        raise ValueError("expected nonempty single-line string")
    print(value)
except (ValueError,KeyError,IndexError,TypeError) as e:
    sys.exit("Invalid/missing JSON value "+sys.argv[1]+": "+str(e))
' "$1"
}

load_deployment() {
  local deployments selected deployment_id expected_id
  if [[ -n "${DEPLOYMENT_NAME:-}" ]]; then
    deployments="$(az deployment group show --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --output json)" ||
      die "Cannot read DEPLOYMENT_NAME '$DEPLOYMENT_NAME'."
  else
    deployments="$(az deployment group list --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --output json)" ||
      die "Cannot list deployments; no changes made."
  fi
  selected="$(printf '%s' "$deployments" | python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
    rows=data if isinstance(data,list) else [data]
    def main(d):
        p=d.get("properties",{})
        o=p.get("outputs") or {}
        return (p.get("provisioningState","").lower()=="succeeded"
            and isinstance(o.get("experimentNames",{}).get("value"),dict)
            and isinstance(o.get("sreAgentPortalUrl",{}).get("value"),str)
            and bool(o["sreAgentPortalUrl"]["value"].strip()))
    rows=[d for d in rows if main(d)]
    if not rows: raise ValueError("No successful main deployment with experimentNames and sreAgentPortalUrl outputs; set DEPLOYMENT_NAME to a valid main deployment.")
    print(json.dumps(max(rows,key=lambda d:d["properties"].get("timestamp",""))))
except (ValueError,KeyError,TypeError,AttributeError) as e: sys.exit(str(e))
')" || die "Main deployment selection failed."
  DEPLOYMENT_NAME="$(printf '%s' "$selected" | json_value name)"
  deployment_id="$(printf '%s' "$selected" | json_value id)"
  expected_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Resources/deployments/$DEPLOYMENT_NAME"
  [[ "${deployment_id,,}" == "${expected_id,,}" ]] || die "Main deployment ID is outside the selected subscription/resource group."
  DEPLOYMENT_OUTPUTS="$(printf '%s' "$selected" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["properties"]["outputs"]))')"
  info "Main deployment: $DEPLOYMENT_NAME"
}

output() { printf '%s' "$DEPLOYMENT_OUTPUTS" | json_value "$1.value${2:+.$2}"; }
resource_name() {
  local value
  value="$(output "$1" "${2:-}")" || die "Missing output: $1."
  [[ "$value" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Invalid resource name in output $1."
  printf '%s\n' "$value"
}

verify_commands() {
  local gateway ip
  gateway="$(resource_name appGwName)"
  ip="$(output appGwPublicIp)"
  info "Verify recovery (cancellation alone does not prove recovery):"
  printf '  az network application-gateway show-backend-health --subscription %q -g %q -n %q\n' "$SUBSCRIPTION_ID" "$RESOURCE_GROUP" "$gateway"
  printf '  curl --fail %q\n' "http://$ip/health.htm"
}

set_probe() {
  local desired="$1" gateway probe current data
  gateway="$(resource_name appGwName)"
  probe="$(resource_name probeName)"
  data="$(az network application-gateway probe show --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" \
    --gateway-name "$gateway" -n "$probe" --output json)" || die "Cannot read lab probe; refusing changes."
  current="$(printf '%s' "$data" | json_value path)" || die "Probe path missing; refusing changes."
  case "$current" in /health.htm|/healthz) ;; *) die "Unexpected custom probe path '$current'; refusing overwrite." ;; esac
  if [[ "$current" == "$desired" ]]; then
    info "Probe already uses $desired; unchanged."
  else
    az network application-gateway probe update --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" \
      --gateway-name "$gateway" -n "$probe" --path "$desired" --output none || die "Probe update failed."
    ok "Probe changed to $desired; backend health propagation takes time."
  fi
  verify_commands
}

load_nsg_rules() {
  NSG_NAME="$(resource_name nsgName)"
  NSG_RULES="$(az network nsg rule list --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --output json)" ||
    die "Cannot read NSG rules; refusing changes."
}

manual_rule_state() {
  local src dst
  src="$(output appGwSubnetPrefix)" || die "Missing App Gateway subnet output."
  dst="$(output vmSubnetPrefix)" || die "Missing VM subnet output."
  printf '%s' "$NSG_RULES" | python3 -c '
import json,sys
rules=json.load(sys.stdin)
if not isinstance(rules,list): sys.exit("Invalid NSG rule list")
mode,src,dst=sys.argv[1:]
for r in rules:
    p=r.get("properties",r)
    name=r.get("name","").lower()
    if mode=="break" and p.get("priority")==100 and name!="manualdenyappgatewayhttp":
        sys.exit("Priority 100 is occupied; no rule changed.")
    if name=="manualdenyappgatewayhttp":
        expected={"priority":100,"access":"Deny","direction":"Inbound","protocol":"Tcp",
                  "sourceAddressPrefix":src,"destinationAddressPrefix":dst,
                  "sourcePortRange":"*","destinationPortRange":"80"}
        if any(str(p.get(k,"")).lower()!=str(v).lower() for k,v in expected.items()):
            sys.exit("Manual rule name belongs to an unexpected rule; refusing overwrite/delete.")
        if any(p.get(k) for k in ("sourceAddressPrefixes","destinationAddressPrefixes","sourcePortRanges","destinationPortRanges","sourceApplicationSecurityGroups","destinationApplicationSecurityGroups")):
            sys.exit("Unexpected plural NSG rule fields; refusing changes.")
print("present" if any(r.get("name","").lower()=="manualdenyappgatewayhttp" for r in rules) else "missing")
' "$1" "$src" "$dst"
}

activity_context() {
  LAW_ID="$(output lawId)"
  DIAGNOSTIC_NAME="sreagentlab-activity-$RESOURCE_GROUP"
  [[ ${#DIAGNOSTIC_NAME} -le 64 ]] || die "Activity diagnostic/deployment name exceeds 64 characters; use a shorter RESOURCE_GROUP."
  local expected="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/"
  local lower="${LAW_ID,,}"
  [[ "$lower" == "${expected,,}"* && "${lower#"${expected,,}"}" =~ ^[a-zA-Z0-9_-]+$ ]] ||
    die "lawId must be a workspace in the selected subscription and lab resource group."
  DIAGNOSTIC_URL="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Insights/diagnosticSettings"
  DIAGNOSTICS="$(az rest --method get --url "$DIAGNOSTIC_URL?api-version=2021-05-01-preview" --output json)" ||
    die "Cannot inspect subscription diagnostics; refusing changes."
}

activity_state() {
  printf '%s' "$DIAGNOSTICS" | python3 -c '
import json,sys
name,law,mode=sys.argv[1:]
data=json.load(sys.stdin)
rows=data["value"]
if not isinstance(rows,list) or data.get("nextLink"): sys.exit("Incomplete diagnostic settings response; refusing changes.")
found=False
categories={"Administrative","Policy","Security","ServiceHealth","Alert","Recommendation","Autoscale","ResourceHealth"}
for r in rows:
    p=r.get("properties",r)
    same=p.get("workspaceId","").lower()==law.lower()
    if r.get("name","").lower()==name.lower():
        if not same: sys.exit("Lab diagnostic setting points to another workspace; refusing changes.")
        found=True
    elif mode=="enable" and same and any(l.get("enabled") and
        (l.get("category") in categories or l.get("categoryGroup")) for l in p.get("logs",[])):
        sys.exit("Another setting already exports Activity Log categories to this workspace; refusing duplicate export.")
print("present" if found else "missing")
' "$DIAGNOSTIC_NAME" "$LAW_ID" "$1"
}
