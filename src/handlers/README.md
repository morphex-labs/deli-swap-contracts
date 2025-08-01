# Position Handlers Technical Details

## V2PositionHandler

Creates synthetic position identifiers for V2-style constant product pools. Uses mappings instead of NFTs, with one position per (poolId, owner) pair. All positions are full-range (MIN_TICK to MAX_TICK) with tick spacing 1.

## V4PositionHandler

Thin wrapper around Uniswap's PositionManager for V4 concentrated liquidity positions. Queries PositionManager directly without storing state. Uses try/catch on `ownerOf()` for token validation.

## Handler Registration

Handlers must be registered with PositionManagerAdapter using `addHandler()`. The adapter iterates through registered handlers to find the appropriate one for each tokenId based on the handler's identifier string.
