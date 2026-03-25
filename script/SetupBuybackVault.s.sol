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
    address[] internal _pathPools;
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

        string memory poolsStr = vm.envString("PATH_POOLS");
        _pathPools = _parseAddresses(poolsStr);

        _weth = vm.envOr("WETH", address(0));
        _volumeLimit = vm.envOr("VOLUME_LIMIT", uint256(0));
    }

    function _setup() internal {
        if (!_vault.approvedTokens(_inputToken)) {
            _vault.approveToken(_inputToken);
        }

        bytes32 pathKey = keccak256(_path);
        if (!_vault.approvedPaths(pathKey)) {
            _vault.approvePath(_path, _pathPools);
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
        console2.log("Path Pools Count:", _pathPools.length);
        if (_weth != address(0)) {
            console2.log("WETH:", _weth);
        }
        if (_volumeLimit > 0) {
            console2.log("Volume Limit:", _volumeLimit);
        }
        console2.log("");
        console2.log(">>> Vault is ready for buybacks");
    }

    function _parseAddresses(string memory str) internal pure returns (address[] memory) {
        bytes memory b = bytes(str);
        if (b.length == 0) {
            return new address[](0);
        }

        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }

        address[] memory result = new address[](count);
        uint256 idx = 0;
        uint256 start = 0;

        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory addrBytes = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    addrBytes[j - start] = b[j];
                }
                result[idx] = _parseAddress(string(addrBytes));
                idx++;
                start = i + 1;
            }
        }

        return result;
    }

    function _parseAddress(string memory str) internal pure returns (address) {
        bytes memory b = bytes(str);
        uint256 start = 0;

        while (start < b.length && (b[start] == " " || b[start] == "\t")) {
            start++;
        }

        if (b.length >= start + 2 && b[start] == "0" && (b[start + 1] == "x" || b[start + 1] == "X")) {
            start += 2;
        }

        uint160 addr = 0;
        for (uint256 i = start; i < b.length && i < start + 40; i++) {
            uint8 digit;
            bytes1 c = b[i];
            if (c >= "0" && c <= "9") {
                digit = uint8(c) - 48;
            } else if (c >= "a" && c <= "f") {
                digit = uint8(c) - 87;
            } else if (c >= "A" && c <= "F") {
                digit = uint8(c) - 55;
            } else {
                break;
            }
            addr = addr * 16 + digit;
        }

        return address(addr);
    }
}
