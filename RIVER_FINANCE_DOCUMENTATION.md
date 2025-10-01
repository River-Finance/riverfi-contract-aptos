# River Finance Protocol - Complete Developer Documentation

## Table of Contents
1. [Smart Contract Developer Guide](#smart-contract-developer-guide)
2. [Frontend Integration Guide](#frontend-integration-guide)
3. [User Guide](#user-guide)
4. [API Reference](#api-reference)
5. [Error Codes](#error-codes)
6. [Testing Examples](#testing-examples)

---

# Smart Contract Developer Guide

## Overview
River Finance is a yield-generating vault protocol on Aptos that:
- Accepts USDC deposits and mints 1:1 RUSD tokens
- Deploys funds to yield-generating protocols (Tapp Exchange, Hyperion)
- Distributes yield proportionally to all RUSD holders
- Maintains a fixed 1:1 USDC:RUSD exchange rate

## Contract Address
**Testnet**: `0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0`

## Core Architecture

### Data Structures

```move
// Main vault configuration
struct Config has key {
    enable_deposit: bool,
    enable_withdraw: bool,
}

// Protocol allocation settings
struct AllocationConfig has key {
    tapp_percent: u8,        // % allocated to Tapp Exchange
    hyperion_percent: u8,    // % allocated to Hyperion
    reserve_percent: u8,     // % kept as reserve (unused)
    last_rebalance_ts: u64,
}

// Yield distribution system
struct YieldPool has key {
    total_claimable_yield: u64,           // For manual claim mode
    total_rusd_earning: u64,              // Total RUSD earning yield
    annual_apy_bps: u64,                  // APY in basis points (1000 = 10%)
    last_yield_accrual_ts: u64,           // Last daily accrual timestamp
    user_last_claim_ts: Table<address, u64>, // User claim timestamps
    auto_distribute_yield: bool,          // Auto vs manual distribution
    total_yield_distributed: u64,        // Total auto-distributed
    last_distribution_time: u64,          // Last distribution timestamp
    yield_per_token_accumulated: u64,     // Accumulated yield per token (scaled 1e12)
    user_yield_debt: Table<address, u64>, // User yield debt tracking
}

// RUSD token references
struct RUSDToken has key {
    token: Object<Metadata>,
    mint_ref: MintRef,
    transfer_ref: TransferRef,
    burn_ref: BurnRef,
    extend_ref: ExtendRef
}

// Main vault state
struct Vault has key {
    extend_ref: ExtendRef,
    total_usdc: u64,                      // Total USDC deposited
    total_rusd_supply: u64,               // Total RUSD minted
    tapp_shares: u128,                    // Shares in Tapp Exchange
    hyperion_lp_tokens: u128,             // LP tokens in Hyperion
    exchange_rate: u128,                  // Always 1:1 (fixed)
    last_harvest_ts: u64,
    // Legacy fields (unused but kept for compatibility)
    hyperion_usdc: u64,
    hyperion_positions: vector<Object<Info>>,
    reserve_usdc: u64,
}
```

### Constants

```move
const RUSD_TOKEN_DECIMALS: u8 = 6;               // 6 decimals like USDC
const FIXED_EXCHANGE_RATE: u128 = 1000000000000; // 1.0 with precision
const DEFAULT_ANNUAL_APY_BPS: u64 = 1000;       // 10% APY
const SECONDS_PER_DAY: u64 = 86400;
const DAYS_PER_YEAR: u64 = 365;

// Error codes
const E_ALREADY_INITIALIZED: u64 = 1;
const E_INSUFFICIENT_BALANCE: u64 = 2;
const E_INSUFFICIENT_VAULT_BALANCE: u64 = 3;
const E_ZERO_AMOUNT: u64 = 4;
```

## Key Design Decisions

### 1. **Fixed 1:1 Exchange Rate**
- RUSD always equals USDC 1:1
- No price fluctuation or slippage
- Yield is distributed as additional tokens, not price appreciation

### 2. **Automatic Yield Distribution**
- Uses reward pool mechanism for gas efficiency
- Yield accumulates per token and is claimed on user interactions
- No need to update all user balances simultaneously

### 3. **Protocol Integration**
- Funds are allocated between Tapp Exchange (30%) and Hyperion (70%)
- Reserve allocation is 0% (legacy feature)
- Positions are automatically unwound for withdrawals

---

# Frontend Integration Guide

## Setup and Connection

### 1. **Wallet Connection**
```javascript
// Example using Aptos TypeScript SDK
import { Aptos, AptosConfig, Network } from "@aptos-labs/ts-sdk";

const config = new AptosConfig({ network: Network.TESTNET });
const aptos = new Aptos(config);

const RIVER_FINANCE_ADDRESS = "0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0";
```

### 2. **Contract Function Calls**

#### **User Functions**

##### **Deposit USDC → Get RUSD**
```javascript
async function deposit(userAccount, usdcAmount) {
    const transaction = {
        type: "entry_function_payload",
        function: `${RIVER_FINANCE_ADDRESS}::vault::deposit`,
        arguments: [usdcAmount.toString()], // u64 as string
        type_arguments: []
    };
    
    return await aptos.signAndSubmitTransaction({ 
        signer: userAccount, 
        transaction 
    });
}

// Example: Deposit 100 USDC (100000000 units due to 6 decimals)
await deposit(userAccount, "100000000");
```

##### **Withdraw RUSD → Get USDC**
```javascript
async function withdraw(userAccount, rusdAmount) {
    const transaction = {
        type: "entry_function_payload",
        function: `${RIVER_FINANCE_ADDRESS}::vault::withdraw`,
        arguments: [rusdAmount.toString()], // u64 as string
        type_arguments: []
    };
    
    return await aptos.signAndSubmitTransaction({ 
        signer: userAccount, 
        transaction 
    });
}

// Example: Withdraw 50 RUSD (50000000 units)
await withdraw(userAccount, "50000000");
```

##### **Transfer RUSD to Another User**
```javascript
async function transfer(userAccount, recipientAddress, amount) {
    const transaction = {
        type: "entry_function_payload",
        function: `${RIVER_FINANCE_ADDRESS}::vault::transfer`,
        arguments: [
            recipientAddress,
            amount.toString()
        ],
        type_arguments: []
    };
    
    return await aptos.signAndSubmitTransaction({ 
        signer: userAccount, 
        transaction 
    });
}
```

##### **Claim Yield Rewards**
```javascript
async function claimRewards(userAccount) {
    const transaction = {
        type: "entry_function_payload",
        function: `${RIVER_FINANCE_ADDRESS}::vault::claim_rewards`,
        arguments: [],
        type_arguments: []
    };
    
    return await aptos.signAndSubmitTransaction({ 
        signer: userAccount, 
        transaction 
    });
}
```

##### **Claim Daily Yield (Manual Mode Only)**
```javascript
async function claimDailyYield(userAccount) {
    const transaction = {
        type: "entry_function_payload",
        function: `${RIVER_FINANCE_ADDRESS}::vault::claim_daily_yield`,
        arguments: [],
        type_arguments: []
    };
    
    return await aptos.signAndSubmitTransaction({ 
        signer: userAccount, 
        transaction 
    });
}
```

#### **Admin Functions**

##### **Add Yield to System**
```javascript
async function adminIncreaseYield(adminAccount, usdcAmount) {
    const transaction = {
        type: "entry_function_payload",
        function: `${RIVER_FINANCE_ADDRESS}::vault::admin_increase_yield`,
        arguments: [usdcAmount.toString()],
        type_arguments: []
    };
    
    return await aptos.signAndSubmitTransaction({ 
        signer: adminAccount, 
        transaction 
    });
}
```

##### **Set Annual APY**
```javascript
async function setAnnualAPY(adminAccount, apyBasisPoints) {
    const transaction = {
        type: "entry_function_payload",
        function: `${RIVER_FINANCE_ADDRESS}::vault::admin_set_annual_apy`,
        arguments: [apyBasisPoints.toString()], // 1000 = 10% APY
        type_arguments: []
    };
    
    return await aptos.signAndSubmitTransaction({ 
        signer: adminAccount, 
        transaction 
    });
}
```

##### **Toggle Auto Yield Distribution**
```javascript
async function setAutoYield(adminAccount, autoDistribute) {
    const transaction = {
        type: "entry_function_payload",
        function: `${RIVER_FINANCE_ADDRESS}::vault::admin_set_auto_yield`,
        arguments: [autoDistribute], // boolean
        type_arguments: []
    };
    
    return await aptos.signAndSubmitTransaction({ 
        signer: adminAccount, 
        transaction 
    });
}
```

### 3. **View Functions (Read-Only)**

#### **Get User Information**
```javascript
// Get user's RUSD balance
async function getUserBalance(userAddress) {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_user_balance`,
        arguments: [userAddress]
    });
    return result[0]; // Returns balance as string
}

// Get user's complete position
async function getUserPosition(userAddress) {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_user_position`,
        arguments: [userAddress]
    });
    return {
        rusdBalance: result[0],    // RUSD tokens owned
        usdcValue: result[1],      // Current USDC value (1:1)
        claimableYield: result[2], // Claimable yield amount
        exchangeRate: result[3]    // Fixed exchange rate
    };
}

// Get user's pending yield rewards
async function getPendingYieldRewards(userAddress) {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_pending_yield_rewards`,
        arguments: [userAddress]
    });
    return result[0];
}

// Get user's pending claimable yield (works for both modes)
async function getPendingYield(userAddress) {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_pending_yield`,
        arguments: [userAddress]
    });
    return result[0];
}
```

#### **Get Vault Information**
```javascript
// Get overall vault statistics
async function getVaultStats() {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_vault_stats`,
        arguments: []
    });
    return {
        totalUsdc: result[0],      // Total USDC deposited
        totalRusdSupply: result[1], // Total RUSD in circulation
        hyperionUsdc: result[2],   // Legacy field (unused)
        reserveUsdc: result[3]     // Legacy field (unused)
    };
}

