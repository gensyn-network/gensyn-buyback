// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "../src/BuybackVault.sol";

/// @notice Executor bot script for BuybackVault.executeBuyback().
///
/// Dry-run (no broadcast):
///   forge script script/ExecuteBuyback.s.sol --rpc-url $RPC_URL -vv
///
/// Live execution:
///   forge script script/ExecuteBuyback.s.sol --rpc-url $RPC_URL --broadcast -vv
///
/// Required env vars:
///   VAULT         - BuybackVault proxy address
///   INPUT_TOKEN   - ERC-20 address to spend (use zero address for ETH buybacks)
///   APPROVED_PATH - ABI-encoded swap path bytes (same as used in approvePath)
///
/// Optional env vars:
///   EXECUTOR_KEY  - Private key for broadcasting (omit for dry-run)
///   AMOUNT_IN     - Override amount (default: full vault balance, capped by epoch)
contract ExecuteBuyback is Script {
    using SafeCast for int256;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    // Flag a potential sandwich when amountOut is within this many BPS of amountOutMin.
    // See monitoring-alerts-full.md Alert #5 and #6.
    uint256 private constant SANDWICH_SIGNAL_BPS = 500;

    error InvalidTick();

    function run() external {
        address vaultAddr = vm.envAddress("VAULT");
        address tokenIn = vm.envAddress("INPUT_TOKEN");
        bytes memory path = vm.envBytes("APPROVED_PATH");
        uint256 amountInOverride = vm.envOr("AMOUNT_IN", uint256(0));

        BuybackVault vault = BuybackVault(payable(vaultAddr));

        _preflight(vault, tokenIn, path);

        address effectiveTokenIn = tokenIn == address(0) ? vault.weth() : tokenIn;

        uint256 amountIn = amountInOverride > 0
            ? amountInOverride
            : _resolveAmountIn(vault, tokenIn, effectiveTokenIn);

        if (amountIn == 0) {
            console2.log("[SKIP] Vault has no balance or epoch limit exhausted.");
            return;
        }

        uint256 amountOutMin = _computeMultiHopTwapFloor(vault, path, effectiveTokenIn, amountIn);

        _logPreExecution(vaultAddr, tokenIn, amountIn, amountOutMin, vault);

        uint256 executorKey = vm.envOr("EXECUTOR_KEY", uint256(0));
        if (executorKey == 0) {
            console2.log("[DRY RUN] Set EXECUTOR_KEY to broadcast the transaction.");
            return;
        }

        vm.startBroadcast(executorKey);
        vault.executeBuyback(tokenIn, path, amountIn, amountOutMin);
        vm.stopBroadcast();

        console2.log("[OK] Buyback executed.");
    }

    // ─── Pre-flight checks ────────────────────────────────────────────────────

    function _preflight(BuybackVault vault, address tokenIn, bytes memory path) internal view {
        require(!vault.paused(), "vault is paused");
        require(vault.approvedTokens(tokenIn), "tokenIn not approved");
        require(vault.approvedPaths(keccak256(path)), "path not approved");
        if (tokenIn == address(0)) {
            require(vault.ethBuybackEnabled(), "ETH buyback disabled");
            require(vault.weth() != address(0), "WETH not configured");
        }
    }

    // ─── Amount resolution ────────────────────────────────────────────────────

    function _resolveAmountIn(BuybackVault vault, address tokenIn, address effectiveTokenIn)
        internal
        view
        returns (uint256)
    {
        uint256 vaultBalance =
            tokenIn == address(0) ? address(vault).balance : IERC20(tokenIn).balanceOf(address(vault));

        uint256 epochCapacity = _epochRemainingCapacity(vault, effectiveTokenIn);
        return Math.min(vaultBalance, epochCapacity);
    }

    function _epochRemainingCapacity(BuybackVault vault, address effectiveTokenIn) internal view returns (uint256) {
        uint256 limit = vault.tokenEpochVolumeLimit(effectiveTokenIn);
        if (limit == 0) return type(uint256).max;

        uint256 currentVolume = vault.tokenEpochIndex(effectiveTokenIn) == vault.epochIndex()
            ? vault.tokenEpochVolume(effectiveTokenIn)
            : 0;

        return limit > currentVolume ? limit - currentVolume : 0;
    }

    // ─── TWAP floor computation ───────────────────────────────────────────────
    //
    // Replicates BuybackVault._computeMultiHopTwapFloor so the bot and the vault
    // agree on the minimum acceptable output before broadcasting.

    function _computeMultiHopTwapFloor(
        BuybackVault vault,
        bytes memory path,
        address effectiveTokenIn,
        uint256 amountIn
    ) internal view returns (uint256) {
        bytes32 pathKey = keccak256(path);
        uint256 numHops = (path.length - 20) / 23;

        uint256 currentAmount = amountIn;
        address currentTokenIn = effectiveTokenIn;

        for (uint256 i = 0; i < numHops; i++) {
            address hopTokenOut;
            // path bytes layout: [token(20)] [fee(3)] [token(20)] ...
            // hop i tokenOut is at byte offset: i*23 + 23
            assembly {
                hopTokenOut := shr(96, mload(add(add(path, 0x20), add(mul(i, 23), 23))))
            }
            address pool = vault.pathPools(pathKey, i);
            require(pool != address(0), "pool not found for hop");
            currentAmount = _hopTwapQuote(pool, currentTokenIn, hopTokenOut, currentAmount, vault.twapWindow());
            currentTokenIn = hopTokenOut;
        }

        return currentAmount * (BPS_DENOMINATOR - vault.maxSlippageBps()) / BPS_DENOMINATOR;
    }

    function _hopTwapQuote(address pool, address tokenIn, address tokenOut, uint256 amountIn, uint32 twapWindow)
        internal
        view
        returns (uint256)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 meanTick = int256(tickDelta / int56(uint56(twapWindow))).toInt24();
        if (tickDelta < 0 && (tickDelta % int56(uint56(twapWindow)) != 0)) meanTick--;

        uint160 sqrtRatioX96 = _getSqrtRatioAtTick(meanTick);

        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return tokenIn < tokenOut
                ? Math.mulDiv(ratioX192, amountIn, 1 << 192)
                : Math.mulDiv(1 << 192, amountIn, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(uint256(sqrtRatioX96), uint256(sqrtRatioX96), 1 << 64);
            return tokenIn < tokenOut
                ? Math.mulDiv(ratioX128, amountIn, 1 << 128)
                : Math.mulDiv(1 << 128, amountIn, ratioX128);
        }
    }

    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        int24 minTick = -887272;
        int24 maxTick = 887272;
        if (tick < minTick || tick > maxTick) revert InvalidTick();

        uint256 absTick = tick < 0 ? (-int256(tick)).toUint256() : int256(tick).toUint256();

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    // ─── Logging ──────────────────────────────────────────────────────────────

    function _logPreExecution(
        address vaultAddr,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        BuybackVault vault
    ) internal view {
        uint256 epochCapacity = _epochRemainingCapacity(vault, tokenIn == address(0) ? vault.weth() : tokenIn);
        uint256 epochLimit = vault.tokenEpochVolumeLimit(tokenIn == address(0) ? vault.weth() : tokenIn);

        console2.log("=== BuybackVault Executor ===");
        console2.log("Vault:         ", vaultAddr);
        console2.log("TokenIn:       ", tokenIn);
        {
            string memory frac = vm.toString(amountIn % 1e6);
            while (bytes(frac).length < 6) frac = string.concat("0", frac);
            bytes memory fracBytes = bytes(frac);
            uint256 len = fracBytes.length;
            while (len > 1 && fracBytes[len - 1] == bytes1("0")) len--;
            bytes memory trimmed = new bytes(len);
            for (uint256 i = 0; i < len; i++) trimmed[i] = fracBytes[i];
            console2.log(string.concat("AmountIn:       $", vm.toString(amountIn / 1e6), ".", string(trimmed)));
        }
        console2.log("AmountOutMin:  ", amountOutMin);
        if (amountOutMin > 0) {
            // price × 1e6 (microUSDC); split into integer + 6-digit fractional parts for display.
            uint256 price = amountIn * 1e18 / amountOutMin;
            string memory frac = vm.toString(price % 1e6);
            while (bytes(frac).length < 6) frac = string.concat("0", frac);
            console2.log(string.concat("Price per AI: $", vm.toString(price / 1e6), ".", frac));
        }
        console2.log("TwapWindow:    ", vault.twapWindow());
        console2.log("MaxSlippageBps:", vault.maxSlippageBps());
        if (epochLimit > 0) {
            console2.log("EpochCapacity: ", epochCapacity);
            console2.log("EpochLimit:    ", epochLimit);
        }
    }
}
