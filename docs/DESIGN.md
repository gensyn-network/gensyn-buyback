# BuybackVault Design Document

## Overview

The **BuybackVault** is an upgradeable smart contract that manages automated token buybacks for the Gensyn protocol. It holds approved tokens (ERC20 or native ETH) received directly, swaps them for the protocol's AI token via Uniswap V3, and distributes the acquired tokens according to configurable split ratios.

## Architecture

```mermaid
sequenceDiagram
    participant User as Delphi/Executor
    participant Vault as BuybackVault
    participant WETH as WETH Contract
    participant Router as SwapRouter02
    participant Treasury
    participant AiToken as AI Token (IBurnable)

    Note over User,Vault: Tokens sent directly to vault (ERC20 transfer or ETH)

    Note over User,AiToken: Execute Buyback
    User->>Vault: executeBuyback(tokenIn, path, amountIn, amountOutMin)

    Note over Vault: Validate params, path, epoch limits
    Note over Vault: Check amountOutMin >= TWAP floor

    alt tokenIn == address(0) (ETH)
        Vault->>WETH: deposit{value: amountIn}()
    end
    Vault->>Vault: forceApprove(router, amountIn)
    Vault->>Router: exactInput(path, recipient, amountIn, amountOutMin)
    Router-->>Vault: amountOut (AI tokens)
    Vault->>Vault: forceApprove(router, 0)

    Note over Vault: Calculate splits:<br/>executorReward, burnAmount, treasuryAmount

    Vault->>User: transfer(executorReward)
    Vault->>AiToken: burn(burnAmount)
    Vault->>Treasury: transfer(treasuryAmount)
    Vault-->>User: Emit BuybackExecuted event
```

## Core Components

### State Variables

| Variable            | Type      | Description                                      |
| ------------------- | --------- | ------------------------------------------------ |
| `aiToken`           | `address` | Target token to acquire via buybacks             |
| `treasury`          | `address` | Recipient of treasury portion                    |
| `swapRouter`        | `address` | Uniswap V3 SwapRouter02 address                  |
| `weth`              | `address` | WETH contract for ETH handling                   |
| `burnBps`           | `uint16`  | Basis points for burn (of post-executor amount)  |
| `executorRewardBps` | `uint16`  | Basis points for executor reward                 |
| `twapWindow`        | `uint32`  | TWAP observation window in seconds               |
| `maxSlippageBps`    | `uint16`  | Maximum allowed slippage from TWAP               |
| `epochDuration`     | `uint32`  | Duration of volume limit epochs                  |
| `epochStart`        | `uint32`  | Timestamp of current epoch start                 |
| `epochIndex`        | `uint32`  | Current epoch index (incremented on epoch reset) |

### Mappings

| Mapping                 | Description                                                               |
| ----------------------- | ------------------------------------------------------------------------- |
| `approvedTokens`        | Whitelist of tokens that can be swapped                                   |
| `approvedPaths`         | Whitelist of Uniswap V3 swap paths (keyed by `keccak256(path)`)           |
| `pathPools`             | Pool addresses for TWAP calculation per path (keyed by `keccak256(path)`) |
| `tokenEpochVolumeLimit` | Per-token volume limit per epoch                                          |
| `tokenEpochVolume`      | Current epoch volume consumed per token                                   |
| `tokenEpochIndex`       | Epoch index when token volume was last updated                            |

## Additional Flow Details

### Receiving Funds

The vault receives funds directly without dedicated deposit functions:

- **ERC20 tokens**: Sent via standard `transfer()` to the vault address
- **Native ETH**: Sent directly to the vault (handled by `receive()` function)

### Epoch Volume Management

