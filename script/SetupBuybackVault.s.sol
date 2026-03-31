// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/BuybackVault.sol";

contract SetupBuybackVault is Script {
    BuybackVault internal _vault;

    uint256 internal _key;
    address internal _vaultAddr;
    address internal _inputToken;
    bytes internal _path;
    address internal _weth;
    uint256 internal _volumeLimit;

    function run() external {
        _load();
        vm.startBroadcast(_key);
        _setup();
        vm.stopBroadcast();
        _validate();
        _log();
    }

    function _load() internal {
        _key = vm.envUint("OWNER_KEY");
        _vaultAddr = vm.envAddress("VAULT");
        _vault = BuybackVault(payable(_vaultAddr));

        _inputToken = vm.envAddress("INPUT_TOKEN");
        _path = vm.envBytes("APPROVED_PATH");

        _weth = vm.envOr("WETH", address(0));
        _volumeLimit = vm.envOr("VOLUME_LIMIT", uint256(0));
    }

    function _setup() internal {
        if (!_vault.approvedTokens(_inputToken)) {
            _vault.approveToken(_inputToken);
        }

        bytes32 pathKey = keccak256(_path);
        if (!_vault.approvedPaths(pathKey)) {
            _vault.approvePath(_path);
        }

        if (_weth != address(0) && _vault.weth() != _weth) {
            _vault.setWeth(_weth);
        }

        if (_volumeLimit > 0 && _vault.tokenEpochVolumeLimit(_inputToken) != _volumeLimit) {
            _vault.setTokenEpochVolumeLimit(_inputToken, _volumeLimit);
        }
    }

    function _validate() internal view {
        require(_vault.approvedTokens(_inputToken), "inputToken not approved");
        require(_vault.approvedPaths(keccak256(_path)), "path not approved");

        if (_weth != address(0)) {
            require(_vault.weth() == _weth, "weth mismatch");
        }
        if (_volumeLimit > 0) {
            require(_vault.tokenEpochVolumeLimit(_inputToken) == _volumeLimit, "volumeLimit mismatch");
        }
    }

    function _log() internal view {
        console2.log("=== BuybackVault Setup Complete ===");
        console2.log("Vault:", _vaultAddr);
        console2.log("Input Token (approved):", _inputToken);
        if (_weth != address(0)) {
            console2.log("WETH:", _weth);
        }
        if (_volumeLimit > 0) {
            console2.log("Volume Limit:", _volumeLimit);
        }
        console2.log("");
        console2.log(">>> Vault is ready for buybacks");
    }

}
