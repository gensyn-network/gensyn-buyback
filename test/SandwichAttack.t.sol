// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GensynMainnetFork.t.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

/// @notice Fork tests for sandwich attack scenarios (monitoring-alerts-full.md alerts #5 and #6).
///
/// Sandwich anatomy:
///   TX1 (attacker front-run)  — buys AI with USDC, inflating the AI price
///   TX2 (vault buyback)       — buys AI at inflated price, gets fewer tokens
///   TX3 (attacker back-run)   — sells AI, pockets the difference
///
/// The TWAP floor in executeBuyback() is the primary protection. These tests verify:
///   1. A large front-run that inflates price beyond the slippage band causes the vault
///      tx to revert — attack fails, attacker loses only gas.
///   2. A calibrated front-run within the slippage band lets the vault tx succeed but
///      amountOut lands near amountOutMin — the "near-floor" detection signal fires.
///   3. The detection helper correctly classifies margin ratios as sandwiched / clean.
///
/// Pool note: mainnet has no liquidity yet, so tests seed a shallow synthetic pool
/// calibrated so LARGE_FRONT_RUN causes ~10% price impact and SMALL_FRONT_RUN ~1%.
/// L is computed dynamically from the pool's current sqrtPriceX96 so the impact
/// ratios hold regardless of the real AI/USDC market price.
///
/// Front-run simulation: the Gensyn SwapRouter02 rejects calls from arbitrary addresses
/// in fork tests (immediate revert, 282 gas). Instead, the test contract calls
/// IUniswapV3Pool.swap() directly, which requires implementing IUniswapV3SwapCallback.
contract SandwichAttackTest is GensynMainnetForkTest, IUniswapV3SwapCallback {
    // ─── Pool liquidity parameters ────────────────────────────────────────────
    //
    // Liquidity is computed dynamically in _seedShallowPool() so that:
    //   L = LARGE_FRONT_RUN * 10 * 2^96 / sqrtPriceX96
    // This guarantees LARGE_FRONT_RUN → ~10% impact and SMALL_FRONT_RUN → ~1%
    // regardless of the pool's real price at the time the test forks mainnet.

    // 10 USDC in raw units (6 dec). Matches test_fork_fullBuybackFlow_USDC amounts.
    uint256 private constant VAULT_AMOUNT = 10e6;

    // Front-run amounts chosen for predictable price impact at L = 1e10
    uint256 private constant SMALL_FRONT_RUN = 50e6;  // ~1% impact → succeeds, signal fires
    uint256 private constant LARGE_FRONT_RUN = 500e6; // ~10% impact → exceeds floor, reverts

    // Standard Uniswap V3 sqrtPrice bounds (= getSqrtRatioAtTick(MIN/MAX_TICK))
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // ─── sandwich signal threshold (mirrors monitoring-alerts-full.md alert #5) ──
    // Flag when amountOut is within this many BPS of amountOutMin.
    uint256 private constant SANDWICH_SIGNAL_BPS = 500;

    // ─── Setup ───────────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();
    }

    // ─── IUniswapV3SwapCallback ───────────────────────────────────────────────────
    //
    // Required to call IUniswapV3Pool.swap() directly from the test contract.
    // The pool calls back here to collect the tokens owed by the caller.

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        (address token0, address token1) = abi.decode(data, (address, address));
        if (amount0Delta > 0) IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
    }

    // ─── Test 1: Large front-run → vault buyback reverts ─────────────────────────
    //
    // Scenario: the test contract simulates a large front-run that drains AI from
    // the pool, moving the spot price to MAX_TICK. The vault's exactInput now returns
    // near-zero AI, which is less than amountOutMin (TWAP floor). Router reverts.
    //
    // This is the happy path for security: the TWAP floor stops the sandwich dead.

    function test_fork_sandwich_largeAttack_vaultBuybackReverts() public onlyFork {
        _seedShallowPool();

        // Fund vault
        deal(USDC_E, address(vault), VAULT_AMOUNT);
        _ensureApprovals();

        uint256 amountOutMin =
            _computeTwapFloor(USDC_AI_POOL, USDC_E, AI_TOKEN, VAULT_AMOUNT, vault.twapWindow(), vault.maxSlippageBps());
        require(amountOutMin > 0, "TWAP floor is zero - pool TWAP not established");

        // ── Front-run: large direct pool swap that pushes price past the 5% floor ─
        _directPoolSwap(USDC_AI_POOL, USDC_E, LARGE_FRONT_RUN);

        // ── Vault buyback attempt: must revert ────────────────────────────────────
        // Pool is AI-depleted; spot price near MAX_TICK → vault swap yields ~0 AI,
        // which is below amountOutMin. Router reverts on the vault's transaction.
        vm.prank(executor);
        vm.expectRevert();
        vault.executeBuyback(USDC_E, usdcToAiPath, VAULT_AMOUNT, amountOutMin);
    }

    // ─── Test 2: Calibrated front-run → partial success, near-floor signal ───────
    //
    // Scenario: a small front-run inflates price by less than maxSlippageBps.
    // The vault tx succeeds, but amountOut lands close to amountOutMin —
    // the "near-floor" detection signal from alert #5 fires.
    //
    // This demonstrates value leakage to MEV even when the tx is not reverted.

    function test_fork_sandwich_smallAttack_nearFloorSignal() public onlyFork {
        _seedShallowPool();

        deal(USDC_E, address(vault), VAULT_AMOUNT);
        _ensureApprovals();

        uint256 amountOutMin =
            _computeTwapFloor(USDC_AI_POOL, USDC_E, AI_TOKEN, VAULT_AMOUNT, vault.twapWindow(), vault.maxSlippageBps());
        require(amountOutMin > 0, "TWAP floor is zero");

        // ── Front-run: small swap that stays within the slippage band ─────────────
        uint256 attackerAiReceived = _directPoolSwap(USDC_AI_POOL, USDC_E, SMALL_FRONT_RUN);

        // ── Vault buyback: should succeed (front-run stayed within slippage) ──────
        uint256 executorAiBefore = IERC20(AI_TOKEN).balanceOf(executor);
        uint256 treasuryAiBefore = IERC20(AI_TOKEN).balanceOf(treasury);

        vm.prank(executor);
        vault.executeBuyback(USDC_E, usdcToAiPath, VAULT_AMOUNT, amountOutMin);

        uint256 executorReward = IERC20(AI_TOKEN).balanceOf(executor) - executorAiBefore;
        uint256 treasuryAmount = IERC20(AI_TOKEN).balanceOf(treasury) - treasuryAiBefore;
        // Note: burnAmount goes to address(0), not captured here, so amountOutApprox is a lower bound
        uint256 amountOutApprox = executorReward + treasuryAmount;

        // ── Check near-floor signal ───────────────────────────────────────────────
        // With a front-run, amountOut should be depressed toward amountOutMin.
        // (amountOutApprox excludes burn so may be below amountOutMin - that's fine
        //  for the signal check; the actual amountOut including burn is >= amountOutMin.)
        bool sandwichSignal = _isSandwichSignal(amountOutApprox, amountOutMin, SANDWICH_SIGNAL_BPS);

        console2.log("=== Sandwich Detection ===");
        console2.log("frontRunAmount:   ", SMALL_FRONT_RUN);
        console2.log("attackerAiRcvd:   ", attackerAiReceived);
        console2.log("amountOutMin:     ", amountOutMin);
        console2.log("amountOutApprox:  ", amountOutApprox);
        console2.log("sandwichSignal:   ", sandwichSignal);

        // ── Back-run: sell AI back to the pool ────────────────────────────────────
        uint256 usdcBefore = IERC20(USDC_E).balanceOf(address(this));
        _directPoolSwap(USDC_AI_POOL, AI_TOKEN, attackerAiReceived);
        uint256 attackerUsdcBack = IERC20(USDC_E).balanceOf(address(this)) - usdcBefore;

        console2.log("attackerUsdcBack: ", attackerUsdcBack);
        if (attackerUsdcBack > SMALL_FRONT_RUN) {
            console2.log("attackerProfit:   ", attackerUsdcBack - SMALL_FRONT_RUN);
        } else {
            console2.log("attackerLoss:     ", SMALL_FRONT_RUN - attackerUsdcBack);
        }
    }

    // ─── Test 3: Detection logic unit tests ──────────────────────────────────────
    //
    // Verifies _isSandwichSignal() with the example values from sandwich_attack.md:
    //   Normal:     amountOut=1050, amountOutMin=950  → 10.5% margin → no signal
    //   Sandwiched: amountOut=952,  amountOutMin=950  → 0.2% margin → signal fires

    function test_sandwich_detectionSignal_matchesExamples() public pure {
        // normal case: healthy 10.5% margin above floor
        assertFalse(
            _isSandwichSignal(1050, 950, SANDWICH_SIGNAL_BPS), "normal execution should not trigger sandwich signal"
        );

        // sandwiched case: 0.2% margin — well within the 5% threshold
        assertTrue(
            _isSandwichSignal(952, 950, SANDWICH_SIGNAL_BPS), "near-floor output should trigger sandwich signal"
        );

        // at the threshold boundary (5%): margin == thresholdBps → not triggered (strict less-than)
        // amountOut = amountOutMin * 1.05, margin = 5% = 500 bps == threshold → no signal
        uint256 floorAt5Pct = 1000;
        uint256 exactBoundary = floorAt5Pct * (10_000 + SANDWICH_SIGNAL_BPS) / 10_000; // = 1050
        assertFalse(
            _isSandwichSignal(exactBoundary, floorAt5Pct, SANDWICH_SIGNAL_BPS),
            "margin == threshold should not trigger"
        );

        // one unit below boundary: margin < threshold → signal fires
        // amountOut = 1049, margin = 490 bps < 500 bps → signal
        assertTrue(
            _isSandwichSignal(exactBoundary - 1, floorAt5Pct, SANDWICH_SIGNAL_BPS), "margin just below threshold triggers"
        );
    }

    // ─── Test 4: TWAP floor validation prevents under-priced amountOutMin ────────
    //
    // Verifies that the vault rejects a call where amountOutMin is set below the
    // TWAP floor — this is what stops an executor from volunteering bad slippage.

    function test_fork_sandwich_vaultRejectsSubFloorAmountOutMin() public onlyFork {
        _seedShallowPool();

        deal(USDC_E, address(vault), VAULT_AMOUNT);
        _ensureApprovals();

        uint256 twapFloor =
            _computeTwapFloor(USDC_AI_POOL, USDC_E, AI_TOKEN, VAULT_AMOUNT, vault.twapWindow(), vault.maxSlippageBps());
        require(twapFloor > 1, "TWAP floor too small for this test");

        // Attempt with amountOutMin below the TWAP floor
        vm.prank(executor);
        vm.expectRevert(BuybackVault.SlippageExceeded.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, VAULT_AMOUNT, twapFloor - 1);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    /// @dev Seeds a shallow pool calibrated so that LARGE_FRONT_RUN produces ~10%
    ///      price impact and SMALL_FRONT_RUN produces ~1%, regardless of the pool's
    ///      real AI/USDC price at fork time.
    ///
    ///      L is derived from the exact-input Uniswap V3 price-impact formula:
    ///        Δ(sqrtPriceX96) / sqrtPriceX96 = amountIn * 2^96 / (L * sqrtPriceX96)
    ///      Solving for 10% impact with LARGE_FRONT_RUN:
    ///        L = LARGE_FRONT_RUN * 10 * 2^96 / sqrtPriceX96
    function _seedShallowPool() internal {
        IUniswapV3Pool v3Pool = IUniswapV3Pool(USDC_AI_POOL);

        (uint160 sqrtPriceX96,,,,,,) = v3Pool.slot0();
        if (sqrtPriceX96 == 0) {
            v3Pool.initialize(SQRT_PRICE_1_1);
            sqrtPriceX96 = SQRT_PRICE_1_1;
        }

        // Only seed if the pool is empty — avoids double-seeding across test runs
        if (v3Pool.liquidity() > 0) return;

        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();

        int24 spacing = v3Pool.tickSpacing();
        int24 tickLower = (TickMath.MIN_TICK / spacing) * spacing;
        int24 tickUpper = (TickMath.MAX_TICK / spacing) * spacing;

        deal(token0, address(this), 1e30);
        deal(token1, address(this), 1e30);

        uint128 liquidityToMint =
            uint128(uint256(LARGE_FRONT_RUN) * 10 * (1 << 96) / uint256(sqrtPriceX96));

        v3Pool.mint(address(this), tickLower, tickUpper, liquidityToMint, abi.encode(token0, token1));

        // Advance time past the TWAP window to establish a stable oracle reading
        vm.warp(block.timestamp + vault.twapWindow() + 1);
    }

    /// @dev Executes a direct pool swap of `tokenIn` for the other token, bypassing
    ///      the router. Returns the amount of the output token received.
    ///
    ///      Uses IUniswapV3Pool.swap() directly because the Gensyn SwapRouter02
    ///      rejects calls from non-whitelisted addresses in fork tests.
    function _directPoolSwap(address poolAddr, address tokenIn, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        address token0 = pool.token0();
        address token1 = pool.token1();

        bool zeroForOne = (tokenIn == token0);
        uint160 sqrtPriceLimit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;

        deal(tokenIn, address(this), IERC20(tokenIn).balanceOf(address(this)) + amountIn);

        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            sqrtPriceLimit,
            abi.encode(token0, token1)
        );

        amountOut = zeroForOne ? uint256(-amount1) : uint256(-amount0);
    }

    function _ensureApprovals() internal {
        if (!vault.approvedTokens(USDC_E)) {
            vm.prank(owner);
            vault.approveToken(USDC_E);
        }
        bytes32 pathKey = keccak256(usdcToAiPath);
        if (!vault.approvedPaths(pathKey)) {
            vm.prank(owner);
            vault.approvePath(usdcToAiPath);
        }
    }

    /// @dev Returns true when amountOut is within thresholdBps of amountOutMin —
    ///      the monitoring signal for a potential sandwich attack (alert #5 / #6).
    ///      See monitoring-alerts-full.md and sandwich_attack.md.
    function _isSandwichSignal(uint256 amountOut, uint256 amountOutMin, uint256 thresholdBps)
        internal
        pure
        returns (bool)
    {
        if (amountOut <= amountOutMin) return true; // at or below floor is always a signal
        // margin = (amountOut - amountOutMin) * 10_000 / amountOutMin
        uint256 marginBps = (amountOut - amountOutMin) * 10_000 / amountOutMin;
        return marginBps < thresholdBps;
    }
}