// Get vault Net Asset Value
async function getVaultNAV() {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_vault_nav`,
        arguments: []
    });
    return {
        totalNav: result[0],       // Total Net Asset Value
        exchangeRate: result[1]    // Current exchange rate (always 1:1)
    };
}

// Get protocol positions
async function getProtocolPositions() {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_protocol_positions`,
        arguments: []
    });
    return {
        tappShares: result[0],     // Shares in Tapp Exchange
        hyperionLpTokens: result[1], // LP tokens in Hyperion
        reserveUsdc: result[2]     // Reserve USDC (unused)
    };
}

// Get allocation configuration
async function getAllocationConfig() {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_allocation_config`,
        arguments: []
    });
    return {
        tappPercent: result[0],     // % to Tapp Exchange (30)
        hyperionPercent: result[1], // % to Hyperion (70)
        reservePercent: result[2]   // % to Reserve (0)
    };
}

// Get yield pool statistics
async function getYieldPoolStats() {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::get_yield_pool_stats`,
        arguments: []
    });
    return {
        totalClaimableYield: result[0],  // Total claimable (manual mode)
        totalRusdEarning: result[1],     // Total RUSD earning yield
        annualApyBps: result[2],         // Annual APY in basis points
        lastYieldAccrualTs: result[3],   // Last accrual timestamp
        autoDistributeYield: result[4]   // Auto-distribution enabled
    };
}

