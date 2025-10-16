# Core Contracts Technical Details

## DeliHook

Primary Uniswap V4 hook for concentrated liquidity pools that:
- Enforces: no native ETH; one side must be wBLT; pool must use dynamic fees
- Bootstraps `DailyEpochGauge` and `IncentiveGauge` on initialization
- Derives and sets the LP fee from tick spacing:
  1→0.01%, 10→0.03%, 40→0.15%, 60→0.30%, 100→0.40%, 200→0.65%, 300→1.00%, 400→1.75%, 600→2.50%
- Overrides the pool LP fee to 0 at swap time using `LPFeeLibrary.OVERRIDE_FEE_FLAG`
- Computes fees (in wBLT) and forwards them to `FeeProcessor` (fee currency is always wBLT; cross-currency conversions use sqrtPrice^2 with rounding up)
- Checkpoints both gauges on every swap
- Full-fill only: reverts on any partial fill (strict specified-side delta equality in afterSwap)

Admin: update `FeeProcessor`, `DailyEpochGauge`, `IncentiveGauge`, and per-pool dynamic fee (0.01%–3%).

## DeliHookConstantProduct

Uniswap V4 hook implementing a V2-style x*y=k AMM on top of `MultiPoolCustomCurve`:
- Per-pool reserves and per-user LP shares (no NFTs); first mint locks minimum liquidity
- Initialization constraints: one token must be wBLT, `tickSpacing=1`, `sqrtPrice=2^96` (tick 0), fee ≥ 0.1%
- Fee currency is always wBLT. The hook burns ERC-6909 claims and takes the real tokens to forward fees to `FeeProcessor`
- Enforces `sqrtPriceLimitX96` against virtual price from reserves
- Full-fill only via limit enforcement: swaps revert on partial fill or when price limit is met
- Notifies `V2PositionHandler` on add/remove liquidity; checkpoints both gauges on swaps
- Views: quotes, multi-hop quotes, `getReserves`, `getTotalSupply`, `balanceOf`, and a virtual `getSlot0`

Admin: setters for `FeeProcessor`, `DailyEpochGauge`, `IncentiveGauge`, `V2PositionHandler`.

## FeeProcessor

Central fee collection and distribution hub:
- Splits incoming wBLT fees: 97% for BMX buybacks, 3% for voters (configurable via `buybackBps`)
- Per-pool pending buffers with swap-and-pop removal
- Keeper-based buyback execution when buffers reach MIN_WBLT_FOR_BUYBACK (1 wBLT)
- Buyback swaps use `PoolManager` with `0xDE1ABEEF` flag to mark internal swaps; fees are still charged and forwarded as normal
- Streams bought BMX directly to `DailyEpochGauge`
- `claimVoterFees()` transfers accumulated voter wBLT to target address

Admin: `setBuybackBps`, `setBuybackPoolKey`, `setHook`, `setKeeper`, emergency `sweepERC20` (excludes BMX/wBLT).

## DailyEpochGauge

BMX reward streaming with 24-hour UTC epochs:
- N+2 day pipeline: fees collected Day N → stream Day N+2
- Range-aware reward distribution (only in-range positions earn)
- Context-based subscription system via `PositionManagerAdapter`
- Sophisticated tick accounting with `RangePool` library
- Supports both individual and batch claiming
- Burn path auto-claims on removal; unsubscribe forfeits rewards (no auto-claim)
- Admin force-unsubscribe functionality

Admin: `setFeeProcessor`, `setPositionManagerAdapter`, `adminForceUnsubscribe`.

## IncentiveGauge

Additional ERC20 token rewards with seamless top-ups:
- 7-day streaming periods with immediate start
- Whitelist system for allowed reward tokens
- Range-aware distribution matching `DailyEpochGauge`
- **Important**: Rewards are forfeited on position unsubscribe (no auto-claim)
- Supports upsert semantics for ongoing incentive programs
- Combined claiming with `DailyEpochGauge` rewards

Admin: `setWhitelist`, `setPositionManagerAdapter`, `adminForceUnsubscribe`.

## PositionManagerAdapter

Modular position event router extending `ISubscriber`:
- Routes Uniswap PositionManager events to appropriate handlers
- Pre-fetches position context for gas optimization
- Handler discovery with `isHandler()` iteration
- V2 fallback for PoolKey lookups via truncated poolId
- Manages subscriptions to both gauge contracts

Admin: `addHandler`, `removeHandler`.

## Voter

Weekly voting system for protocol revenue distribution:
- Tuesday-aligned epochs with batch-aware finalization
- Auto-vote array tracking with balance verification at finalization
- Manual votes override auto-votes for that epoch
- Vote weight equals `SBF_BMX.balanceOf(user)` at tally time; manual votes are reduced if balance decreased since vote; auto-votes use live balances during tally
- Distributes by winning option: winner’s share to Safety Module, remainder streamed over 1 week via RewardDistributor
- Admin deposits WETH for each epoch
- Operational requirement: during finalization batches, BMX staking (sbfBMX issuance) must be temporarily disabled in the external RewardRouter to prevent vote manipulation between batches

Admin: `setOptions`, `deposit`, `finalize` with batch support.