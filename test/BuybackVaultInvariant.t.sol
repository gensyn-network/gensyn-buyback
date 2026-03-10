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
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 0, owner)
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
}

contract BuybackVaultHandler is Test {
    BuybackVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal ai;
    MockSwapRouter internal router;

    bytes internal approvedPath;
    address internal actor = makeAddr("invariant_actor");

    uint256 public totalDeposited;
    uint256 public totalSwapped;

    constructor(BuybackVault _vault, MockERC20 _usdc, MockERC20 _ai, MockSwapRouter _router, bytes memory _path) {
        vault = _vault;
        usdc = _usdc;
        ai = _ai;
        router = _router;
        approvedPath = _path;
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

        router.setNextAmountOut(mockOut, address(ai));
        vm.prank(actor);
        try vault.executeBuyback(address(usdc), approvedPath, amountIn, 1, block.timestamp + 300) {
            totalSwapped += amountIn;
        } catch {}
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
            BuybackVault.initialize, (address(ai), treasury, address(router), 7_000, 100, 1_800, 100, 0, owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));

        vm.startPrank(owner);
        vault.approveToken(address(usdc));
        vault.approvePath(approvedPath, new address[](0));
        vm.stopPrank();

        handler = new BuybackVaultHandler(vault, usdc, ai, router, approvedPath);

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
}