// Get projected APY from protocols
async function getProjectedAPY() {
    const result = await aptos.view({
        function: `${RIVER_FINANCE_ADDRESS}::vault::projected_apy`,
        arguments: []
    });
    return {
        tappApr: result[0],        // Tapp Exchange APR
        hyperionApr: result[1]     // Hyperion APR
    };
}
```

### 4. **Helper Functions for Frontend**

#### **Decimal Conversion**
```javascript
// Convert human-readable amount to contract units (6 decimals)
function toContractUnits(amount) {
    return (parseFloat(amount) * 1000000).toString();
}

// Convert contract units to human-readable amount
function fromContractUnits(units) {
    return (parseInt(units) / 1000000).toFixed(6);
}

// Examples:
// toContractUnits("100.5") → "100500000"
// fromContractUnits("100500000") → "100.500000"
```

#### **Event Listening**
```javascript
// Listen for deposit events
async function listenForDeposits() {
    // Filter for DepositedEvent
    const events = await aptos.getAccountEvents({
        accountAddress: RIVER_FINANCE_ADDRESS,
        eventType: `${RIVER_FINANCE_ADDRESS}::vault::DepositedEvent`
    });
    
    events.forEach(event => {
        console.log('Deposit:', {
            user: event.data.user,
            usdcAmount: fromContractUnits(event.data.usdc_amount),
            rusdAmount: fromContractUnits(event.data.rusd_amount),
            timestamp: event.data.timestamp
        });
    });
}

