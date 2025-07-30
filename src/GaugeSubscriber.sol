// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";

/**
 * @title GaugeSubscriber
 * @notice Helper contract that multiplexes PositionManager subscription
 *         callbacks to both DailyEpochGauge and IncentiveGauge, overcoming the
 *         single-subscriber limitation in Uniswap-v4 NFTs. It performs no
 *         additional logic – it merely forwards every callback unchanged.
 */
contract GaugeSubscriber is ISubscriber {
    /*//////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////*/

    IPositionManager public immutable POSITION_MANAGER;
    ISubscriber public immutable DAILY_GAUGE;
    ISubscriber public immutable INCENTIVE_GAUGE;

    /*//////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPositionManager _pm, ISubscriber _daily, ISubscriber _incentive) {
        if (address(_pm) == address(0)) revert DeliErrors.ZeroAddress();
        if (address(_daily) == address(0)) revert DeliErrors.ZeroAddress();
        if (address(_incentive) == address(0)) revert DeliErrors.ZeroAddress();

        POSITION_MANAGER = _pm;
        DAILY_GAUGE = _daily;
        INCENTIVE_GAUGE = _incentive;
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyPositionManager() {
        if (msg.sender != address(POSITION_MANAGER)) revert DeliErrors.NotPositionManager();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            SUBSCRIPTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISubscriber
    function notifySubscribe(uint256 tokenId, bytes memory data) external override onlyPositionManager {
        DAILY_GAUGE.notifySubscribe(tokenId, data);
        INCENTIVE_GAUGE.notifySubscribe(tokenId, data);
    }

    /// @inheritdoc ISubscriber
    function notifyUnsubscribe(uint256 tokenId) external override onlyPositionManager {
        DAILY_GAUGE.notifyUnsubscribe(tokenId);
        INCENTIVE_GAUGE.notifyUnsubscribe(tokenId);
    }

    /// @inheritdoc ISubscriber
    function notifyBurn(
        uint256 tokenId,
        address ownerAddr,
        PositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) external override onlyPositionManager {
        DAILY_GAUGE.notifyBurn(tokenId, ownerAddr, info, liquidity, feesAccrued);
        INCENTIVE_GAUGE.notifyBurn(tokenId, ownerAddr, info, liquidity, feesAccrued);
    }

    /// @inheritdoc ISubscriber
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued)
        external
        override
        onlyPositionManager
    {
        DAILY_GAUGE.notifyModifyLiquidity(tokenId, liquidityChange, feesAccrued);
        INCENTIVE_GAUGE.notifyModifyLiquidity(tokenId, liquidityChange, feesAccrued);
    }
}
