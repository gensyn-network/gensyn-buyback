// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../src/BuybackVault.sol";
import "../src/interfaces/external/IWETH.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

interface IDelphiFactory {
    function settleCompute(address solver, uint256 amount) external payable;
}

interface ISwapRouterWithFactory {
    function factory() external view returns (address);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

// Import ISwapRouter02 from the source
import "../src/interfaces/external/ISwapRouter02.sol";
import "../src/libraries/TickMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract GensynTestnetForkTest is Test {
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    // ============ Gensyn Testnet Addresses ============
    address constant WETH = 0xCa086d8bA028B799B089c73DD10D722B9a5c6577;
    address constant USDC_E = 0x72936441E8791A96eF283464BEaB677F9C36a162;
    address constant AI_TOKEN = 0x02344970FAEd3241F0581a0977167ba636a63019;
    address constant SWAP_ROUTER = 0x8458ee1e5eD6c35b3bDA10ae0666C745BfbB7E85;
    address constant USDC_AI_POOL = 0x046B3362C4ff28758A22c5C61C0D78AA6013A9eC;
    address constant UNISWAP_FACTORY = 0x89E5d670700B56Ed0AB1bb6c7e8FC870A9b62ef0;
    address constant QUOTER_V2 = 0x6B2f8c561830dA438Ebc24109c16CE9663374955;
    address constant POSITION_MANAGER = 0x90B8F2BF7621386aC76f27a6551cbb16466D705e;
    address constant DELPHI_FACTORY = 0x509875D8B4d97Eb41eab3948328a3fA14031C518;

    string constant GENSYN_RPC_FALLBACK = "https://gensyn-testnet.g.alchemy.com/public";
    uint256 constant CHAIN_ID = 685685;

    // ============ Test Actors ============
    address internal owner;
    uint256 internal ownerKey;
    address internal executor;
    address internal treasury;

    // ============ Contracts ============
    BuybackVault internal vault;
    BuybackVault internal vaultImpl;

    // ============ Swap Paths ============
    // USDC.e -> AI (fee tier 3000 = 0.3%)
    bytes internal usdcToAiPath;
    // WETH -> AI (fee tier 3000 = 0.3%)
    bytes internal wethToAiPath;

    bool internal forkEnabled;

    function setUp() public {
        string memory rpcUrl = vm.envOr("GENSYN_TESTNET_RPC", GENSYN_RPC_FALLBACK);
        vm.createSelectFork(rpcUrl);
        forkEnabled = true;

        // Verify chain ID
        assertEq(block.chainid, CHAIN_ID, "Wrong chain ID");

        // Setup actors
        (owner, ownerKey) = makeAddrAndKey("owner");
        executor = makeAddr("executor");
        treasury = makeAddr("treasury");

        // Fund owner with ETH for gas
        vm.deal(owner, 100 ether);
        vm.deal(executor, 10 ether);

        // Build USDC.e -> AI path (token0 + fee + token1)
        // Path format: tokenIn (20 bytes) + fee (3 bytes) + tokenOut (20 bytes)
        // Pool fee is 3000 (0.3%), token0=AI, token1=USDC.e
        usdcToAiPath = abi.encodePacked(USDC_E, uint24(3000), AI_TOKEN);

        // Build WETH -> AI path for ETH buybacks
        // Pool fee is 3000 (0.3%)
        wethToAiPath = abi.encodePacked(WETH, uint24(3000), AI_TOKEN);

        // Deploy BuybackVault
        _deployVault();
    }

