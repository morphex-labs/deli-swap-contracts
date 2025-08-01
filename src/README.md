# Core Contracts Technical Details

## DeliHook

Primary V4 hook for concentrated liquidity pools. Intercepts swap fees before they reach LPs and forwards to FeeProcessor. Uses BeforeSwapDelta for exact input swaps on non-BMX pools, otherwise uses take() method.

## DeliHookConstantProduct

V2-style x*y=k AMM implementation. Extends MultiPoolCustomCurve to override concentrated liquidity. Maintains per-pool reserves and uses synthetic position identifiers instead of NFTs. Fees are implicit in the constant product formula.

## FeeProcessor

Central fee collection hub. Splits fees 97% for BMX buybacks (via PoolManager swap) and 3% for voters (as wBLT). Includes slippage protection and handles both BMX and non-BMX pool fees differently.

## DailyEpochGauge

BMX reward distribution with 24-hour UTC epochs. Implements 3-day pipeline: fees collected Day N → queued Day N+1 → streamed Day N+2. Only in-range positions earn rewards through sophisticated tick accounting.

## IncentiveGauge

Additional ERC20 token rewards with 7-day streaming periods. Supports multiple reward tokens per pool. Uses same range-aware distribution as DailyEpochGauge.

## PositionManagerAdapter

ISubscriber implementation that routes position events from Uniswap's PositionManager to appropriate handlers. Manages handler discovery and forwards subscription events to both gauge contracts.

## Voter

Weekly voting for sbfBMX holders to allocate protocol revenue. Features auto-vote system that tracks voters in array, checks balances at finalization, and removes zero-balance voters. Manual votes override auto-votes for that epoch.
