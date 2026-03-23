#!/bin/bash
# Deploy BuybackVault to Gensyn Testnet and run fork tests
#
# Usage:
#   ./script/deploy-testnet.sh
#
# Required environment variables:
#   DEPLOYER_KEY - Private key for deployment (without 0x prefix)
#   OWNER - Address that will own the vault
#   TREASURY - Address to receive treasury portion
#
# Optional environment variables (with defaults):
#   BURN_BPS - Burn percentage (default: 7000 = 70%)
#   EXECUTOR_REWARD_BPS - Executor reward (default: 100 = 1%)
#   TWAP_WINDOW - TWAP window in seconds (default: 1800 = 30 min)
#   MAX_SLIPPAGE_BPS - Max slippage (default: 200 = 2%)
#   EPOCH_DURATION - Epoch duration in seconds (default: 86400 = 1 day)
#   SKIP_TESTS - Set to "true" to skip running fork tests after deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FORK_TEST_FILE="$PROJECT_ROOT/test/GensynTestnetFork.t.sol"
DEPLOYED_ADDRESSES_FILE="$PROJECT_ROOT/.deployed-addresses.json"

# Load .env file if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    echo "Loading environment variables from .env file..."
    set -a  # automatically export all variables
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Check required env vars
if [ -z "$DEPLOYER_KEY" ]; then
    echo "Error: DEPLOYER_KEY is required"
    exit 1
fi

if [ -z "$OWNER" ]; then
    echo "Error: OWNER is required"
    exit 1
fi

if [ -z "$TREASURY" ]; then
    echo "Error: TREASURY is required"
    exit 1
fi

# ============================================================
# STEP 1: Deploy BuybackVault
# ============================================================
echo "=== Step 1: Deploying BuybackVault to Gensyn Testnet ==="
echo "Owner: $OWNER"
echo "Treasury: $TREASURY"
echo ""

# Run deployment and capture output
DEPLOY_OUTPUT=$(forge script script/DeployGensynTestnet.s.sol:DeployGensynTestnet \
    --rpc-url https://gensyn-testnet.g.alchemy.com/public \
    --broadcast \
    --verify \
    --verifier blockscout \
    --verifier-url https://gensyn-testnet.explorer.alchemy.com/api \
    -vvvv 2>&1) || {
    echo "Deployment failed!"
    echo "$DEPLOY_OUTPUT"
    exit 1
}

echo "$DEPLOY_OUTPUT"

# Extract deployed addresses from output (macOS compatible - no -P flag)
# Look for "Proxy (vault)  : 0x..." pattern
VAULT_PROXY=$(echo "$DEPLOY_OUTPUT" | grep "Proxy (vault)" | sed -n 's/.*: \(0x[a-fA-F0-9]\{40\}\).*/\1/p' | head -1)
VAULT_IMPL=$(echo "$DEPLOY_OUTPUT" | grep "Implementation :" | sed -n 's/.*: \(0x[a-fA-F0-9]\{40\}\).*/\1/p' | head -1)

if [ -z "$VAULT_PROXY" ]; then
    echo "Warning: Could not extract vault proxy address from deployment output"
    echo "Trying alternative pattern..."
    VAULT_PROXY=$(echo "$DEPLOY_OUTPUT" | grep "BuybackVault Proxy:" | sed -n 's/.*: \(0x[a-fA-F0-9]\{40\}\).*/\1/p' | head -1)
fi

if [ -n "$VAULT_PROXY" ]; then
    echo ""
    echo "=== Deployed Addresses ==="
    echo "Vault Proxy: $VAULT_PROXY"
    echo "Vault Implementation: $VAULT_IMPL"
    
    # Save addresses to JSON file for reference
    cat > "$DEPLOYED_ADDRESSES_FILE" << EOF
{
    "network": "gensyn_testnet",
    "chainId": 685685,
    "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "contracts": {
        "vaultProxy": "$VAULT_PROXY",
        "vaultImplementation": "$VAULT_IMPL"
    },
    "config": {
        "owner": "$OWNER",
        "treasury": "$TREASURY"
    }
}
EOF
    echo "Addresses saved to: $DEPLOYED_ADDRESSES_FILE"
else
    echo "Warning: Could not extract deployed addresses"
fi

echo ""
echo "=== Deployment Complete ==="
echo "Check the explorer for verification status:"
echo "https://gensyn-testnet.explorer.alchemy.com/"

# ============================================================
# STEP 2: Update fork test file with deployed addresses
# ============================================================
echo ""
echo "=== Step 2: Updating Fork Test Addresses ==="

# Read deployed addresses if available (macOS compatible)
if [ -f "$DEPLOYED_ADDRESSES_FILE" ]; then
    VAULT_PROXY=$(grep "vaultProxy" "$DEPLOYED_ADDRESSES_FILE" | sed -n 's/.*"\(0x[a-fA-F0-9]\{40\}\)".*/\1/p' | head -1)
    echo "Using vault address from deployment: $VAULT_PROXY"
fi

if [ -z "$VAULT_PROXY" ]; then
    echo "Warning: No deployed vault address found. Tests will deploy a fresh vault."
else
    echo "Fork tests will use deployed vault: $VAULT_PROXY"
fi

# ============================================================
# STEP 3: Run fork tests
# ============================================================
if [ "$SKIP_TESTS" != "true" ]; then
    echo ""
    echo "=== Step 3: Running Fork Tests ==="
    echo ""
    
    cd "$PROJECT_ROOT"
    
    # Export vault address for tests to use
    export DEPLOYED_VAULT_ADDRESS="$VAULT_PROXY"
    
    # Run fork tests with verbose output
    forge test --match-path test/GensynTestnetFork.t.sol -vvv --fork-url https://gensyn-testnet.g.alchemy.com/public
    
    TEST_EXIT_CODE=$?
    
    echo ""
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        echo "=== All Fork Tests Passed! ==="
    else
        echo "=== Some Fork Tests Failed ==="
        exit $TEST_EXIT_CODE
    fi
else
    echo ""
    echo "=== Skipping tests (SKIP_TESTS=true) ==="
fi

echo ""
echo "=== Script Complete ==="
