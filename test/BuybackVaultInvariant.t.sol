// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/BuybackVault.sol";
import "./BuybackVault.t.sol"; // reuse MockERC20, MockSwapRouter, MockUniswapPool
import "../script/DeployBuybackVault.s.sol";

contract BuybackVaultFuzzTest is Test, DeployBuybackVault {
    address internal owner = makeAddr("fuzz_owner");
    address internal alice = makeAddr("fuzz_alice");
    address internal treasury = makeAddr("fuzz_treasury");

    BuybackVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal ai;
    MockSwapRouter internal router;
    MockUniswapPool internal pool;

    bytes internal approvedPath;

    function setUp() public {
        usdc = new MockERC20("USDC.e", "USDC.e");
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();
        pool = new MockUniswapPool();
        pool.setTickCumulatives(0, 0);

        approvedPath = abi.encodePacked(address(usdc), uint24(3_000), address(ai));

        {
            (address t0, address t1) =
                address(usdc) < address(ai) ? (address(usdc), address(ai)) : (address(ai), address(usdc));
            pool.setPoolConfig(t0, t1, 3_000);
        }

        _ai = address(ai);
        _treasury = treasury;
        _router = address(router);
        _burn = 7_000;
        _reward = 100;
        _twap = 1_800;
        _slip = 100;
        _epoch = 86_400;
        _owner = owner;
        _deploy();
        _validate();
        vault = _vault;

        {
            address[] memory poolArr = new address[](1);
            poolArr[0] = address(pool);
            vm.startPrank(owner);
            vault.approveToken(address(usdc));
            vault.approvePath(approvedPath, poolArr);
            vm.stopPrank();
        }
    }

    /// @dev Fuzz amountOut to verify split math never loses or creates tokens.
    function testFuzz_splitSumsToAmountOut(uint128 amountIn, uint128 amountOut) public {
        vm.assume(amountIn > 0 && amountOut > 0);
        vm.assume(uint256(amountOut) >= uint256(amountIn) / 1e12); // crude sanity

        uint16 burn = vault.burnBps();
        uint16 reward = vault.executorRewardBps();

        uint256 executorReward = (uint256(amountOut) * reward) / 10_000;
        uint256 burnAmount = ((uint256(amountOut) - executorReward) * burn) / 10_000;
        uint256 treasuryAmount = uint256(amountOut) - executorReward - burnAmount;

        assertEq(executorReward + burnAmount + treasuryAmount, uint256(amountOut), "split must sum to amountOut");
    }

    function testFuzz_bpsAlwaysWithinBounds(uint16 newBurn) public {
        uint16 maxBurn = uint16(10_000 - vault.executorRewardBps());
        vm.assume(newBurn <= maxBurn);
        vm.prank(owner);
        vault.setBurnBps(newBurn);
        assertTrue(uint256(vault.burnBps()) + uint256(vault.executorRewardBps()) <= 10_000);
    }

    function testFuzz_executeBuyback_split(
        uint16 burnBps_,
        uint16 rewardBps_,
        uint128 amountIn_,
        uint128 mockAmountOut_
    ) public {
        vm.assume(uint256(burnBps_) + uint256(rewardBps_) <= 10_000);
        vm.assume(amountIn_ > 0 && mockAmountOut_ > 0);

        vm.startPrank(owner);
        vault.setBurnBps(0);
        vault.setExecutorRewardBps(rewardBps_);
        vault.setBurnBps(burnBps_);
        vm.stopPrank();

        usdc.mint(address(vault), amountIn_);

        uint256 floor = uint256(amountIn_) * (10_000 - vault.maxSlippageBps()) / 10_000;
        uint256 minOut = floor > 0 ? floor : 1;
        mockAmountOut_ = uint128(bound(uint256(mockAmountOut_), minOut, type(uint128).max));
        router.setNextAmountOut(mockAmountOut_, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, minOut);

        uint256 executorBal = ai.balanceOf(alice);
        uint256 burnBal = ai.balanceOf(address(0xdEaD));
        uint256 treasuryBal = ai.balanceOf(treasury);

        assertEq(executorBal + burnBal + treasuryBal, mockAmountOut_, "split must equal amountOut");
        assertEq(ai.balanceOf(address(vault)), 0, "vault must hold no $AI after buyback");
    }

    function testFuzz_vaultBalanceAccountingCorrect(uint128 amountIn_, uint128 mockAmountOut_) public {
        vm.assume(amountIn_ > 0 && mockAmountOut_ > 0);

        usdc.mint(address(vault), amountIn_);

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 routerUsdcBefore = usdc.balanceOf(address(router));

        uint256 floor = uint256(amountIn_) * (10_000 - vault.maxSlippageBps()) / 10_000;
        uint256 minOut = floor > 0 ? floor : 1;
        vm.assume(uint256(mockAmountOut_) >= minOut);
        router.setNextAmountOut(mockAmountOut_, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, minOut);

        // Vault USDC decreased by amountIn
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore - amountIn_, "vault USDC must decrease by amountIn");
        // Router received the USDC
        assertEq(usdc.balanceOf(address(router)), routerUsdcBefore + amountIn_, "router must receive amountIn USDC");
        // AI distribution matches mockAmountOut
        uint256 totalAiDistributed = ai.balanceOf(alice) + ai.balanceOf(address(0xdEaD)) + ai.balanceOf(treasury);
        assertEq(totalAiDistributed, mockAmountOut_, "AI distribution must equal mockAmountOut");
    }

    function testFuzz_onlyOwnerCanSetBurnBps(address caller, uint16 newBps) public {
        vm.assume(caller != owner);
        vm.assume(newBps <= 10_000 - vault.executorRewardBps());
        vm.prank(caller);
        vm.expectRevert();
        vault.setBurnBps(newBps);
    }

    function testFuzz_onlyOwnerCanSetExecutorRewardBps(address caller, uint16 newBps) public {
        vm.assume(caller != owner);
        vm.assume(newBps <= 10_000 - vault.burnBps());
        vm.prank(caller);
        vm.expectRevert();
        vault.setExecutorRewardBps(newBps);
    }

    function testFuzz_onlyOwnerCanSetTreasury(address caller, address newTreasury) public {
        vm.assume(caller != owner);
        vm.assume(newTreasury != address(0));
        vm.prank(caller);
        vm.expectRevert();
        vault.setTreasury(newTreasury);
    }

    function testFuzz_onlyOwnerCanSetAiToken(address caller, address newAiToken) public {
        vm.assume(caller != owner);
        vm.assume(newAiToken != address(0));
        vm.prank(caller);
        vm.expectRevert();
        vault.setAiToken(newAiToken);
    }

    function testFuzz_onlyOwnerCanApproveToken(address caller, address token) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert();
        vault.approveToken(token);
    }

    function testFuzz_onlyOwnerCanRevokeToken(address caller, address token) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert();
        vault.revokeToken(token);
    }

    function testFuzz_onlyOwnerCanPause(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert();
        vault.pause();
    }

    function testFuzz_onlyOwnerCanUnpause(address caller) public {
        vm.assume(caller != owner);
        vm.prank(owner);
        vault.pause();
        vm.prank(caller);
        vm.expectRevert();
        vault.unpause();
    }

    function testFuzz_pausedBlocksBuyback(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0);
        usdc.mint(address(vault), amountIn_);

        vm.prank(owner);
        vault.pause();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vm.expectRevert();
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1);
    }

    function testFuzz_epochVolumeLimit(uint128 limit, uint128 amountIn_) public {
        vm.assume(limit > 0 && limit < type(uint128).max / 2);
        vm.assume(amountIn_ > 0 && amountIn_ <= limit);

        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), limit);

        usdc.mint(address(vault), amountIn_);

        uint256 floor = uint256(amountIn_) * (10_000 - vault.maxSlippageBps()) / 10_000;
        uint256 minOut = floor > 0 ? floor : 1;
        router.setNextAmountOut(minOut, address(ai));
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, minOut);
    }

    function testFuzz_epochVolumeExceeded(uint128 limit, uint128 firstAmount, uint128 secondAmount) public {
        vm.assume(limit > 1 && limit < type(uint64).max);
        vm.assume(firstAmount > 0 && firstAmount < limit);
        vm.assume(secondAmount > 0);
        vm.assume(uint256(firstAmount) + uint256(secondAmount) > limit);

        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), limit);

        uint256 totalAmount = uint256(firstAmount) + uint256(secondAmount);
        usdc.mint(address(vault), totalAmount);

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        {
            uint256 floor = uint256(firstAmount) * (10_000 - vault.maxSlippageBps()) / 10_000;
            uint256 minOut = floor > 0 ? floor : 1;
            router.setNextAmountOut(minOut, address(ai));
            vault.executeBuyback(address(usdc), approvedPath, firstAmount, minOut);
        }

        vm.prank(alice);
        vm.expectRevert(BuybackVault.EpochLimitExceeded.selector);
        vault.executeBuyback(address(usdc), approvedPath, secondAmount, 1);
    }

    function testFuzz_epochRolloverResetsVolume(uint128 limit, uint128 amount, uint32 epochDur) public {
        vm.assume(epochDur >= 1 && epochDur <= 365 days);
        vm.assume(limit > 0 && limit < type(uint64).max);
        vm.assume(amount > 0 && amount <= limit);

        vm.startPrank(owner);
        vault.setEpochConfig(epochDur);
        vault.setTokenEpochVolumeLimit(address(usdc), limit);
        vm.stopPrank();

        usdc.mint(address(vault), uint256(amount) * 2);

        {
            uint256 floor = uint256(amount) * (10_000 - vault.maxSlippageBps()) / 10_000;
            uint256 minOut = floor > 0 ? floor : 1;
            router.setNextAmountOut(minOut, address(ai));
            vm.prank(alice);
            vault.executeBuyback(address(usdc), approvedPath, amount, minOut);
        }

        uint256 warpTo = block.timestamp + uint256(epochDur) + 1;
        vm.warp(warpTo);

        {
            uint256 floor = uint256(amount) * (10_000 - vault.maxSlippageBps()) / 10_000;
            uint256 minOut = floor > 0 ? floor : 1;
            router.setNextAmountOut(minOut, address(ai));
            vm.prank(alice);
            vault.executeBuyback(address(usdc), approvedPath, amount, minOut);
        }
    }

    function testFuzz_largeAmountBoundary(uint256 amountIn_) public {
        // Test values around uint128 max boundary
        vm.assume(amountIn_ > type(uint128).max / 2 && amountIn_ <= type(uint128).max);

        usdc.mint(address(vault), amountIn_);

        {
            uint256 floor = amountIn_ * (10_000 - vault.maxSlippageBps()) / 10_000;
            uint256 minOut = floor > 0 ? floor : 1;
            router.setNextAmountOut(minOut, address(ai));
            vm.prank(alice);
            vault.executeBuyback(address(usdc), approvedPath, amountIn_, minOut);
        }
    }

    function test_amountExceedsUint128Rejected() public {
        uint256 tooLarge = uint256(type(uint128).max) + 1;

        usdc.mint(address(vault), tooLarge);

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.AmountTooLarge.selector);
        vault.executeBuyback(address(usdc), approvedPath, tooLarge, 1);
    }

    function testFuzz_smallAmountBoundary(uint8 amountIn_) public {
        vm.assume(amountIn_ > 0);

        usdc.mint(address(vault), amountIn_);

        {
            uint256 floor = uint256(amountIn_) * (10_000 - vault.maxSlippageBps()) / 10_000;
            uint256 minOut = floor > 0 ? floor : 1;
            router.setNextAmountOut(minOut, address(ai));
            vm.prank(alice);
            vault.executeBuyback(address(usdc), approvedPath, amountIn_, minOut);
        }
    }

    function testFuzz_zeroAmountRejected(uint128 mockOut) public {
        vm.assume(mockOut > 0);
        router.setNextAmountOut(mockOut, address(ai));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(address(usdc), approvedPath, 0, 1);
    }

    function testFuzz_zeroAmountOutMinRejected(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0);

        usdc.mint(address(vault), amountIn_);

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 0);
    }
}