```mermaid
stateDiagram-v2
    [*] --> CheckEpochDuration: executeBuyback called

    CheckEpochDuration --> Skip: epochDuration == 0
    CheckEpochDuration --> CheckEpoch: epochDuration > 0

    CheckEpoch --> SameEpoch: block.timestamp < epochStart + epochDuration
    CheckEpoch --> NewEpoch: block.timestamp >= epochStart + epochDuration

    NewEpoch --> UpdateEpoch: Update epochStart, epochIndex++
    UpdateEpoch --> CheckLimit

    SameEpoch --> CheckLimit

    CheckLimit --> Skip: tokenEpochVolumeLimit[token] == 0
    CheckLimit --> CheckVolume: limit > 0

    CheckVolume --> ResetIfNewEpoch: tokenEpochIndex[token] != epochIndex
    CheckVolume --> AddVolume: tokenEpochIndex[token] == epochIndex

    ResetIfNewEpoch --> AddVolume: currentVolume = 0

    AddVolume --> UpdateVolume: volume + amountIn <= limit
    AddVolume --> Revert: volume + amountIn > limit

    UpdateVolume --> [*]: Update tokenEpochVolume, tokenEpochIndex
    Skip --> [*]: Continue execution
    Revert --> [*]: EpochLimitExceeded
```

## Token Distribution

```mermaid
pie title AI Token Distribution (Example: 70% burn, 1% executor)
    "Burn (70% of remainder)" : 69.3
    "Treasury (30% of remainder)" : 29.7
    "Executor Reward (1%)" : 1.0
```

The distribution formula:

1. **Executor Reward**: `amountOut * executorRewardBps / 10000`
2. **Burn Amount**: `(amountOut - executorReward) * burnBps / 10000`
3. **Treasury Amount**: `amountOut - executorReward - burnAmount`

## TWAP Slippage Protection

```mermaid
graph LR
    subgraph TWAP Calculation
        A[Get tick cumulatives<br/>at t and t-twapWindow] --> B[Calculate average tick]
        B --> C[Convert tick to price]
        C --> D[Apply maxSlippageBps]
        D --> E[TWAP Floor]
    end

    subgraph Validation
        E --> F{amountOutMin >= floor?}
        F -->|Yes| G[Proceed with swap]
        F -->|No| H[Revert SlippageExceeded]
    end
```

For multi-hop swaps, the TWAP floor is computed by chaining quotes through each pool in the path.

## Access Control

```mermaid
graph TD
    subgraph Owner Only
        A[setAiToken]
        B[setTreasury]
        C[setSwapRouter]
        D[setBurnBps]
        E[setExecutorRewardBps]
        F[setTwapWindow]
        G[setMaxSlippageBps]
        H[setEpochConfig]
        I[setTokenEpochVolumeLimit]
        J[setWeth]
        K[approveToken / revokeToken]
        L[approvePath / revokePath]
        M[pause / unpause]
        O[upgradeToAndCall]
    end

    subgraph Owner Only + When Paused
        N[emergencySweep]
    end

    subgraph Public
        R[executeBuyback]
    end

    subgraph When Not Paused
        R
    end
```

## Security Features

### Reentrancy Protection

- `executeBuyback` uses OpenZeppelin's `ReentrancyGuard` (`nonReentrant` modifier)

### Pausability

- Owner can pause/unpause the contract
- `executeBuyback` is blocked when paused
- `emergencySweep` only available when paused (allows recovery)

### Upgradeability

- UUPS proxy pattern with `Ownable2Step` for safe ownership transfer
- Storage gap (`__gap[41]`) for future upgrades

### Input Validation

- All addresses validated against zero address
- BPS values validated to not exceed 10,000 (combined `burnBps + executorRewardBps`)
- Path structure validated for Uniswap V3 format (minimum 43 bytes, `(length - 20) % 23 == 0`)
- Amounts validated against overflow (uint128 max)
- Pool addresses are derived from the Uniswap V3 factory (`IUniswapV3Factory.getPool`) on each `approvePath` call — owners cannot supply arbitrary pool addresses
- WETH address validated as contract (not EOA) when set

## Contract Inheritance

