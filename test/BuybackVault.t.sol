// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/BuybackVault.sol";
import "../script/DeployBuybackVault.s.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockSwapRouter {
    uint256 public nextAmountOut;
    address public tokenOut;

    function setNextAmountOut(uint256 amount, address _tokenOut) external {
        nextAmountOut = amount;
        tokenOut = _tokenOut;
    }

    function exactInput(ISwapRouter.ExactInputParams calldata params) external returns (uint256 amountOut) {
        address tokenIn;
        bytes memory path = params.path;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
        }
        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        amountOut = nextAmountOut;
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: insufficient output");

        MockERC20(tokenOut).mint(params.recipient, amountOut);
    }
}

contract MockUniswapPool {
    int56 public tickCumulative0;
    int56 public tickCumulative1;

    address private _token0;
    address private _token1;
    uint24 private _fee;

    function setTickCumulatives(int56 past, int56 now_) external {
        tickCumulative0 = past;
        tickCumulative1 = now_;
    }

    function setPoolConfig(address t0, address t1, uint24 fee_) external {
        _token0 = t0;
        _token1 = t1;
        _fee = fee_;
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external view returns (address) {
        return _token1;
    }

    function fee() external view returns (uint24) {
        return _fee;
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulative0;
        tickCumulatives[1] = tickCumulative1;
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }
}

contract BuybackVaultTest is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    BuybackVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal ai;
    MockSwapRouter internal router;
    MockUniswapPool internal pool;

    uint16 constant BURN_BPS = 7_000;
    uint16 constant REWARD_BPS = 100;
    uint32 constant TWAP_WINDOW = 1_800;
    uint16 constant SLIPPAGE_BPS = 100;
    uint256 constant EPOCH_DUR = 86_400;
    uint256 constant EPOCH_VOL_LIM = 1_000_000e6;

    bytes internal approvedPath;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC.e");
        ai = new MockERC20("AI Token", "$AI");
        router = new MockSwapRouter();
        pool = new MockUniswapPool();

        pool.setTickCumulatives(0, 0);

        approvedPath = abi.encodePacked(address(usdc), uint24(3_000), address(ai));

        {
            (address t0, address t1) =
                address(usdc) < address(ai) ? (address(usdc), address(ai)) : (address(ai), address(usdc));
            pool.setPoolConfig(t0, t1, 3_000);
        }

        DeployBuybackVault script = new DeployBuybackVault();
        (, vault) = script.deploy(
            address(ai),
            bob,
            address(router),
            BURN_BPS,
            REWARD_BPS,
            TWAP_WINDOW,
            SLIPPAGE_BPS,
            EPOCH_DUR,
            owner,
            address(usdc),
            approvedPath,
            address(pool)
        );

        vm.startPrank(owner);
        vault.approveToken(address(usdc));
        vault.approvePath(approvedPath, new address[](0));
        vm.stopPrank();
    }

    function test_initialState() public view {
        assertEq(vault.aiToken(), address(ai));
        assertEq(vault.treasury(), bob);
        assertEq(vault.swapRouter(), address(router));
        assertEq(vault.burnBps(), BURN_BPS);
        assertEq(vault.executorRewardBps(), REWARD_BPS);
        assertEq(vault.twapWindow(), TWAP_WINDOW);
        assertEq(vault.maxSlippageBps(), SLIPPAGE_BPS);
        assertEq(vault.owner(), owner);
        assertFalse(vault.paused());
    }

    function test_initRevertsOnZeroAiToken() public {
        BuybackVault impl2 = new BuybackVault();
        bytes memory bad = abi.encodeCall(
            BuybackVault.initialize,
            (address(0), bob, address(router), BURN_BPS, REWARD_BPS, TWAP_WINDOW, SLIPPAGE_BPS, EPOCH_DUR, owner)
        );
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initRevertsOnBpsOverflow() public {
        BuybackVault impl2 = new BuybackVault();
        bytes memory bad = abi.encodeCall(
            BuybackVault.initialize,
            (address(ai), bob, address(router), 9_000, 2_000, TWAP_WINDOW, SLIPPAGE_BPS, EPOCH_DUR, owner)
        );
        vm.expectRevert(BuybackVault.BpsOverflow.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_deposit_emitsEvent() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vm.expectEmit(true, true, false, true);
        emit IBuybackVault.Deposited(address(usdc), alice, 1_000e6);
        vault.deposit(address(usdc), 1_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_deposit_revertsUnapprovedToken() public {
        MockERC20 rando = new MockERC20("Rando", "RND");
        rando.mint(alice, 100);
        vm.startPrank(alice);
        rando.approve(address(vault), 100);
        vm.expectRevert(BuybackVault.TokenNotApproved.selector);
        vault.deposit(address(rando), 100);
        vm.stopPrank();
    }

    function test_deposit_revertsZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.deposit(address(usdc), 0);
        vm.stopPrank();
    }

    function test_depositETH() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vault.depositETH{value: 1 ether}();
        assertEq(address(vault).balance, 1 ether);
    }

    function test_receiveETH() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 1 ether);
    }

    function _seedVault(uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function test_executeBuyback_splitsMath() public {
        uint256 amountIn = 1_000e6;
        uint256 amountOut = 500e18;
        _seedVault(amountIn);
        router.setNextAmountOut(amountOut, address(ai));

        uint256 expectedReward = (amountOut * REWARD_BPS) / 10_000;
        uint256 expectedBurn = ((amountOut - expectedReward) * BURN_BPS) / 10_000;
        uint256 expectedTreasury = amountOut - expectedReward - expectedBurn;

        vm.expectEmit(true, false, false, true);
        emit IBuybackVault.BuybackExecuted(
            address(usdc), amountIn, amountOut, expectedReward, expectedBurn, expectedTreasury
        );

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn, 1, block.timestamp + 300);

        assertEq(ai.balanceOf(alice), expectedReward, "executor reward");
        assertEq(ai.balanceOf(address(0xdEaD)), expectedBurn, "burn");
        assertEq(ai.balanceOf(bob), expectedTreasury, "treasury");
        assertEq(ai.balanceOf(address(vault)), 0, "vault should be empty");
    }

    function test_executeBuyback_revertsUnapprovedToken() public {
        MockERC20 rando = new MockERC20("R", "R");
        vm.prank(alice);
        vm.expectRevert(BuybackVault.TokenNotApproved.selector);
        vault.executeBuyback(address(rando), approvedPath, 1e6, 1, block.timestamp + 300);
    }

    function test_executeBuyback_revertsUnapprovedPath() public {
        bytes memory badPath = abi.encodePacked(address(usdc), uint24(500), address(ai));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.PathNotApproved.selector);
        vault.executeBuyback(address(usdc), badPath, 1e6, 1, block.timestamp + 300);
    }

    function test_executeBuyback_revertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.executeBuyback(address(usdc), approvedPath, 1e6, 1, block.timestamp + 300);
    }

    function test_executeBuyback_revertsZeroAmountIn() public {
        vm.prank(alice);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(address(usdc), approvedPath, 0, 1, block.timestamp + 300);
    }

    function test_executeBuyback_revertsExpiredDeadline() public {
        _seedVault(1_000e6);
        router.setNextAmountOut(1, address(ai));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.DeadlineExpired.selector);
        vault.executeBuyback(address(usdc), approvedPath, 1_000e6, 1, block.timestamp - 1);
    }

    function test_executeBuyback_epochLimitEnforced() public {
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), 500e6);

        _seedVault(1_000e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 500e6, 1, block.timestamp + 300);

        vm.prank(alice);
        vm.expectRevert(BuybackVault.EpochLimitExceeded.selector);
        vault.executeBuyback(address(usdc), approvedPath, 1e6, 1, block.timestamp + 300);
    }

    function test_executeBuyback_epochResetsAfterDuration() public {
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), 500e6);

        _seedVault(2_000e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 500e6, 1, block.timestamp + 300);

        uint256 warpTo = block.timestamp + EPOCH_DUR + 1;
        vm.warp(warpTo);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 500e6, 1, warpTo + 300);
    }

    function test_executeBuyback_rejectsBelowTwapFloor() public {
        pool.setTickCumulatives(0, 180_000);

        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));

        _seedVault(1_000e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vm.expectRevert(BuybackVault.SlippageExceeded.selector);
        vault.executeBuyback(address(usdc), approvedPath, 1_000e6, 1, block.timestamp + 300);
    }

    function test_setBurnBps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setBurnBps(5_000);
    }

    function test_setBurnBps_overflowReverts() public {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.BpsOverflow.selector);
        vault.setBurnBps(9_950); // 9950 + 100 > 10000
    }

    function test_setBurnBps_success() public {
        vm.prank(owner);
        vault.setBurnBps(5_000);
        assertEq(vault.burnBps(), 5_000);
    }

    function test_setExecutorRewardBps_overflowReverts() public {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.BpsOverflow.selector);
        vault.setExecutorRewardBps(3_500); // 7000 + 3500 > 10000
    }

    function test_setTreasury_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setTreasury(alice);
    }

    function test_setTwapWindow_minimum() public {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.TwapWindowTooShort.selector);
        vault.setTwapWindow(299);
    }

    function test_setMaxSlippageBps_cap() public {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.SlippageTooHigh.selector);
        vault.setMaxSlippageBps(501);
    }

    function test_approveToken_and_revoke() public {
        MockERC20 newTok = new MockERC20("T", "T");
        vm.prank(owner);
        vault.approveToken(address(newTok));
        assertTrue(vault.approvedTokens(address(newTok)));

        vm.prank(owner);
        vault.revokeToken(address(newTok));
        assertFalse(vault.approvedTokens(address(newTok)));
    }

    function test_approvePath_and_revoke() public {
        bytes memory newPath = abi.encodePacked(address(usdc), uint24(500), address(ai));
        vm.prank(owner);
        vault.approvePath(newPath, new address[](0)); // no TWAP pool needed
        assertTrue(vault.approvedPaths(keccak256(newPath)));

        vm.prank(owner);
        vault.revokePath(newPath);
        assertFalse(vault.approvedPaths(keccak256(newPath)));
    }

    function test_pause_unpause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_emergencySweep_erc20() public {
        usdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        vault.pause();

        uint256 before = usdc.balanceOf(owner);
        vm.prank(owner);
        vault.emergencySweep(address(usdc), owner, 1_000e6);
        assertEq(usdc.balanceOf(owner), before + 1_000e6);
    }

    function test_emergencySweep_eth() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(owner);
        vault.pause();

        uint256 before = owner.balance;
        vm.prank(owner);
        vault.emergencySweep(address(0), owner, 1 ether);
        assertEq(owner.balance, before + 1 ether);
    }

    function test_emergencySweep_revertsWhenNotPaused() public {
        usdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        vm.expectRevert();
        vault.emergencySweep(address(usdc), owner, 1_000e6);
    }

    function test_emergencySweep_onlyOwner() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.emergencySweep(address(usdc), alice, 1);
    }

    function test_ownershipTransferTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(alice);
        // Still previous owner until alice accepts
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), alice);

        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
    }

    function test_upgrade_onlyOwner() public {
        BuybackVault impl2 = new BuybackVault();
        vm.prank(alice);
        vm.expectRevert();
        vault.upgradeToAndCall(address(impl2), "");
    }

    function test_approvePath_rejectsPathNotEndingWithAiToken() public {
        MockERC20 rando = new MockERC20("Rando", "RND");
        bytes memory badPath = abi.encodePacked(address(usdc), uint24(3_000), address(rando));
        vm.prank(owner);
        vm.expectRevert(BuybackVault.InvalidPathOutput.selector);
        vault.approvePath(badPath, new address[](0));
    }

    function test_approvePath_rejectsShortPath() public {
        bytes memory tooShort = abi.encodePacked(address(usdc), uint24(3_000)); // 23 bytes
        vm.prank(owner);
        vm.expectRevert(BuybackVault.InvalidPath.selector);
        vault.approvePath(tooShort, new address[](0));
    }

    function test_approvePath_rejectsInvalidLengthPath() public {
        bytes memory badLen = new bytes(44); // 44 != 20 + 23*n
        vm.prank(owner);
        vm.expectRevert(BuybackVault.InvalidPath.selector);
        vault.approvePath(badLen, new address[](0));
    }

    function test_approvePath_singlePoolStored() public {
        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));
        assertEq(vault.pathPools(keccak256(approvedPath), 0), address(pool));
    }

    function test_approvePath_rejectsPoolsLengthMismatch() public {
        MockERC20 mid = new MockERC20("MidToken", "MID");
        bytes memory twoHop = abi.encodePacked(address(usdc), uint24(500), address(mid), uint24(3_000), address(ai));
        vm.prank(owner);
        vm.expectRevert(BuybackVault.PoolsLengthMismatch.selector);
        vault.approvePath(twoHop, _singlePool(address(pool)));
    }

    function test_approvePath_multiHopWithNoPool() public {
        MockERC20 mid = new MockERC20("MidToken", "MID");
        bytes memory twoHop = abi.encodePacked(address(usdc), uint24(500), address(mid), uint24(3_000), address(ai));
        vm.prank(owner);
        vault.approvePath(twoHop, new address[](0));
        assertTrue(vault.approvedPaths(keccak256(twoHop)));
    }

    function test_approvePath_rejectsPoolTokenMismatch() public {
        MockUniswapPool wrongPool = new MockUniswapPool();
        MockERC20 rando = new MockERC20("Rando", "RND");
        (address t0, address t1) =
            address(rando) < address(ai) ? (address(rando), address(ai)) : (address(ai), address(rando));
        wrongPool.setPoolConfig(t0, t1, 3_000);
        wrongPool.setTickCumulatives(0, 0);

        vm.prank(owner);
        vm.expectRevert(); // pool token0 or token1 mismatch
        vault.approvePath(approvedPath, _singlePool(address(wrongPool)));
    }

    function test_approvePath_rejectsPoolFeeMismatch() public {
        MockUniswapPool wrongFeePool = new MockUniswapPool();
        (address t0, address t1) =
            address(usdc) < address(ai) ? (address(usdc), address(ai)) : (address(ai), address(usdc));
        wrongFeePool.setPoolConfig(t0, t1, 500); // path uses 3000
        wrongFeePool.setTickCumulatives(0, 0);

        vm.prank(owner);
        vm.expectRevert(BuybackVault.PoolMismatch.selector);
        vault.approvePath(approvedPath, _singlePool(address(wrongFeePool)));
    }

    function test_revokePath_clearsPools() public {
        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));
        assertEq(vault.pathPools(keccak256(approvedPath), 0), address(pool));

        vm.prank(owner);
        vault.revokePath(approvedPath);
        assertFalse(vault.approvedPaths(keccak256(approvedPath)));

        vm.expectRevert();
        vault.pathPools(keccak256(approvedPath), 0);
    }

    function test_executeBuyback_revertsTokenInMismatch() public {
        MockERC20 weth = new MockERC20("WETH", "WETH");
        vm.prank(owner);
        vault.approveToken(address(weth));
        weth.mint(address(vault), 1e18);

        vm.prank(alice);
        vm.expectRevert(BuybackVault.TokenInMismatch.selector);
        vault.executeBuyback(address(weth), approvedPath, 1e18, 1, block.timestamp + 300);
    }

    function test_executeBuyback_revertsAiTokenOutputMismatch() public {
        MockERC20 rando = new MockERC20("Rando", "RND");
        bytes memory badPath = abi.encodePacked(address(usdc), uint24(3_000), address(rando));
        vm.prank(alice);
        vm.expectRevert(BuybackVault.InvalidPathOutput.selector);
        vault.executeBuyback(address(usdc), badPath, 1e6, 1, block.timestamp + 300);
    }

    function test_executeBuyback_revertsInvalidPathLength() public {
        bytes memory badPath = new bytes(44); // 44 != 20+23*n
        vm.prank(alice);
        vm.expectRevert(BuybackVault.InvalidPath.selector);
        vault.executeBuyback(address(usdc), badPath, 1e6, 1, block.timestamp + 300);
    }

    function test_setEpochConfig_zeroDisablesRateLimiting() public {
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), 500e6);

        vm.prank(owner);
        vault.setEpochConfig(0);

        _seedVault(2_000e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 1_000e6, 1, block.timestamp + 300);
        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 1_000e6, 1, block.timestamp + 300);
    }

    function test_setAiToken_emitsEvent() public {
        MockERC20 newAi = new MockERC20("New AI", "NAI");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IBuybackVault.AiTokenUpdated(address(ai), address(newAi));
        vault.setAiToken(address(newAi));
    }

    function test_setTreasury_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IBuybackVault.TreasuryUpdated(bob, alice);
        vault.setTreasury(alice);
    }

    function test_setSwapRouter_emitsEvent() public {
        MockSwapRouter newRouter = new MockSwapRouter();
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IBuybackVault.SwapRouterUpdated(address(router), address(newRouter));
        vault.setSwapRouter(address(newRouter));
    }

    function test_setBurnBps_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IBuybackVault.BurnBpsUpdated(BURN_BPS, 5_000);
        vault.setBurnBps(5_000);
    }

    function test_setExecutorRewardBps_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IBuybackVault.ExecutorRewardBpsUpdated(REWARD_BPS, 50);
        vault.setExecutorRewardBps(50);
    }

    function test_setTwapWindow_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IBuybackVault.TwapWindowUpdated(TWAP_WINDOW, 3_600);
        vault.setTwapWindow(3_600);
    }

    function test_setMaxSlippageBps_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IBuybackVault.MaxSlippageBpsUpdated(SLIPPAGE_BPS, 200);
        vault.setMaxSlippageBps(200);
    }

    function test_setEpochConfig_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IBuybackVault.EpochConfigUpdated(7 days);
        vault.setEpochConfig(7 days);
    }

    function test_setTokenEpochVolumeLimit_setsAndEmits() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IBuybackVault.TokenEpochVolumeLimitUpdated(address(usdc), 2_000e6);
        vault.setTokenEpochVolumeLimit(address(usdc), 2_000e6);
        assertEq(vault.tokenEpochVolumeLimit(address(usdc)), 2_000e6);
    }

    function test_setWeth_emitsEvent() public {
        MockWETH wethToken = new MockWETH();
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IBuybackVault.WethUpdated(address(0), address(wethToken));
        vault.setWeth(address(wethToken));
        assertEq(vault.weth(), address(wethToken));
    }

    function test_setWeth_allowsZeroToDisable() public {
        MockWETH wethToken = new MockWETH();
        vm.startPrank(owner);
        vault.setWeth(address(wethToken));
        vault.setWeth(address(0));
        vm.stopPrank();
        assertEq(vault.weth(), address(0));
    }

    function test_setWeth_revertsNonContract() public {
        address eoa = makeAddr("eoa");
        vm.prank(owner);
        vm.expectRevert(BuybackVault.NotAContract.selector);
        vault.setWeth(eoa);
    }

    function test_setWeth_onlyOwner() public {
        MockWETH wethToken = new MockWETH();
        vm.prank(alice);
        vm.expectRevert();
        vault.setWeth(address(wethToken));
    }

    function test_executeBuyback_eth_wrapsAndSwaps() public {
        MockWETH wethToken = new MockWETH();

        vm.startPrank(owner);
        vault.setWeth(address(wethToken));
        vault.approveToken(address(0));
        bytes memory ethPath = abi.encodePacked(address(wethToken), uint24(500), address(ai));
        vault.approvePath(ethPath, new address[](0));
        vm.stopPrank();

        uint256 amountIn = 1 ether;
        vm.deal(address(vault), amountIn);

        uint256 amountOut = 500e18;
        router.setNextAmountOut(amountOut, address(ai));

        uint256 expectedReward = (amountOut * REWARD_BPS) / 10_000;
        uint256 expectedBurn = ((amountOut - expectedReward) * BURN_BPS) / 10_000;
        uint256 expectedTreasury = amountOut - expectedReward - expectedBurn;

        vm.prank(alice);
        vault.executeBuyback(address(0), ethPath, amountIn, 1, block.timestamp + 300);

        assertEq(address(vault).balance, 0, "vault ETH should be zero");
        assertEq(wethToken.balanceOf(address(vault)), 0, "vault should hold no WETH");
        assertEq(ai.balanceOf(alice), expectedReward, "executor reward");
        assertEq(ai.balanceOf(address(0xdEaD)), expectedBurn, "burn");
        assertEq(ai.balanceOf(bob), expectedTreasury, "treasury");
    }

    function test_executeBuyback_eth_revertsWhenWethNotSet() public {
        vm.prank(owner);
        vault.approveToken(address(0));

        MockWETH wethToken = new MockWETH();
        bytes memory ethPath = abi.encodePacked(address(wethToken), uint24(500), address(ai));
        vm.prank(owner);
        vault.approvePath(ethPath, new address[](0));

        vm.deal(address(vault), 1 ether);
        vm.prank(alice);
        vm.expectRevert(BuybackVault.WethNotConfigured.selector);
        vault.executeBuyback(address(0), ethPath, 1 ether, 1, block.timestamp + 300);
    }

    function test_approvePath_multiHopWithPools() public {
        MockERC20 mid = new MockERC20("MidToken", "MID");
        bytes memory twoHop = abi.encodePacked(address(usdc), uint24(500), address(mid), uint24(3_000), address(ai));

        MockUniswapPool pool1 = new MockUniswapPool();
        MockUniswapPool pool2 = new MockUniswapPool();
        {
            (address t0, address t1) =
                address(usdc) < address(mid) ? (address(usdc), address(mid)) : (address(mid), address(usdc));
            pool1.setPoolConfig(t0, t1, 500);
            pool1.setTickCumulatives(0, 0);
        }
        {
            (address t0, address t1) =
                address(mid) < address(ai) ? (address(mid), address(ai)) : (address(ai), address(mid));
            pool2.setPoolConfig(t0, t1, 3_000);
            pool2.setTickCumulatives(0, 0);
        }

        address[] memory pools = new address[](2);
        pools[0] = address(pool1);
        pools[1] = address(pool2);

        vm.prank(owner);
        vault.approvePath(twoHop, pools);

        assertTrue(vault.approvedPaths(keccak256(twoHop)));
        assertEq(vault.pathPools(keccak256(twoHop), 0), address(pool1));
        assertEq(vault.pathPools(keccak256(twoHop), 1), address(pool2));
    }

    function test_executeBuyback_multiHop_rejectsBelowTwapFloor() public {
        MockERC20 mid = new MockERC20("MidToken", "MID");
        bytes memory twoHop = abi.encodePacked(address(usdc), uint24(500), address(mid), uint24(3_000), address(ai));

        MockUniswapPool pool1 = new MockUniswapPool();
        MockUniswapPool pool2 = new MockUniswapPool();
        // tickDelta = 180 000 over 1800s → meanTick = 100 → price > 1:1 for both hops
        pool1.setTickCumulatives(0, 180_000);
        pool2.setTickCumulatives(0, 180_000);
        {
            (address t0, address t1) =
                address(usdc) < address(mid) ? (address(usdc), address(mid)) : (address(mid), address(usdc));
            pool1.setPoolConfig(t0, t1, 500);
        }
        {
            (address t0, address t1) =
                address(mid) < address(ai) ? (address(mid), address(ai)) : (address(ai), address(mid));
            pool2.setPoolConfig(t0, t1, 3_000);
        }

        address[] memory pools = new address[](2);
        pools[0] = address(pool1);
        pools[1] = address(pool2);

        vm.startPrank(owner);
        vault.approvePath(twoHop, pools);
        vm.stopPrank();

        _seedVault(1_000e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vm.expectRevert(BuybackVault.SlippageExceeded.selector);
        vault.executeBuyback(address(usdc), twoHop, 1_000e6, 1, block.timestamp + 300);
    }

    function test_executeBuyback_multiHop_acceptsAboveTwapFloor() public {
        MockERC20 mid = new MockERC20("MidToken", "MID");
        bytes memory twoHop = abi.encodePacked(address(usdc), uint24(500), address(mid), uint24(3_000), address(ai));

        MockUniswapPool pool1 = new MockUniswapPool();
        MockUniswapPool pool2 = new MockUniswapPool();
        pool1.setTickCumulatives(0, 0); // tick = 0 → price 1:1
        pool2.setTickCumulatives(0, 0);
        {
            (address t0, address t1) =
                address(usdc) < address(mid) ? (address(usdc), address(mid)) : (address(mid), address(usdc));
            pool1.setPoolConfig(t0, t1, 500);
        }
        {
            (address t0, address t1) =
                address(mid) < address(ai) ? (address(mid), address(ai)) : (address(ai), address(mid));
            pool2.setPoolConfig(t0, t1, 3_000);
        }

        address[] memory pools = new address[](2);
        pools[0] = address(pool1);
        pools[1] = address(pool2);

        vm.startPrank(owner);
        vault.approvePath(twoHop, pools);
        vm.stopPrank();

        uint256 amountIn = 1_000e6;
        uint256 floor = amountIn * (10_000 - SLIPPAGE_BPS) / 10_000; // 990e6
        _seedVault(amountIn);
        router.setNextAmountOut(floor, address(ai)); // exactly at the floor

        vm.prank(alice);
        vault.executeBuyback(address(usdc), twoHop, amountIn, floor, block.timestamp + 300);
        assertEq(ai.balanceOf(address(vault)), 0, "vault holds no $AI");
    }

    function _singlePool(address p) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = p;
    }

    function test_initRevertsOnZeroTreasury() public {
        BuybackVault impl2 = new BuybackVault();
        bytes memory bad = abi.encodeCall(
            BuybackVault.initialize,
            (
                address(ai),
                address(0),
                address(router),
                BURN_BPS,
                REWARD_BPS,
                TWAP_WINDOW,
                SLIPPAGE_BPS,
                EPOCH_DUR,
                owner
            )
        );
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initRevertsOnZeroSwapRouter() public {
        BuybackVault impl2 = new BuybackVault();
        bytes memory bad = abi.encodeCall(
            BuybackVault.initialize,
            (address(ai), bob, address(0), BURN_BPS, REWARD_BPS, TWAP_WINDOW, SLIPPAGE_BPS, EPOCH_DUR, owner)
        );
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initRevertsOnTwapWindowTooShort() public {
        BuybackVault impl2 = new BuybackVault();
        bytes memory bad = abi.encodeCall(
            BuybackVault.initialize,
            (address(ai), bob, address(router), BURN_BPS, REWARD_BPS, 1799, SLIPPAGE_BPS, EPOCH_DUR, owner)
        );
        vm.expectRevert(BuybackVault.TwapWindowTooShort.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initRevertsOnSlippageTooHigh() public {
        BuybackVault impl2 = new BuybackVault();
        bytes memory bad = abi.encodeCall(
            BuybackVault.initialize,
            (address(ai), bob, address(router), BURN_BPS, REWARD_BPS, TWAP_WINDOW, 501, EPOCH_DUR, owner)
        );
        vm.expectRevert(BuybackVault.SlippageTooHigh.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initRevertsOnZeroOwner() public {
        BuybackVault impl2 = new BuybackVault();
        bytes memory bad = abi.encodeCall(
            BuybackVault.initialize,
            (address(ai), bob, address(router), BURN_BPS, REWARD_BPS, TWAP_WINDOW, SLIPPAGE_BPS, EPOCH_DUR, address(0))
        );
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_initRevertsOnEpochDurationOverflow() public {
        BuybackVault impl2 = new BuybackVault();
        bytes memory bad = abi.encodeCall(
            BuybackVault.initialize,
            (
                address(ai),
                bob,
                address(router),
                BURN_BPS,
                REWARD_BPS,
                TWAP_WINDOW,
                SLIPPAGE_BPS,
                uint256(type(uint32).max) + 1,
                owner
            )
        );
        vm.expectRevert(BuybackVault.EpochDurationOverflow.selector);
        new ERC1967Proxy(address(impl2), bad);
    }

    function test_executeBuyback_revertsZeroAmountOutMin() public {
        vm.prank(alice);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(address(usdc), approvedPath, 1e6, 0, block.timestamp + 300);
    }

    function test_executeBuyback_revertsAmountTooLarge() public {
        uint256 huge = uint256(type(uint128).max) + 1;
        vm.prank(alice);
        vm.expectRevert(BuybackVault.AmountTooLarge.selector);
        vault.executeBuyback(address(usdc), approvedPath, huge, 1, block.timestamp + 300);
    }

    function test_approvePath_revertsZeroPool() public {
        address[] memory pools = new address[](1);
        pools[0] = address(0);
        vm.prank(owner);
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        vault.approvePath(approvedPath, pools);
    }

    function test_setAiToken_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        vault.setAiToken(address(0));
    }

    function test_setTreasury_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
    }

    function test_setSwapRouter_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        vault.setSwapRouter(address(0));
    }

    function test_setEpochConfig_revertsOverflow() public {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.EpochDurationOverflow.selector);
        vault.setEpochConfig(uint256(type(uint32).max) + 1);
    }

    function test_setExecutorRewardBps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setExecutorRewardBps(50);
    }

    function test_setTwapWindow_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setTwapWindow(3_600);
    }

    function test_setMaxSlippageBps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxSlippageBps(200);
    }

    function test_setEpochConfig_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setEpochConfig(7 days);
    }

    function test_setTokenEpochVolumeLimit_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setTokenEpochVolumeLimit(address(usdc), 1_000e6);
    }

    function test_approveToken_onlyOwner() public {
        MockERC20 t = new MockERC20("T", "T");
        vm.prank(alice);
        vm.expectRevert();
        vault.approveToken(address(t));
    }

    function test_revokeToken_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.revokeToken(address(usdc));
    }

    function test_approvePath_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.approvePath(approvedPath, new address[](0));
    }

    function test_revokePath_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.revokePath(approvedPath);
    }

    function test_emergencySweep_revertsZeroTo() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vm.expectRevert(BuybackVault.ZeroAddress.selector);
        vault.emergencySweep(address(usdc), address(0), 1e6);
    }

    function test_emergencySweep_revertsFailedEthTransfer() public {
        EthRejecter rejecter = new EthRejecter();
        vm.deal(address(vault), 1 ether);
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vm.expectRevert(BuybackVault.EthTransferFailed.selector);
        vault.emergencySweep(address(0), address(rejecter), 1 ether);
    }

    function test_executeBuyback_zeroExecutorReward() public {
        vm.prank(owner);
        vault.setExecutorRewardBps(0);

        uint256 amountIn = 1_000e6;
        _seedVault(amountIn);
        router.setNextAmountOut(amountIn, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn, 1, block.timestamp + 300);

        assertEq(ai.balanceOf(alice), 0, "executor reward should be zero");
    }

    function test_executeBuyback_zeroBurnAmount() public {
        vm.prank(owner);
        vault.setBurnBps(0);

        uint256 amountIn = 1_000e6;
        _seedVault(amountIn);
        router.setNextAmountOut(amountIn, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn, 1, block.timestamp + 300);

        assertEq(ai.balanceOf(address(0xdEaD)), 0, "burn amount should be zero");
    }

    function test_executeBuyback_zeroTreasuryAmount() public {
        vm.startPrank(owner);
        vault.setBurnBps(0);
        vault.setExecutorRewardBps(10_000);
        vm.stopPrank();

        uint256 amountIn = 1_000e6;
        _seedVault(amountIn);
        router.setNextAmountOut(amountIn, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, amountIn, 1, block.timestamp + 300);

        assertEq(ai.balanceOf(bob), 0, "treasury amount should be zero");
    }

    function test_twap_maxTick_largeRatioBranch() public {
        int56 tickDelta = int56(int256(887272 * uint256(TWAP_WINDOW)));
        pool.setTickCumulatives(0, tickDelta);

        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));

        _seedVault(1e6);
        router.setNextAmountOut(1e18, address(ai));

        vm.startPrank(alice);
        try vault.executeBuyback(address(usdc), approvedPath, 1e6, 1, block.timestamp + 300) {}
        catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == BuybackVault.SlippageExceeded.selector || sel == BuybackVault.InvalidTick.selector,
                "unexpected revert"
            );
        }
        vm.stopPrank();
    }

    function test_twap_invalidTick_reverts() public {
        int56 tickDelta = int56(int256(887273 * uint256(TWAP_WINDOW)));
        pool.setTickCumulatives(0, tickDelta);

        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));

        _seedVault(1e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vm.expectRevert(BuybackVault.InvalidTick.selector);
        vault.executeBuyback(address(usdc), approvedPath, 1e6, 1, block.timestamp + 300);
    }

    function test_twap_negativeTickRounding_meanTickDecrement() public {
        pool.setTickCumulatives(1, 0);

        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));

        _seedVault(1_000e6);
        router.setNextAmountOut(1_000e6, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 1_000e6, 1_000e6, block.timestamp + 300);
    }

    function test_twap_negativeTickAllLowBits() public {
        int56 tickDelta = -int56(int256(262143 * uint256(TWAP_WINDOW) + 1));
        pool.setTickCumulatives(0, tickDelta);

        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));

        _seedVault(1e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vm.expectRevert(BuybackVault.SlippageExceeded.selector);
        vault.executeBuyback(address(usdc), approvedPath, 1e6, 1, block.timestamp + 300);
    }

    function test_twap_positiveTickAllLowBits() public {
        int56 tickDelta = int56(int256(262143 * uint256(TWAP_WINDOW)));
        pool.setTickCumulatives(0, tickDelta);

        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));

        _seedVault(1e6);
        router.setNextAmountOut(1e18, address(ai));

        vm.startPrank(alice);
        try vault.executeBuyback(address(usdc), approvedPath, 1e6, 1, block.timestamp + 300) {}
        catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(sel == BuybackVault.SlippageExceeded.selector, "unexpected revert");
        }
        vm.stopPrank();
    }

    function test_twap_reverseTokenOrder_midGreaterThanAi() public {
        address midAddr;
        MockERC20 mid;
        for (uint256 i = 0; i < 30; i++) {
            mid = new MockERC20("MID", "MID");
            if (address(mid) > address(ai)) {
                midAddr = address(mid);
                break;
            }
        }
        if (midAddr == address(0)) return;

        bytes memory twoHop = abi.encodePacked(address(usdc), uint24(500), midAddr, uint24(3_000), address(ai));

        MockUniswapPool pool1 = new MockUniswapPool();
        MockUniswapPool pool2 = new MockUniswapPool();

        {
            (address t0, address t1) = address(usdc) < midAddr ? (address(usdc), midAddr) : (midAddr, address(usdc));
            pool1.setPoolConfig(t0, t1, 500);
            pool1.setTickCumulatives(0, 0);
        }
        {
            pool2.setPoolConfig(address(ai), midAddr, 3_000);
            pool2.setTickCumulatives(0, 0);
        }

        address[] memory pools = new address[](2);
        pools[0] = address(pool1);
        pools[1] = address(pool2);

        vm.prank(owner);
        vault.approvePath(twoHop, pools);

        _seedVault(1_000e6);
        router.setNextAmountOut(1_000e6, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), twoHop, 1_000e6, 1_000e6, block.timestamp + 300);
    }

    function test_epochVolume_cumulatesWithinSameEpoch() public {
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), 2_000e6);

        _seedVault(2_000e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 500e6, 1, block.timestamp + 300);

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 500e6, 1, block.timestamp + 300);
    }

    function test_epochVolume_resetOnNewEpoch() public {
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(address(usdc), 500e6);

        _seedVault(2_000e6);
        router.setNextAmountOut(1, address(ai));

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 500e6, 1, block.timestamp + 300);

        vm.warp(block.timestamp + EPOCH_DUR + 1);

        vm.prank(alice);
        vault.executeBuyback(address(usdc), approvedPath, 500e6, 1, block.timestamp + 300);
    }

    function test_setExecutorRewardBps_success() public {
        vm.prank(owner);
        vault.setExecutorRewardBps(50);
        assertEq(vault.executorRewardBps(), 50);
    }

    function test_setTwapWindow_success() public {
        vm.prank(owner);
        vault.setTwapWindow(3_600);
        assertEq(vault.twapWindow(), 3_600);
    }

    function test_setMaxSlippageBps_success() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(200);
        assertEq(vault.maxSlippageBps(), 200);
    }

    function test_setAiToken_success() public {
        MockERC20 newAi = new MockERC20("NewAI", "NAI");
        vm.prank(owner);
        vault.setAiToken(address(newAi));
        assertEq(vault.aiToken(), address(newAi));
    }

    function test_setTreasury_success() public {
        vm.prank(owner);
        vault.setTreasury(alice);
        assertEq(vault.treasury(), alice);
    }

    function test_setSwapRouter_success() public {
        MockSwapRouter newRouter = new MockSwapRouter();
        vm.prank(owner);
        vault.setSwapRouter(address(newRouter));
        assertEq(vault.swapRouter(), address(newRouter));
    }

    function test_approvePath_emptyPoolsClearsExistingPools() public {
        vm.prank(owner);
        vault.approvePath(approvedPath, _singlePool(address(pool)));
        assertEq(vault.pathPools(keccak256(approvedPath), 0), address(pool));

        vm.prank(owner);
        vault.approvePath(approvedPath, new address[](0));

        vm.expectRevert();
        vault.pathPools(keccak256(approvedPath), 0);
    }

    function test_depositETH_emitsEvent() public {
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IBuybackVault.Deposited(address(0), alice, 1 ether);
        vault.depositETH{value: 1 ether}();
    }

    function test_receiveETH_emitsEvent() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IBuybackVault.Deposited(address(0), alice, 0.5 ether);
        (bool ok,) = address(vault).call{value: 0.5 ether}("");
        assertTrue(ok);
    }
}

contract EthRejecter {
    receive() external payable {
        revert("rejected");
    }
}