// Other events to listen for:
// - WithdrawnEvent
// - YieldClaimedEvent
// - YieldDistributedEvent
// - ManualYieldAddedEvent
// - TransferEvent
```

### 5. **Error Handling**
```javascript
async function handleTransaction(transactionFunction) {
    try {
        const result = await transactionFunction();
        return { success: true, result };
    } catch (error) {
        console.error('Transaction failed:', error);
        
        // Parse common errors
        if (error.message.includes('E_INSUFFICIENT_BALANCE')) {
            return { success: false, error: 'Insufficient balance' };
        } else if (error.message.includes('E_ZERO_AMOUNT')) {
            return { success: false, error: 'Amount must be greater than zero' };
        } else if (error.message.includes('E_INSUFFICIENT_VAULT_BALANCE')) {
            return { success: false, error: 'Insufficient vault liquidity' };
        }
        
        return { success: false, error: 'Transaction failed' };
    }
}
```

---

# User Guide

## What is River Finance?

River Finance is a yield-generating vault that:
- **Accepts your USDC** and gives you RUSD tokens (1:1 ratio)
- **Generates yield** by investing in DeFi protocols
- **Distributes rewards** proportionally to all RUSD holders
- **Maintains stability** with a fixed 1:1 USDC exchange rate

## How to Use

### 1. **Deposit USDC**
- Connect your wallet to the River Finance app
- Enter the USDC amount you want to deposit
- Confirm the transaction
- Receive RUSD tokens 1:1 (100 USDC = 100 RUSD)

### 2. **Earn Yield**
- Your RUSD automatically starts earning yield
- Yield comes from Tapp Exchange and Hyperion protocols
- Current APY is displayed in the app
- Yield is distributed proportionally to all RUSD holders

### 3. **Claim Rewards**
- **Automatic Mode (Default)**: Rewards accumulate and are claimed when you interact
- **Manual Mode**: You must manually claim daily rewards
- Check your pending rewards in the app
- Click "Claim Rewards" to add them to your balance

### 4. **Withdraw USDC**
- Enter the RUSD amount you want to withdraw
- Confirm the transaction
- Receive USDC 1:1 (100 RUSD = 100 USDC)
- Any pending rewards are automatically claimed before withdrawal

### 5. **Transfer RUSD**
- Send RUSD to other users like any token
- Pending rewards are automatically claimed before transfer
- Recipient starts earning yield immediately

## Important Notes

### **Decimal System**
- RUSD uses 6 decimals (like USDC)
- 1 RUSD = 1,000,000 units in the contract
- Always check your amounts carefully

### **Yield Distribution**
- Yield is distributed proportionally based on your RUSD balance
- If you own 10% of total RUSD, you get 10% of the yield
- Rewards accumulate continuously and are claimed when you interact

### **No Price Risk**
- RUSD always equals USDC 1:1
- Your principal is protected
- Yield comes as additional tokens, not price appreciation

---

# API Reference

## Entry Functions (Write Operations)

| Function | Parameters | Description | Access |
|----------|------------|-------------|---------|
| `deposit` | `amount: u64` | Deposit USDC, get RUSD | User |
| `withdraw` | `rusd_amount: u64` | Burn RUSD, get USDC | User |
| `transfer` | `to: address, amount: u64` | Transfer RUSD to another user | User |
| `claim_rewards` | None | Claim accumulated yield rewards | User |
| `claim_daily_yield` | None | Claim daily yield (manual mode only) | User |
| `admin_increase_yield` | `usdc_amount: u64` | Add yield to system | Admin |
| `admin_set_annual_apy` | `apy_bps: u64` | Set annual APY rate | Admin |
| `admin_set_auto_yield` | `auto_distribute: bool` | Toggle auto-distribution | Admin |
| `admin_set_allocation` | `tapp_percent: u8, hyperion_percent: u8, reserve_percent: u8` | Set protocol allocation | Admin |

## View Functions (Read Operations)

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `get_user_balance` | `user: address` | `u64` | User's RUSD balance |
| `get_user_position` | `user: address` | `(u64, u64, u64, u128)` | RUSD balance, USDC value, claimable yield, exchange rate |
| `get_pending_yield` | `user: address` | `u64` | User's pending claimable yield |
| `get_pending_yield_rewards` | `user: address` | `u64` | User's pending reward (auto mode) |
| `get_vault_stats` | None | `(u64, u64, u64, u64)` | Total USDC, RUSD supply, legacy fields |
| `get_vault_nav` | None | `(u128, u128)` | Total NAV, exchange rate |
| `get_protocol_positions` | None | `(u128, u128, u64)` | Tapp shares, Hyperion LP, reserve |
| `get_allocation_config` | None | `(u8, u8, u8)` | Tapp %, Hyperion %, Reserve % |
| `get_yield_pool_stats` | None | `(u64, u64, u64, u64, bool)` | Claimable, earning, APY, timestamp, auto-mode |
| `projected_apy` | None | `(u64, u64)` | Tapp APR, Hyperion APR |

## Events

| Event | Fields | Description |
|-------|--------|-------------|
| `DepositedEvent` | `user, usdc_amount, rusd_amount, timestamp` | User deposited USDC |
| `WithdrawnEvent` | `user, rusd_amount, usdc_amount, timestamp` | User withdrew to USDC |
| `YieldClaimedEvent` | `user, claimed_amount, timestamp` | User claimed yield |
| `YieldDistributedEvent` | `total_amount, distributed_to_holders, timestamp` | Yield distributed |
| `ManualYieldAddedEvent` | `admin, usdc_amount, rusd_minted, timestamp` | Admin added yield |
| `TransferEvent` | `from, to, amount, timestamp` | RUSD transferred |
| `YieldRateChangedEvent` | `old_rate_bps, new_rate_bps, admin, timestamp` | APY changed |

---

# Error Codes

| Code | Name | Description | Solution |
|------|------|-------------|----------|
| 1 | `E_ALREADY_INITIALIZED` | Contract already initialized or permission denied | Check admin permissions |
| 2 | `E_INSUFFICIENT_BALANCE` | User doesn't have enough tokens | Check balance before transaction |
| 3 | `E_INSUFFICIENT_VAULT_BALANCE` | Vault doesn't have enough liquidity | Wait for liquidity or lower amount |
| 4 | `E_ZERO_AMOUNT` | Amount cannot be zero | Use amount > 0 |

## Common Error Messages

- **"Subtraction overflow"** → Trying to claim more yield than available
- **"Multiplication overflow"** → Using amounts too large, use smaller values
- **"Insufficient balance"** → User doesn't have enough RUSD to withdraw/transfer
- **"Permission denied"** → Only admin can call admin functions

---

# Testing Examples

## Complete Frontend Integration Example

```javascript
class RiverFinanceSDK {
    constructor(aptosClient, contractAddress) {
        this.aptos = aptosClient;
        this.address = contractAddress;
    }
    
