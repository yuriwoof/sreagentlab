#!/usr/bin/env bash
# =============================================================================
# deploy.sh – Deploy from any working directory; password is prompted twice.
# Requires Bash, Azure CLI/Bicep, Python 3 and mktemp (Linux/Cloud Shell/Git Bash).
# PARAMETERS_FILE: absolute or repo-relative; default main.parameters.local.json
# if present, else main.parameters.json. Password value must be absent or empty.
# RESOURCE_GROUP=rg-sreagentlab; LOCATION=eastus2 overrides parameter location.
# DEPLOYMENT_NAME defaults to a timestamp; SUBSCRIPTION_ID selects Azure account.
# Scratch files are owner-only in the repo and removed on exit/signals. On Windows,
# use a private NTFS checkout (umask cannot replace filesystem ACL protection).
# Never run with Bash -v: verbose mode can echo input before scripts can disable it.
# =============================================================================
set +x
set +v
set +a
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
export AZURE_CORE_LOG_LEVEL=warning
preflight create
command -v mktemp >/dev/null || die "mktemp is required (included with Git Bash/Cloud Shell)."
if [[ -z "${PARAMETERS_FILE:-}" ]]; then
  PARAMETERS_FILE=main.parameters.json
  [[ ! -f "$REPO_ROOT/main.parameters.local.json" ]] || PARAMETERS_FILE=main.parameters.local.json
