# Libraries Technical Details

## DeliErrors

Custom error definitions for gas-efficient reverts. Categories include:

- **Generic**: `ZeroAddress()`, `ZeroAmount()`, `ZeroWeight()`
- **Access Control**: `NotAdmin()`, `NotHook()`, `NotFeeProcessor()`, `NotSubscriber()`
- **State/Config**: `AlreadySettled()`, `InvalidBps()`, `Slippage()`

## InternalSwapFlag

Constant `0xDE1ABEEF` used to mark internal buyback swaps and prevent recursive fee collection.

## Math

Basic utilities: `sqrt()` using Babylonian method and `min()` for value comparison.

## RangePool

Tick-aware accumulator for streaming rewards to concentrated liquidity positions. Tracks active liquidity, maintains tick bitmap, and calculates range-specific rewards. Key function `rangeRplX128()` determines rewards inside a position's tick range by subtracting outside rewards from global total.

## RangePosition

Per-position reward tracking. Stores last checkpoint snapshot and accumulated unclaimed rewards. Includes helper functions for position array management using swap-and-pop pattern.

## TimeLibrary

UTC-aligned time utilities. Provides `dayStart()` and `dayNext()` for epoch calculations with constants DAY (86400) and WEEK (604800) seconds.
