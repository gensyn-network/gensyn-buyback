// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/BuybackVault.sol";

/// @title DeployBuybackVault
/// @notice Deploys BuybackVault implementation and proxy. Does NOT perform setup.
/// @dev Run SetupBuybackVault.s.sol after deployment to configure tokens and paths.
contract DeployBuybackVault is Script {
    BuybackVault internal _impl;
    BuybackVault internal _vault;

    uint256 internal _key;
    address internal _ai;
    address internal _treasury;
    address internal _router;
    address internal _owner;
    uint16 internal _burn;
    uint16 internal _reward;
    uint32 internal _twap;
    uint16 internal _slip;
    uint32 internal _epoch;

    function run() external {
        _load();
        vm.startBroadcast(_key);
        _deploy();
        vm.stopBroadcast();
        _validate();
        _log();
    }

    function _load() internal {
        _key = vm.envUint("DEPLOYER_KEY");
        _ai = vm.envAddress("AI_TOKEN");
        _treasury = vm.envAddress("TREASURY");
        _router = vm.envAddress("SWAP_ROUTER");
        _owner = vm.envAddress("OWNER");
        _burn = uint16(vm.envOr("BURN_BPS", uint256(7_000)));
        _reward = uint16(vm.envOr("EXECUTOR_REWARD_BPS", uint256(100)));
        _twap = uint32(vm.envOr("TWAP_WINDOW", uint256(1_800)));
        _slip = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(200)));
        _epoch = uint32(vm.envOr("EPOCH_DURATION", uint256(86_400)));
    }

    function _deploy() internal {
        _impl = new BuybackVault();
        bytes memory initData = abi.encodeCall(
            BuybackVault.initialize, (_ai, _treasury, _router, _burn, _reward, _twap, _slip, _epoch, _owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(_impl), initData);
        _vault = BuybackVault(payable(address(proxy)));
    }

    function _validate() internal view {
        require(_vault.owner() == _owner, "owner mismatch");
        require(_vault.aiToken() == _ai, "aiToken mismatch");
        require(_vault.treasury() == _treasury, "treasury mismatch");
        require(_vault.swapRouter() == _router, "swapRouter mismatch");
        require(_vault.burnBps() == _burn, "burnBps mismatch");
        require(_vault.executorRewardBps() == _reward, "executorRewardBps mismatch");
        require(_vault.twapWindow() == _twap, "twapWindow mismatch");
        require(_vault.maxSlippageBps() == _slip, "maxSlippageBps mismatch");
        require(_vault.epochDuration() == _epoch, "epochDuration mismatch");
    }

    function _log() internal view {
        console2.log("=== BuybackVault Deployed ===");
        console2.log("Implementation:", address(_impl));
        console2.log("Proxy:", address(_vault));
        console2.log("Owner:", _owner);
        console2.log("AI Token:", _ai);
        console2.log("Treasury:", _treasury);
        console2.log("Swap Router:", _router);
        console2.log("Burn BPS:", _burn);
        console2.log("Executor Reward BPS:", _reward);
        console2.log("TWAP Window:", _twap, "s");
        console2.log("Max Slippage BPS:", _slip);
        console2.log("Epoch Duration:", _epoch, "s");
        console2.log("");
        console2.log(">>> Next: Run SetupBuybackVault.s.sol to configure tokens and paths");
    }
}