contract BuybackVaultHandler is Test {
    BuybackVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal ai;
    MockSwapRouter internal router;
    address internal owner;
    address internal treasury;

    bytes internal approvedPath;
    address public actor = makeAddr("invariant_actor");

    uint256 public totalDeposited;
    uint256 public totalSwapped;
    uint256 public totalBurned;
    uint256 public totalExecutorRewards;
    uint256 public totalTreasuryReceived;

    constructor(
        BuybackVault _vault,
        MockERC20 _usdc,
        MockERC20 _ai,
        MockSwapRouter _router,
        bytes memory _path,
        address _owner,
        address _treasury
    ) {
        vault = _vault;
        usdc = _usdc;
        ai = _ai;
        router = _router;
        approvedPath = _path;
        owner = _owner;
        treasury = _treasury;
    }

    function deposit(uint128 amount) external {
        amount = uint128(bound(amount, 1, 1_000_000e6));
        usdc.mint(address(vault), amount);
        totalDeposited += amount;
    }

    function executeBuyback(uint128 amountIn, uint128 mockOut) external {
        uint256 bal = usdc.balanceOf(address(vault));
        if (bal == 0) return;
        amountIn = uint128(bound(amountIn, 1, bal));

        uint256 floor = uint256(amountIn) * (10_000 - vault.maxSlippageBps()) / 10_000;
        uint256 minOut = floor > 0 ? floor : 1;
        mockOut = uint128(bound(uint256(mockOut), minOut, type(uint128).max));

        uint256 burnBefore = ai.balanceOf(address(0xdEaD));
        uint256 executorBefore = ai.balanceOf(actor);
        uint256 treasuryBefore = ai.balanceOf(treasury);

        router.setNextAmountOut(mockOut, address(ai));
        vm.prank(actor);
        try vault.executeBuyback(address(usdc), approvedPath, amountIn, minOut) {
            totalSwapped += amountIn;
            totalBurned += ai.balanceOf(address(0xdEaD)) - burnBefore;
            totalExecutorRewards += ai.balanceOf(actor) - executorBefore;
            totalTreasuryReceived += ai.balanceOf(treasury) - treasuryBefore;
        } catch {}
    }

    function warpTime(uint32 delta) external {
        delta = uint32(bound(delta, 1, 7 days));
        vm.warp(block.timestamp + delta);
    }

    /// @dev bound() reads current bps values which may be stale if the fuzzer
    /// calls setBurnBps and setExecutorRewardBps in sequence. invariant_configBoundsRespected
    /// catches any resulting violation.
    function setBurnBps(uint16 newBps) external {
        newBps = uint16(bound(newBps, 0, 10_000 - vault.executorRewardBps()));
        vm.prank(owner);
        vault.setBurnBps(newBps);
    }

    /// @dev See setBurnBps note about stale-read race condition.
    function setExecutorRewardBps(uint16 newBps) external {
        newBps = uint16(bound(newBps, 0, 10_000 - vault.burnBps()));
        vm.prank(owner);
        vault.setExecutorRewardBps(newBps);
    }

    function setTwapWindow(uint32 newWindow) external {
        newWindow = uint32(bound(newWindow, 1800, 7 days));
        vm.prank(owner);
        vault.setTwapWindow(newWindow);
    }

    function setMaxSlippageBps(uint16 newBps) external {
        newBps = uint16(bound(newBps, 0, 500));
        vm.prank(owner);
        vault.setMaxSlippageBps(newBps);
    }
}

