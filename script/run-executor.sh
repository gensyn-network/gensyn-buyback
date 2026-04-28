#!/bin/bash
# BuybackVault Executor Bot
#
# Calls executeBuyback() in a loop whenever the vault has a balance.
# Exits immediately on unrecoverable errors (bad config, missing env vars).
# Skips gracefully on transient conditions (no balance, epoch exhausted, paused).
#
# Usage:
#   ./script/run-executor.sh
#
# Required env vars:
#   RPC_URL       - Gensyn node RPC endpoint
#   VAULT         - BuybackVault proxy address
#   INPUT_TOKEN   - ERC-20 token address to spend (zero address for ETH)
#   APPROVED_PATH - ABI-encoded swap path bytes
#   EXECUTOR_KEY  - Private key that receives the executor reward
#
# Optional env vars:
#   POLL_INTERVAL - Seconds between attempts (default: 60)
#   AMOUNT_IN     - Override the amount to swap (default: full vault balance)
#   DRY_RUN       - Set to "true" to simulate without broadcasting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[$(date -u +%H:%M:%SZ) INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[$(date -u +%H:%M:%SZ) OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[$(date -u +%H:%M:%SZ) WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[$(date -u +%H:%M:%SZ) ERROR]${NC} $1"; }

# ── Load .env if present ─────────────────────────────────────────────────────
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
    set +a
fi

# ── Validate required env vars ───────────────────────────────────────────────
for var in RPC_URL VAULT INPUT_TOKEN APPROVED_PATH; do
    if [ -z "${!var:-}" ]; then
        log_error "$var is required. Set it in .env or the environment."
        exit 1
    fi
done

if [ "${DRY_RUN:-false}" != "true" ] && [ -z "${EXECUTOR_KEY:-}" ]; then
    log_error "EXECUTOR_KEY is required for live execution. Set DRY_RUN=true to simulate."
    exit 1
fi

POLL_INTERVAL="${POLL_INTERVAL:-60}"

# ── Build forge command ───────────────────────────────────────────────────────
build_forge_cmd() {
    local cmd="forge script script/ExecuteBuyback.s.sol:ExecuteBuyback"
    cmd+=" --rpc-url $RPC_URL"
    cmd+=" -vv"

    if [ "${DRY_RUN:-false}" != "true" ]; then
        cmd+=" --broadcast"
    fi

    echo "$cmd"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
log_info "Starting BuybackVault executor"
log_info "Vault:    $VAULT"
log_info "Token:    $INPUT_TOKEN"
log_info "Interval: ${POLL_INTERVAL}s"
[ "${DRY_RUN:-false}" = "true" ] && log_warn "DRY RUN mode — no transactions will be broadcast"
echo ""

cd "$PROJECT_ROOT"

while true; do
    log_info "Attempting buyback..."

    FORGE_CMD=$(build_forge_cmd)
    OUTPUT=$($FORGE_CMD 2>&1) || true

    if echo "$OUTPUT" | grep -q "\[OK\] Buyback executed"; then
        log_success "Buyback executed successfully."
        # Check for sandwich signal in the output
        if echo "$OUTPUT" | grep -q "\[SANDWICH SIGNAL\]"; then
            log_warn "Sandwich signal detected — amountOut near TWAP floor. Check monitoring."
        fi
    elif echo "$OUTPUT" | grep -q "\[SKIP\]"; then
        log_info "Skipped: $(echo "$OUTPUT" | grep '\[SKIP\]' | head -1)"
    elif echo "$OUTPUT" | grep -q "\[DRY RUN\]"; then
        log_info "Dry run complete."
        echo "$OUTPUT"
        break  # exit after one dry run iteration
    else
        # Log the error but keep looping — transient RPC or mempool errors are expected
        log_warn "Execution did not complete cleanly:"
        echo "$OUTPUT" | tail -20
    fi

    log_info "Sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
done
