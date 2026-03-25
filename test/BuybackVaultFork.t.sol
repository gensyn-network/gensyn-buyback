// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../src/BuybackVault.sol";
import "../script/DeployBuybackVault.s.sol";

contract BuybackVaultForkTest is Test, DeployBuybackVault {
    using SafeERC20 for IERC20;

    address internal aiToken;
    address internal inputToken;
    address internal pathPool;
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
        pathPool = vm.envAddress("PATH_POOL");
        whale = vm.envAddress("WHALE");
        approvedPath = vm.envBytes("APPROVED_PATH");

        // Populate deployer storage and reuse the deployment script
        _ai = aiToken;
        _treasury = vm.envAddress("TREASURY");
        _router = vm.envAddress("SWAP_ROUTER");
        _burn = 7_000;
        _reward = 100;
        _twap = 1_800;
        _slip = 200;
        _epoch = 0;
        _owner = owner;
        _deploy();
        _validate();
        vault = _vault;

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
        IERC20(inputToken).safeTransfer(address(vault), depositAmount);
        assertEq(IERC20(inputToken).balanceOf(address(vault)), depositAmount, "vault funded");

        uint256 treasuryBefore = IERC20(aiToken).balanceOf(_treasury);
        uint256 totalSupplyBefore = IERC20(aiToken).totalSupply();

        uint256 amountOutMin = 1;

        vm.prank(executor);
        vault.executeBuyback(inputToken, approvedPath, depositAmount, amountOutMin);

        uint256 executorAI = IERC20(aiToken).balanceOf(executor);
        uint256 treasuryAI = IERC20(aiToken).balanceOf(_treasury) - treasuryBefore;
        uint256 totalSupplyAfter = IERC20(aiToken).totalSupply();
        uint256 actualBurned = totalSupplyBefore - totalSupplyAfter;

        assertTrue(executorAI > 0, "executor should receive reward");
        assertTrue(actualBurned > 0, "tokens should be burned");
        assertTrue(treasuryAI > 0, "treasury should receive remainder");
        assertEq(IERC20(aiToken).balanceOf(address(vault)), 0, "vault should hold no AI");
        assertEq(IERC20(inputToken).balanceOf(address(vault)), 0, "vault should hold no inputToken");
    }

    function test_fork_pauseAndSweep() public onlyFork {
        uint256 depositAmount = 500e6;

        vm.prank(whale);
        IERC20(inputToken).safeTransfer(address(vault), depositAmount);

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(executor);
        vm.expectRevert();
        vault.executeBuyback(inputToken, approvedPath, depositAmount, 1);

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
        IERC20(inputToken).safeTransfer(address(vault), 100e6);

        vm.prank(executor);
        vm.expectRevert(BuybackVault.PathNotApproved.selector);
        vault.executeBuyback(inputToken, approvedPath, 100e6, 1);
    }

    function test_fork_upgradeToNewImpl() public onlyFork {
        BuybackVault newImpl = new BuybackVault();

        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(vault.aiToken(), aiToken, "aiToken preserved after upgrade");
        assertEq(vault.treasury(), _treasury, "treasury preserved");
        assertEq(vault.swapRouter(), _router, "swapRouter preserved");
    }
}
