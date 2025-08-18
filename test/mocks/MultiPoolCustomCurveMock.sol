// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

contract MultiPoolCustomCurveMock is MultiPoolCustomCurve, ERC20 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencySettler for Currency;
    
    // Track liquidity shares per pool per user
    mapping(PoolId => mapping(address => uint256)) public balanceOf;
    
    // Track total supply per pool
    mapping(PoolId => uint256) public totalSupplyPerPool;
    
    // Legacy reserve trackers (not relied upon for calculations anymore). Kept for compatibility.
    mapping(PoolId => uint256) public reserve0;
    mapping(PoolId => uint256) public reserve1;

    constructor(IPoolManager _poolManager) 
        MultiPoolCustomCurve(_poolManager) 
        ERC20("MultiPoolCurveLiquidity", "MPCL") 
    {}

    function _getUnspecifiedAmount(PoolKey memory, SwapParams calldata params) 
        internal 
        pure 
        override 
        returns (uint256) 
    {
        bool exactInput = params.amountSpecified < 0;
        uint256 amountSpecified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        
        // Simple 1:1 swap for testing
        return amountSpecified;
    }

    function _getSwapFeeAmount(PoolKey memory, SwapParams calldata, uint256)
        internal
        pure
        override
        returns (uint256)
    {
        // No fees for testing
        return 0;
    }

    function _getAmountOut(PoolKey memory key, RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        PoolId poolId = key.toId();
        shares = params.liquidity;

        uint256 supply = totalSupplyPerPool[poolId];
        if (supply == 0) {
            return (0, 0, 0);
        }

        // Read current ERC-6909 claim balances directly from PoolManager to stay in sync with swaps
        uint256 curReserve0 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(key.currency0));
        uint256 curReserve1 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(key.currency1));

        amount0 = (shares * curReserve0) / supply;
        amount1 = (shares * curReserve1) / supply;
    }

    function _getAmountIn(PoolKey memory, AddLiquidityParams memory params)
        internal
        pure
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        // Simple 1:1 for testing
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        shares = (amount0 + amount1) / 2;
    }

    function _getAddLiquidity(PoolKey memory key, uint160, AddLiquidityParams memory params)
        internal
        override
        returns (bytes memory, uint256)
    {
        (uint256 amount0, uint256 amount1, uint256 shares) = _getAmountIn(key, params);
        
        // Update reserves
        PoolId poolId = key.toId();
        reserve0[poolId] += amount0;
        reserve1[poolId] += amount1;
        
        // Return the encoded amounts as int128 (following MultiPoolCustomCurve pattern)
        return (abi.encode(amount0.toInt128(), amount1.toInt128()), shares);
    }

    function _getRemoveLiquidity(PoolKey memory key, RemoveLiquidityParams memory params)
        internal
        override
        returns (bytes memory, uint256)
    {
        (uint256 amount0, uint256 amount1, ) = _getAmountOut(key, params);

        // Return the encoded amounts as negative int128 (following MultiPoolCustomCurve pattern)
        return (abi.encode(-amount0.toInt128(), -amount1.toInt128()), params.liquidity);
    }

    function _mint(
        PoolKey memory key,
        AddLiquidityParams memory,
        BalanceDelta,
        BalanceDelta,
        uint256 shares
    ) internal override {
        PoolId poolId = key.toId();
        balanceOf[poolId][msg.sender] += shares;
        totalSupplyPerPool[poolId] += shares;
        _mint(msg.sender, shares); // ERC20 mint for compatibility
    }

    function _burn(
        PoolKey memory key,
        RemoveLiquidityParams memory,
        BalanceDelta,
        BalanceDelta,
        uint256 shares
    ) internal override {
        PoolId poolId = key.toId();
        require(balanceOf[poolId][msg.sender] >= shares, "Insufficient balance");
        balanceOf[poolId][msg.sender] -= shares;
        totalSupplyPerPool[poolId] -= shares;
        _burn(msg.sender, shares); // ERC20 burn for compatibility
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Update reserves after swap for proper tracking
        PoolId poolId = key.toId();
        uint256 balance0 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(key.currency0));
        uint256 balance1 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(key.currency1));
        
        reserve0[poolId] = uint128(balance0);
        reserve1[poolId] = uint128(balance1);
        
        return (this.afterSwap.selector, 0);
    }
}