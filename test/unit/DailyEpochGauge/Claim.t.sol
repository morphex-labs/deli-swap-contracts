// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/DailyEpochGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {RangePool} from "src/libraries/RangePool.sol";
import {RangePosition} from "src/libraries/RangePosition.sol";
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockBMX is ERC20 {
    constructor() ERC20("BMX","BMX") { _mint(msg.sender, 1e24); }
}

contract MockAdapter {
    mapping(uint256 => address) public ownerOf;
    address public positionManager;
    
    function setOwner(uint256 tokenId, address owner) external {
        ownerOf[tokenId] = owner;
    }
    
    function setPositionManager(address pm) external {
        positionManager = pm;
    }
}

contract MockPositionManager {
    function poolKeys(bytes25) external pure returns (PoolKey memory) {
        // Return a dummy pool key for testing
        return PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}

// Harness exposing internal setters (copied from Storage.t.sol)
contract GaugeHarness2 is DailyEpochGauge {
    constructor(address _fp, address _pm, address _posMgr, address _hook, IERC20 _bmx)
        DailyEpochGauge(_fp, IPoolManager(_pm), IPositionManagerAdapter(_posMgr), _hook, _bmx, address(0)) {}

    function setPositionState(bytes32 key, uint256 paidRpl, uint256 accrued, uint128 liq, uint256 tokenId) external {
        RangePosition.State storage ps = positionRewards[key];
        ps.rewardsPerLiquidityLastX128 = paidRpl;
        ps.rewardsAccrued = accrued;
        positionLiquidity[key] = liq;
        positionTokenIds[key] = tokenId;
    }

    function pushOwnerPos(PoolId pid, address owner, bytes32 key) external {
        ownerPositions[pid][owner].push(key);
    }

    function getAccrued(bytes32 key) external view returns (uint256) {
        return positionRewards[key].rewardsAccrued;
    }
}

contract DailyEpochGauge_ClaimAllTest is Test {
    GaugeHarness2 gauge;
    MockBMX bmx;
    MockAdapter mockAdapter;
    MockPositionManager mockPositionManager;
    MockPoolManager mockPoolManager;

    PoolId constant PID = PoolId.wrap(bytes25(uint200(42)));
    address constant OWNER = address(0xDEF);

    bytes32 pos1;
    bytes32 pos2;

    function setUp() public {
        bmx = new MockBMX();
        mockAdapter = new MockAdapter();
        mockPositionManager = new MockPositionManager();
        mockAdapter.setPositionManager(address(mockPositionManager));
        mockPoolManager = new MockPoolManager();
        gauge = new GaugeHarness2(address(0xFEE), address(mockPoolManager), address(mockAdapter), address(0x3), bmx);

        uint256 tokenId1 = 1;
        uint256 tokenId2 = 2;
        
        // Set ownership in mock adapter
        mockAdapter.setOwner(tokenId1, OWNER);
        mockAdapter.setOwner(tokenId2, OWNER);
        
        pos1 = keccak256(abi.encode(tokenId1, PID));
        pos2 = keccak256(abi.encode(tokenId2, PID));

        // create two positions each with accrued rewards
        uint256 acc1 = 4 ether;
        uint256 acc2 = 6 ether;
        uint128 liq = 1e6;

        gauge.setPositionState(pos1, 0, acc1, liq, tokenId1);
        gauge.setPositionState(pos2, 0, acc2, liq, tokenId2);

        gauge.pushOwnerPos(PID, OWNER, pos1);
        gauge.pushOwnerPos(PID, OWNER, pos2);

        // fund gauge with enough BMX to pay
        bmx.transfer(address(gauge), acc1 + acc2);
        
        // Initialize the pool in MockPoolManager
        mockPoolManager.setLiquidity(PoolId.unwrap(PID), 1_000_000);
    }

    function testClaimAllTransfersAndZeroes() public {
        PoolId[] memory arr = new PoolId[](1);
        arr[0] = PID;

        vm.prank(OWNER);
        gauge.claimAllForOwner(arr, OWNER);
        
        // Assert owner's balance increased by 10 ether
        assertEq(bmx.balanceOf(OWNER), 10 ether, "owner received tokens");

        // Position accrued should now be zero
        assertEq(gauge.getAccrued(pos1), 0, "pos1 not zeroed");
        assertEq(gauge.getAccrued(pos2), 0, "pos2 not zeroed");

        // Gauge balance should be zero
        assertEq(bmx.balanceOf(address(gauge)), 0);
    }
} 