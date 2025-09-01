# Base Contracts Technical Details

## MultiPoolCustomCurve

Abstract base contract for implementing custom AMM curves in Uniswap v4. Provides the foundation for overriding concentrated liquidity with alternative pricing models.

### Architecture

Combines multiple V4 hook patterns:
- **BaseCustomAccounting**: Custom token settlement handling
- **BaseCustomCurve**: Alternative pricing implementation
- **Multi-pool support**: Manages state across multiple pools

### Key Features

- **Public entry points**: 
  - `addLiquidity()` - User-facing liquidity provision
  - `removeLiquidity()` - User-facing liquidity removal
- **Unlock pattern**: Uses PoolManager's callback system for atomic operations
- **ERC-6909 claims**: Manages token transfers through Uniswap's claim system
- **Hook integration**: Works within V4's hook framework while bypassing core pricing

### Abstract Methods

Implementations must override:

- `_getUnspecifiedAmount(params, swapDelta)` - Custom curve pricing logic for swaps
- `_getAmountIn(pool, recipient, currency, desired)` - Calculate input for desired output
- `_getAmountOut(pool, recipient, currency, desired)` - Calculate output for given input
- `_mint(owner, id, liquidity)` - Issue liquidity tokens/shares
- `_burn(owner, id, liquidity)` - Remove liquidity tokens/shares
- `_getSwapFeeAmount(pool, amount, isInput)` - Optional custom fee calculation

### Storage Pattern

Derived contracts typically maintain:
- Per-pool state (e.g., reserves for constant product)
- Per-user positions (e.g., liquidity shares)
- Custom accounting logic

### Usage Example

`DeliHookConstantProduct` extends this base to implement x*y=k AMM:
- Overrides pricing methods with constant product formula
- Maintains `reserves` mapping for per-pool token balances
- Tracks `liquidityShares` for fungible LP positions
- Implements virtual price calculations and slippage limits

### Security Considerations

- Must handle reentrancy carefully during unlocks
- Should validate all pricing calculations to prevent manipulation
- Needs proper access control for administrative functions
- Must ensure conservation of value across swaps and liquidity operations