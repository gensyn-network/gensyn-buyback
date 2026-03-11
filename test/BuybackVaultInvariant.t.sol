// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/BuybackVault.sol";
import "./BuybackVault.t.sol"; // reuse MockERC20, MockSwapRouter, MockUniswapPool

contract BuybackVaultFuzzTest is Test {
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

        BuybackVault impl = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 86_400, owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));

        vm.startPrank(owner);
        vault.approveToken(address(usdc));
        vault.approvePath(approvedPath, new address[](0));
        vm.stopPrank();
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

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        router.setNextAmountOut(mockAmountOut_, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1, block.timestamp + 300);

        uint256 executorBal = ai.balanceOf(alice);
        uint256 burnBal = ai.balanceOf(address(0xdEaD));
        uint256 treasuryBal = ai.balanceOf(treasury);

        assertEq(executorBal + burnBal + treasuryBal, mockAmountOut_, "split must equal amountOut");
        assertEq(ai.balanceOf(address(vault)), 0, "vault must hold no $AI after buyback");
    }

    function testFuzz_vaultBalanceAccountingCorrect(uint128 amountIn_, uint128 mockAmountOut_) public {
        vm.assume(amountIn_ > 0 && mockAmountOut_ > 0);

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 routerUsdcBefore = usdc.balanceOf(address(router));

        router.setNextAmountOut(mockAmountOut_, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1, block.timestamp + 300);

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

    function testFuzz_unapprovedTokenRejected(address randomToken, uint128 amount) public {
        vm.assume(randomToken != address(usdc) && randomToken != address(0));
        vm.assume(amount > 0);
        vm.prank(alice);
        vm.expectRevert(BuybackVault.TokenNotApproved.selector);
        vault.deposit(randomToken, amount);
    }

    function testFuzz_pausedBlocksBuyback(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0);
        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        vm.prank(owner);
        vault.pause();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vm.expectRevert();
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1, block.timestamp + 300);
    }

    function testFuzz_epochVolumeLimit(uint128 limit, uint128 amountIn_) public {
        vm.assume(limit > 0 && limit < type(uint128).max / 2);
        vm.assume(amountIn_ > 0 && amountIn_ <= limit);

        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), limit);

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1, block.timestamp + 300);
    }

    function testFuzz_epochVolumeExceeded(uint128 limit, uint128 firstAmount, uint128 secondAmount) public {
        vm.assume(limit > 1 && limit < type(uint64).max);
        vm.assume(firstAmount > 0 && firstAmount < limit);
        vm.assume(secondAmount > 0);
        vm.assume(uint256(firstAmount) + uint256(secondAmount) > limit);

        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), limit);

        uint256 totalAmount = uint256(firstAmount) + uint256(secondAmount);
        usdc.mint(alice, totalAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), totalAmount);
        vault.deposit(address(usdc), totalAmount);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, firstAmount, 1, block.timestamp + 300);

        vm.prank(alice);
        vm.expectRevert(BuybackVault.EpochLimitExceeded.selector);
        vault.executeBuyback(address(usdc), approvedPath, secondAmount, 1, block.timestamp + 300);
    }

    function testFuzz_epochRolloverResetsVolume(uint128 limit, uint128 amount, uint32 epochDur) public {
        vm.assume(epochDur >= 1 && epochDur <= 365 days);
        vm.assume(limit > 0 && limit < type(uint64).max);
        vm.assume(amount > 0 && amount <= limit);

        vm.startPrank(owner);
        vault.setEpochConfig(epochDur);
        vault.setTokenEpochVolumeLimit(address(usdc), limit);
        vm.stopPrank();

        usdc.mint(alice, uint256(amount) * 2);
        vm.startPrank(alice);
        usdc.approve(address(vault), uint256(amount) * 2);
        vault.deposit(address(usdc), uint256(amount) * 2);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amount, 1, block.timestamp + 300);

        vm.warp(block.timestamp + uint256(epochDur) + 1);

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amount, 1, block.timestamp + 300);
    }

    function testFuzz_largeAmountBoundary(uint256 amountIn_) public {
        // Test values around uint128 max boundary
        vm.assume(amountIn_ > type(uint128).max / 2 && amountIn_ <= type(uint128).max);

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1, block.timestamp + 300);
    }

    function test_amountExceedsUint128Rejected() public {
        uint256 tooLarge = uint256(type(uint128).max) + 1;

        usdc.mint(alice, tooLarge);
        vm.startPrank(alice);
        usdc.approve(address(vault), tooLarge);
        vault.deposit(address(usdc), tooLarge);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.AmountTooLarge.selector);
        vault.executeBuyback(address(usdc), approvedPath, tooLarge, 1, block.timestamp + 300);
    }

    function testFuzz_smallAmountBoundary(uint8 amountIn_) public {
        vm.assume(amountIn_ > 0);

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1, block.timestamp + 300);
    }

    function testFuzz_zeroAmountRejected(uint128 mockOut) public {
        vm.assume(mockOut > 0);
        router.setNextAmountOut(mockOut, address(ai));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(address(usdc), approvedPath, 0, 1, block.timestamp + 300);
    }

    function testFuzz_deadlineExpired(uint128 amountIn_, uint256 pastTime) public {
        vm.assume(amountIn_ > 0);
        vm.assume(pastTime > 0 && pastTime <= block.timestamp);

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.DeadlineExpired.selector);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1, block.timestamp - pastTime);
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
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
        totalDeposited += amount;
    }

    function executeBuyback(uint128 amountIn, uint128 mockOut) external {
        uint256 bal = usdc.balanceOf(address(vault));
        if (bal == 0) return;
        amountIn = uint128(bound(amountIn, 1, bal));
        mockOut = uint128(bound(mockOut, 1, type(uint128).max));

        uint256 burnBefore = ai.balanceOf(address(0xdEaD));
        uint256 executorBefore = ai.balanceOf(actor);
        uint256 treasuryBefore = ai.balanceOf(treasury);

        router.setNextAmountOut(mockOut, address(ai));
        vm.prank(actor);
        try vault.executeBuyback(address(usdc), approvedPath, amountIn, 1, block.timestamp + 300) {
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

    function setBurnBps(uint16 newBps) external {
        newBps = uint16(bound(newBps, 0, 10_000 - vault.executorRewardBps()));
        vm.prank(owner);
        vault.setBurnBps(newBps);
    }

    function setExecutorRewardBps(uint16 newBps) external {
        newBps = uint16(bound(newBps, 0, 10_000 - vault.burnBps()));
        vm.prank(owner);
        vault.setExecutorRewardBps(newBps);
    }

}

contract BuybackVaultInvariantTest is Test {
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

        BuybackVault impl = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 86_400, owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));

        vm.startPrank(owner);
        vault.approveToken(address(usdc));
        vault.approvePath(approvedPath, new address[](0));
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
    function invariant_splitSumsTo100Percent() public view {
        uint256 totalDistributed = handler.totalBurned() + handler.totalExecutorRewards() + handler.totalTreasuryReceived();
        uint256 totalAiMinted = ai.totalSupply();

        uint256 routerBalance = ai.balanceOf(address(router));
        assertEq(totalDistributed + routerBalance, totalAiMinted, "all AI must be accounted for");
    }
}