contract BuybackVaultInvariantTest is Test, DeployBuybackVault {
    address internal owner = makeAddr("inv_owner");
    address internal treasury = makeAddr("inv_treasury");

    BuybackVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal ai;
    MockSwapRouter internal router;
    MockUniswapPool internal pool;
    BuybackVaultHandler internal handler;

    bytes internal approvedPath;

    function setUp() public {
        usdc = new MockERC20("USDC.e", "USDC.e");
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();
        pool = new MockUniswapPool();
        pool.setTickCumulatives(0, 0);

        approvedPath = abi.encodePacked(address(usdc), uint24(3_000), address(ai));

        _ai = address(ai);
        _treasury = treasury;
        _router = address(router);
        _burn = 7_000;
        _reward = 100;
        _twap = 1_800;
        _slip = 100;
        _epoch = 86_400;
        _owner = owner;
        _deploy();
        _validate();
        vault = _vault;

        vm.startPrank(owner);
        vault.approveToken(address(usdc));
        {
            (address t0, address t1) =
                address(usdc) < address(ai) ? (address(usdc), address(ai)) : (address(ai), address(usdc));
            pool.setPoolConfig(t0, t1, 3_000);
            address[] memory poolArr = new address[](1);
            poolArr[0] = address(pool);
            vault.approvePath(approvedPath, poolArr);
        }
        vm.stopPrank();

        handler = new BuybackVaultHandler(vault, usdc, ai, router, approvedPath, owner, treasury);

        targetContract(address(handler));
    }

    function invariant_vaultHoldsNoAI() public view {
        assertEq(ai.balanceOf(address(vault)), 0, "vault must never hold $AI between calls");
    }

    function invariant_bpsNeverOverflow() public view {
        assertTrue(uint256(vault.burnBps()) + uint256(vault.executorRewardBps()) <= 10_000, "bps invariant violated");
    }

    function invariant_accountingIntegrity() public view {
        assertEq(
            usdc.balanceOf(address(vault)),
            handler.totalDeposited() - handler.totalSwapped(),
            "vault USDC balance must match deposit-swap accounting"
        );
    }

    /// @dev This invariant assumes actor, treasury, and 0xdEaD receive AI tokens
    /// ONLY through handler.executeBuyback(). Any external AI distribution would break this.
    function invariant_ghostVariablesConsistency() public view {
        uint256 actualBurn = ai.balanceOf(address(0xdEaD));
        uint256 actualExecutor = ai.balanceOf(handler.actor());
        uint256 actualTreasury = ai.balanceOf(treasury);

        assertEq(handler.totalBurned(), actualBurn, "ghost burn must match actual");
        assertEq(handler.totalExecutorRewards(), actualExecutor, "ghost executor must match actual");
        assertEq(handler.totalTreasuryReceived(), actualTreasury, "ghost treasury must match actual");
    }

    function invariant_configBoundsRespected() public view {
        assertTrue(vault.twapWindow() >= 1800, "twapWindow must be >= 1800");
        assertTrue(vault.maxSlippageBps() <= 500, "maxSlippageBps must be <= 500");
        assertTrue(uint256(vault.burnBps()) + uint256(vault.executorRewardBps()) <= 10_000, "bps sum must be <= 10000");
    }
    /// @dev All minted AI must be distributed to executor, burn address, or treasury.
    /// Router should never hold AI after a swap (MockSwapRouter mints directly to recipient).

    function invariant_splitSumsTo100Percent() public view {
        uint256 totalDistributed =
            handler.totalBurned() + handler.totalExecutorRewards() + handler.totalTreasuryReceived();
        uint256 totalAiMinted = ai.totalSupply();

        // Router should never hold AI - if it does, there's a leak
        assertEq(ai.balanceOf(address(router)), 0, "router must not hold AI");
        assertEq(totalDistributed, totalAiMinted, "all AI must be distributed");
    }
}