    function _deployVault() internal {
        // Check if we should use a deployed vault address from environment
        // This allows testing against the actual deployed contract
        address deployedVault = vm.envOr("DEPLOYED_VAULT_ADDRESS", address(0));
        if (deployedVault != address(0)) {
            vault = BuybackVault(payable(deployedVault));
            emit log_named_address("Using deployed vault", deployedVault);

            // Get actual owner and treasury from deployed vault
            owner = vault.owner();
            treasury = vault.treasury();
            emit log_named_address("Vault owner", owner);
            emit log_named_address("Vault treasury", treasury);

            // Fund the actual owner with ETH for tests that need owner actions
            vm.deal(owner, 100 ether);
            return;
        }

        // Deploy fresh vault for testing
        emit log("Deploying fresh vault for testing");
        vaultImpl = new BuybackVault();

        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize,
            (
                AI_TOKEN, // aiToken
                treasury, // treasury
                SWAP_ROUTER, // swapRouter
                7_000, // burnBps (70%)
                100, // executorRewardBps (1%)
                1_800, // twapWindow (30 min)
                200, // maxSlippageBps (2%)
                86_400, // epochDuration (1 day)
                owner // owner
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = BuybackVault(payable(address(proxy)));

        // Configure vault
        vm.startPrank(owner);
        vault.setWeth(WETH);
        vault.approveToken(USDC_E);
        vault.approveToken(address(0)); // ETH

        // Approve USDC.e -> AI path with pool for TWAP
        address[] memory usdcPools = new address[](1);
        usdcPools[0] = USDC_AI_POOL;
        vault.approvePath(usdcToAiPath, usdcPools);

        // For WETH -> AI path, we need to find or create the pool
        // Check if WETH/AI pool exists on testnet
        address wethAiPool = IUniswapV3Factory(UNISWAP_FACTORY).getPool(WETH, AI_TOKEN, 3000);
        if (wethAiPool != address(0)) {
            address[] memory wethPools = new address[](1);
            wethPools[0] = wethAiPool;
            vault.approvePath(wethToAiPath, wethPools);
        }
        // If no WETH/AI pool exists, ETH buyback tests will be skipped
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!forkEnabled) {
            vm.skip(true); // Explicitly skip test - will show as skipped in test results, not passed
        }
        _;
    }

    // ============================================================
    //                    END-TO-END TESTS
    // ============================================================

    function test_fork_deploymentState() public onlyFork {
        assertEq(vault.aiToken(), AI_TOKEN, "aiToken mismatch");
        assertEq(vault.treasury(), treasury, "treasury mismatch");
        assertEq(vault.swapRouter(), SWAP_ROUTER, "swapRouter mismatch");
        assertEq(vault.weth(), WETH, "weth mismatch");
        assertEq(vault.burnBps(), 7_000, "burnBps mismatch");
        assertEq(vault.executorRewardBps(), 100, "executorRewardBps mismatch");
        assertEq(vault.twapWindow(), 1_800, "twapWindow mismatch");
        assertEq(vault.maxSlippageBps(), 200, "maxSlippageBps mismatch");
        assertEq(vault.owner(), owner, "owner mismatch");
        assertTrue(vault.approvedTokens(USDC_E), "USDC.e not approved");
        assertTrue(vault.approvedPaths(keccak256(usdcToAiPath)), "path not approved");
    }

    function test_fork_receiveUSDC() public onlyFork {
        // Fund vault directly via transfer (no deposit function)
        uint256 amount = 100e6; // 100 USDC.e
        deal(USDC_E, executor, amount);

        vm.prank(executor);
        IERC20(USDC_E).safeTransfer(address(vault), amount);

        assertEq(IERC20(USDC_E).balanceOf(address(vault)), amount, "vault should hold USDC.e");
    }

    function test_fork_receiveETH() public onlyFork {
        uint256 amount = 1 ether;

        // Send ETH directly to vault via receive()
        vm.prank(executor);
        (bool success,) = address(vault).call{value: amount}("");
        assertTrue(success, "ETH transfer should succeed");

        assertEq(address(vault).balance, amount, "vault should hold ETH");
    }