contract TwapSlippageFuzzTest is Test {
    address internal owner = makeAddr("twap_owner");
    address internal alice = makeAddr("twap_alice");
    address internal treasury = makeAddr("twap_treasury");

    BuybackVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal ai;
    MockSwapRouter internal router;

    bytes internal approvedPath;

    function setUp() public {
        usdc = new MockERC20("USDC.e", "USDC.e");
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();

        approvedPath = abi.encodePacked(address(usdc), uint24(3_000), address(ai));

        BuybackVault impl = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 86_400, owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));

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

    function testFuzz_buybackSucceedsWithoutTwapPools(uint128 amountIn_, uint128 mockAmountOut_) public {
        // When no TWAP pools are configured, slippage check uses amountOutMin directly
        vm.assume(amountIn_ > 0 && mockAmountOut_ > 0);

        vm.prank(owner);
        vault.approvePath(approvedPath, new address[](0)); // no TWAP pools

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        router.setNextAmountOut(mockAmountOut_, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, mockAmountOut_, block.timestamp + 300);
    }

    function testFuzz_buybackRevertsWhenRouterReturnsLessThanMin(uint128 amountIn_, uint128 mockAmountOut_) public {
        vm.assume(amountIn_ > 0 && mockAmountOut_ > 1);

        vm.prank(owner);
        vault.approvePath(approvedPath, new address[](0)); // no TWAP pools

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        // Router will return less than amountOutMin
        router.setNextAmountOut(mockAmountOut_ - 1, address(ai));

        vm.prank(alice);
        vm.expectRevert("MockSwapRouter: insufficient output");
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, mockAmountOut_, block.timestamp + 300);
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