    // User deposits USDC and gets RUSD
    async deposit(account, usdcAmount) {
        const amountStr = this.toContractUnits(usdcAmount);
        return await this.submitTransaction(account, 'deposit', [amountStr]);
    }
    
    // User withdraws RUSD and gets USDC
    async withdraw(account, rusdAmount) {
        const amountStr = this.toContractUnits(rusdAmount);
        return await this.submitTransaction(account, 'withdraw', [amountStr]);
    }
    
    // Get user's complete position
    async getUserDashboard(userAddress) {
        const [balance, position, pendingRewards, yieldStats] = await Promise.all([
            this.getUserBalance(userAddress),
            this.getUserPosition(userAddress),
            this.getPendingYieldRewards(userAddress),
            this.getYieldPoolStats()
        ]);
        
        return {
            rusdBalance: this.fromContractUnits(balance),
            usdcValue: this.fromContractUnits(position.usdcValue),
            pendingRewards: this.fromContractUnits(pendingRewards),
            currentAPY: (yieldStats.annualApyBps / 100) + '%',
            autoDistribution: yieldStats.autoDistributeYield
        };
    }
    
    // Helper methods
    async submitTransaction(account, functionName, args = []) {
        const transaction = {
            type: "entry_function_payload",
            function: `${this.address}::vault::${functionName}`,
            arguments: args,
            type_arguments: []
        };
        return await this.aptos.signAndSubmitTransaction({
            signer: account,
            transaction
        });
    }
    
