// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/BuybackVault.sol";

contract DeployBuybackVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address aiToken = vm.envAddress("AI_TOKEN");
        address treasury = vm.envAddress("TREASURY");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        address owner = vm.envAddress("OWNER");
        address inputToken = vm.envAddress("INPUT_TOKEN");
        bytes memory path = vm.envBytes("APPROVED_PATH");
        address pathPool = vm.envAddress("PATH_POOL");

        uint16 burnBps = uint16(vm.envOr("BURN_BPS", uint256(7_000)));
        uint16 executorRewardBps = uint16(vm.envOr("EXECUTOR_REWARD_BPS", uint256(100)));
        uint32 twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(1_800)));
        uint16 maxSlippageBps = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(100)));
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(86_400));

        vm.startBroadcast(deployerKey);

        BuybackVault impl = new BuybackVault();

        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize,
            (
                aiToken,
                treasury,
                swapRouter,
                burnBps,
                executorRewardBps,
                twapWindow,
                maxSlippageBps,
                epochDuration,
                owner
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BuybackVault vault = BuybackVault(payable(address(proxy)));

        try vault.approveToken(inputToken) {}
        catch {
            console2.log("WARNING: approveToken skipped (caller is not owner).");
            console2.log("Governance Safe must call approveToken + approvePath post-deploy.");
        }

        {
            address[] memory _pools = new address[](1);
            _pools[0] = pathPool;
            try vault.approvePath(path, _pools) {}
            catch {
                console2.log("WARNING: approvePath skipped (caller is not owner).");
            }
        }

        vm.stopBroadcast();

        console2.log("=== BuybackVault Deployment ===");
        console2.log("Implementation : ", address(impl));
        console2.log("Proxy (vault)  : ", address(vault));
        console2.log("Owner          : ", owner);
        console2.log("aiToken        : ", aiToken);
        console2.log("treasury       : ", treasury);
        console2.log("swapRouter     : ", swapRouter);
        console2.log("burnBps        : ", burnBps);
        console2.log("executorRewardBps: ", executorRewardBps);
        console2.log("twapWindow     : ", twapWindow, "s");
        console2.log("maxSlippageBps : ", maxSlippageBps);
        console2.log("epochDuration  : ", epochDuration, "s");
    }
}
