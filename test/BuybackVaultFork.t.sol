// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../src/BuybackVault.sol";

contract BuybackVaultForkTest is Test {
    address internal aiToken;
    address internal inputToken;
    address internal swapRouter;
    address internal pathPool;
    address internal treasury;
    address internal whale;
    bytes internal approvedPath;

    BuybackVault internal vault;

    address internal owner = makeAddr("fork_owner");
    address internal executor = makeAddr("fork_executor");

    bool internal forkEnabled;

    function setUp() public {
        string memory rpcUrl = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            forkEnabled = false;
            return;
        }
        forkEnabled = true;

        uint256 blockNumber = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (blockNumber != 0) {
            vm.createSelectFork(rpcUrl, blockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        aiToken = vm.envAddress("AI_TOKEN");
        inputToken = vm.envAddress("INPUT_TOKEN");
        swapRouter = vm.envAddress("SWAP_ROUTER");
        pathPool = vm.envAddress("PATH_POOL");
        treasury = vm.envAddress("TREASURY");
        whale = vm.envAddress("WHALE");
        approvedPath = vm.envBytes("APPROVED_PATH");

        BuybackVault impl = new BuybackVault();
        bytes memory initData =
            abi.encodeCall(BuybackVault.initialize, (aiToken, treasury, swapRouter, 7_000, 100, 1_800, 200, 0, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = BuybackVault(payable(address(proxy)));

        vm.startPrank(owner);
        vault.approveToken(inputToken);
        {
            address[] memory _pools = new address[](1);
            _pools[0] = pathPool;
            vault.approvePath(approvedPath, _pools);
        }
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!forkEnabled) return;
        _;
    }

    function test_fork_fullBuybackFlow() public onlyFork {
        uint256 depositAmount = 1_000e6;

        vm.prank(whale);
        IERC20(inputToken).transfer(address(vault), depositAmount);
        assertEq(IERC20(inputToken).balanceOf(address(vault)), depositAmount, "vault funded");

        uint256 treasuryBefore = IERC20(aiToken).balanceOf(treasury);
        uint256 deadBefore = IERC20(aiToken).balanceOf(address(0xdEaD));

        uint256 amountOutMin = 1;

        vm.prank(executor);
        vault.executeBuyback(inputToken, approvedPath, depositAmount, amountOutMin, block.timestamp + 300);

        uint256 executorAI = IERC20(aiToken).balanceOf(executor);
        uint256 burnAI = IERC20(aiToken).balanceOf(address(0xdEaD)) - deadBefore;
        uint256 treasuryAI = IERC20(aiToken).balanceOf(treasury) - treasuryBefore;

        assertTrue(executorAI > 0, "executor should receive reward");
        assertTrue(burnAI > 0, "some AI should be burned");
        assertTrue(treasuryAI > 0, "treasury should receive remainder");
        assertEq(IERC20(aiToken).balanceOf(address(vault)), 0, "vault should hold no AI");
        assertEq(IERC20(inputToken).balanceOf(address(vault)), 0, "vault should hold no inputToken");
    }

    function test_fork_pauseAndSweep() public onlyFork {
        uint256 depositAmount = 500e6;

        vm.prank(whale);
        IERC20(inputToken).transfer(address(vault), depositAmount);

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(executor);
        vm.expectRevert();
        vault.executeBuyback(inputToken, approvedPath, depositAmount, 1, block.timestamp + 300);

        address safeAddr = makeAddr("safe");
        vm.prank(owner);
        vault.emergencySweep(inputToken, safeAddr, depositAmount);
        assertEq(IERC20(inputToken).balanceOf(safeAddr), depositAmount, "swept funds recovered");

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_fork_parameterUpdate() public onlyFork {
        vm.prank(owner);
        vault.setBurnBps(5_000);
        assertEq(vault.burnBps(), 5_000);

        vm.prank(owner);
        vault.setTreasury(executor);
        assertEq(vault.treasury(), executor);
    }

    function test_fork_revokePathPreventsExecution() public onlyFork {
        vm.prank(owner);
        vault.revokePath(approvedPath);
        assertFalse(vault.approvedPaths(keccak256(approvedPath)));

        vm.prank(whale);
        IERC20(inputToken).transfer(address(vault), 100e6);

        vm.prank(executor);
        vm.expectRevert(BuybackVault.PathNotApproved.selector);
        vault.executeBuyback(inputToken, approvedPath, 100e6, 1, block.timestamp + 300);
    }

    function test_fork_upgradeToNewImpl() public onlyFork {
        BuybackVault newImpl = new BuybackVault();

        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(vault.aiToken(), aiToken, "aiToken preserved after upgrade");
        assertEq(vault.treasury(), treasury, "treasury preserved");
        assertEq(vault.swapRouter(), swapRouter, "swapRouter preserved");
    }
}