    function test_fork_fullBuybackFlow_USDC() public onlyFork {
        uint256 amount = 100e6; // 100 USDC.e - reasonable amount within pool liquidity

        // Verify pool state
        uint128 poolLiquidity = IUniswapV3Pool(USDC_AI_POOL).liquidity();
        uint24 poolFee = IUniswapV3Pool(USDC_AI_POOL).fee();
        uint256 poolUsdcBalance = IERC20(USDC_E).balanceOf(USDC_AI_POOL);
        uint256 poolAiBalance = IERC20(AI_TOKEN).balanceOf(USDC_AI_POOL);

        emit log_named_uint("Pool liquidity", poolLiquidity);
        emit log_named_uint("Pool fee", poolFee);
        emit log_named_uint("Pool USDC.e balance", poolUsdcBalance);
        emit log_named_uint("Pool AI balance", poolAiBalance);

        require(poolLiquidity > 0, "Pool has no liquidity");
        require(poolUsdcBalance >= amount, "Pool doesn't have enough USDC.e");
        require(poolFee == 3000, "Pool fee mismatch - expected 3000");

        // Step 1: Get USDC.e from the pool and send directly to vault
        vm.prank(USDC_AI_POOL);
        IERC20(USDC_E).safeTransfer(address(vault), amount);
        emit log_named_uint("Vault USDC.e balance", IERC20(USDC_E).balanceOf(address(vault)));

        assertEq(IERC20(USDC_E).balanceOf(address(vault)), amount, "vault should hold USDC.e");

        // Record balances and total supply before buyback
        uint256 treasuryBefore = IERC20(AI_TOKEN).balanceOf(treasury);
        uint256 executorBefore = IERC20(AI_TOKEN).balanceOf(executor);
        uint256 totalSupplyBefore = IERC20(AI_TOKEN).totalSupply();
        uint256 deadBalanceBefore = IERC20(AI_TOKEN).balanceOf(address(0xdEaD));

        emit log_named_uint("AI Total Supply Before", totalSupplyBefore);
        emit log_named_uint("Dead Address Balance Before", deadBalanceBefore);

        // Calculate amountOutMin by querying the actual TWAP from the pool
        // This mirrors the contract's TWAP floor calculation
        uint256 twapFloor = _computeTwapFloor(USDC_AI_POOL, USDC_E, AI_TOKEN, amount, 1800, 200);
        emit log_named_uint("Computed TWAP floor", twapFloor);

        // Set amountOutMin to exactly the TWAP floor (minimum acceptable)
        uint256 amountOutMin = twapFloor;
        emit log_named_uint("amountOutMin (= TWAP floor)", amountOutMin);

        vm.prank(executor);
        vault.executeBuyback(USDC_E, usdcToAiPath, amount, amountOutMin);

        // Step 3: Verify distributions
        uint256 executorReward = IERC20(AI_TOKEN).balanceOf(executor) - executorBefore;
        uint256 treasuryAmount = IERC20(AI_TOKEN).balanceOf(treasury) - treasuryBefore;
        uint256 totalSupplyAfter = IERC20(AI_TOKEN).totalSupply();
        uint256 deadBalanceAfter = IERC20(AI_TOKEN).balanceOf(address(0xdEaD));

        emit log_named_uint("USDC Buyback - Executor reward (AI)", executorReward);
        emit log_named_uint("USDC Buyback - Treasury amount (AI)", treasuryAmount);
        emit log_named_uint("AI Total Supply After", totalSupplyAfter);
        emit log_named_uint("Dead Address Balance After", deadBalanceAfter);

        // CRITICAL: Validate burn occurred
        // Check 1: Total supply should decrease (true burn)
        // Check 2: OR dead address balance should increase (pseudo-burn)
        uint256 supplyDecrease = totalSupplyBefore > totalSupplyAfter ? totalSupplyBefore - totalSupplyAfter : 0;
        uint256 deadBalanceIncrease = deadBalanceAfter - deadBalanceBefore;

        emit log_named_uint("AI Supply Decrease (true burn)", supplyDecrease);
        emit log_named_uint("Dead Address Increase (pseudo-burn)", deadBalanceIncrease);

        // Verify executor got reward
        assertTrue(executorReward > 0, "executor should receive reward");
        // Verify treasury received funds
        assertTrue(treasuryAmount > 0, "treasury should receive remainder");
        // Verify vault is empty
        assertEq(IERC20(AI_TOKEN).balanceOf(address(vault)), 0, "vault should hold no AI");
        assertEq(IERC20(USDC_E).balanceOf(address(vault)), 0, "vault should hold no USDC.e");

        assertTrue(
            supplyDecrease > 0,
            "CRITICAL: totalSupply did not decrease - tokens sent to DEAD_ADDRESS instead of being burned"
        );

        // Verify distribution ratios (1% executor, 70% burn of remainder, 29% treasury)
        // Calculate expected amounts based on what we received
        uint256 burnAmount = supplyDecrease > 0 ? supplyDecrease : deadBalanceIncrease;
        uint256 totalOut = executorReward + burnAmount + treasuryAmount;
        uint256 expectedExecutorReward = totalOut * 100 / 10_000; // 1%
        uint256 remainder = totalOut - expectedExecutorReward;
        uint256 expectedBurn = remainder * 7_000 / 10_000; // 70% of remainder
        uint256 expectedTreasury = remainder - expectedBurn; // 29% of remainder

        emit log_named_uint("Total AI received", totalOut);
        emit log_named_uint("Expected executor (1%)", expectedExecutorReward);
        emit log_named_uint("Expected burn (70% of remainder)", expectedBurn);
        emit log_named_uint("Expected treasury (29% of remainder)", expectedTreasury);

        // Allow 1 wei tolerance for rounding
        assertApproxEqAbs(executorReward, expectedExecutorReward, 1, "executor reward ratio incorrect");
        assertApproxEqAbs(burnAmount, expectedBurn, 1, "burn ratio incorrect");
        assertApproxEqAbs(treasuryAmount, expectedTreasury, 1, "treasury ratio incorrect");
    }

