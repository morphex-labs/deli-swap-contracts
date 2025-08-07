// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "src/DailyEpochGauge.sol";
import {IPositionManagerAdapter} from "src/interfaces/IPositionManagerAdapter.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";
import {MockIncentiveGauge} from "test/mocks/MockIncentiveGauge.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

// simple token
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenMock is ERC20 {
    constructor() ERC20("BMX","BMX") { _mint(msg.sender, 1e24); }
}

contract MockPositionManager {
    function poolKeys(bytes25) external pure returns (PoolKey memory) {
        // Return a dummy pool key for testing
        return PoolKey({
            currency0: Currency.wrap(address(0xAAA)),
            currency1: Currency.wrap(address(0xBBB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}

contract MockAdapter {
    mapping(uint256 => address) public ownerOf;
    address public immutable positionManager;
    
    constructor(address _positionManager) {
        positionManager = _positionManager;
    }
    
    function setOwner(uint256 tokenId, address owner) external {
        ownerOf[tokenId] = owner;
    }
    
    function getPoolAndPositionInfo(uint256) external pure returns (PoolKey memory key, PositionInfo info) {
        key = PoolKey({
            currency0: Currency.wrap(address(0xAAA)),
            currency1: Currency.wrap(address(0xBBB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        // Return an empty PositionInfo - it's a struct with packed data
        info = PositionInfo.wrap(0);
    }
    
    function getPositionLiquidity(uint256) external pure returns (uint128) {
        return 1_000_000; // Return the same liquidity used in the test
    }
    
    function getPoolKeyFromPoolId(PoolId) external pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0xAAA)),
            currency1: Currency.wrap(address(0xBBB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}

// harness to expose internal mappings we need for assertions
contract GaugeViewHarness is DailyEpochGauge {
    constructor(address fp, address pm, address pos, address hook, IERC20 bmx)
        DailyEpochGauge(fp, IPoolManager(pm), IPositionManagerAdapter(pos), hook, bmx, address(0)) {}

    function ownerPosLen(PoolId pid, address owner) external view returns (uint256) {
        return ownerPositions[pid][owner].length;
    }

    function cachedLiquidity(bytes32 k) external view returns (uint128) {
        return positionLiquidity[k];
    }

    // Custom helper to mimic the removed updatePosition hook entry.
    // Directly updates owner index and liquidity cache like the former implementation.
    function updatePosition(
        PoolKey calldata key,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 liquidity
    ) external {
        PoolId pid = key.toId();
        
        // Use salt as tokenId (for test purposes)
        uint256 tokenId = uint256(salt);

        // Compute positionKey using new format
        bytes32 posKey = keccak256(abi.encode(tokenId, pid));

        if (positionLiquidity[posKey] == 0 && liquidity > 0) {
            ownerPositions[pid][owner].push(posKey);
            positionTokenIds[posKey] = tokenId; // Store tokenId mapping
        }

        positionLiquidity[posKey] = liquidity;

        // emulate liquidity effect on pool accumulator so tests work
        if (liquidity > 0) {
            poolRewards[pid].liquidity = liquidity;
        } else {
            poolRewards[pid].liquidity = 0;
        }

        // store tick range for pending computations
        positionTicks[posKey] = TickRange({lower: tickLower, upper: tickUpper});

        if (liquidity == 0) {
            // remove from ownerPositions array
            bytes32[] storage arr = ownerPositions[pid][owner];
            uint256 len = arr.length;
            for (uint256 i; i < len; ++i) {
                if (arr[i] == posKey) {
                    arr[i] = arr[len - 1];
                    arr.pop();
                    break;
                }
            }
            delete positionTokenIds[posKey];
        }
    }

    function poolRpl(PoolId pid) external view returns (uint256) {
         return poolRewards[pid].rewardsPerLiquidityCumulativeX128;
     }
}

contract DailyEpochGauge_UpdateTest is Test {
    GaugeViewHarness gauge;
    MockPoolManager pm;
    MockAdapter mockAdapter;
    MockPositionManager mockPositionManager;
    address hookAddr = address(0xBEEF1);

    PoolKey key;
    PoolId pid;
    address owner = address(0xABCD);

    TokenMock bmxToken;

    function setUp() public {
        pm = new MockPoolManager();
        bmxToken = new TokenMock();
        mockPositionManager = new MockPositionManager();
        mockAdapter = new MockAdapter(address(mockPositionManager));
        
        // Set owner for tokenId 0 (used in tests)
        mockAdapter.setOwner(0, owner);

        gauge = new GaugeViewHarness(address(0xFEE), address(pm), address(mockAdapter), hookAddr, bmxToken);

        key = PoolKey({
            currency0: Currency.wrap(address(0xAAA)),
            currency1: Currency.wrap(address(0xBBB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pid = key.toId();

        vm.warp(1704067200);
        pm.setLiquidity(PoolId.unwrap(pid), 1_000_000);

        // initialise epoch
        gauge.rollIfNeeded(pid);
    }

    function _callUpdate(uint128 liq) internal returns (bytes32 posKey) {
        vm.prank(hookAddr);
        gauge.updatePosition(key, owner, -60000, 60000, bytes32(0), liq);
        posKey = keccak256(abi.encode(uint256(0), pid));
    }

    function testIndexingAndCache() public {
        bytes32 pk = _callUpdate(1_000_000);
        assertEq(gauge.ownerPosLen(pid, owner), 1);
        assertEq(gauge.cachedLiquidity(pk), 1_000_000);
    }

    function testRemoveOnZeroLiquidity() public {
        bytes32 pk = _callUpdate(1_000_000);
        // now set liquidity to zero
        _callUpdate(0);
        assertEq(gauge.ownerPosLen(pid, owner), 0);
        assertEq(gauge.cachedLiquidity(pk), 0);
    }

    function testPokePoolUpdatesAccumulator() public {
        // add dummy position so poolRewards has active liquidity
        _callUpdate(1_000_000);

        // Day0: add rewards bucket
        vm.prank(address(0xFEE));
        gauge.addRewards(pid, 1e20 * 1 days);

        // Roll to Day1 (streamRate still 0, nextStreamRate set)
        (, uint64 end0,,,) = gauge.epochInfo(pid);
        vm.warp(end0);
        gauge.rollIfNeeded(pid);

        // Roll to Day2 (stream not yet active)
        vm.warp(end0 + 1 days);
        gauge.rollIfNeeded(pid);

        // Roll to Day3 to activate streamRate
        vm.warp(end0 + 2 days);
        gauge.rollIfNeeded(pid);

        uint256 beforeRpl = gauge.poolRpl(pid);
        // advance 1h into streaming day
        vm.warp(block.timestamp + 3600);
        vm.prank(hookAddr);
        gauge.pokePool(key);
        uint256 afterRpl = gauge.poolRpl(pid);
        assertGt(afterRpl, beforeRpl);
    }

    function testAccrualOverTime() public {
        uint256 dailyTokensPerSec = 10 * 1e18;
        uint256 bucket = dailyTokensPerSec * 1 days;
        vm.prank(address(0xFEE));
        gauge.addRewards(pid, bucket);

        // Roll to Day1
        (, uint64 end0,,,) = gauge.epochInfo(pid);
        vm.warp(end0);
        gauge.rollIfNeeded(pid);

        // Roll to Day2 (still no stream)
        vm.warp(end0 + 1 days);
        gauge.rollIfNeeded(pid);

        // Roll to Day3 where stream becomes active
        vm.warp(end0 + 2 days);
        gauge.rollIfNeeded(pid);

        // add position before accumulator starts
        _callUpdate(1_000_000);

        // advance 1h into streaming day and poke
        vm.warp(block.timestamp + 3600);
        vm.prank(hookAddr);
        gauge.pokePool(key);

        // advance dt = 2 hours more and poke again
        vm.warp(block.timestamp + 2 hours);
        vm.prank(hookAddr);
        gauge.pokePool(key);

        uint256 pending = gauge.pendingRewardsByTokenId(0);
        assertGt(pending, 0);
    }

    function testClaimAllForOwnerCallsIncentive() public {
        // deploy new gauge with incentive address
        MockIncentiveGauge mig = new MockIncentiveGauge();
        DailyEpochGauge g2 = new DailyEpochGauge(
            address(0xFEE),
            IPoolManager(address(pm)),
            IPositionManagerAdapter(address(mockAdapter)),
            hookAddr,
            bmxToken,
            address(mig)
        );

        PoolId[] memory arr = new PoolId[](1);
        arr[0] = pid;
        g2.claimAllForOwner(arr, owner);
        assertTrue(mig.called());
    }
}