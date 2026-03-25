// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../src/BuybackVault.sol";
import "../src/interfaces/external/IWETH.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

import "../src/interfaces/external/ISwapRouter02.sol";
import "../src/libraries/TickMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract GensynMainnetForkTest is Test {
    using SafeERC20 for IERC20;
    using SafeCast for int256;

    // ============ Gensyn Mainnet Addresses ============
    // These are loaded from environment variables to support both testnet and mainnet
    // Fallback to testnet addresses if env vars not set
    address constant WETH_FALLBACK = 0xCa086d8bA028B799B089c73DD10D722B9a5c6577;
    address constant USDC_E_FALLBACK = 0x72936441E8791A96eF283464BEaB677F9C36a162;
    address constant AI_TOKEN_FALLBACK = 0x02344970FAEd3241F0581a0977167ba636a63019;
    address constant SWAP_ROUTER_FALLBACK = 0x8458ee1e5eD6c35b3bDA10ae0666C745BfbB7E85;
    address constant USDC_AI_POOL_FALLBACK = 0x046B3362C4ff28758A22c5C61C0D78AA6013A9eC;
    address constant UNISWAP_FACTORY_FALLBACK = 0x89E5d670700B56Ed0AB1bb6c7e8FC870A9b62ef0;

    string constant GENSYN_RPC_FALLBACK = "https://gensyn-testnet.g.alchemy.com/public";

    // Runtime addresses (loaded from env or fallback)
    address internal WETH;
    address internal USDC_E;
    address internal AI_TOKEN;
    address internal SWAP_ROUTER;
    address internal USDC_AI_POOL;
    address internal UNISWAP_FACTORY;

    // ============ Test Actors ============
    address internal owner;
    uint256 internal ownerKey;
    address internal executor;
    address internal treasury;

    // ============ Contracts ============
    BuybackVault internal vault;
    BuybackVault internal vaultImpl;

    // ============ Swap Paths ============
    bytes internal usdcToAiPath;
    bytes internal wethToAiPath;

    bool internal forkEnabled;
    bool internal usingDeployedVault;

    function setUp() public {
        // Load addresses from environment or use fallbacks
        _loadAddresses();

        // Check if already running in forked environment (via --fork-url)
        if (block.chainid != 0 && block.chainid != 31337) {
            forkEnabled = true;
        } else {
            // Try to create fork
            string memory rpcUrl;
            try vm.rpcUrl("gensyn_mainnet") returns (string memory url) {
                rpcUrl = url;
            } catch {
                rpcUrl = GENSYN_RPC_FALLBACK;
            }

            if (bytes(rpcUrl).length == 0) {
                forkEnabled = false;
                return;
            }

            try vm.createSelectFork(rpcUrl) {
                forkEnabled = true;
            } catch {
                forkEnabled = false;
                return;
            }
        }

        // Setup actors
        (owner, ownerKey) = makeAddrAndKey("owner");
        executor = makeAddr("executor");
        treasury = makeAddr("treasury");

        // Fund actors with ETH for gas
        vm.deal(owner, 100 ether);
        vm.deal(executor, 10 ether);

        // Build swap paths
        usdcToAiPath = abi.encodePacked(USDC_E, uint24(3000), AI_TOKEN);
        wethToAiPath = abi.encodePacked(WETH, uint24(3000), AI_TOKEN);

        // Deploy or use existing vault
        _deployVault();
    }

    function _deployVault() internal {
        // Check if we should use a deployed vault address from environment
        try vm.envAddress("DEPLOYED_VAULT") returns (address deployedVault) {
            if (deployedVault != address(0)) {
                vault = BuybackVault(payable(deployedVault));
                usingDeployedVault = true;

                // Get actual owner and treasury from deployed vault
                owner = vault.owner();
                treasury = vault.treasury();

                // Fund the actual owner with ETH for tests
                vm.deal(owner, 100 ether);

                emit log_named_address("Using deployed vault", deployedVault);
                emit log_named_address("Vault owner", owner);
                emit log_named_address("Vault treasury", treasury);
                return;
            }
        } catch {}

        // Deploy fresh vault for testing
        emit log("Deploying fresh vault for testing");
        vaultImpl = new BuybackVault();

        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize,
            (
                AI_TOKEN,
                treasury,
                SWAP_ROUTER,
                7_000, // burnBps (70%)
                100, // executorRewardBps (1%)
                1_800, // twapWindow (30 min)
                200, // maxSlippageBps (2%)
                86_400, // epochDuration (1 day)
                owner
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

        // Check if WETH/AI pool exists
        address wethAiPool = IUniswapV3Factory(UNISWAP_FACTORY).getPool(WETH, AI_TOKEN, 3000);
        if (wethAiPool != address(0)) {
            address[] memory wethPools = new address[](1);
            wethPools[0] = wethAiPool;
            vault.approvePath(wethToAiPath, wethPools);
        }
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!forkEnabled) {
            vm.skip(true);
        }
        _;
    }

    // ============================================================
    //                    END-TO-END TESTS
    // ============================================================

    function test_fork_deploymentState() public onlyFork {
        assertTrue(address(vault) != address(0), "vault not deployed");
        assertTrue(vault.aiToken() != address(0), "aiToken not set");
        assertTrue(vault.swapRouter() != address(0), "swapRouter not set");
        assertTrue(vault.owner() != address(0), "owner not set");
        assertTrue(vault.treasury() != address(0), "treasury not set");
    }

    function test_fork_receiveUSDC() public onlyFork {
        uint256 amount = 100e6;
        deal(USDC_E, executor, amount);

        vm.prank(executor);
        IERC20(USDC_E).safeTransfer(address(vault), amount);

        assertEq(IERC20(USDC_E).balanceOf(address(vault)), amount, "vault should hold USDC.e");
    }

    function test_fork_receiveETH() public onlyFork {
        uint256 amount = 1 ether;

        vm.prank(executor);
        (bool success,) = address(vault).call{value: amount}("");
        assertTrue(success, "ETH transfer should succeed");

        assertEq(address(vault).balance, amount, "vault should hold ETH");
    }

    function test_fork_fullBuybackFlow_USDC() public onlyFork {
        // Get input token and path from env or use defaults
        address inputToken;
        bytes memory approvedPath;
        address pool;

        try vm.envAddress("INPUT_TOKEN") returns (address token) {
            inputToken = token;
        } catch {
            inputToken = USDC_E;
        }

        try vm.envBytes("APPROVED_PATH") returns (bytes memory path) {
            approvedPath = path;
        } catch {
            approvedPath = usdcToAiPath;
        }

        try vm.envAddress("PATH_POOLS") returns (address p) {
            pool = p;
        } catch {
            pool = USDC_AI_POOL;
        }

        // Verify pool state
        uint128 poolLiquidity = IUniswapV3Pool(pool).liquidity();
        require(poolLiquidity > 0, "Pool has no liquidity");

        uint256 amount = 10e6; // 10 USDC - small amount for low liquidity pools

        // Fund vault
        deal(inputToken, address(vault), amount);

        // Ensure token and path are approved
        if (!vault.approvedTokens(inputToken)) {
            vm.prank(owner);
            vault.approveToken(inputToken);
        }

        bytes32 pathKey = keccak256(approvedPath);
        if (!vault.approvedPaths(pathKey)) {
            address[] memory pools = new address[](1);
            pools[0] = pool;
            vm.prank(owner);
            vault.approvePath(approvedPath, pools);
        }

        // Record balances before
        uint256 treasuryBefore = IERC20(AI_TOKEN).balanceOf(treasury);
        uint256 executorBefore = IERC20(AI_TOKEN).balanceOf(executor);

        // Compute TWAP floor for proper amountOutMin
        uint256 amountOutMin =
            _computeTwapFloor(pool, inputToken, AI_TOKEN, amount, vault.twapWindow(), vault.maxSlippageBps());

        // Execute buyback with proper slippage protection
        vm.prank(executor);
        vault.executeBuyback(inputToken, approvedPath, amount, amountOutMin);

        // Verify distributions
        uint256 executorReward = IERC20(AI_TOKEN).balanceOf(executor) - executorBefore;
        uint256 treasuryAmount = IERC20(AI_TOKEN).balanceOf(treasury) - treasuryBefore;

        assertTrue(executorReward > 0, "executor should receive reward");
        assertTrue(treasuryAmount > 0, "treasury should receive remainder");
        assertEq(IERC20(inputToken).balanceOf(address(vault)), 0, "vault should be empty");
    }

    function test_fork_buybackRevertsOnUnapprovedToken() public onlyFork {
        address randomToken = makeAddr("randomToken");

        vm.prank(executor);
        vm.expectRevert(BuybackVault.TokenNotApproved.selector);
        vault.executeBuyback(randomToken, usdcToAiPath, 100e6, 1);
    }

    function test_fork_buybackRevertsOnUnapprovedPath() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        // Ensure token is approved
        if (!vault.approvedTokens(USDC_E)) {
            vm.prank(owner);
            vault.approveToken(USDC_E);
        }

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
        vault.setTwapWindow(3_600);
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
        uint256 limit = 1_000_000e6;
        vm.prank(owner);
        vault.setTokenEpochVolumeLimit(USDC_E, limit);
        assertEq(vault.tokenEpochVolumeLimit(USDC_E), limit, "volume limit set");
    }

    // ============================================================
    //                    PATH MANAGEMENT TESTS
    // ============================================================

    function test_fork_approvePath() public onlyFork {
        bytes memory newPath = abi.encodePacked(USDC_E, uint24(3000), AI_TOKEN);

        vm.prank(owner);
        address[] memory pools = new address[](1);
        pools[0] = USDC_AI_POOL;
        vault.approvePath(newPath, pools);

        assertTrue(vault.approvedPaths(keccak256(newPath)), "new path approved");
    }

    function test_fork_revokePath() public onlyFork {
        // First ensure path is approved
        bytes memory pathToRevoke = abi.encodePacked(USDC_E, uint24(3000), AI_TOKEN);
        bytes32 pathKey = keccak256(pathToRevoke);

        if (!vault.approvedPaths(pathKey)) {
            vm.prank(owner);
            address[] memory pools = new address[](1);
            pools[0] = USDC_AI_POOL;
            vault.approvePath(pathToRevoke, pools);
        }

        vm.prank(owner);
        vault.revokePath(pathToRevoke);

        assertFalse(vault.approvedPaths(pathKey), "path revoked");
    }

    function test_fork_approveToken() public onlyFork {
        address newToken = makeAddr("newToken");

        vm.prank(owner);
        vault.approveToken(newToken);

        assertTrue(vault.approvedTokens(newToken), "token approved");
    }

    function test_fork_revokeToken() public onlyFork {
        address tokenToRevoke = makeAddr("tokenToRevoke");

        vm.startPrank(owner);
        vault.approveToken(tokenToRevoke);
        vault.revokeToken(tokenToRevoke);
        vm.stopPrank();

        assertFalse(vault.approvedTokens(tokenToRevoke), "token revoked");
    }

    // ============================================================
    //                    UPGRADE TESTS
    // ============================================================

    function test_fork_upgradeToNewImpl() public onlyFork {
        BuybackVault newImpl = new BuybackVault();

        address currentOwner = vault.owner();
        address currentTreasury = vault.treasury();
        address currentAiToken = vault.aiToken();

        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(vault.owner(), currentOwner, "owner preserved");
        assertEq(vault.treasury(), currentTreasury, "treasury preserved");
        assertEq(vault.aiToken(), currentAiToken, "aiToken preserved");
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
        vault.setTwapWindow(1_799);
    }

    function test_fork_maxSlippageMaximum() public onlyFork {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.SlippageTooHigh.selector);
        vault.setMaxSlippageBps(501);
    }

    function test_fork_bpsOverflow() public onlyFork {
        vm.prank(owner);
        vm.expectRevert(BuybackVault.BpsOverflow.selector);
        vault.setBurnBps(10_000);
    }

    function test_fork_zeroAmountIn() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        if (!vault.approvedTokens(USDC_E)) {
            vm.prank(owner);
            vault.approveToken(USDC_E);
        }

        vm.prank(executor);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, 0, 1);
    }

    function test_fork_zeroAmountOutMin() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        if (!vault.approvedTokens(USDC_E)) {
            vm.prank(owner);
            vault.approveToken(USDC_E);
        }

        vm.prank(executor);
        vm.expectRevert(BuybackVault.ZeroAmount.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, 100e6, 0);
    }

    function test_fork_amountTooLarge() public onlyFork {
        uint256 tooLargeAmount = uint256(type(uint128).max) + 1;

        if (!vault.approvedTokens(USDC_E)) {
            vm.prank(owner);
            vault.approveToken(USDC_E);
        }

        vm.prank(executor);
        vm.expectRevert(BuybackVault.AmountTooLarge.selector);
        vault.executeBuyback(USDC_E, usdcToAiPath, tooLargeAmount, 1);
    }

    function test_fork_wethNotConfigured() public onlyFork {
        // Approve ETH (address(0)) as token first - contract checks TokenNotApproved before WethNotConfigured
        if (!vault.approvedTokens(address(0))) {
            vm.prank(owner);
            vault.approveToken(address(0));
        }

        // Set WETH to address(0)
        vm.prank(owner);
        vault.setWeth(address(0));

        // Fund vault with ETH
        vm.deal(address(vault), 1 ether);

        vm.prank(executor);
        vm.expectRevert(BuybackVault.WethNotConfigured.selector);
        vault.executeBuyback(address(0), wethToAiPath, 1 ether, 1);
    }

    function test_fork_tokenInMismatch() public onlyFork {
        deal(USDC_E, address(vault), 100e6);

        if (!vault.approvedTokens(USDC_E)) {
            vm.prank(owner);
            vault.approveToken(USDC_E);
        }

        // Path says WETH -> AI, but we pass USDC_E as tokenIn
        vm.prank(executor);
        vm.expectRevert(BuybackVault.TokenInMismatch.selector);
        vault.executeBuyback(USDC_E, wethToAiPath, 100e6, 1);
    }

    function test_fork_epochDurationOverflow() public onlyFork {
        uint256 tooLargeDuration = uint256(type(uint32).max) + 1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", 32, tooLargeDuration));
        vault.setEpochConfig(tooLargeDuration);
    }

    // ============================================================
    //                    HELPER FUNCTIONS
    // ============================================================

    function _loadAddresses() internal {
        // Load addresses from environment variables with testnet fallbacks
        try vm.envAddress("WETH") returns (address addr) {
            WETH = addr;
        } catch {
            WETH = WETH_FALLBACK;
        }

        try vm.envAddress("INPUT_TOKEN") returns (address addr) {
            USDC_E = addr;
        } catch {
            USDC_E = USDC_E_FALLBACK;
        }

        try vm.envAddress("AI_TOKEN") returns (address addr) {
            AI_TOKEN = addr;
        } catch {
            AI_TOKEN = AI_TOKEN_FALLBACK;
        }

        try vm.envAddress("SWAP_ROUTER") returns (address addr) {
            SWAP_ROUTER = addr;
        } catch {
            SWAP_ROUTER = SWAP_ROUTER_FALLBACK;
        }

        try vm.envAddress("UNISWAP_FACTORY") returns (address addr) {
            UNISWAP_FACTORY = addr;
        } catch {
            UNISWAP_FACTORY = UNISWAP_FACTORY_FALLBACK;
        }

        // PATH_POOLS can be comma-separated; take first pool for USDC_AI_POOL
        try vm.envString("PATH_POOLS") returns (string memory poolsStr) {
            USDC_AI_POOL = _parseFirstPool(poolsStr);
        } catch {
            USDC_AI_POOL = USDC_AI_POOL_FALLBACK;
        }
    }

    function _parseFirstPool(string memory poolsStr) internal pure returns (address) {
        bytes memory poolsBytes = bytes(poolsStr);
        if (poolsBytes.length == 0) return USDC_AI_POOL_FALLBACK;

        // Find first comma or end of string
        uint256 end = poolsBytes.length;
        for (uint256 i = 0; i < poolsBytes.length; i++) {
            if (poolsBytes[i] == ",") {
                end = i;
                break;
            }
        }

        // Extract first address (should be 42 chars: 0x + 40 hex)
        if (end < 42) return USDC_AI_POOL_FALLBACK;

        bytes memory addrBytes = new bytes(42);
        for (uint256 i = 0; i < 42; i++) {
            addrBytes[i] = poolsBytes[i];
        }

        return _parseAddress(string(addrBytes));
    }

    function _parseAddress(string memory addrStr) internal pure returns (address) {
        bytes memory addrBytes = bytes(addrStr);
        if (addrBytes.length != 42) return address(0);
        if (addrBytes[0] != "0" || (addrBytes[1] != "x" && addrBytes[1] != "X")) return address(0);

        uint160 result = 0;
        for (uint256 i = 2; i < 42; i++) {
            uint8 b = uint8(addrBytes[i]);
            uint8 val;
            if (b >= 48 && b <= 57) {
                val = b - 48; // 0-9
            } else if (b >= 65 && b <= 70) {
                val = b - 55; // A-F
            } else if (b >= 97 && b <= 102) {
                val = b - 87; // a-f
            } else {
                return address(0);
            }
            result = result * 16 + val;
        }
        return address(result);
    }

    function _computeTwapFloor(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint32 twapWindow,
        uint16 maxSlippageBps
    ) internal view returns (uint256 floor) {
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