    function test_fork_buybackRevertsOnSlippageExceeded() public onlyFork {
        // This test verifies that SlippageExceeded is thrown when amountOutMin < twapFloor
        // The contract requires: amountOutMin >= twapFloor, otherwise reverts with SlippageExceeded

        // First check if the pool fee matches what we expect
        uint24 poolFee = IUniswapV3Pool(USDC_AI_POOL).fee();
        emit log_named_uint("USDC/AI Pool actual fee", poolFee);

        // Build path with the actual pool fee
        bytes memory pathWithCorrectFee = abi.encodePacked(USDC_E, poolFee, AI_TOKEN);

        vm.startPrank(owner);
        // Revoke old path and approve with correct fee
        vault.revokePath(usdcToAiPath);
        address[] memory pools = new address[](1);
        pools[0] = USDC_AI_POOL;
        vault.approvePath(pathWithCorrectFee, pools);
        vm.stopPrank();

        uint256 depositAmount = 1e6;
        deal(USDC_E, address(vault), depositAmount);

        // Set amountOutMin = 1, which is below any reasonable TWAP floor
        // This triggers SlippageExceeded because 1 < twapFloor
        // Note: amountOutMin = 0 would trigger ZeroAmount() instead
        uint256 tooLowAmountOutMin = 1;

        vm.prank(executor);
        vm.expectRevert(BuybackVault.SlippageExceeded.selector);
        vault.executeBuyback(USDC_E, pathWithCorrectFee, depositAmount, tooLowAmountOutMin);
    }

    function test_fork_buybackRevertsOnUnapprovedToken() public onlyFork {
        address randomToken = makeAddr("randomToken");

        vm.prank(executor);
        vm.expectRevert(BuybackVault.TokenNotApproved.selector);
        vault.executeBuyback(randomToken, usdcToAiPath, 100e6, 1);
    }

    function test_fork_buybackRevertsOnUnapprovedPath() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        // Create a different path that's not approved (different fee tier)
        bytes memory unapprovedPath = abi.encodePacked(USDC_E, uint24(10000), AI_TOKEN);