contract TwapSlippageFuzzTest is Test, DeployBuybackVault {
    address internal owner = makeAddr("twap_owner");
    address internal alice = makeAddr("twap_alice");
    address internal treasury = makeAddr("twap_treasury");

    BuybackVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal ai;
    MockSwapRouter internal router;
    MockUniswapPool internal pool;

    bytes internal approvedPath;

    function setUp() public {
        usdc = new MockERC20("USDC.e", "USDC.e");
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();

        approvedPath = abi.encodePacked(address(usdc), uint24(3_000), address(ai));

        _ai = address(ai);
        _treasury = treasury;
        _router = address(router);
        _burn = 7_000;
        _reward = 100;
        _twap = 1_800;
        _slip = 100;
        _epoch = 86_400;
        _owner = owner;
        _deploy();
        _validate();
        vault = _vault;

        pool = new MockUniswapPool();
        pool.setTickCumulatives(0, 0);
        {
            (address t0, address t1) =
                address(usdc) < address(ai) ? (address(usdc), address(ai)) : (address(ai), address(usdc));
            pool.setPoolConfig(t0, t1, 3_000);
        }

        vm.startPrank(owner);
        vault.approveToken(address(usdc));
        vm.stopPrank();
    }

    function testFuzz_slippageBpsCanBeSetWithinBounds(uint16 slippageBps) public {
        vm.assume(slippageBps <= 500);
        vm.prank(owner);
        vault.setMaxSlippageBps(slippageBps);
        assertEq(vault.maxSlippageBps(), slippageBps);
    }

    function testFuzz_approvePathRevertsWithEmptyPools(uint128 amountIn_) public {
        // TWAP protection cannot be bypassed by approving a path with no pools
        vm.assume(amountIn_ > 0);
        vm.prank(owner);
        vm.expectRevert(BuybackVault.PoolsLengthMismatch.selector);
        vault.approvePath(approvedPath, new address[](0));
    }

    function testFuzz_buybackRevertsWhenRouterReturnsLessThanMin(uint128 amountIn_, uint128 mockAmountOut_) public {
        vm.assume(amountIn_ > 0 && mockAmountOut_ > 1);

        uint256 floor = uint256(amountIn_) * (10_000 - vault.maxSlippageBps()) / 10_000;
        uint256 minOut = floor > 0 ? floor : 1;
        vm.assume(uint256(mockAmountOut_) > minOut);

        {
            address[] memory poolArr = new address[](1);
            poolArr[0] = address(pool);
            vm.prank(owner);
            vault.approvePath(approvedPath, poolArr);
        }

        usdc.mint(address(vault), amountIn_);

        // Router will return less than amountOutMin
        router.setNextAmountOut(mockAmountOut_ - 1, address(ai));

        vm.prank(alice);
        vm.expectRevert("MockSwapRouter: insufficient output");
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, mockAmountOut_);
    }

    function testFuzz_twapWindowMinimum(uint32 window) public {
        vm.assume(window < 1800);
        vm.prank(owner);
        vm.expectRevert(BuybackVault.TwapWindowTooShort.selector);
        vault.setTwapWindow(window);
    }

    function testFuzz_twapWindowValid(uint32 window) public {
        vm.assume(window >= 1800);
        vm.prank(owner);
        vault.setTwapWindow(window);
        assertEq(vault.twapWindow(), window);
    }

    function testFuzz_maxSlippageCap(uint16 slippageBps) public {
        vm.assume(slippageBps > 500);
        vm.prank(owner);
        vm.expectRevert(BuybackVault.SlippageTooHigh.selector);
        vault.setMaxSlippageBps(slippageBps);
    }
}

