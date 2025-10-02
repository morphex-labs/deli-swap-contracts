# Interfaces Technical Details

## IDailyEpochGauge

Interface for BMX reward streaming with 24-hour UTC epochs:

### Key Functions
- `addRewards(amount)` - Queue BMX rewards for N+2 day distribution
- `notifySubscribe/Unsubscribe(positionInfo, extraData)` - Position lifecycle management
- `claim(positionInfo, epochs, extraData)` - Claim accumulated rewards
- `pokePool(poolId)` - Update pool state on swaps
- `pendingRewards(positionInfo, epochs)` - View unclaimed amounts

### Pipeline Details
- Day N: Fees collected and added as rewards
- Day N+2: Rewards stream to in-range positions over 24 hours
- Auto-claims on position transfer/removal

## IIncentiveGauge

Interface for distributing additional ERC20 incentive tokens:

### Key Functions
- `notifyAndDistribute(token, amount, maxDuration)` - Add token incentives
- `notifySubscribe/Unsubscribe(positionInfo, extraData)` - Position tracking
- `claim(positionInfo, tokens, extraData)` - Claim specific token rewards
- `whitelistedTokens()` - View allowed reward tokens

### Important Behavior
- 7-day streaming periods with immediate start
- Supports multiple simultaneous reward tokens
- **Rewards are forfeited on position unsubscribe** (no auto-claim)
- Seamless top-ups extend existing streams

## IFeeProcessor

Minimal interface for centralized fee collection:

### Key Functions
- `collectFee(currency, amount, pool)` - Receive fees from hooks
- `collectInternalFee(currency, amount, pool)` - Internal buyback swap fees

### Implementation Details
- Assumes all fees arrive as wBLT
- Maintains per-pool pending buffers
- Keeper-triggered buybacks when buffer ≥ 1 wBLT
- Uses 0xDE1ABEEF flag for internal swaps

## IPositionManagerAdapter

Bridge interface extending ISubscriber for unified position management:

### Key Functions
- `subscribeToNFTUpdates(subscriber)` - PositionManager hook
- `unsubscribeFromNFTUpdates()` - Cleanup hook
- `notifySubscribe/Unsubscribe/ModifyLiquidity()` - NFT event handlers
- `contextFor(tokenIds, pools)` - Batch position data fetching

### Routing Logic
- Receives events from Uniswap PositionManager
- Routes to appropriate handler based on tokenId
- Pre-fetches context for gas optimization
- Manages gauge subscriptions

## IPositionHandler

Base interface for position handler implementations:

### Required Methods
- `isHandler(tokenId)` - Check if handler manages this token
- `getPoolId(positionInfo)` - Extract pool identifier
- `getPositionLiquidity(positionInfo)` - Current liquidity amount
- `identifier()` - Unique handler name
- `positionOwner(positionInfo)` - Position ownership lookup

## IV2PositionHandler

Specialized interface extending IPositionHandler for V2-style positions:

### Additional Methods
- `notifyAddLiquidity(owner, liquidity, pool)` - Direct hook notification
- `notifyRemoveLiquidity(owner, liquidity, pool)` - Direct hook notification
- `positions(bytes25, address)` - Position data lookup
- `liquidityOf(truncatedPoolId, owner)` - User liquidity balance

### Implementation Note
- Only V2 hooks call these notification methods directly
- V4 positions route through PositionManagerAdapter

## IPoolKeys

Utility interface for pool metadata lookups:

### Key Function
- `poolKeys(tokenId)` - Convert tokenId to PoolKey struct

### Usage
- Provides PoolKey when poolId is unavailable
- Critical for position operations after burns
- V2Handler maintains truncated poolId mappings

## IRewardDistributor

Minimal interface for Voter's reward distribution targets:

### Key Function
- `notifyRewardAmount(token, amount)` - Receive protocol revenue

### Implementation
- Called by Voter during weekly finalization
- Typically implemented by Safety Module and reward contracts
- Must handle multiple token types