fi
case "$PARAMETERS_FILE" in /*|[A-Za-z]:*) ;; *) PARAMETERS_FILE="$REPO_ROOT/$PARAMETERS_FILE" ;; esac
PARAMETERS_FILE="$(native_path "$PARAMETERS_FILE")"
[[ -f "$PARAMETERS_FILE" ]] || die "Parameters file not found: $PARAMETERS_FILE"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-sreagentlab-$(date +%Y%m%d-%H%M%S)}"
[[ "$DEPLOYMENT_NAME" =~ ^[a-zA-Z0-9_.()-]+$ && ${#DEPLOYMENT_NAME} -le 64 ]] || die "Invalid DEPLOYMENT_NAME (maximum 64 characters)."

# Validate non-secret input BEFORE asking for a password or making cloud changes.
TAGS="$(python3 - "$PARAMETERS_FILE" <<'PY'
import ipaddress,json,re,sys,uuid
try:
    doc=json.load(open(sys.argv[1],encoding="utf-8-sig"))
    p=doc["parameters"]
    def value(k,default=None): return p.get(k,{}).get("value",default)
    if not isinstance(p,dict) or any(not isinstance(v,dict) or set(v)!={"value"} for v in p.values()):
        raise ValueError("Use literal value entries only; parameter references are not supported.")
    if value("adminPassword","") not in ("",None):
        raise ValueError("Remove the stored adminPassword; only an empty/absent password is allowed.")
    def strings(x):
        if isinstance(x,str): yield x
        elif isinstance(x,dict):
            for v in x.values(): yield from strings(v)
        elif isinstance(x,list):
            for v in x: yield from strings(v)
    if any(re.search(r"<[^>]+>|YOUR_[A-Z_]+",v) for v in strings(p)):
        raise ValueError("Replace all <...>/YOUR_... placeholders.")
    prefix=value("prefix","srelab")
    if not isinstance(prefix,str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{0,8}",prefix) or prefix.endswith("-"):
        raise ValueError("prefix must start with a letter, contain letters/digits/hyphens, end alphanumeric, and be 1..9 characters (Windows name limit).")
    username=value("adminUsername","azureuser")
    reserved={"administrator","admin","user","user1","test","test1","test2","test3","guest","root","1","123","a","actuser","adm","admin1","admin2","aspnet","backup","console","david","john","owner","support","sys","sql","ubuntu"}
    if (not isinstance(username,str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,19}",username)
            or username.lower() in reserved):
        raise ValueError("adminUsername must be a non-reserved Windows username, 1..20 letters/digits/_/-, starting with a letter.")
    count=value("vmCount",2)
    if type(count) is not int or not 1<=count<=99: raise ValueError("vmCount must be an integer 1..99.")
    enabled=value("enableRdpPublicIp",False)
    if type(enabled) is not bool: raise ValueError("enableRdpPublicIp must be boolean.")
    if enabled:
        source=value("allowedRdpSource","127.0.0.1/32")
        if not isinstance(source,str) or "/" not in source: raise ValueError("RDP requires an explicit restricted IPv4 CIDR.")
        network=ipaddress.IPv4Network(source,strict=True)
        if network.prefixlen==0 or network.overlaps(ipaddress.IPv4Network("127.0.0.0/8")) or network.is_unspecified or network.is_multicast:
            raise ValueError("RDP CIDR cannot be /0, wildcard, unspecified, multicast or loopback.")
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+",value("alertEmail","")): raise ValueError("alertEmail is required.")
    uuid.UUID(value("deployerPrincipalId",""))
    tags={"project":"sreagentlab","env":"demo",**value("tags",{})}
    if any(not isinstance(v,str) or any(ord(c)<32 for c in k+v) or "=" in k for k,v in tags.items()):
        raise ValueError("Tags must be single-line strings.")
    print(json.dumps(tags))
except (ValueError,KeyError,TypeError,AttributeError,OSError) as e:
    sys.exit("Invalid parameters: "+str(e))
PY
)" || die "Parameter validation failed; no changes made."

umask 077
SECURE_FILE=''
ERROR_FILE=''
cleanup_secrets() {
  unset PASSWORD CONFIRM_PASSWORD
  [[ -z "$SECURE_FILE" ]] || rm -f -- "$SECURE_FILE"
  [[ -z "$ERROR_FILE" ]] || rm -f -- "$ERROR_FILE"
}
trap cleanup_secrets EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
SECURE_FILE="$(mktemp "$REPO_ROOT/.deploy-parameters.XXXXXX.json")"
ERROR_FILE="$(mktemp "$REPO_ROOT/.deploy-errors.XXXXXX.log")"
unset PASSWORD CONFIRM_PASSWORD
read -rs -p "Windows administrator password: " PASSWORD || die "Password input required."
printf '\n'
read -rs -p "Confirm password: " CONFIRM_PASSWORD || die "Password confirmation required."
printf '\n'
[[ "$PASSWORD" == "$CONFIRM_PASSWORD" ]] || die "Passwords do not match."
# Password travels only over stdin, never process arguments or environment.
printf '%s' "$PASSWORD" | python3 -c '
import json,re,sys
password=sys.stdin.read()
doc=json.load(open(sys.argv[1],encoding="utf-8-sig"))
p=doc["parameters"]
username=p.get("adminUsername",{}).get("value","azureuser")
classes=sum(bool(re.search(pattern,password)) for pattern in (r"[a-z]",r"[A-Z]",r"[0-9]",r"[^a-zA-Z0-9]"))
if not 12<=len(password)<=123 or classes<3 or username.lower() in password.lower() or any(ord(c)<32 for c in password):
    sys.exit("Password must be 12..123 characters, contain 3 character classes, and not contain the username.")
p["adminPassword"]={"value":password}
p["location"]={"value":sys.argv[3]}
p["tags"]={"value":json.loads(sys.argv[4])}
with open(sys.argv[2],"w",encoding="utf-8") as f: json.dump(doc,f)
' "$PARAMETERS_FILE" "$SECURE_FILE" "$LOCATION" "$TAGS" || die "Password validation failed."
unset PASSWORD CONFIRM_PASSWORD
info "Building main.bicep..."
az bicep build --file "$REPO_ROOT/main.bicep" --stdout > /dev/null || die "Bicep build failed."
for provider in Microsoft.App Microsoft.AlertsManagement Microsoft.Chaos Microsoft.Insights Microsoft.OperationalInsights Microsoft.Compute Microsoft.Network Microsoft.ManagedIdentity Microsoft.Portal; do
  az provider register --subscription "$SUBSCRIPTION_ID" --namespace "$provider" --wait --output none ||
    die "Provider registration failed: $provider"
done
TAG_ARGS=()
while IFS= read -r tag; do TAG_ARGS+=("$tag"); done < <(printf '%s' "$TAGS" | python3 -c 'import json,sys; [print(k+"="+v) for k,v in json.load(sys.stdin).items()]')
az group create --subscription "$SUBSCRIPTION_ID" --name "$RESOURCE_GROUP" --location "$LOCATION" \
  --tags "${TAG_ARGS[@]}" --output none || die "Resource group creation failed."
info "Deploying '$DEPLOYMENT_NAME'..."
# Azure errors/debug output can contain parameter bodies. Keep it private and
# discard it on exit; investigate failed operations in the portal, never echo it.
if ! az deployment group create --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" --template-file "$REPO_ROOT/main.bicep" --parameters "@$SECURE_FILE" \
  --only-show-errors --output none > "$ERROR_FILE" 2>&1; then
  die "Deployment '$DEPLOYMENT_NAME' failed. Inspect deployment operations in Azure Portal (secret-bearing CLI output suppressed)."
fi
cleanup_secrets
SECURE_FILE=''; ERROR_FILE=''
load_deployment
ok "Deployment completed: $DEPLOYMENT_NAME"
info "App Gateway: http://$(output appGwPublicIp)"
info "SRE Agent: $(output sreAgentPortalUrl)"
info "Live report: open the agent, select Live Reports > + New report (see docs/sre-agent-setup.md)."
verify_commands