    toContractUnits(amount) {
        return (parseFloat(amount) * 1000000).toString();
    }
    
    fromContractUnits(units) {
        return (parseInt(units) / 1000000).toString();
    }
}

// Usage example
const sdk = new RiverFinanceSDK(aptos, RIVER_FINANCE_ADDRESS);

// User deposits 100 USDC
await sdk.deposit(userAccount, "100");

// Check user dashboard
const dashboard = await sdk.getUserDashboard(userAddress);
console.log(dashboard);
// Output: {
//   rusdBalance: "100.000000",
//   usdcValue: "100.000000", 
//   pendingRewards: "0.000000",
//   currentAPY: "10%",
//   autoDistribution: true
// }
```

## CLI Testing Commands

```bash
# Contract address
CONTRACT="0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0"

# User deposits 10 USDC (10000000 units)
aptos move run --function-id "$CONTRACT::vault::deposit" --args u64:10000000 --profile testnet

# Check user balance
aptos move view --function-id "$CONTRACT::vault::get_user_balance" --args address:YOUR_ADDRESS

# Admin adds 5 USDC worth of yield
aptos move run --function-id "$CONTRACT::vault::admin_increase_yield" --args u64:5000000 --profile admin

# User claims rewards
aptos move run --function-id "$CONTRACT::vault::claim_rewards" --profile testnet

# User withdraws 5 RUSD
aptos move run --function-id "$CONTRACT::vault::withdraw" --args u64:5000000 --profile testnet
```

---

## Support and Troubleshooting

### Common Issues
1. **Transaction fails with "insufficient balance"** → Check USDC balance for deposits, RUSD balance for withdrawals
2. **"No claimable yield"** → Either no yield generated yet, or auto-distribution is enabled
3. **Large numbers causing overflow** → Use appropriate decimal conversion, avoid extremely large amounts
4. **Wrong decimal places** → Remember RUSD uses 6 decimals (1 RUSD = 1,000,000 units)

### Best Practices
- Always validate user inputs and convert to proper decimal format
- Check user balances before transactions
- Handle errors gracefully with user-friendly messages
- Listen to events for real-time updates
- Use view functions to update UI state
- Test with small amounts first