```mermaid
classDiagram
    class BuybackVault {
        +executeBuyback()
        +approvePath()
        +revokePath()
        +approveToken()
        +revokeToken()
        +emergencySweep()
        +setAiToken()
        +setTreasury()
        +setSwapRouter()
        +setBurnBps()
        +setExecutorRewardBps()
        +setTwapWindow()
        +setMaxSlippageBps()
        +setEpochConfig()
        +setTokenEpochVolumeLimit()
        +setWeth()
        -_checkAndUpdateEpoch()
        -_computeMultiHopTwapFloor()
        -_computeTwapHopQuote()
        -_validateBuybackParams()
        -_validatePathEndpoints()
        -_validateTwapFloor()
        -_resolveEffectiveTokenIn()
        -_requireApprovedPath()
        -_executeSwap()
        -_distributeOutput()
    }

    class UUPSUpgradeable {
        +upgradeToAndCall()
        #_authorizeUpgrade()
    }

    class Ownable2StepUpgradeable {
        +owner()
        +transferOwnership()
        +acceptOwnership()
    }

    class PausableUpgradeable {
        +paused()
        +pause()
        +unpause()
    }

    class ReentrancyGuard {
        #nonReentrant
    }

    class IBuybackVault {
        <<interface>>
        +executeBuyback()
        +approvePath()
        +revokePath()
    }

    BuybackVault --|> UUPSUpgradeable
    BuybackVault --|> Ownable2StepUpgradeable
    BuybackVault --|> PausableUpgradeable
    BuybackVault --|> ReentrancyGuard
    BuybackVault ..|> IBuybackVault
```

## Events

### Core Events

| Event             | Parameters                                                               | Description                                                    |
| ----------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------- |
| `BuybackExecuted` | tokenIn, amountIn, amountOut, executorReward, burnAmount, treasuryAmount | Emitted on successful buyback                                  |
| `PathApproved`    | path, derivedPools                                                       | Emitted when a swap path is approved (includes factory-derived pool addresses) |
| `PathRevoked`     | path                                                                     | Emitted when a swap path is revoked                            |
| `TokenApproved`   | token                                                                    | Emitted when a token is approved                               |
| `TokenRevoked`    | token                                                                    | Emitted when a token is revoked                                |
| `EmergencySwept`  | token, to, amount                                                        | Emitted when funds are swept during emergency                  |

### Configuration Update Events

| Event                          | Parameters               | Description                                          |
| ------------------------------ | ------------------------ | ---------------------------------------------------- |
| `AiTokenUpdated`               | oldToken, newToken       | Emitted when AI token address is changed             |
| `TreasuryUpdated`              | oldTreasury, newTreasury | Emitted when treasury address is changed             |
| `SwapRouterUpdated`            | oldRouter, newRouter     | Emitted when swap router address is changed          |
| `BurnBpsUpdated`               | oldBps, newBps           | Emitted when burn basis points is changed            |
| `ExecutorRewardBpsUpdated`     | oldBps, newBps           | Emitted when executor reward basis points is changed |
| `TwapWindowUpdated`            | oldWindow, newWindow     | Emitted when TWAP window is changed                  |
| `MaxSlippageBpsUpdated`        | oldBps, newBps           | Emitted when max slippage basis points is changed    |
| `EpochConfigUpdated`           | duration                 | Emitted when epoch duration is changed               |
| `TokenEpochVolumeLimitUpdated` | token, newLimit          | Emitted when token epoch volume limit is changed     |
| `WethUpdated`                  | oldWeth, newWeth         | Emitted when WETH address is changed                 |

## Error Codes

| Error                   | Condition                                      |
| ----------------------- | ---------------------------------------------- |
| `ZeroAddress`           | Address parameter is zero                      |
| `BpsOverflow`           | BPS values sum exceeds 10,000                  |
| `TwapWindowTooShort`    | TWAP window < 1800 seconds                     |
| `SlippageTooHigh`       | Max slippage > 500 bps (5%)                    |
| `EpochDurationOverflow` | Epoch duration exceeds uint32 max              |
| `TokenNotApproved`      | Token not in whitelist                         |
| `ZeroAmount`            | Amount parameter is zero                       |
| `AmountTooLarge`        | Amount exceeds uint128 max                     |
| `InvalidPath`           | Path structure invalid for Uniswap V3          |
| `WethNotConfigured`     | ETH swap attempted without WETH set            |
| `TokenInMismatch`       | Path first token doesn't match tokenIn         |
| `InvalidPathOutput`     | Path last token doesn't match aiToken          |
| `PathNotApproved`       | Swap path not approved                         |
| `SlippageExceeded`      | amountOutMin below TWAP floor                  |
| `PoolNotFound`          | Factory returned zero address for a path hop               |
| `EpochLimitExceeded`    | Volume limit reached for epoch                             |
| `EthTransferFailed`     | Native ETH transfer failed                     |
| `NotAContract`          | Address has no code (used for WETH validation) |
