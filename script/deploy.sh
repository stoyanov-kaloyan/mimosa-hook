#!/usr/bin/env bash
# deploy.sh — Deploy the full Mimosa Hook stack across two chains.
#
# Step 1: MimosaHook + MimosaCallback  →  Origin chain (e.g. Sepolia)
# Step 2: MimosaReactive               →  Reactive Network
#
# Each step writes a JSON manifest to deployments/ that the web UI and
# the next step can consume.
#
# Usage:
#   cp .env.example .env   # fill in your values
#   source .env
#   ./script/deploy.sh
set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

check_var() {
    if [[ -z "${!1:-}" ]]; then
        echo "❌ Missing required env var: $1" >&2
        exit 1
    fi
}

check_var ORIGIN_RPC
check_var REACTIVE_RPC
check_var POOL_MANAGER
check_var CALLBACK_PROXY
check_var ORIGIN_CHAIN_ID

# Optional — defaults
REACTIVE_DEPOSIT_WEI="${REACTIVE_DEPOSIT_WEI:-0}"
VERIFY_FLAGS="${VERIFY_FLAGS:---verify}"

mkdir -p deployments

info "Step 1/2 — Deploying MimosaHook + MimosaCallback on origin chain (ID: $ORIGIN_CHAIN_ID)"

forge script script/DeployMimosaHook.s.sol \
    --rpc-url "$ORIGIN_RPC" \
    --broadcast \
    $VERIFY_FLAGS

ORIGIN_MANIFEST="deployments/${ORIGIN_CHAIN_ID}.json"
if [[ ! -f "$ORIGIN_MANIFEST" ]]; then
    echo "❌ Origin manifest not found at $ORIGIN_MANIFEST" >&2
    exit 1
fi

HOOK_ADDR=$(jq -r '.hook' "$ORIGIN_MANIFEST")
CALLBACK_ADDR=$(jq -r '.callback' "$ORIGIN_MANIFEST")

ok "MimosaHook:     $HOOK_ADDR"
ok "MimosaCallback: $CALLBACK_ADDR"

info "Step 2/2 — Deploying MimosaReactive on Reactive Network"

ORIGIN_CHAIN_ID="$ORIGIN_CHAIN_ID" \
HOOK="$HOOK_ADDR" \
CALLBACK="$CALLBACK_ADDR" \
REACTIVE_DEPOSIT_WEI="$REACTIVE_DEPOSIT_WEI" \
forge script script/DeployReactive.s.sol \
    --rpc-url "$REACTIVE_RPC" \
    --broadcast

REACTIVE_MANIFEST=$(ls deployments/reactive-*.json 2>/dev/null | head -1)
if [[ -z "$REACTIVE_MANIFEST" ]]; then
    echo "❌ Reactive manifest not found" >&2
    exit 1
fi

REACTIVE_ADDR=$(jq -r '.reactive' "$REACTIVE_MANIFEST")
ok "MimosaReactive: $REACTIVE_ADDR"

info "Writing combined deployment manifest"

COMBINED="deployments/mimosa.json"
jq -s '
{
    origin: {
        chainId:       .[0].chainId,
        poolManager:   .[0].poolManager,
        callbackProxy: .[0].callbackProxy,
        hook:          .[0].hook,
        callback:      .[0].callback,
        hookSalt:      .[0].hookSalt,
        deployedAt:    .[0].deployedAt
    },
    reactive: {
        chainId:       .[1].reactiveChainId,
        reactive:      .[1].reactive,
        deployedAt:    .[1].deployedAt
    }
}' "$ORIGIN_MANIFEST" "$REACTIVE_MANIFEST" > "$COMBINED"

ok "Combined manifest: $COMBINED"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Mimosa Hook — Full deployment complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Origin chain ($ORIGIN_CHAIN_ID):"
echo "    MimosaHook:     $HOOK_ADDR"
echo "    MimosaCallback: $CALLBACK_ADDR"
echo ""
echo "  Reactive Network:"
echo "    MimosaReactive: $REACTIVE_ADDR"
echo ""
echo "  Manifests:"
echo "    $ORIGIN_MANIFEST"
echo "    $REACTIVE_MANIFEST"
echo "    $COMBINED  ← use this for the web UI"
echo ""
