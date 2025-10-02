# Libraries Technical Details

## DeliErrors

Custom error definitions for gas-efficient reverts across the protocol.

### Error Categories

**Generic Errors**:
- `ZeroAddress()` - Null address validation
- `ZeroAmount()` - Empty value checks
- `ZeroWeight()` - Voting weight validation

**Access Control**:
- `NotAdmin()` - Admin-only function access
- `NotHook()` - Hook authorization check
- `NotFeeProcessor()` - Fee processor validation
- `NotSubscriber()` - Subscription system access
- `NotHandler()` - Position handler validation

**State/Configuration**:
- `AlreadySettled()` - Duplicate settlement prevention
- `InvalidBps()` - Basis points validation (>10,000)
- `Slippage()` - Price protection failures
- `InvalidEpoch()` - Time-based validation
- `NotWhitelisted()` - Token whitelist check

## InternalSwapFlag

Constant used to identify internal protocol operations:

### Usage
- `FLAG = 0xDE1ABEEF` - Marks FeeProcessor buyback swaps
- Prevents recursive fee collection on BMX buyback swaps
- Checked by hooks to differentiate user swaps from protocol swaps

## Math

Basic mathematical utilities optimized for gas efficiency:

### Functions
- `sqrt(uint256 x)` - Square root using Babylonian method
  - Iterative approximation with guaranteed convergence
  - Used for constant product AMM calculations
- `min(uint256 a, uint256 b)` - Minimum value comparison
  - Simple ternary operator implementation
  - Used throughout for bounds checking

## RangePool

Sophisticated tick-aware accumulator for streaming rewards to concentrated liquidity positions:

### Core Functionality
- Tracks global reward rate (`rateX128`) in Q128 format
- Maintains tick bitmap for active liquidity ranges
- Calculates position-specific rewards using range queries

### Key Algorithm
`rangeRplX128(tickLower, tickUpper)` - Determines rewards inside a range:
1. Calculates rewards outside the range (below lower + above upper)
2. Subtracts from global total to get inside rewards
3. Handles edge cases for infinite ranges

### Storage Pattern
- `tickBitmap` - Packed uint256 tracking initialized ticks
- `ticks` - Per-tick cumulative reward tracking
- `global` - Pool-wide accumulator state

## RangePosition

Per-position reward tracking and ownership management:

### Core Features
- Stores checkpoint data: `snapshotRplX128` and `snapshotTime`
- Accumulates `pendingRewards` between claims
- Maps position keys to owners for permission checks

### Array Management
Helper functions using swap-and-pop pattern:
- `deleteOwner(owners, index)` - Efficient array removal
- `findOwner(owners, target)` - Linear search for owner
- Gas-optimized for small owner arrays

### Usage Pattern
1. Checkpoint position on liquidity changes
2. Accumulate rewards based on time and range
3. Claim resets pending to zero

## TimeLibrary

UTC-aligned time utilities for epoch-based systems:

### Constants
- `DAY = 86400` - Seconds in 24 hours
- `WEEK = 604800` - Seconds in 7 days

### Functions
- `dayStart(timestamp)` - Returns midnight UTC for given timestamp
  - Used by DailyEpochGauge for 24-hour epochs
- `dayNext(timestamp)` - Returns next midnight UTC
  - Calculates epoch boundaries
- `weekStart(timestamp)` - Returns Tuesday 00:00 UTC
  - Used by Voter for weekly epochs
