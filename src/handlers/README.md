# Position Handlers Technical Details

## Overview

Position handlers implement the `IPositionHandler` interface to manage different types of liquidity positions. The system uses tokenId ranges to distinguish between handler types:

- **V4 Positions**: tokenId ∈ [1, 2^255-1]
- **V2 Positions**: tokenId ∈ [2^255, 2^256-1] (bit 255 set)

## V2PositionHandler

Manages synthetic positions for V2-style constant product pools:

### Key Features

- **Synthetic TokenIds**: Uses bit 255 as prefix to generate unique IDs
- **Mapping-based Storage**: No NFTs; positions stored in `positions` mapping
- **One Position Per User**: Each (poolId, owner) pair has exactly one position
- **Full-Range Only**: All positions use MIN_TICK to MAX_TICK
- **Direct Notifications**: Receives `notifyAddLiquidity`/`notifyRemoveLiquidity` from hook

### Position Management

- Truncates poolId to bytes25 for storage optimization
- Maintains `poolIdsByTruncated` for reverse lookups
- Uses deterministic formula: `tokenId = (1 << 255) | (uint256(bytes25(poolId)) << 160) | uint160(owner)`
- Position key: `keccak256(abi.encode(tokenId, poolId))`

### Context Building

Returns `PositionInfo` with:
- Hardcoded tick range (full-range)
- Pool-specific liquidity from `liquidityOf()`
- Tick spacing always 1

## V4PositionHandler

Thin wrapper around Uniswap's PositionManager for V4 concentrated liquidity positions:

### Key Features

- **No State Storage**: Queries PositionManager directly
- **NFT-Based**: Real ERC721 tokens with configurable tick ranges
- **Validation**: Uses try/catch on `ownerOf()` to verify token existence
- **Pass-Through**: Simply forwards all queries to PositionManager

### Context Building

Fetches from PositionManager:
- Actual tick ranges (lower/upper)
- Current liquidity amount
- Variable tick spacing per pool

## Handler Registration

The `PositionManagerAdapter` manages handler discovery:

1. **Registration**: Call `addHandler(handler)` to register new handlers
2. **Discovery**: Adapter calls `isHandler(tokenId)` on each registered handler
3. **Routing**: First handler returning `true` handles that position
4. **Order Matters**: Handlers checked in registration order

### Implementation Requirements

Handlers must implement:
- `isHandler(tokenId)` - Return true for handled token ranges
- `getPoolId(positionInfo)` - Extract poolId from position
- `getPositionLiquidity(positionInfo)` - Current liquidity amount
- `identifier()` - Unique string identifier for handler type

### Security Considerations

- V2Handler has no ownership controls (managed by hook)
- V4Handler inherits PositionManager's access control
- Handler registration requires admin privileges
- Invalid tokenIds gracefully return zero/empty values