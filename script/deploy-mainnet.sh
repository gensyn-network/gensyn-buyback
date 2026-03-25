#!/bin/bash
# Deploy BuybackVault to Gensyn Mainnet
#
# Usage:
#   ./script/deploy-mainnet.sh [MODE]
#
# Modes:
#   deploy       - Deploy contracts only (default)
#   setup        - Deploy + run setup script
#   full         - Deploy + setup + run fork tests
#
# Required environment variables:
#   DEPLOYER_KEY    - Private key for deployment
#   OWNER_KEY       - Private key for owner (required for setup/full modes)
#   AI_TOKEN        - AI token address
#   TREASURY        - Treasury address
#   SWAP_ROUTER     - Uniswap SwapRouter02 address
#   OWNER           - Owner address (multisig)
#
# Setup mode additional env vars:
#   INPUT_TOKEN     - Token to approve for buybacks
#   APPROVED_PATH   - Encoded swap path (bytes)
#   PATH_POOLS      - Comma-separated pool addresses for TWAP
#   WETH            - (optional) WETH address
#   VOLUME_LIMIT    - (optional) Volume limit per epoch
#
# Optional env vars:
#   BURN_BPS              - Burn percentage (default: 7000 = 70%)
#   EXECUTOR_REWARD_BPS   - Executor reward (default: 100 = 1%)
#   TWAP_WINDOW           - TWAP window in seconds (default: 1800)
#   MAX_SLIPPAGE_BPS      - Max slippage (default: 200 = 2%)
#   EPOCH_DURATION        - Epoch duration in seconds (default: 86400)
#   RPC_URL               - Custom RPC URL

set -e

MODE="${1:-deploy}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEPLOYED_ADDRESSES_FILE="$PROJECT_ROOT/.deployed-mainnet.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_usage() {
    echo ""
    echo "Usage: ./script/deploy-mainnet.sh [MODE]"
    echo ""
    echo "Modes:"
    echo "  deploy    Deploy contracts only (default)"
    echo "  setup     Deploy + configure vault (approveToken, approvePath, etc.)"
    echo "  full      Deploy + setup + run fork tests"
    echo ""
    echo "Examples:"
    echo "  ./script/deploy-mainnet.sh deploy"
    echo "  ./script/deploy-mainnet.sh setup"
    echo "  ./script/deploy-mainnet.sh full"
    echo ""
}

if [ -f "$PROJECT_ROOT/.env" ]; then
    log_info "Loading environment from .env..."
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

RPC_URL="${RPC_URL:-}"

if [ -z "$RPC_URL" ]; then
    log_error "RPC_URL is required for mainnet deployment"
    exit 1
fi

validate_deploy_env() {
    local missing=0
    
    if [ -z "$DEPLOYER_KEY" ]; then
        log_error "DEPLOYER_KEY is required"
        missing=1
    fi
    if [ -z "$AI_TOKEN" ]; then
        log_error "AI_TOKEN is required"
        missing=1
    fi
    if [ -z "$TREASURY" ]; then
        log_error "TREASURY is required"
        missing=1
    fi
    if [ -z "$SWAP_ROUTER" ]; then
        log_error "SWAP_ROUTER is required"
        missing=1
    fi
    if [ -z "$OWNER" ]; then
        log_error "OWNER is required"
        missing=1
    fi
    if [ -z "$RPC_URL" ]; then
        log_error "RPC_URL is required"
        missing=1
    fi
    if [ -z "$VERIFIER_URL" ]; then
        log_error "VERIFIER_URL is required for contract verification"
        missing=1
    fi
    
    return $missing
}

validate_setup_env() {
    local missing=0
    
    if [ -z "$OWNER_KEY" ]; then
        log_error "OWNER_KEY is required for setup mode"
        missing=1
    fi
    if [ -z "$INPUT_TOKEN" ]; then
        log_error "INPUT_TOKEN is required for setup mode"
        missing=1
    fi
    if [ -z "$APPROVED_PATH" ]; then
        log_error "APPROVED_PATH is required for setup mode"
        missing=1
    fi
    if [ -z "$PATH_POOLS" ]; then
        log_error "PATH_POOLS is required for setup mode"
        missing=1
    fi
    
    return $missing
}

