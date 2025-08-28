// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeliHookConstantProduct_TestBase} from "./Common.t.sol";
import {MultiPoolCustomCurve} from "src/base/MultiPoolCustomCurve.sol";

contract DeliHookConstantProduct_InvariantTest is DeliHookConstantProduct_TestBase {
    function test_constantProduct_invariant() public {
        addLiquidityToPool1(100 ether, 100 ether);
        (uint128 r0Init, uint128 r1Init) = hook.getReserves(id1);
        uint256 k0 = uint256(r0Init) * uint256(r1Init);

        swapInPool1(10 ether, true);
        (uint128 r0, uint128 r1) = hook.getReserves(id1);
        uint256 k1 = uint256(r0) * uint256(r1);
        assertApproxEqRel(k1, k0, 0.01e18);

        swapInPool1(5 ether, false);
        (r0, r1) = hook.getReserves(id1);
        uint256 k2 = uint256(r0) * uint256(r1);
        assertApproxEqRel(k2, k1, 0.01e18);

        uint256 amount0ToAdd = 50 ether;
        uint256 amount1ToAdd = (amount0ToAdd * r1) / r0;
        addLiquidityToPool1(amount0ToAdd, amount1ToAdd + 1 ether);
        (r0, r1) = hook.getReserves(id1);
        uint256 k3 = uint256(r0) * uint256(r1);
        assertTrue(k3 > k2);

        uint256 shares = hook.balanceOf(id1, address(this)) / 2;
        hook.removeLiquidity(key1, MultiPoolCustomCurve.RemoveLiquidityParams({
            liquidity: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: MAX_DEADLINE,
            tickLower: 0,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        }));

        (r0, r1) = hook.getReserves(id1);
        uint256 k4 = uint256(r0) * uint256(r1);
        assertTrue(k4 < k3);
        uint256 expectedK4 = k3 / 4;
        assertApproxEqRel(k4, expectedK4, 0.01e18);
    }
}


