# BuybackVault Deployment Guide

This document covers deploying the BuybackVault contract.

> **For post-deployment setup and configuration**, see [SETUP.md](./SETUP.md).


## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Private key with sufficient ETH for gas
- Contract addresses ready (AI token, treasury, swap router)

## Quick Start

```bash
# 1. Copy and configure environment
cp .env.example .env

# 2. Deploy (testnet)
./script/deploy-testnet.sh

# 3. Deploy (mainnet)
./script/deploy-mainnet.sh full
```

---

## Environment Variables

### Required for Deployment

| Variable | Description |
|----------|-------------|
| `DEPLOYER_KEY` | Private key for deployment |
| `AI_TOKEN` | AI token contract address |
| `TREASURY` | Treasury address for buyback proceeds |
| `SWAP_ROUTER` | Uniswap V3 SwapRouter02 address |
| `OWNER` | Owner address (can be multisig) |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `BURN_BPS` | 7000 | Burn percentage (70%) |
| `EXECUTOR_REWARD_BPS` | 100 | Executor reward (1%) |
| `TWAP_WINDOW` | 1800 | TWAP window in seconds |
| `MAX_SLIPPAGE_BPS` | 200 | Max slippage (2%) |
| `EPOCH_DURATION` | 86400 | Epoch duration (1 day) |

> **Setup variables** (INPUT_TOKEN, APPROVED_PATH, etc.) are documented in [SETUP.md](./SETUP.md).

---

## Testnet Deployment

### Using Bash Script (Recommended)

The testnet script handles deployment and fork testing in one command:

```bash
./script/deploy-testnet.sh
```

To skip tests after deployment:

```bash
SKIP_TESTS=true ./script/deploy-testnet.sh
```



## Mainnet Deployment

For mainnet, you have two options: using the bash script or running forge commands directly.

### Option 1: Bash Script

The mainnet script supports three modes:

#### Deploy Only

Deploys the vault without any setup. Use this when the owner is a multisig that will run setup separately.

```bash
./script/deploy-mainnet.sh deploy
```

#### Deploy + Setup

Deploys and configures the vault (approves tokens, paths, sets WETH, etc.):

```bash
./script/deploy-mainnet.sh setup
```

#### Full (Deploy + Setup + Test)

Deploys, configures, and runs fork tests:

```bash
./script/deploy-mainnet.sh full
```

Expected output:

```bash
❯ ./script/deploy-mainnet.sh full
[INFO] Loading environment from .env...

====================================================
  Gensyn Mainnet Deployment (Deploy + Setup + Test)
====================================================

[INFO] Deploying BuybackVault to Gensyn Mainnet...

Configuration:
  Owner:       0x1774aCa1D3c79A1d0c22cA409fcc65E38128a68E
  Treasury:    0x3B065Ab8b77AABe83D5b291DB6D2E867B5971117
  AI Token:    0x02344970FAEd3241F0581a0977167ba636a63019
  Swap Router: 0x8458ee1e5eD6c35b3bDA10ae0666C745BfbB7E85
```

### Option 2: Manual Forge Commands

For more control, run the forge scripts directly.

#### Step 1: Deploy

```bash
forge script script/DeployBuybackVault.s.sol:DeployBuybackVault \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    --verifier blockscout \
    --verifier-url $VERIFIER_URL \
    -vvvv
```

**Required env vars:**
- `DEPLOYER_KEY`
- `AI_TOKEN`
- `TREASURY`
- `SWAP_ROUTER`
- `OWNER`

#### Step 2: Setup

See [SETUP.md](./SETUP.md) for post-deployment configuration.

#### Step 3: Verify

```bash
export DEPLOYED_VAULT=<deployed-proxy-address>

forge test --match-path test/GensynMainnetFork.t.sol \
    --fork-url $RPC_URL \
    -vvv
```


## Post-Deployment Checklist

- [ ] Verify contracts on block explorer
- [ ] Confirm owner address is correct
- [ ] Confirm treasury address is correct
- [ ] Run setup script (see [SETUP.md](./SETUP.md))
- [ ] Run fork tests to verify functionality


## Deployed Addresses

After deployment, addresses are saved to:
- Testnet: `.deployed-testnet.json`
- Mainnet: `.deployed-mainnet.json`


## Troubleshooting

See [SETUP.md](./SETUP.md#troubleshooting) for common errors and solutions.