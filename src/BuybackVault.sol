// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/external/ISwapRouter02.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "./interfaces/external/IWETH.sol";
import "./interfaces/IBuybackVault.sol";
import "./libraries/TickMath.sol";

contract BuybackVault is IBuybackVault, UUPSUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint16 private constant BPS_DENOMINATOR = 10_000;

    error ZeroAddress();
    error BpsOverflow();
    error TwapWindowTooShort();
    error SlippageTooHigh();
    error EpochDurationOverflow();
    error TokenNotApproved();
    error ZeroAmount();
    error AmountTooLarge();
    error DeadlineExpired();
    error InvalidPath();
    error WethNotConfigured();
    error TokenInMismatch();
    error InvalidPathOutput();
    error PathNotApproved();
    error SlippageExceeded();
    error PoolsLengthMismatch();
    error PoolMismatch();
    error EpochLimitExceeded();
    error EthTransferFailed();
    error NotAContract();

    address public aiToken;
    address public treasury;
    address public swapRouter;
    address public weth;
    uint32 public twapWindow;
    uint16 public burnBps;
    uint16 public executorRewardBps;
    uint16 public maxSlippageBps;
    uint32 public epochDuration;
    uint32 public epochStart;
    uint32 public epochIndex;

    mapping(address => bool) public approvedTokens;
    mapping(bytes32 => bool) public approvedPaths;
    mapping(address => uint256) public tokenEpochVolumeLimit;
    mapping(address => uint256) public tokenEpochVolume;
    mapping(address => uint256) public tokenEpochIndex;
    mapping(bytes32 => address[]) public pathPools;

    // solhint-disable-next-line var-name-mixedcase
    uint256[41] private __gap;

    /// @dev Reserved storage gap for future upgrades. See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage-gaps
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _aiToken,
        address _treasury,
        address _swapRouter,
        uint16 _burnBps,
        uint16 _executorRewardBps,
        uint32 _twapWindow,
        uint16 _maxSlippageBps,
        uint256 _epochDuration,
        address _owner
    ) external initializer {
        if (_aiToken == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_swapRouter == address(0)) revert ZeroAddress();
        if (uint256(_burnBps) + uint256(_executorRewardBps) > BPS_DENOMINATOR) revert BpsOverflow();
        if (_twapWindow < 1800) revert TwapWindowTooShort();
        if (_maxSlippageBps > 500) revert SlippageTooHigh();
        if (_owner == address(0)) revert ZeroAddress();
        if (_epochDuration > type(uint32).max) revert EpochDurationOverflow();

        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Pausable_init();

        aiToken = _aiToken;
        treasury = _treasury;
        swapRouter = _swapRouter;
        burnBps = _burnBps;
        executorRewardBps = _executorRewardBps;
        twapWindow = _twapWindow;
        maxSlippageBps = _maxSlippageBps;
        epochDuration = uint32(_epochDuration);
        epochStart = uint32(block.timestamp);
    }

    receive() external payable {}

    function executeBuyback(
        address tokenIn,
        bytes calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external whenNotPaused nonReentrant {
        if (deadline < block.timestamp) revert DeadlineExpired();
        _validateBuybackParams(tokenIn, amountIn, amountOutMin, path);

        address effectiveTokenIn = _resolveEffectiveTokenIn(tokenIn);
        _validatePathEndpoints(path, effectiveTokenIn);

        bytes32 pathKey = _requireApprovedPath(path);
        _checkAndUpdateEpoch(amountIn, tokenIn);

        _validateTwapFloor(pathKey, path, amountIn, effectiveTokenIn, amountOutMin);

        uint256 amountOut = _executeSwap(tokenIn, effectiveTokenIn, path, amountIn, amountOutMin, deadline);

        (uint256 executorReward, uint256 burnAmount, uint256 treasuryAmount) = _distributeOutput(amountOut);

        emit BuybackExecuted(tokenIn, amountIn, amountOut, executorReward, burnAmount, treasuryAmount);
    }

    function _validateBuybackParams(address tokenIn, uint256 amountIn, uint256 amountOutMin, bytes calldata path)
        internal
        view
    {
        if (!approvedTokens[tokenIn]) revert TokenNotApproved();
        if (amountIn == 0) revert ZeroAmount();
        if (amountOutMin == 0) revert ZeroAmount();
        if (amountIn > type(uint128).max) revert AmountTooLarge();
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert InvalidPath();
    }

    function _requireApprovedPath(bytes calldata path) internal view returns (bytes32 pathKey) {
        pathKey = keccak256(path);
        if (!approvedPaths[pathKey]) revert PathNotApproved();
    }

    function _resolveEffectiveTokenIn(address tokenIn) internal view returns (address effectiveTokenIn) {
        if (tokenIn == address(0)) {
            address _weth = weth;
            if (_weth == address(0)) revert WethNotConfigured();
            return _weth;
        }
        return tokenIn;
    }

    function _validatePathEndpoints(bytes calldata path, address effectiveTokenIn) internal view {
        address pathFirstToken;
        address pathLastToken;
        assembly {
            pathFirstToken := shr(96, calldataload(path.offset))
            pathLastToken := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
        if (pathFirstToken != effectiveTokenIn) revert TokenInMismatch();
        if (pathLastToken != aiToken) revert InvalidPathOutput();
    }

    function _validateTwapFloor(
        bytes32 pathKey,
        bytes calldata path,
        uint256 amountIn,
        address effectiveTokenIn,
        uint256 amountOutMin
    ) internal view {
        address[] storage pools = pathPools[pathKey];
        if (pools.length == 0) revert PoolsLengthMismatch();
        uint256 twapFloor = _computeMultiHopTwapFloor(path, pools, amountIn, effectiveTokenIn);
        if (amountOutMin < twapFloor) revert SlippageExceeded();
    }

    function _executeSwap(
        address tokenIn,
        address effectiveTokenIn,
        bytes calldata path,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (tokenIn == address(0)) {
            IWETH(effectiveTokenIn).deposit{value: amountIn}();
        }
        address _swapRouter = swapRouter;
        IERC20(effectiveTokenIn).forceApprove(_swapRouter, amountIn);

        ISwapRouter02.ExactInputParams memory params = ISwapRouter02.ExactInputParams({
            path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: amountOutMin
        });

        amountOut = ISwapRouter02(_swapRouter).exactInput(params);

        IERC20(effectiveTokenIn).forceApprove(_swapRouter, 0);
    }

    function _distributeOutput(uint256 amountOut)
        internal
        returns (uint256 executorReward, uint256 burnAmount, uint256 treasuryAmount)
    {
        address _aiToken = aiToken;
        uint16 _executorRewardBps = executorRewardBps;
        uint16 _burnBps = burnBps;

        executorReward = (amountOut * uint256(_executorRewardBps)) / BPS_DENOMINATOR;
        burnAmount = ((amountOut - executorReward) * uint256(_burnBps)) / BPS_DENOMINATOR;
        unchecked {
            treasuryAmount = amountOut - executorReward - burnAmount;
        }

        if (executorReward > 0) IERC20(_aiToken).safeTransfer(msg.sender, executorReward);
        if (burnAmount > 0) IERC20(_aiToken).safeTransfer(DEAD_ADDRESS, burnAmount);
        if (treasuryAmount > 0) IERC20(_aiToken).safeTransfer(treasury, treasuryAmount);
    }

    function approvePath(bytes calldata path, address[] calldata pools) external onlyOwner {
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert InvalidPath();

        if (pools.length == 0) revert PoolsLengthMismatch();

        uint256 numHops = (path.length - 20) / 23;
        if (pools.length != numHops) revert PoolsLengthMismatch();

        address pathLastToken;
        assembly {
            pathLastToken := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
        if (pathLastToken != aiToken) revert InvalidPathOutput();

        bytes32 key = keccak256(path);
        approvedPaths[key] = true;

        for (uint256 i = 0; i < numHops; i++) {
            address hopTokenIn;
            uint24 hopFee;
            address hopTokenOut;
            uint256 hopOffset = i * 23;
            assembly {
                hopTokenIn := shr(96, calldataload(add(path.offset, hopOffset)))
                hopFee := shr(232, calldataload(add(path.offset, add(hopOffset, 20))))
                hopTokenOut := shr(96, calldataload(add(path.offset, add(hopOffset, 23))))
            }
            address hopPool = pools[i];
            if (hopPool == address(0)) revert ZeroAddress();
            (address sortedA, address sortedB) =
                hopTokenIn < hopTokenOut ? (hopTokenIn, hopTokenOut) : (hopTokenOut, hopTokenIn);
            if (IUniswapV3Pool(hopPool).token0() != sortedA) revert PoolMismatch();
            if (IUniswapV3Pool(hopPool).token1() != sortedB) revert PoolMismatch();
            if (IUniswapV3Pool(hopPool).fee() != hopFee) revert PoolMismatch();
        }
        pathPools[key] = pools;

        emit PathApproved(path, pools);
    }

    function revokePath(bytes calldata path) external onlyOwner {
        bytes32 key = keccak256(path);
        approvedPaths[key] = false;
        delete pathPools[key];
        emit PathRevoked(path);
    }

    function approveToken(address token) external onlyOwner {
        approvedTokens[token] = true;
        emit TokenApproved(token);
    }

    function revokeToken(address token) external onlyOwner {
        approvedTokens[token] = false;
        emit TokenRevoked(token);
    }

    function setAiToken(address _aiToken) external onlyOwner {
        if (_aiToken == address(0)) revert ZeroAddress();
        emit AiTokenUpdated(aiToken, _aiToken);
        aiToken = _aiToken;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setSwapRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        emit SwapRouterUpdated(swapRouter, _router);
        swapRouter = _router;
    }

    function setBurnBps(uint16 _burnBps) external onlyOwner {
        if (uint256(_burnBps) + uint256(executorRewardBps) > BPS_DENOMINATOR) revert BpsOverflow();
        emit BurnBpsUpdated(burnBps, _burnBps);
        burnBps = _burnBps;
    }

    function setExecutorRewardBps(uint16 _executorRewardBps) external onlyOwner {
        if (uint256(burnBps) + uint256(_executorRewardBps) > BPS_DENOMINATOR) revert BpsOverflow();
        emit ExecutorRewardBpsUpdated(executorRewardBps, _executorRewardBps);
        executorRewardBps = _executorRewardBps;
    }

    function setTwapWindow(uint32 _twapWindow) external onlyOwner {
        if (_twapWindow < 1800) revert TwapWindowTooShort();
        emit TwapWindowUpdated(twapWindow, _twapWindow);
        twapWindow = _twapWindow;
    }

    function setMaxSlippageBps(uint16 _maxSlippageBps) external onlyOwner {
        if (_maxSlippageBps > 500) revert SlippageTooHigh();
        emit MaxSlippageBpsUpdated(maxSlippageBps, _maxSlippageBps);
        maxSlippageBps = _maxSlippageBps;
    }

    function setEpochConfig(uint256 _epochDuration) external onlyOwner {
        if (_epochDuration > type(uint32).max) revert EpochDurationOverflow();
        epochDuration = uint32(_epochDuration);
        epochStart = uint32(block.timestamp);
        epochIndex++;
        emit EpochConfigUpdated(_epochDuration);
    }

    function setTokenEpochVolumeLimit(address token, uint256 limit) external onlyOwner {
        tokenEpochVolumeLimit[token] = limit;
        emit TokenEpochVolumeLimitUpdated(token, limit);
    }

    function setWeth(address _weth) external onlyOwner {
        if (_weth != address(0) && _weth.code.length == 0) revert NotAContract();
        emit WethUpdated(weth, _weth);
        weth = _weth;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencySweep(address token, address to, uint256 amount) external onlyOwner whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit EmergencySwept(token, to, amount);
    }

    function _checkAndUpdateEpoch(uint256 amountIn, address tokenIn) internal {
        if (epochDuration == 0) return;

        if (block.timestamp >= uint256(epochStart) + uint256(epochDuration)) {
            epochStart = uint32(block.timestamp);
            epochIndex++;
        }

        uint256 limit = tokenEpochVolumeLimit[tokenIn];
        if (limit == 0) return;

        uint256 currentVolume = tokenEpochIndex[tokenIn] == epochIndex ? tokenEpochVolume[tokenIn] : 0;
        uint256 newVolume = currentVolume + amountIn;
        if (newVolume > limit) revert EpochLimitExceeded();
        tokenEpochVolume[tokenIn] = newVolume;
        tokenEpochIndex[tokenIn] = epochIndex;
    }

    function _computeMultiHopTwapFloor(
        bytes calldata path,
        address[] storage pools,
        uint256 amountIn,
        address firstToken
    ) internal view returns (uint256 floor) {
        uint256 currentAmount = amountIn;
        uint256 numHops = pools.length;
        address currentTokenIn = firstToken;
        for (uint256 i = 0; i < numHops; i++) {
            address currentTokenOut;
            uint256 hopOffset = i * 23;
            assembly {
                currentTokenOut := shr(96, calldataload(add(path.offset, add(hopOffset, 23))))
            }
            currentAmount = _computeTwapHopQuote(pools[i], currentTokenIn, currentTokenOut, currentAmount);
            currentTokenIn = currentTokenOut;
        }
        floor = currentAmount * (BPS_DENOMINATOR - maxSlippageBps) / BPS_DENOMINATOR;
    }

    function _computeTwapHopQuote(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        uint32 window = twapWindow;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 meanTick = int24(tickDelta / int56(uint56(window)));
        if (tickDelta < 0 && (tickDelta % int56(uint56(window)) != 0)) meanTick--;

        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(meanTick);

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
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