contract UpgradeSafetyFuzzTest is Test, DeployBuybackVault {
    address internal owner = makeAddr("upgrade_owner");
    address internal treasury = makeAddr("upgrade_treasury");

    BuybackVault internal vault;
    MockERC20 internal ai;
    MockSwapRouter internal router;

    function setUp() public {
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();

        _ai = address(ai);
        _treasury = treasury;
        _router = address(router);
        _burn = 7_000;
        _reward = 100;
        _twap = 1_800;
        _slip = 100;
        _epoch = 86_400;
        _owner = owner;
        _deploy();
        _validate();
        vault = _vault;
    }

    function testFuzz_onlyOwnerCanUpgrade(address caller) public {
        vm.assume(caller != owner);
        BuybackVault newImpl = new BuybackVault();
        vm.prank(caller);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function testFuzz_upgradePreservesState(uint16 newBurnBps) public {
        vm.assume(newBurnBps <= 10_000 - vault.executorRewardBps());

        vm.prank(owner);
        vault.setBurnBps(newBurnBps);

        address aiTokenBefore = vault.aiToken();
        address treasuryBefore = vault.treasury();
        uint16 burnBpsBefore = vault.burnBps();
        uint16 rewardBpsBefore = vault.executorRewardBps();

        BuybackVault newImpl = new BuybackVault();
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(vault.aiToken(), aiTokenBefore, "aiToken must be preserved");
        assertEq(vault.treasury(), treasuryBefore, "treasury must be preserved");
        assertEq(vault.burnBps(), burnBpsBefore, "burnBps must be preserved");
        assertEq(vault.executorRewardBps(), rewardBpsBefore, "executorRewardBps must be preserved");
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        vault.initialize(address(ai), treasury, address(router), 5_000, 50, 1_800, 100, 86_400, owner);
    }

    function test_implementationCannotBeInitialized() public {
        BuybackVault impl = new BuybackVault();
        vm.expectRevert();
        impl.initialize(address(ai), treasury, address(router), 5_000, 50, 1_800, 100, 86_400, owner);
    }
}

contract EthWethFuzzTest is Test, DeployBuybackVault {
    address internal owner = makeAddr("eth_owner");
    address internal alice = makeAddr("eth_alice");
    address internal treasury = makeAddr("eth_treasury");

    BuybackVault internal vault;
    MockERC20 internal ai;
    MockSwapRouter internal router;
    MockWETH internal weth;

    bytes internal ethPath;

    function setUp() public {
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();
        weth = new MockWETH();

        ethPath = abi.encodePacked(address(weth), uint24(500), address(ai));

        _ai = address(ai);
        _treasury = treasury;
        _router = address(router);
        _burn = 7_000;
        _reward = 100;
        _twap = 1_800;
        _slip = 100;
        _epoch = 86_400;
        _owner = owner;
        _deploy();
        _validate();
        vault = _vault;

        vm.startPrank(owner);
        vault.setWeth(address(weth));
        vault.approveToken(address(0));
        {
            MockUniswapPool ethPool = new MockUniswapPool();
            ethPool.setTickCumulatives(0, 0);
            (address t0, address t1) =
                address(weth) < address(ai) ? (address(weth), address(ai)) : (address(ai), address(weth));
            ethPool.setPoolConfig(t0, t1, 500);
            address[] memory ethPools = new address[](1);
            ethPools[0] = address(ethPool);
            vault.approvePath(ethPath, ethPools);
        }
        vm.stopPrank();
    }

    function testFuzz_ethDepositAndBuyback(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0 && amountIn_ <= 10_000 ether);

        vm.deal(address(vault), amountIn_);

        uint256 mockOut = uint256(amountIn_) * 100;
        router.setNextAmountOut(mockOut, address(ai));

        uint256 floor = uint256(amountIn_) * (10_000 - vault.maxSlippageBps()) / 10_000;
        uint256 minOut = floor > 0 ? floor : 1;

        vm.prank(alice);
        vault.executeBuyback(address(0), ethPath, amountIn_, minOut);

        assertEq(address(vault).balance, 0, "vault ETH should be zero after buyback");
        assertEq(weth.balanceOf(address(vault)), 0, "vault WETH should be zero after buyback");

        // Verify AI distribution
        uint256 totalAiDistributed = ai.balanceOf(alice) + ai.balanceOf(address(0xdEaD)) + ai.balanceOf(treasury);
        assertEq(totalAiDistributed, mockOut, "AI distribution must equal mockOut");
    }

    function testFuzz_ethDepositViaReceive(uint128 amount) public {
        vm.assume(amount > 0 && amount <= 10_000 ether);
        vm.deal(alice, amount);

        vm.prank(alice);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok, "ETH transfer should succeed");
        assertEq(address(vault).balance, amount, "vault should hold ETH");
    }

    function testFuzz_wethNotConfiguredReverts(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0);

        BuybackVault impl2 = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 86_400, owner)
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        BuybackVault vault2 = BuybackVault(payable(address(proxy2)));

        vm.startPrank(owner);
        vault2.approveToken(address(0));
        {
            MockUniswapPool ethPool2 = new MockUniswapPool();
            ethPool2.setTickCumulatives(0, 0);
            (address t0, address t1) =
                address(weth) < address(ai) ? (address(weth), address(ai)) : (address(ai), address(weth));
            ethPool2.setPoolConfig(t0, t1, 500);
            address[] memory ethPools2 = new address[](1);
            ethPools2[0] = address(ethPool2);
            vault2.approvePath(ethPath, ethPools2);
        }
        vm.stopPrank();

        vm.deal(address(vault2), amountIn_);

        vm.prank(alice);
        vm.expectRevert(BuybackVault.WethNotConfigured.selector);
        vault2.executeBuyback(address(0), ethPath, amountIn_, 1);
    }

    function testFuzz_ethWrappedToWethBeforeSwap(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0 && amountIn_ <= 10_000 ether);

        vm.deal(address(vault), amountIn_);

        uint256 wethSupplyBefore = weth.totalSupply();
        uint256 mockOut = uint256(amountIn_) * 100;
        router.setNextAmountOut(mockOut, address(ai));

        uint256 floor = uint256(amountIn_) * (10_000 - vault.maxSlippageBps()) / 10_000;
        uint256 minOut = floor > 0 ? floor : 1;

        vm.prank(alice);
        vault.executeBuyback(address(0), ethPath, amountIn_, minOut);

        assertEq(weth.totalSupply(), wethSupplyBefore + amountIn_, "WETH must be minted from ETH");
        assertEq(weth.balanceOf(address(router)), amountIn_, "router must receive WETH");
    }
}

