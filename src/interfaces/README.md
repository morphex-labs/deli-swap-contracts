# Interfaces Technical Details

## IDailyEpochGauge

Interface for BMX reward streaming with 24-hour epochs. Includes functions for adding rewards, position subscription/unsubscription, claiming, and view helpers for pending rewards.

## IIncentiveGauge

Interface for distributing additional ERC20 incentive tokens with 7-day streaming periods. Supports multiple reward tokens per pool.

## IFeeProcessor

Minimal interface for fee collection. Defines `collectFee()` for normal swaps and `collectInternalFee()` for internal buyback swaps.

## IPositionManagerAdapter

Bridge interface extending ISubscriber for unified position management. Routes events from PositionManager to handlers and provides position data access.

## IPositionHandler

Base interface for position handler implementations. Defines methods for position queries, liquidity info, and handler identification.

## IV2PositionHandler

Specialized interface for V2-style position notifications. Adds `notifyAddLiquidity()` and `notifyRemoveLiquidity()` for direct hook integration.

## IPoolKeys

Utility interface for reverse pool lookups. Converts PositionInfo to PoolKey when tokenId is unavailable (e.g., after burn).

## IRewardDistributor

Minimal interface for Voter's reward distribution targets. Defines `notifyRewardAmount()` for receiving protocol revenue.