run_deploy() {
    log_info "Deploying BuybackVault to Gensyn Mainnet..."
    echo ""
    echo "Configuration:"
    echo "  Owner:       $OWNER"
    echo "  Treasury:    $TREASURY"
    echo "  AI Token:    $AI_TOKEN"
    echo "  Swap Router: $SWAP_ROUTER"
    echo ""

    DEPLOY_OUTPUT=$(forge script script/DeployBuybackVault.s.sol:DeployBuybackVault \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --verify \
        --verifier blockscout \
        --verifier-url "${VERIFIER_URL:-}" \
        -vvvv 2>&1) || {
        log_error "Deployment failed!"
        echo "$DEPLOY_OUTPUT"
        exit 1
    }

    echo "$DEPLOY_OUTPUT"

    # Extract addresses from broadcast JSON (more reliable than parsing logs)
    BROADCAST_FILE="$PROJECT_ROOT/broadcast/DeployBuybackVault.s.sol/$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "685685")/run-latest.json"
    
    if [ -f "$BROADCAST_FILE" ]; then
        VAULT_IMPL=$(jq -r '.transactions[] | select(.contractName == "BuybackVault") | .contractAddress' "$BROADCAST_FILE" | head -1)
        VAULT_PROXY=$(jq -r '.transactions[] | select(.contractName == "ERC1967Proxy") | .contractAddress' "$BROADCAST_FILE" | head -1)
    fi

    if [ -n "$VAULT_PROXY" ]; then
        cat > "$DEPLOYED_ADDRESSES_FILE" << EOF
{
    "network": "gensyn_mainnet",
    "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "contracts": {
        "vaultProxy": "$VAULT_PROXY",
        "vaultImplementation": "$VAULT_IMPL"
    },
    "config": {
        "owner": "$OWNER",
        "treasury": "$TREASURY",
        "aiToken": "$AI_TOKEN",
        "swapRouter": "$SWAP_ROUTER"
    }
}
EOF
        log_success "Deployment complete!"
        echo ""
        echo "Vault Proxy: $VAULT_PROXY"
        echo "Vault Impl:  $VAULT_IMPL"
        echo ""
        echo "Addresses saved to: $DEPLOYED_ADDRESSES_FILE"
        
        export VAULT="$VAULT_PROXY"
    else
        log_warn "Could not extract deployed addresses from output"
    fi
}

run_setup() {
    if [ -z "$VAULT" ]; then
        if [ -f "$DEPLOYED_ADDRESSES_FILE" ]; then
            VAULT=$(grep "vaultProxy" "$DEPLOYED_ADDRESSES_FILE" | sed -n 's/.*"\(0x[a-fA-F0-9]\{40\}\)".*/\1/p' | head -1)
        fi
    fi

    if [ -z "$VAULT" ]; then
        log_error "VAULT address not found. Run deploy first or set VAULT env var."
        exit 1
    fi

    log_info "Setting up BuybackVault at $VAULT..."
    echo ""
    echo "Configuration:"
    echo "  Vault:        $VAULT"
    echo "  Input Token:  $INPUT_TOKEN"
    echo "  Path Pools:   $PATH_POOLS"
    [ -n "$WETH" ] && echo "  WETH:         $WETH"
    [ -n "$VOLUME_LIMIT" ] && echo "  Volume Limit: $VOLUME_LIMIT"
    echo ""

    export VAULT

    SETUP_OUTPUT=$(forge script script/SetupBuybackVault.s.sol:SetupBuybackVault \
        --rpc-url "$RPC_URL" \
        --broadcast \
        -vvvv 2>&1) || {
        log_error "Setup failed!"
        echo "$SETUP_OUTPUT"
        exit 1
    }

    echo "$SETUP_OUTPUT"
    log_success "Setup complete!"
}

run_tests() {
    if [ -z "$VAULT" ]; then
        if [ -f "$DEPLOYED_ADDRESSES_FILE" ]; then
            VAULT=$(grep "vaultProxy" "$DEPLOYED_ADDRESSES_FILE" | sed -n 's/.*"\(0x[a-fA-F0-9]\{40\}\)".*/\1/p' | head -1)
        fi
    fi

    log_info "Running fork tests..."
    echo ""

    cd "$PROJECT_ROOT"

    if [ -z "$VAULT" ]; then
        log_error "VAULT address is empty. Cannot run tests."
        exit 1
    fi

    echo "Testing with DEPLOYED_VAULT=$VAULT"
    export DEPLOYED_VAULT="$VAULT"

    forge test --match-path test/GensynMainnetFork.t.sol -vvv --fork-url "$RPC_URL"

    TEST_EXIT_CODE=$?

    if [ $TEST_EXIT_CODE -eq 0 ]; then
        log_success "All fork tests passed!"
    else
        log_error "Some fork tests failed"
        exit $TEST_EXIT_CODE
    fi
}

case "$MODE" in
    deploy)
        echo ""
        echo "=========================================="
        echo "  Gensyn Mainnet Deployment (Deploy Only)"
        echo "=========================================="
        echo ""
        
        if ! validate_deploy_env; then
            print_usage
            exit 1
        fi
        
        run_deploy
        
        echo ""
        log_info "Next step: Run './script/deploy-mainnet.sh setup' to configure the vault"
        ;;
        
    setup)
        echo ""
        echo "========================================"
        echo "  Gensyn Mainnet Setup (Configure Vault)"
        echo "========================================"
        echo ""
        
        if ! validate_setup_env; then
            print_usage
            exit 1
        fi
        
        run_setup
        
        echo ""
        log_info "Setup complete! Run './script/deploy-mainnet.sh test' to run fork tests"
        ;;
        
    full)
        echo ""
        echo "===================================================="
        echo "  Gensyn Mainnet Deployment (Deploy + Setup + Test)"
        echo "===================================================="
        echo ""
        
        if ! validate_deploy_env; then
            print_usage
            exit 1
        fi
        
        if ! validate_setup_env; then
            print_usage
            exit 1
        fi
        
        run_deploy
        echo ""
        run_setup
        echo ""
        run_tests
        ;;
        
    -h|--help|help)
        print_usage
        exit 0
        ;;
        
    *)
        log_error "Unknown mode: $MODE"
        print_usage
        exit 1
        ;;
esac

echo ""
log_success "Script complete!"