        vm.prank(executor);
        vm.expectRevert(BuybackVault.PathNotApproved.selector);
        vault.executeBuyback(USDC_E, unapprovedPath, 100e6, 1);
    }

    // ============================================================
    //                 GOVERNANCE OPERATIONS TESTS
    // ============================================================

    function test_fork_pause() public onlyFork {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused(), "vault should be paused");

        // Buyback should revert when paused
        deal(USDC_E, address(vault), 100e6);
        vm.prank(executor);
        vm.expectRevert();
        vault.executeBuyback(USDC_E, usdcToAiPath, 100e6, 1);
    }

    function test_fork_unpause() public onlyFork {
        vm.startPrank(owner);
        vault.pause();
        assertTrue(vault.paused());
        vault.unpause();
        assertFalse(vault.paused(), "vault should be unpaused");
        vm.stopPrank();
    }

    function test_fork_emergencySweep() public onlyFork {
        uint256 depositAmount = 500e6;
        deal(USDC_E, address(vault), depositAmount);

        // Must pause first
        vm.startPrank(owner);
        vault.pause();

        address safeAddr = makeAddr("safe");
        vault.emergencySweep(USDC_E, safeAddr, depositAmount);
        vm.stopPrank();

        assertEq(IERC20(USDC_E).balanceOf(safeAddr), depositAmount, "swept funds recovered");
        assertEq(IERC20(USDC_E).balanceOf(address(vault)), 0, "vault emptied");
    }

    function test_fork_emergencySweepETH() public onlyFork {
        uint256 depositAmount = 1 ether;
        vm.deal(address(vault), depositAmount);

        vm.startPrank(owner);
        vault.pause();

        address safeAddr = makeAddr("safe");
        uint256 safeBefore = safeAddr.balance;
        vault.emergencySweep(address(0), safeAddr, depositAmount);
        vm.stopPrank();

        assertEq(safeAddr.balance - safeBefore, depositAmount, "ETH swept");
    }

    function test_fork_emergencySweepRevertsWhenNotPaused() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        vm.prank(owner);
        vm.expectRevert();
        vault.emergencySweep(USDC_E, owner, 100e6);
    }

    function test_fork_setBurnBps() public onlyFork {
        vm.prank(owner);
        vault.setBurnBps(5_000);
        assertEq(vault.burnBps(), 5_000, "burnBps updated");
    }

    function test_fork_setExecutorRewardBps() public onlyFork {
        vm.prank(owner);
        vault.setExecutorRewardBps(200);
        assertEq(vault.executorRewardBps(), 200, "executorRewardBps updated");
    }

    function test_fork_setTreasury() public onlyFork {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        vault.setTreasury(newTreasury);
        assertEq(vault.treasury(), newTreasury, "treasury updated");
    }

    function test_fork_setTwapWindow() public onlyFork {
        vm.prank(owner);
        vault.setTwapWindow(3_600); // 1 hour
        assertEq(vault.twapWindow(), 3_600, "twapWindow updated");
    }

    function test_fork_setMaxSlippageBps() public onlyFork {
        vm.prank(owner);
        vault.setMaxSlippageBps(300);
        assertEq(vault.maxSlippageBps(), 300, "maxSlippageBps updated");
    }

    function test_fork_setEpochConfig() public onlyFork {
        vm.prank(owner);
        vault.setEpochConfig(7 days);
        assertEq(vault.epochDuration(), 7 days, "epochDuration updated");
    }

    function test_fork_setTokenEpochVolumeLimit() public onlyFork {
        uint256 limit = 1_000_000e6; // 1M USDC.e
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(USDC_E, limit);
        assertEq(vault.tokenEpochVolumeLimit(USDC_E), limit, "volume limit set");
    }

    function test_fork_epochVolumeLimitEnforced() public onlyFork {
        uint256 limit = 2e6; // 2 USDC.e limit (small for testing)
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(USDC_E, limit);

        // Fund vault from pool
        vm.prank(USDC_AI_POOL);
        IERC20(USDC_E).transfer(address(vault), 3e6);

        uint256 amountOutMin = _computeTwapFloor(USDC_AI_POOL, USDC_E, AI_TOKEN, 1e6, 1800, 200);

        vm.prank(executor);
        vault.executeBuyback(USDC_E, usdcToAiPath, 1e6, amountOutMin);

        vm.prank(executor);
        vm.expectRevert(BuybackVault.EpochLimitExceeded.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, 2e6, 1);
    }

    function test_fork_epochVolumeResetsAfterEpoch() public onlyFork {
        uint256 limit = 1e6; // 1 USDC.e limit
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(USDC_E, limit);

        // Fund vault from pool
        vm.prank(USDC_AI_POOL);
        IERC20(USDC_E).transfer(address(vault), 2e6);

        uint256 amountOutMin = _computeTwapFloor(USDC_AI_POOL, USDC_E, AI_TOKEN, 1e6, 1800, 200);

        vm.prank(executor);
        vault.executeBuyback(USDC_E, usdcToAiPath, 1e6, amountOutMin);

        vm.warp(block.timestamp + 86_401);

        vm.prank(USDC_AI_POOL);
        IERC20(USDC_E).transfer(address(vault), 1e6);

        vm.prank(executor);
        vault.executeBuyback(USDC_E, usdcToAiPath, 1e6, amountOutMin);
    }

    // ============================================================
    //                    PATH MANAGEMENT TESTS
    // ============================================================

    function test_fork_approvePath() public onlyFork {
        // Create a new path (same fee tier, re-approve with pool)
        bytes memory newPath = abi.encodePacked(USDC_E, uint24(3000), AI_TOKEN);

        vm.prank(owner);
        address[] memory pools = new address[](1);
        pools[0] = USDC_AI_POOL;
        vault.approvePath(newPath, pools);

        assertTrue(vault.approvedPaths(keccak256(newPath)), "new path approved");
    }

    function test_fork_revokePath() public onlyFork {
        vm.prank(owner);
        vault.revokePath(usdcToAiPath);

        assertFalse(vault.approvedPaths(keccak256(usdcToAiPath)), "path revoked");

        // Buyback should fail
        deal(USDC_E, address(vault), 100e6);
        vm.prank(executor);
        vm.expectRevert(BuybackVault.PathNotApproved.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, 100e6, 1);
    }

    function test_fork_approveToken() public onlyFork {
        address newToken = makeAddr("newToken");

        vm.prank(owner);
        vault.approveToken(newToken);

        assertTrue(vault.approvedTokens(newToken), "token approved");
    }

    function test_fork_revokeToken() public onlyFork {
        vm.prank(owner);
        vault.revokeToken(USDC_E);

        assertFalse(vault.approvedTokens(USDC_E), "token revoked");

        deal(USDC_E, address(vault), 100e6);
        vm.prank(executor);
        vm.expectRevert(BuybackVault.TokenNotApproved.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, 100e6, 1);
    }

    // ============================================================
    //                    UPGRADE TESTS
    // ============================================================

    function test_fork_upgradeToNewImpl() public onlyFork {
        BuybackVault newImpl = new BuybackVault();

        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(vault.aiToken(), AI_TOKEN, "aiToken preserved");
        assertEq(vault.treasury(), treasury, "treasury preserved");
        assertEq(vault.swapRouter(), SWAP_ROUTER, "swapRouter preserved");
        assertEq(vault.weth(), WETH, "weth preserved");
        assertEq(vault.burnBps(), 7_000, "burnBps preserved");
        assertTrue(vault.approvedTokens(USDC_E), "token approval preserved");
        assertTrue(vault.approvedPaths(keccak256(usdcToAiPath)), "path approval preserved");
    }

    function test_fork_upgradeRevertsForNonOwner() public onlyFork {
        BuybackVault newImpl = new BuybackVault();

        vm.prank(executor);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");
    }

    // ============================================================
    //                 OWNERSHIP TRANSFER TESTS
    // ============================================================

    function test_fork_transferOwnership() public onlyFork {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vault.transferOwnership(newOwner);

        // Still old owner until accepted
        assertEq(vault.owner(), owner, "owner unchanged until accepted");

        vm.prank(newOwner);
        vault.acceptOwnership();

        assertEq(vault.owner(), newOwner, "ownership transferred");
    }

    // ============================================================
    //                    ACCESS CONTROL TESTS
    // ============================================================

    function test_fork_onlyOwnerCanPause() public onlyFork {
        vm.prank(executor);
        vm.expectRevert();
        vault.pause();
    }

    function test_fork_onlyOwnerCanSetBurnBps() public onlyFork {
        vm.prank(executor);
        vm.expectRevert();
        vault.setBurnBps(5_000);
    }

    function test_fork_onlyOwnerCanApprovePath() public onlyFork {
        bytes memory path = abi.encodePacked(USDC_E, uint24(3000), AI_TOKEN);
        address[] memory pools = new address[](1);
        pools[0] = USDC_AI_POOL;

        vm.prank(executor);
        vm.expectRevert();
        vault.approvePath(path, pools);
    }

    function test_fork_onlyOwnerCanApproveToken() public onlyFork {
        vm.prank(executor);
        vm.expectRevert();
        vault.approveToken(makeAddr("token"));
    }

    // ============================================================
    //                    VALIDATION TESTS
    // ============================================================

    function test_fork_twapWindowMinimum() public onlyFork {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.TwapWindowTooShort.selector);
        vault.setTwapWindow(1_799); // Less than 30 min
    }

    function test_fork_maxSlippageMaximum() public onlyFork {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.SlippageTooHigh.selector);
        vault.setMaxSlippageBps(501); // More than 5%
    }

    function test_fork_bpsOverflow() public onlyFork {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.BpsOverflow.selector);
        vault.setBurnBps(10_000); // Would exceed 100% with executor reward
    }

    function test_fork_zeroAmountIn() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        vm.prank(executor);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, 0, 1);
    }

    function test_fork_zeroAmountOutMin() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        vm.prank(executor);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, 100e6, 0);
    }

    function test_fork_amountTooLarge() public onlyFork {
        // amountIn > type(uint128).max should revert
        uint256 tooLargeAmount = uint256(type(uint128).max) + 1;

        vm.prank(executor);
        vm.expectRevert(BuybackVault.AmountTooLarge.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, tooLargeAmount, 1);
    }

    function test_fork_wethNotConfigured() public onlyFork {
        // Set WETH to address(0)
        vm.prank(owner);
        vault.setWeth(address(0));

        // Fund vault with ETH
        vm.deal(address(vault), 1 ether);

        // Try ETH buyback - should fail because WETH not configured
        vm.prank(executor);
        vm.expectRevert(BuybackVault.WethNotConfigured.selector);
        vault.executeBuyback(address(0), wethToAiPath, 1 ether, 1);
    }

    function test_fork_tokenInMismatch() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        // Create a path that starts with a different token than what we pass as tokenIn
        // Path says WETH -> AI, but we pass USDC_E as tokenIn
        vm.prank(executor);
        vm.expectRevert(BuybackVault.TokenInMismatch.selector);
        vault.executeBuyback(USDC_E, wethToAiPath, 100e6, 1);
    }

    function test_fork_epochDurationOverflow() public onlyFork {
        // setEpochConfig with value > type(uint32).max should revert
        uint256 tooLargeDuration = uint256(type(uint32).max) + 1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", 32, tooLargeDuration));
        vault.setEpochConfig(tooLargeDuration);
    }

    // ============================================================
    //                    HELPER FUNCTIONS
    // ============================================================

    /// @notice Compute TWAP floor the same way BuybackVault does
    function _computeTwapFloor(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint32 twapWindow,
        uint16 maxSlippageBps
    ) internal view returns (uint256 floor) {
        // Query TWAP from pool
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 meanTick = int256(tickDelta / int56(uint56(twapWindow))).toInt24();
        if (tickDelta < 0 && (tickDelta % int56(uint56(twapWindow)) != 0)) meanTick--;

        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(meanTick);

        uint256 amountOut;
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            amountOut = tokenIn < tokenOut
                ? Math.mulDiv(ratioX192, amountIn, 1 << 192)
                : Math.mulDiv(1 << 192, amountIn, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(uint256(sqrtRatioX96), uint256(sqrtRatioX96), 1 << 64);
            amountOut = tokenIn < tokenOut
                ? Math.mulDiv(ratioX128, amountIn, 1 << 128)
                : Math.mulDiv(1 << 128, amountIn, ratioX128);
        }

        floor = amountOut * (10_000 - maxSlippageBps) / 10_000;
    }
}
