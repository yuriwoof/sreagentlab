#!/usr/bin/env bash
# =============================================================================
# fix-appgw-probe.sh – Restore only the known lab probe to /health.htm.
# =============================================================================
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
preflight
load_deployment
set_probe /health.htm
