// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title DeliErrors
library DeliErrors {
    // generic
    error ZeroAddress();
    error ZeroAmount();
    error ZeroWeight();

    // access control
    error NotAdmin();
    error NotHook();
    error NotFeeProcessor();
    error NotSubscriber();
    error NotPoolManager();
    error NotPositionManager();

    // state / config
    error AlreadySettled();
    error AlreadySet();
    error InvalidBps();
    error InvalidOption();
    error InvalidPoolKey();
    error NotAllowed();
    error NoFunds();
    error NoKey();
    error SwapActive();
    error NoSwap();
    error Slippage();
    error NativeEthNotSupported();
    error WbltMissing();
    error ComponentNotDeployed();
    error EpochRunning();
    error InsufficientIncentive();
    
    // pool errors
    error PoolNotInitialized();
    error PoolNotFound();
    error InvalidTickSpacing();
    error InvalidFee();
    error NoLiquidity();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error InvalidPositionParams();
    
    // handler errors
    error HandlerAlreadyExists();
    error HandlerNotFound();
    error PositionNotFound();
    error NotAuthorized();
    
    // arithmetic errors
    error BalanceOverflow();
}
