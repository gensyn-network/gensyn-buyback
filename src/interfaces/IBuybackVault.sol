// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBuybackVault {
    event BuybackExecuted(
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 executorReward,
        uint256 burnAmount,
        uint256 treasuryAmount
    );

    event PathApproved(bytes path, address[] pools);
    event PathRevoked(bytes path);
    event TokenApproved(address indexed token);
    event TokenRevoked(address indexed token);
    event EmergencySwept(address indexed token, address indexed to, uint256 amount);

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SwapRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event BurnBpsUpdated(uint16 oldBps, uint16 newBps);
    event ExecutorRewardBpsUpdated(uint16 oldBps, uint16 newBps);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);
    event MaxSlippageBpsUpdated(uint16 oldBps, uint16 newBps);
    event EpochConfigUpdated(uint256 duration);
    event TokenEpochVolumeLimitUpdated(address indexed token, uint256 newLimit);
    event WethUpdated(address indexed oldWeth, address indexed newWeth);
    event EthBuybackEnabledUpdated(bool enabled);

    function executeBuyback(address tokenIn, bytes calldata path, uint256 amountIn, uint256 amountOutMin) external;

    function pause() external;
    function unpause() external;
    function emergencySweep(address token, address to, uint256 amount) external;

    function approvePath(bytes calldata path, address[] calldata pools) external;
    function revokePath(bytes calldata path) external;

    function setTreasury(address treasury) external;
    function setSwapRouter(address router) external;
    function setBurnBps(uint16 burnBps) external;
    function setExecutorRewardBps(uint16 executorRewardBps) external;
    function setTwapWindow(uint32 twapWindow) external;
    function setMaxSlippageBps(uint16 maxSlippageBps) external;
    function approveToken(address token) external;
    function revokeToken(address token) external;
    function setEpochConfig(uint256 epochDuration) external;
    function setTokenEpochVolumeLimit(address token, uint256 limit) external;
    function setWeth(address weth) external;
    function setEthBuybackEnabled(bool enabled) external;
}
