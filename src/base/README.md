# Base Contracts Technical Details

## MultiPoolCustomCurve

Abstract base contract for implementing custom AMM curves in Uniswap v4. Combines BaseCustomAccounting and BaseCustomCurve patterns with multi-pool support.

### Key Features

- **Public entry points**: `addLiquidity()` and `removeLiquidity()` handle user interactions
- **Unlock pattern**: Uses PoolManager's callback system for atomic operations
- **ERC-6909 claims**: Manages token transfers through Uniswap's claim system

### Abstract Methods

Implementations must override:

- `_getUnspecifiedAmount()` - Custom curve pricing logic
- `_getAmountIn()` / `_getAmountOut()` - Liquidity calculations
- `_mint()` / `_burn()` - Token management
- `_getSwapFeeAmount()` - Optional fee calculation

### Usage Example

DeliHookConstantProduct extends this to implement x*y=k AMM by overriding pricing methods with constant product formula and maintaining per-pool reserve state.
