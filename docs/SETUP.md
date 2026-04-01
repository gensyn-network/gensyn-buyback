# BuybackVault Setup & Configuration Guide

This document covers post-deployment setup and configuration for the BuybackVault contract.

> **Looking to deploy?** See [DEPLOYMENT.md](./DEPLOYMENT.md) first.

---

## Table of Contents

- [Environment Variables](#environment-variables)
- [Default Configurations](#default-configurations)
- [Path Encoding](#path-encoding)
- [Setup Script](#setup-script)
- [Manual Configuration](#manual-configuration)
- [Troubleshooting](#troubleshooting)

---

## Environment Variables

### Required for Setup

| Variable | Description |
|----------|-------------|
| `OWNER_KEY` | Owner's private key |
| `VAULT` | Deployed vault proxy address |
| `INPUT_TOKEN` | Token to approve for buybacks |
| `APPROVED_PATH` | Encoded swap path (see [Path Encoding](#path-encoding)) |

### Optional

| Variable | Description |
|----------|-------------|
| `WETH` | WETH address (for ETH buybacks) |
| `VOLUME_LIMIT` | Volume limit per epoch per token |

---

## Default Configurations

### Gensyn Testnet

Copy these values directly to your `.env` file:

```bash
# Network
RPC_URL=https://gensyn-testnet.g.alchemy.com/public
VERIFIER_URL=https://gensyn-testnet.explorer.alchemy.com/api/

# Core Addresses
AI_TOKEN=0x02344970FAEd3241F0581a0977167ba636a63019
SWAP_ROUTER=0x8458ee1e5eD6c35b3bDA10ae0666C745BfbB7E85
WETH=0xCa086d8bA028B799B089c73DD10D722B9a5c6577

# Setup Configuration (USDC.e → AI)
INPUT_TOKEN=0x72936441E8791A96eF283464BEaB677F9C36a162
APPROVED_PATH=0x72936441e8791a96ef283464beab677f9c36a162000bb802344970faed3241f0581a0977167ba636a63019
```

#### Testnet Address Reference

| Contract | Address | Notes |
|----------|---------|-------|
| AI Token | `0x02344970FAEd3241F0581a0977167ba636a63019` | ERC20 |
| SwapRouter02 | `0x8458ee1e5eD6c35b3bDA10ae0666C745BfbB7E85` | Uniswap V3 |
| WETH | `0xCa086d8bA028B799B089c73DD10D722B9a5c6577` | Wrapped ETH |
| USDC.e | `0x72936441E8791A96eF283464BEaB677F9C36a162` | Bridged USDC |
| USDC.e/AI Pool | `0x046B3362C4ff28758A22c5C61C0D78AA6013A9eC` | 0.3% fee tier |

### Gensyn Mainnet

> **Note:** Mainnet addresses will be added after launch.

```bash
# Network
RPC_URL=https://gensyn-mainnet.g.alchemy.com/public
VERIFIER_URL=https://gensyn-mainnet.explorer.alchemy.com/api/

# Core Addresses (TBD)
AI_TOKEN=
SWAP_ROUTER=
WETH=

# Setup Configuration (TBD)
INPUT_TOKEN=
APPROVED_PATH=
```

---

## Path Encoding

The `APPROVED_PATH` is a Uniswap V3 encoded swap path. Getting this wrong is a common source of errors.

### Format

```
tokenIn (20 bytes) + fee (3 bytes) + tokenOut (20 bytes)
```

### Fee Tiers

| Fee | Hex Value | Typical Use |
|-----|-----------|-------------|
| 0.01% | `000064` | Stable pairs (USDC/USDT) |
| 0.05% | `0001f4` | Stable/major pairs |
| 0.3% | `000bb8` | Most pairs (default) |
| 1% | `002710` | Exotic/volatile pairs |

### Example: USDC.e → AI (0.3% fee)

```
Path: 0x72936441e8791a96ef283464beab677f9c36a162000bb802344970faed3241f0581a0977167ba636a63019

Breakdown:
┌─────────────────────────────────────────┬────────┬──────────────────────────────────────────┐
│ USDC.e (20 bytes)                       │ Fee    │ AI Token (20 bytes)                      │
├─────────────────────────────────────────┼────────┼──────────────────────────────────────────┤
│ 72936441e8791a96ef283464beab677f9c36a162│ 000bb8 │ 02344970faed3241f0581a0977167ba636a63019 │
└─────────────────────────────────────────┴────────┴──────────────────────────────────────────┘
```

### Multi-hop Paths

For routes like USDC → WETH → AI:

```
tokenA (20 bytes) + feeAB (3 bytes) + tokenB (20 bytes) + feeBC (3 bytes) + tokenC (20 bytes)
```

Example:
```bash
# USDC → WETH (0.05%) → AI (0.3%)
APPROVED_PATH=$(cast concat-hex \
  0x72936441E8791A96eF283464BEaB677F9C36a162 \
  0x0001f4 \
  0xCa086d8bA028B799B089c73DD10D722B9a5c6577 \
  0x000bb8 \
  0x02344970FAEd3241F0581a0977167ba636a63019)
```

### Generating Paths with Cast

```bash
# Single hop
APPROVED_PATH=$(cast concat-hex $INPUT_TOKEN 0x000bb8 $AI_TOKEN)

# Verify
echo "Path: $APPROVED_PATH"
echo "Length: $(echo -n $APPROVED_PATH | wc -c) chars (should be 88 for single hop)"
```

### PATH_POOLS

Pool addresses are no longer supplied manually. When `approvePath` is called, the contract
automatically derives the correct pool address for each hop by querying the Uniswap V3 factory
(`IUniswapV3Factory.getPool(tokenIn, tokenOut, fee)`). The call reverts with `PoolNotFound` if
no pool exists for a hop.

---

## Setup Script

After deployment, run the setup script to configure the vault:

```bash
# Set required variables
export VAULT=<deployed-proxy-address>
export OWNER_KEY=<owner-private-key>

# Run setup
forge script script/SetupBuybackVault.s.sol:SetupBuybackVault \
    --rpc-url $RPC_URL \
    --broadcast \
    -vvvv
```

Or use the bash script:

```bash
./script/deploy-mainnet.sh setup
```

### What Setup Does

1. **Approves input token** - Allows the token to be used for buybacks
2. **Approves swap path** - Registers the path with its TWAP pools
3. **Sets WETH** (if provided) - Enables ETH buybacks
4. **Sets volume limit** (if provided) - Caps buyback volume per epoch

---

## Manual Configuration

If you need to configure the vault manually (e.g., from a multisig):

### Approve a Token

```solidity
vault.approveToken(tokenAddress);
```

```bash
cast send $VAULT "approveToken(address)" $INPUT_TOKEN --private-key $OWNER_KEY --rpc-url $RPC_URL
```

### Approve a Path

```solidity
vault.approvePath(path, pools);
```

```bash
# Note: Arrays need special encoding
cast send $VAULT "approvePath(bytes,address[])" \
    $APPROVED_PATH \
    "[$PATH_POOLS]" \
    --private-key $OWNER_KEY \
    --rpc-url $RPC_URL
```

### Set WETH

```bash
cast send $VAULT "setWeth(address)" $WETH --private-key $OWNER_KEY --rpc-url $RPC_URL
```

### Set Volume Limit

```bash
cast send $VAULT "setTokenEpochVolumeLimit(address,uint256)" $INPUT_TOKEN $VOLUME_LIMIT \
    --private-key $OWNER_KEY --rpc-url $RPC_URL
```

---

## Troubleshooting

### "TokenNotApproved" Error

The input token hasn't been approved.

```bash
# Check if approved
cast call $VAULT "approvedTokens(address)(bool)" $INPUT_TOKEN --rpc-url $RPC_URL

# Approve it
cast send $VAULT "approveToken(address)" $INPUT_TOKEN --private-key $OWNER_KEY --rpc-url $RPC_URL
```

### "PathNotApproved" Error

The swap path hasn't been approved or was encoded incorrectly.

```bash
# Get path hash
PATH_HASH=$(cast keccak256 $APPROVED_PATH)

# Check if approved
cast call $VAULT "approvedPaths(bytes32)(bool)" $PATH_HASH --rpc-url $RPC_URL

# If false, approve it
cast send $VAULT "approvePath(bytes,address[])" $APPROVED_PATH "[$PATH_POOLS]" \
    --private-key $OWNER_KEY --rpc-url $RPC_URL
```

### "SlippageExceeded" Error

The actual swap output is below the TWAP-calculated minimum. Causes:
- Pool has low liquidity
- Large price movement since TWAP window
- Incorrect pool address in `PATH_POOLS`

```bash
# Check pool liquidity
cast call $PATH_POOLS "liquidity()(uint128)" --rpc-url $RPC_URL
```

### Path Encoding Issues

Verify your path is correctly encoded:

```bash
# Should be 86 hex chars (43 bytes) for single hop
echo "Path length: $(echo -n ${APPROVED_PATH#0x} | wc -c)"

# Decode and verify
echo "Token In:  0x${APPROVED_PATH:2:40}"
echo "Fee:       0x${APPROVED_PATH:42:6}"
echo "Token Out: 0x${APPROVED_PATH:48:40}"
```

### RPC Rate Limiting (429 Error)

The public RPC has rate limits. Solutions:
- Wait and retry
- Use a private RPC endpoint
- Add delays between calls

---

## Verification Checklist

After setup, verify everything is configured:

```bash
# Check token approved
cast call $VAULT "approvedTokens(address)(bool)" $INPUT_TOKEN --rpc-url $RPC_URL
# Expected: true

# Check path approved
cast call $VAULT "approvedPaths(bytes32)(bool)" $(cast keccak256 $APPROVED_PATH) --rpc-url $RPC_URL
# Expected: true

# Check WETH (if set)
cast call $VAULT "weth()(address)" --rpc-url $RPC_URL
# Expected: $WETH address

# Check owner
cast call $VAULT "owner()(address)" --rpc-url $RPC_URL
# Expected: Your owner address
```

Or run the fork tests:

```bash
export DEPLOYED_VAULT=$VAULT
forge test --match-path test/GensynMainnetFork.t.sol --fork-url $RPC_URL -vvv
```
