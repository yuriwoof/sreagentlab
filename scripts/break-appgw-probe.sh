#!/usr/bin/env bash
# =============================================================================
# break-appgw-probe.sh – Switch only the lab probe from /health.htm to /healthz.
# =============================================================================
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
preflight
load_deployment
set_probe /healthz
