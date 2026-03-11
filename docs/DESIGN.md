# BuybackVault Design Document

## Overview

The **BuybackVault** is an upgradeable smart contract that manages automated token buybacks for the Gensyn protocol. It accepts deposits of approved tokens (ERC20 or native ETH), swaps them for the protocol's AI token via Uniswap V3, and distributes the acquired tokens according to configurable split ratios.

## Architecture

```mermaid
sequenceDiagram
    participant User as Delphi/Executor
    participant Vault as BuybackVault
    participant UniV3 as Uniswap V3 Router
    participant Treasury
    participant Burn as Burn Address (0xdEaD)

    Note over User,Vault: Phase 1: Deposit
    User->>Vault: deposit(token, amount) / depositETH()
    Vault-->>User: Emit Deposited event

    Note over User,Burn: Phase 2: Execute Buyback
    User->>Vault: executeBuyback(tokenIn, path, amountIn, amountOutMin, deadline)
    Vault->>UniV3: exactInput(swapParams)
    UniV3-->>Vault: amountOut (AI tokens)
    
    Note over Vault: Calculate splits:<br/>executorReward, burnAmount, treasuryAmount
    
    Vault->>User: transfer(executorReward)
    Vault->>Burn: transfer(burnAmount)
    Vault->>Treasury: transfer(treasuryAmount)
    Vault-->>User: Emit BuybackExecuted event
```

## Core Components

### State Variables

| Variable | Type | Description |
|----------|------|-------------|
| `aiToken` | `address` | Target token to acquire via buybacks |
| `treasury` | `address` | Recipient of treasury portion |
| `swapRouter` | `address` | Uniswap V3 SwapRouter address |
| `weth` | `address` | WETH contract for ETH handling |
| `burnBps` | `uint16` | Basis points for burn (of post-executor amount) |
| `executorRewardBps` | `uint16` | Basis points for executor reward |
| `twapWindow` | `uint32` | TWAP observation window in seconds |
| `maxSlippageBps` | `uint16` | Maximum allowed slippage from TWAP |
| `epochDuration` | `uint32` | Duration of volume limit epochs |
| `epochStart` | `uint32` | Timestamp of current epoch start |

### Mappings

| Mapping | Description |
|---------|-------------|
| `approvedTokens` | Whitelist of tokens that can be deposited/swapped |
| `approvedPaths` | Whitelist of Uniswap V3 swap paths |
| `pathPools` | Pool addresses for TWAP calculation per path |
| `tokenEpochVolumeLimit` | Per-token volume limit per epoch |
| `tokenEpochVolume` | Current epoch volume consumed per token |

## Additional Flow Details

### ERC20 Deposit Flow

```mermaid
sequenceDiagram
    participant User as Delphi
    participant Vault as BuybackVault
    participant Token as ERC20 Token

    User->>Vault: deposit(token, amount)
    Vault->>Vault: Check token approved
    Vault->>Vault: Check amount > 0
    Vault->>Token: transferFrom(user, vault, amount)
    Token-->>Vault: Transfer success
    Vault-->>User: Emit Deposited event
```

### ETH Deposit Flow

```mermaid
sequenceDiagram
    participant User as Delphi
    participant Vault as BuybackVault

    User->>Vault: depositETH{value: amount}()
    Note over Vault: ETH held as native balance
    Vault-->>User: Emit Deposited event

    Note over User,Vault: Alternative: send ETH directly
    User->>Vault: receive(){value: amount}
    Vault-->>User: Emit Deposited event
```

### Epoch Volume Management

```mermaid
stateDiagram-v2
    [*] --> CheckEpoch: executeBuyback called
    
    CheckEpoch --> SameEpoch: block.timestamp < epochStart + epochDuration
    CheckEpoch --> NewEpoch: block.timestamp >= epochStart + epochDuration
    
    NewEpoch --> ResetVolume: Reset tokenEpochVolume[token] = 0
    ResetVolume --> UpdateEpoch: Update epochStart, epochIndex
    UpdateEpoch --> CheckLimit
    
    SameEpoch --> CheckLimit
    
    CheckLimit --> AddVolume: volume + amountIn <= limit
    CheckLimit --> Revert: volume + amountIn > limit
    
    AddVolume --> [*]: Continue execution
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
        N[emergencySweep]
        O[upgradeToAndCall]
    end
    
    subgraph Public
        P[deposit]
        Q[depositETH]
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
- Deposits remain available (allows recovery)

### Upgradeability
- UUPS proxy pattern with `Ownable2Step` for safe ownership transfer
- Storage gap (`__gap[41]`) for future upgrades

### Input Validation
- All addresses validated against zero address
- BPS values validated to not exceed 10,000
- Path structure validated for Uniswap V3 format
- Amounts validated against overflow (uint128 max)

## Contract Inheritance

```mermaid
classDiagram
    class BuybackVault {
        +deposit()
        +depositETH()
        +executeBuyback()
        +approvePath()
        +approveToken()
        -_checkAndUpdateEpoch()
        -_computeMultiHopTwapFloor()
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
        +deposit()
        +executeBuyback()
    }
    
    BuybackVault --|> UUPSUpgradeable
    BuybackVault --|> Ownable2StepUpgradeable
    BuybackVault --|> PausableUpgradeable
    BuybackVault --|> ReentrancyGuard
    BuybackVault ..|> IBuybackVault
```

## Events

| Event | Parameters | Description |
|-------|------------|-------------|
| `Deposited` | token, depositor, amount | Emitted on successful deposit |
| `BuybackExecuted` | tokenIn, amountIn, amountOut, executorReward, burnAmount, treasuryAmount | Emitted on successful buyback |
| `PathApproved` | pathHash | Emitted when a swap path is approved |
| `PathRevoked` | pathHash | Emitted when a swap path is revoked |
| `TokenApproved` | token | Emitted when a token is approved |
| `TokenRevoked` | token | Emitted when a token is revoked |

## Error Codes

| Error | Condition |
|-------|-----------|
| `ZeroAddress` | Address parameter is zero |
| `BpsOverflow` | BPS values sum exceeds 10,000 |
| `TwapWindowTooShort` | TWAP window < 1800 seconds |
| `SlippageTooHigh` | Max slippage > 500 bps (5%) |
| `TokenNotApproved` | Token not in whitelist |
| `PathNotApproved` | Swap path not approved |
| `DeadlineExpired` | Transaction deadline passed |
| `SlippageExceeded` | amountOutMin below TWAP floor |
| `EpochLimitExceeded` | Volume limit reached for epoch |
| `WethNotConfigured` | ETH swap attempted without WETH set |