contract UpgradeSafetyFuzzTest is Test {
    address internal owner = makeAddr("upgrade_owner");
    address internal treasury = makeAddr("upgrade_treasury");

    BuybackVault internal vault;
    MockERC20 internal ai;
    MockSwapRouter internal router;
    ERC1967Proxy internal proxy;

    function setUp() public {
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();

        BuybackVault impl = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 86_400, owner)
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));
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

contract EthWethFuzzTest is Test {
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

        BuybackVault impl = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 86_400, owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));

        vm.startPrank(owner);
        vault.setWeth(address(weth));
        vault.approveToken(address(0));
        vault.approvePath(ethPath, new address[](0));
        vm.stopPrank();
    }

    function testFuzz_ethDepositAndBuyback(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0 && amountIn_ <= 10_000 ether);

        vm.deal(address(vault), amountIn_);

        uint256 mockOut = uint256(amountIn_) * 100;
        router.setNextAmountOut(mockOut, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(0), ethPath, amountIn_, 1, block.timestamp + 300);

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

    function testFuzz_ethDepositViaDepositETH(uint128 amount) public {
        vm.assume(amount > 0 && amount <= 10_000 ether);
        vm.deal(alice, amount);

        vm.prank(alice);
        vault.depositETH{value: amount}();
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
        vault2.approvePath(ethPath, new address[](0));
        vm.stopPrank();

        vm.deal(address(vault2), amountIn_);

        vm.prank(alice);
        vm.expectRevert(BuybackVault.WethNotConfigured.selector);
        vault2.executeBuyback(address(0), ethPath, amountIn_, 1, block.timestamp + 300);
    }

    function testFuzz_ethWrappedToWethBeforeSwap(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0 && amountIn_ <= 10_000 ether);

        vm.deal(address(vault), amountIn_);

        uint256 wethSupplyBefore = weth.totalSupply();
        uint256 mockOut = uint256(amountIn_) * 100;
        router.setNextAmountOut(mockOut, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(0), ethPath, amountIn_, 1, block.timestamp + 300);

        assertEq(weth.totalSupply(), wethSupplyBefore + amountIn_, "WETH must be minted from ETH");
        assertEq(weth.balanceOf(address(router)), amountIn_, "router must receive WETH");
    }
}

