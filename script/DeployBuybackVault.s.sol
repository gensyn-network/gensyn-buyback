// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/BuybackVault.sol";

contract DeployBuybackVault is Script {
    BuybackVault internal _impl;
    BuybackVault internal _vault;

    // Storage for env vars
    uint256 internal _key;
    address internal _ai;
    address internal _treasury;
    address internal _router;
    address internal _owner;
    address internal _inputToken;
    bytes internal _path;
    address internal _pathPool;
    uint16 internal _burn;
    uint16 internal _reward;
    uint32 internal _twap;
    uint16 internal _slip;
    uint256 internal _epoch;

    function run() external {
        _load();
        vm.startBroadcast(_key);
        _deploy();
        _approveTokenAndPath();
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
        _inputToken = vm.envAddress("INPUT_TOKEN");
        _path = vm.envBytes("APPROVED_PATH");
        _pathPool = vm.envAddress("PATH_POOL");
        _burn = uint16(vm.envOr("BURN_BPS", uint256(7_000)));
        _reward = uint16(vm.envOr("EXECUTOR_REWARD_BPS", uint256(100)));
        _twap = uint32(vm.envOr("TWAP_WINDOW", uint256(1_800)));
        _slip = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(100)));
        _epoch = vm.envOr("EPOCH_DURATION", uint256(86_400));
    }

    function _deploy() internal {
        _impl = new BuybackVault();
        _createProxy();
    }

    function _createProxy() internal {
        bytes memory d = _encodeInit();
        ERC1967Proxy p = new ERC1967Proxy(address(_impl), d);
        _vault = BuybackVault(payable(address(p)));
    }

    function _encodeInit() internal view returns (bytes memory) {
        return abi.encodeCall(
            BuybackVault.initialize, (_ai, _treasury, _router, _burn, _reward, _twap, _slip, _epoch, _owner)
        );
    }

    function _approveTokenAndPath() internal {
        try _vault.approveToken(_inputToken) {}
        catch {
            console2.log("WARNING: approveToken skipped (caller is not owner).");
            console2.log("Governance Safe must call approveToken + approvePath post-deploy.");
        }
        address[] memory pools = new address[](1);
        pools[0] = _pathPool;
        try _vault.approvePath(_path, pools) {}
        catch {
            console2.log("WARNING: approvePath skipped (caller is not owner).");
        }
    }

    function _validate() internal view {
        require(_vault.owner() == _owner, "BuybackVault: owner mismatch");
        require(_vault.aiToken() == _ai, "BuybackVault: aiToken mismatch");
        require(_vault.treasury() == _treasury, "BuybackVault: treasury mismatch");
        require(_vault.swapRouter() == _router, "BuybackVault: swapRouter mismatch");
        require(_vault.burnBps() == _burn, "BuybackVault: burnBps mismatch");
        require(_vault.executorRewardBps() == _reward, "BuybackVault: executorRewardBps mismatch");
        require(_vault.twapWindow() == _twap, "BuybackVault: twapWindow mismatch");
        require(_vault.maxSlippageBps() == _slip, "BuybackVault: maxSlippageBps mismatch");
        require(_vault.epochDuration() == uint32(_epoch), "BuybackVault: epochDuration mismatch");
    }

    function _log() internal view {
        console2.log("=== BuybackVault Deployment ===");
        console2.log("Implementation:", address(_impl));
        console2.log("Proxy (vault):", address(_vault));
        console2.log("Owner:", _owner);
        console2.log("aiToken:", _ai);
        console2.log("treasury:", _treasury);
        console2.log("swapRouter:", _router);
        console2.log("burnBps:", _burn);
        console2.log("executorRewardBps:", _reward);
        console2.log("twapWindow:", _twap, "s");
        console2.log("maxSlippageBps:", _slip);
        console2.log("epochDuration:", _epoch, "s");
    }
}
