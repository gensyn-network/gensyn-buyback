// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/BuybackVault.sol";

/**
 * @title DeployGensynTestnet
 * @notice Deployment script for BuybackVault on Gensyn Testnet
 *
 * Network Info:
 *   RPC: https://gensyn-testnet.g.alchemy.com/public
 *   Chain ID: 685685
 *   Explorer: https://gensyn-testnet.explorer.alchemy.com/
 *
 * Usage:
 *   forge script script/DeployGensynTestnet.s.sol:DeployGensynTestnet \
 *     --rpc-url https://gensyn-testnet.g.alchemy.com/public \
 *     --broadcast \
 *     --verify \
 *     --verifier blockscout \
 *     --verifier-url https://gensyn-testnet.explorer.alchemy.com/api \
 *     -vvvv
 *
 * Required env vars:
 *   DEPLOYER_KEY - Private key for deployment
 *   OWNER - Address that will own the vault (e.g., governance multisig)
 *   TREASURY - Address to receive treasury portion of buybacks
 *
 * Optional env vars (with defaults):
 *   BURN_BPS - Burn percentage in basis points (default: 7000 = 70%)
 *   EXECUTOR_REWARD_BPS - Executor reward in basis points (default: 100 = 1%)
 *   TWAP_WINDOW - TWAP window in seconds (default: 1800 = 30 min)
 *   MAX_SLIPPAGE_BPS - Max slippage in basis points (default: 200 = 2%)
 *   EPOCH_DURATION - Epoch duration in seconds (default: 86400 = 1 day)
 */
contract DeployGensynTestnet is Script {
    // ============ Gensyn Testnet Addresses ============
    address constant WETH = 0xCa086d8bA028B799B089c73DD10D722B9a5c6577;
    address constant USDC_E = 0x72936441E8791A96eF283464BEaB677F9C36a162;
    address constant AI_TOKEN = 0x02344970FAEd3241F0581a0977167ba636a63019;
    address constant SWAP_ROUTER = 0x8458ee1e5eD6c35b3bDA10ae0666C745BfbB7E85;
    address constant USDC_AI_POOL = 0x046B3362C4ff28758A22c5C61C0D78AA6013A9eC;
    address constant DELPHI_FACTORY = 0x509875D8B4d97Eb41eab3948328a3fA14031C518;

    uint256 constant CHAIN_ID = 685685;

    function run() external {
        // Verify we're on the right network
        require(block.chainid == CHAIN_ID, "Wrong chain! Expected Gensyn Testnet (685685)");

        // Load required env vars
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");

        // Load optional env vars with defaults
        uint16 burnBps = uint16(vm.envOr("BURN_BPS", uint256(7_000)));
        uint16 executorRewardBps = uint16(vm.envOr("EXECUTOR_REWARD_BPS", uint256(100)));
        uint32 twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(1_800)));
        uint16 maxSlippageBps = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(200)));
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(86_400));

        console2.log("=== Gensyn Testnet Deployment ===");
        console2.log("Chain ID       :", block.chainid);
        console2.log("Deployer       :", vm.addr(deployerKey));
        console2.log("Owner          :", owner);
        console2.log("Treasury       :", treasury);

        vm.startBroadcast(deployerKey);

        // 1. Deploy implementation
        BuybackVault impl = new BuybackVault();
        console2.log("Implementation :", address(impl));

        // 2. Deploy proxy with initialization
        // NOTE: Initialize with deployer as owner so we can configure the vault
        // Ownership will be transferred to the final owner at the end
        address deployer = vm.addr(deployerKey);
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize,
            (
                AI_TOKEN,
                treasury,
                SWAP_ROUTER,
                burnBps,
                executorRewardBps,
                twapWindow,
                maxSlippageBps,
                epochDuration,
                deployer // Initialize with deployer as owner
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BuybackVault vault = BuybackVault(payable(address(proxy)));
        console2.log("Proxy (vault)  :", address(vault));

        // 3. Configure WETH and enable ETH buyback
        vault.setWeth(WETH);
        vault.setEthBuybackEnabled(true);
        console2.log("WETH configured:", WETH);
        console2.log("ETH buyback enabled");

        // 4. Approve USDC.e as input token
        vault.approveToken(USDC_E);
        console2.log("USDC.e approved:", USDC_E);

        // 5. Approve ETH (address(0)) as input token
        vault.approveToken(address(0));
        console2.log("ETH approved   : address(0)");

        // 6. Build and approve USDC.e -> AI path with TWAP pool
        // Pool fee is 3000 (0.3%), token0=AI, token1=USDC.e
        bytes memory usdcToAiPath = abi.encodePacked(USDC_E, uint24(3000), AI_TOKEN);
        address[] memory pools = new address[](1);
        pools[0] = USDC_AI_POOL;
        vault.approvePath(usdcToAiPath, pools);
        console2.log("Path approved  : USDC.e -> AI (0.3% fee)");
        console2.log("TWAP Pool      :", USDC_AI_POOL);

        console2.log("WETH -> AI path: Not configured (no pool available yet)");

        // 8. Transfer ownership to the final owner (if different from deployer)
        if (owner != deployer) {
            vault.transferOwnership(owner);
            console2.log("Ownership transfer initiated to:", owner);
            console2.log("NOTE: Owner must call acceptOwnership() to complete transfer");
        }

        vm.stopBroadcast();

        // Print summary
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("BuybackVault Proxy:", address(vault));
        console2.log("Implementation    :", address(impl));
        console2.log("");
        console2.log("=== Configuration ===");
        console2.log("AI Token      :", AI_TOKEN);
        console2.log("Treasury      :", treasury);
        console2.log("Swap Router   :", SWAP_ROUTER);
        console2.log("WETH          :", WETH);
        console2.log("Burn BPS      :", burnBps);
        console2.log("Executor BPS  :", executorRewardBps);
        console2.log("TWAP Window   :", twapWindow, "seconds");
        console2.log("Max Slippage  :", maxSlippageBps, "bps");
        console2.log("Epoch Duration:", epochDuration, "seconds");
        console2.log("");
        console2.log("=== Approved Tokens ===");
        console2.log("- USDC.e:", USDC_E);
        console2.log("- ETH: address(0)");
        console2.log("");
        console2.log("=== Approved Paths ===");
        console2.log("- USDC.e -> AI (fee: 3000, pool:", USDC_AI_POOL, ")");
        console2.log("- WETH -> AI: NOT CONFIGURED (no pool available)");
        console2.log("");
        console2.log("=== External Contracts ===");
        console2.log("Delphi Factory:", DELPHI_FACTORY);
        console2.log("");
        console2.log("=== Verification Command ===");
        console2.log("forge verify-contract", address(vault));
        console2.log("  --chain-id 685685");
        console2.log("  --verifier blockscout");
        console2.log("  --verifier-url https://gensyn-testnet.explorer.alchemy.com/api");
    }
}