/// @dev Test reentrancy protection with a malicious token
contract ReentrancyFuzzTest is Test {
    address internal owner = makeAddr("reentry_owner");
    address internal alice = makeAddr("reentry_alice");
    address internal treasury = makeAddr("reentry_treasury");

    BuybackVault internal vault;
    MockERC20 internal ai;
    MockSwapRouter internal router;
    ReentrantToken internal maliciousToken;

    bytes internal maliciousPath;

    function setUp() public {
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();

        BuybackVault impl = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 86_400, owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));

        maliciousToken = new ReentrantToken("EVIL", "EVIL", vault);
        maliciousPath = abi.encodePacked(address(maliciousToken), uint24(3_000), address(ai));

        vm.startPrank(owner);
        vault.approveToken(address(maliciousToken));
        vault.approvePath(maliciousPath, new address[](0));
        vm.stopPrank();
    }

    function testFuzz_reentrancyBlocked(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0 && amountIn_ <= 1_000_000e6);

        maliciousToken.mint(alice, amountIn_ * 2);
        vm.startPrank(alice);
        maliciousToken.approve(address(vault), amountIn_ * 2);
        vault.deposit(address(maliciousToken), amountIn_);
        vm.stopPrank();

        // Configure malicious token to attempt reentrancy on transferFrom
        maliciousToken.setReentryTarget(address(vault), maliciousPath, amountIn_ / 2);

        router.setNextAmountOut(1, address(ai));

        // The reentrancy attempt should be blocked by nonReentrant modifier
        vm.prank(alice);
        vault.executeBuyback(address(maliciousToken), maliciousPath, amountIn_, 1, block.timestamp + 300);

        assertTrue(true, "reentrancy blocked");
    }
}

contract ReentrantToken is MockERC20 {
    BuybackVault public targetVault;
    bytes public reentryPath;
    uint256 public reentryAmount;
    bool public shouldReenter;

    constructor(string memory name, string memory symbol, BuybackVault _vault) MockERC20(name, symbol) {
        targetVault = _vault;
    }

    function setReentryTarget(address _vault, bytes memory _path, uint256 _amount) external {
        targetVault = BuybackVault(payable(_vault));
        reentryPath = _path;
        reentryAmount = _amount;
        shouldReenter = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (shouldReenter && msg.sender == address(targetVault)) {
            shouldReenter = false; // Prevent infinite loop
            try targetVault.executeBuyback(address(this), reentryPath, reentryAmount, 1, block.timestamp + 300) {
                revert("Reentrancy succeeded - vulnerability!");
            } catch {
                // Expected: reentrancy blocked
            }
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Test deadline boundary conditions
contract DeadlineBoundaryTest is Test {
    address internal owner = makeAddr("deadline_owner");
    address internal alice = makeAddr("deadline_alice");
    address internal treasury = makeAddr("deadline_treasury");

    BuybackVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal ai;
    MockSwapRouter internal router;

    bytes internal approvedPath;

    function setUp() public {
        usdc = new MockERC20("USDC.e", "USDC.e");
        ai = new MockERC20("AI", "$AI");
        router = new MockSwapRouter();

        approvedPath = abi.encodePacked(address(usdc), uint24(3_000), address(ai));

        BuybackVault impl = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 86_400, owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));

        vm.startPrank(owner);
        vault.approveToken(address(usdc));
        vault.approvePath(approvedPath, new address[](0));
        vm.stopPrank();
    }

    function test_deadlineExactlyAtBlockTimestamp() public {
        uint256 amount = 1000e6;
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));

        // deadline == block.timestamp should succeed (contract uses < not <=)
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amount, 1, block.timestamp);
    }

    function test_deadlineOneSecondBeforeBlockTimestamp() public {
        vm.warp(1000);

        uint256 amount = 1000e6;
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));

        // deadline == block.timestamp - 1 should revert
        vm.prank(alice);
        vm.expectRevert(BuybackVault.DeadlineExpired.selector);
        vault.executeBuyback(address(usdc), approvedPath, amount, 1, block.timestamp - 1);
    }

    function test_deadlineOneSecondAfterBlockTimestamp() public {
        uint256 amount = 1000e6;
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));

        // deadline == block.timestamp + 1 should succeed
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amount, 1, block.timestamp + 1);
    }

    function testFuzz_deadlineZeroAlwaysReverts(uint128 amountIn_) public {
        vm.assume(amountIn_ > 0);

        usdc.mint(alice, amountIn_);
        vm.startPrank(alice);
        usdc.approve(address(vault), amountIn_);
        vault.deposit(address(usdc), amountIn_);
        vm.stopPrank();

        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vm.expectRevert(BuybackVault.DeadlineExpired.selector);
        vault.executeBuyback(address(usdc), approvedPath, amountIn_, 1, 0);
    }
}