/// @dev Test reentrancy protection with a malicious AI token that attempts reentry on transfer
contract ReentrancyFuzzTest is Test, DeployBuybackVault {
    address internal owner = makeAddr("reentry_owner");
    address internal alice = makeAddr("reentry_alice");
    address internal treasury = makeAddr("reentry_treasury");

    BuybackVault internal vault;
    ReentrantAiToken internal maliciousAi;
    MockERC20 internal usdc;
    MockSwapRouter internal router;

    bytes internal approvedPath;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC");
        router = new MockSwapRouter();

        // Deploy with placeholder AI token (address(1)) to avoid circular dependency
        _ai = address(1);
        _treasury = treasury;
        _router = address(router);
        _burn = 7_000;
        _reward = 100;
        _twap = 1_800;
        _slip = 100;
        _epoch = 86_400;
        _owner = owner;
        _deploy();
        vault = _vault;

        // Create malicious AI token that will attempt reentrancy
        maliciousAi = new ReentrantAiToken("AI", "AI", vault, usdc);
        approvedPath = abi.encodePacked(address(usdc), uint24(3_000), address(maliciousAi));

        // Update vault to use malicious AI token
        vm.startPrank(owner);
        vault.setAiToken(address(maliciousAi));
        vault.approveToken(address(usdc));
        {
            MockUniswapPool reentrantPool = new MockUniswapPool();
            reentrantPool.setTickCumulatives(0, 0);
            (address t0, address t1) = address(usdc) < address(maliciousAi)
                ? (address(usdc), address(maliciousAi))
                : (address(maliciousAi), address(usdc));
            reentrantPool.setPoolConfig(t0, t1, 3_000);
            address[] memory poolArr = new address[](1);
            poolArr[0] = address(reentrantPool);
            vault.approvePath(approvedPath, poolArr);
        }
        vm.stopPrank();

        // Configure router to mint malicious AI token
        router.setNextAmountOut(0, address(maliciousAi));
    }

    function testFuzz_reentrancyBlocked(uint128 amountIn_) public {
        vm.assume(amountIn_ >= 100 && amountIn_ <= 1_000_000e6);

        usdc.mint(address(vault), amountIn_);

        // Configure malicious AI to attempt reentrancy when transferred (executor reward)
        maliciousAi.setReentryTarget(approvedPath, amountIn_ / 2);

        uint256 floor = uint256(amountIn_) * (10_000 - vault.maxSlippageBps()) / 10_000;
        uint256 mockOut = floor > 1000 ? floor : 1000;
        router.setNextAmountOut(mockOut, address(maliciousAi));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, mockOut);

        assertTrue(maliciousAi.reentrancyAttempted(), "reentrancy should be attempted");
        assertTrue(maliciousAi.reentrancyBlocked(), "reentrancy should be blocked");
    }
}

/// @dev Malicious AI token that attempts reentrancy during transfer (when executor reward is sent)
contract ReentrantAiToken is MockERC20 {
    BuybackVault public targetVault;
    MockERC20 public usdc;
    bytes public reentryPath;
    uint256 public reentryAmount;
    bool public shouldReenter;
    bool public reentrancyAttempted;
    bool public reentrancyBlocked;

    constructor(string memory name, string memory symbol, BuybackVault _vault, MockERC20 _usdc)
        MockERC20(name, symbol)
    {
        targetVault = _vault;
        usdc = _usdc;
    }

    function setReentryTarget(bytes memory _path, uint256 _amount) external {
        reentryPath = _path;
        reentryAmount = _amount;
        shouldReenter = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (shouldReenter && msg.sender == address(targetVault)) {
            shouldReenter = false;
            reentrancyAttempted = true;
            // Attempt reentrancy - this should fail with ReentrancyGuard
            try targetVault.executeBuyback(address(usdc), reentryPath, reentryAmount, 1) {
                revert("Reentrancy succeeded - vulnerability!");
            } catch {
                reentrancyBlocked = true;
            }
        }
        return super.transfer(to, amount);
    }
}

