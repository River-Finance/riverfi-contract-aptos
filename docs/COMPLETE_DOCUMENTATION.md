# 🌊 River Fi - Complete Developer & User Documentation

## 📋 **Table of Contents**
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Smart Contracts](#smart-contracts)
4. [Setup & Installation](#setup--installation)
5. [Testing Guide](#testing-guide)
6. [User Flow](#user-flow)
7. [Developer API](#developer-api)
8. [Deployment](#deployment)
9. [Admin Functions](#admin-functions)
10. [Troubleshooting](#troubleshooting)

---

## 📖 **Overview**

River Fi is a **DeFi yield aggregator** built on Aptos that automatically allocates user deposits across multiple yield-generating protocols to maximize returns while maintaining liquidity.

### **Key Features**
- 🏦 **Mock USDC Token** - Complete testing environment
- 💰 **Automatic Yield Generation** - Up to 10% APR with daily compounding
- 🔄 **Auto-Allocation** - 50% Tapp Exchange, 30% Hyperion, 20% Reserve
- 📈 **RUSDC Token** - Appreciating yield-bearing token
- ⚡ **Instant Withdrawals** - Reserve pool + protocol unwinding
- 🛡️ **Admin Controls** - APR management and emergency controls

---

## 🏗️ **Architecture**

```
┌─────────────┐    ┌──────────────┐    ┌─────────────┐
│  Mock USDC  │───▶│  River Fi    │───▶│   RUSDC     │
│   (mUSDC)   │    │    Vault     │    │  (Yield)    │
└─────────────┘    └──────┬───────┘    └─────────────┘
                          │
              ┌───────────┼────────────┐
              ▼           ▼            ▼
    ┌─────────────┐ ┌─────────┐ ┌─────────────┐
    │ Tapp Exchange│ │Hyperion │ │  Reserve    │
    │  (8% APR)   │ │(9% APR) │ │ (Liquidity) │
    └─────────────┘ └─────────┘ └─────────────┘
```

### **Smart Contract Modules**

| Module | Purpose | Key Features |
|--------|---------|--------------|
| `mock_usdc.move` | Mock USDC token | Faucet, minting, testing |
| `yield_math.move` | Mathematical utilities | Compound interest, precision |
| `tapp_exchange.move` | Mock DEX protocol | 8% APR + 0.1% trading fees |
| `hyperion.move` | Mock liquidity protocol | 9% APR + 0.3% LP fees + bonuses |
| `vault.move` | Main River Fi vault | Auto-allocation, RUSDC minting |
| `storage.move` | Storage utilities | Object management |

---

## 💻 **Setup & Installation**

### **Prerequisites**
```bash
# Install Aptos CLI
curl -fsSL "https://aptos.dev/scripts/install_cli.py" | python3

# Verify installation
aptos --version
```

### **Project Setup**
```bash
# Clone and navigate to project
cd riverfi-contract-aptos

# Compile contracts
aptos move compile --dev

# Initialize Aptos account (if needed)
aptos init --network devnet
```

### **Environment Setup**
```bash
# Set up development addresses in Move.toml
[dev-addresses]
riverfi = "0xFACE"
deployer = "0xBB"  
dex_contract = "0xAA"
```

---

## 🧪 **Testing Guide**

### **Complete Test Sequence**

#### **Step 1: Deploy Contracts**
```bash
# Deploy all contracts
aptos move publish --dev
# This automatically initializes:
# - Mock USDC with 1M initial supply
# - River Fi vault with default allocation
# - Tapp Exchange (8% APR)
# - Hyperion (9% APR)
```

#### **Step 2: Get Mock USDC**
```bash
# Anyone can get 1000 USDC from faucet
aptos move run --dev --function-id default::mock_usdc::faucet

# Check your balance
aptos move view --dev --function-id default::mock_usdc::get_balance --args address:0xFACE
# Should return: 1000000000 (1000 USDC with 6 decimals)
```

#### **Step 3: Initial State Verification**
```bash
# Check vault allocation
aptos move view --dev --function-id default::vault::get_allocation_config
# Returns: (50, 30, 20) = 50% Tapp, 30% Hyperion, 20% Reserve

# Check protocol APRs
aptos move view --dev --function-id default::tapp_exchange::get_apr      # 800 (8%)
aptos move view --dev --function-id default::hyperion::get_apr           # 900 (9%)

# Check vault stats (should be empty)
aptos move view --dev --function-id default::vault::get_vault_stats      # (0,0,0,0)
```

#### **Step 4: Make First Deposit**
```bash
# Deposit 100 USDC into River Fi vault
aptos move run --dev --function-id default::vault::deposit --args u64:100000000

# Check RUSDC balance
aptos move view --dev --function-id default::vault::get_user_balance --args address:0xFACE
# Returns: 100000000 (100 RUSDC)

# Check detailed position
aptos move view --dev --function-id default::vault::get_user_position --args address:0xFACE
# Returns: (100000000, 100000000, 0, 1000000000000)
# Meaning: 100 RUSDC, worth 100 USDC, 0 yield, 1.0 exchange rate
```

#### **Step 5: Verify Auto-Allocation**
```bash
# Check protocol positions
aptos move view --dev --function-id default::vault::get_protocol_positions
# Should show: (~50M shares, ~30M LP tokens, ~20M reserve)

# Check vault NAV
aptos move view --dev --function-id default::vault::get_vault_nav
# Returns: (~100000000, 1000000000000) = 100 USDC NAV, 1.0 exchange rate
```

#### **Step 6: Simulate Yield Generation**
```bash
# Option A: Wait for real time to pass, then harvest
aptos move run --dev --function-id default::vault::harvest_yield

# Option B: Manually compound protocols (simulates time passage)
aptos move run --dev --function-id default::tapp_exchange::compound_yield
aptos move run --dev --function-id default::hyperion::compound_rewards

# Then harvest to update vault exchange rate
aptos move run --dev --function-id default::vault::harvest_yield
```

#### **Step 7: Check Yield Accumulation**
```bash
# Check updated position
aptos move view --dev --function-id default::vault::get_user_position --args address:0xFACE
# Should show: (100000000, >100000000, >0, >1000000000000)
# Meaning: Same RUSDC amount, but higher value and yield > 0

# Check protocol TVLs (should be higher than initial deposits)
aptos move view --dev --function-id default::tapp_exchange::get_tvl
aptos move view --dev --function-id default::hyperion::get_tvl
```

#### **Step 8: Test Withdrawal with Yield**
```bash
# Withdraw 50 RUSDC (should get more than 50 USDC due to yield)
aptos move run --dev --function-id default::vault::withdraw --args u64:50000000

# Check Mock USDC balance (should be > original 1000 USDC)
aptos move view --dev --function-id default::mock_usdc::get_balance --args address:0xFACE

# Check remaining RUSDC position
aptos move view --dev --function-id default::vault::get_user_position --args address:0xFACE
```

### **Expected Results**

| Test Stage | Expected Outcome |
|------------|------------------|
| After Faucet | 1000 mUSDC balance |
| After 100 USDC Deposit | 100 RUSDC, 1.0 exchange rate |
| After Allocation | 50M Tapp shares, 30M Hyperion LP, 20M reserve |
| After Yield Accrual | Exchange rate > 1.0, yield > 0 |
| After 50 RUSDC Withdrawal | Receive >50 USDC, remaining 50 RUSDC |

---

## 👤 **User Flow**

### **1. Getting Started**
```bash
# Step 1: Get test tokens
aptos move run --dev --function-id default::mock_usdc::faucet
```

### **2. Making a Deposit**
```bash
# Step 2: Deposit USDC to earn yield
aptos move run --dev --function-id default::vault::deposit --args u64:AMOUNT

# Check your RUSDC
aptos move view --dev --function-id default::vault::get_user_position --args address:YOUR_ADDRESS
```

### **3. Monitoring Yields**
```bash
# Check current position anytime
aptos move view --dev --function-id default::vault::get_user_position --args address:YOUR_ADDRESS
# Returns: (RUSDC balance, Current USDC value, Yield earned, Exchange rate)

# Manually trigger yield update
aptos move run --dev --function-id default::vault::harvest_yield
```

### **4. Withdrawing with Yield**
```bash
# Withdraw any amount of RUSDC
aptos move run --dev --function-id default::vault::withdraw --args u64:RUSDC_AMOUNT

# Check your Mock USDC balance
aptos move view --dev --function-id default::mock_usdc::get_balance --args address:YOUR_ADDRESS
```

---

## 🔧 **Developer API**

### **Mock USDC Functions**
```move
// Get test tokens (1000 USDC)
public entry fun faucet(recipient: &signer)

// Check balance
#[view] public fun get_balance(account: address): u64

// Admin mint
public entry fun admin_mint(admin: &signer, recipient: address, amount: u64)
```

### **Vault Functions**
```move
// Core user functions
public entry fun deposit(sender: &signer, amount: u64)
public entry fun withdraw(sender: &signer, rusdc_amount: u64)

// View functions
#[view] public fun get_user_balance(user: address): u64
#[view] public fun get_user_position(user: address): (u64, u64, u64, u128)
#[view] public fun get_vault_nav(): (u128, u128)
#[view] public fun get_allocation_config(): (u8, u8, u8)

// Yield management
public entry fun harvest_yield()
```

### **Protocol Functions**
```move
// Tapp Exchange
public entry fun deposit(account: &signer, amount: u64)
public entry fun compound_yield()
#[view] public fun get_apr(): u64
#[view] public fun get_tvl(): u128

// Hyperion
public entry fun provide_liquidity(account: &signer, amount: u64)
public entry fun compound_rewards()
#[view] public fun get_apr(): u64
#[view] public fun get_tvl(): u128
```

---

## 🚀 **Deployment**

### **Development Deployment**
```bash
# Deploy to devnet
aptos move publish --dev

# Verify deployment
aptos account list --account default
```

### **Production Checklist**
- [ ] Update addresses in Move.toml
- [ ] Set proper admin addresses
- [ ] Configure real token addresses (if applicable)
- [ ] Test all functions on testnet first
- [ ] Verify contract verification
- [ ] Set up monitoring and alerting

### **Post-Deployment Setup**
```bash
# Initialize protocols with desired APRs
aptos move run --function-id ADDR::tapp_exchange::admin_set_apr --args u64:800
aptos move run --function-id ADDR::hyperion::admin_set_apr --args u64:900

# Set vault allocation strategy
aptos move run --function-id ADDR::vault::admin_set_allocation --args u8:50 u8:30 u8:20
```

---

## 👨‍💼 **Admin Functions**

### **APR Management**
```bash
# Adjust Tapp Exchange APR (max 1000 = 10%)
aptos move run --dev --function-id default::tapp_exchange::admin_set_apr --args u64:850

# Adjust Hyperion APR
aptos move run --dev --function-id default::hyperion::admin_set_apr --args u64:950
```

### **Allocation Management**
```bash
# Change vault allocation (must sum to 100)
aptos move run --dev --function-id default::vault::admin_set_allocation --args u8:60 u8:25 u8:15
# 60% Tapp, 25% Hyperion, 15% Reserve
```

### **Emergency Controls**
```bash
# Pause Tapp Exchange
aptos move run --dev --function-id default::tapp_exchange::admin_set_pause --args bool:true

# Pause Hyperion
aptos move run --dev --function-id default::hyperion::admin_set_pause --args bool:true
```

### **Token Management**
```bash
# Mint additional Mock USDC (admin only)
aptos move run --dev --function-id default::mock_usdc::admin_mint --args address:0xRECIPIENT u64:1000000000
```

---

## 🎯 **Key Concepts**

### **Exchange Rate Mechanism**
- **Same rate for all users**: 1 RUSDC starts at 1.0 USDC
- **Appreciates over time**: As yield is earned, 1 RUSDC = 1.05 USDC, etc.
- **Automatic compounding**: No need to claim rewards

### **Yield Sources**
1. **Tapp Exchange**: 8% base APR + 0.1% simulated trading fees
2. **Hyperion**: 9% base APR + 0.3% LP fees + variable bonuses (0.01-0.05%)
3. **Combined**: ~8.5-9% effective APR with auto-compounding

### **Liquidity Management**
- **Reserve Pool**: 20% kept for instant withdrawals
- **Protocol Unwinding**: Larger withdrawals automatically liquidate positions
- **Proportional Exit**: Withdrawals maintain allocation ratios

---

## 🐛 **Troubleshooting**

### **Common Issues**

#### **Compilation Errors**
```bash
# Issue: Address not found
# Solution: Ensure dev-addresses are set in Move.toml

# Issue: Missing dependencies
# Solution: Run `aptos move clean` then `aptos move compile --dev`
```

#### **Transaction Failures**
```bash
# Issue: Insufficient balance
# Solution: Use faucet to get more Mock USDC
aptos move run --dev --function-id default::mock_usdc::faucet

# Issue: Amount too small
# Solution: Ensure amounts are above minimum (1000 for deposits)

# Issue: Permission denied
# Solution: Use correct admin account for admin functions
```

#### **View Function Issues**
```bash
# Issue: Returns (0,0,0,0)
# Solution: Make sure you've made deposits first

# Issue: Exchange rate stuck at 1.0
# Solution: Trigger harvest_yield to update rates
aptos move run --dev --function-id default::vault::harvest_yield
```

### **Debug Commands**
```bash
# Check all balances
aptos move view --dev --function-id default::mock_usdc::get_balance --args address:YOUR_ADDR
aptos move view --dev --function-id default::vault::get_user_balance --args address:YOUR_ADDR

# Check contract state
aptos move view --dev --function-id default::vault::get_vault_stats
aptos move view --dev --function-id default::vault::get_vault_nav

# Check protocol states
aptos move view --dev --function-id default::tapp_exchange::get_tvl
aptos move view --dev --function-id default::hyperion::get_tvl
```

### **Performance Notes**
- **Gas Costs**: Deposits are more expensive due to auto-allocation
- **Time Simulation**: Manual compound calls simulate time passage for testing
- **Precision**: All rates use 1e12 precision for accurate calculations

---

## 📚 **Additional Resources**

### **Contract Addresses (Devnet)**
- Replace with actual deployed addresses after deployment

### **Event Monitoring**
```bash
# Monitor deposit events
aptos account events --account default --field-name DepositedEvent

# Monitor harvest events  
aptos account events --account default --field-name HarvestEvent
```

### **Integration Examples**
```typescript
// Example TypeScript integration
const client = new AptosClient("https://fullnode.devnet.aptoslabs.com");

// Check user position
const position = await client.view({
  function: "ADDR::vault::get_user_position",
  arguments: [userAddress]
});

// Make deposit
const payload = {
  function: "ADDR::vault::deposit",
  arguments: [amount]
};
```

---

## 🔐 **Security Considerations**

### **For MVP/Testing**
- ✅ Mock tokens for safe testing
- ✅ Simplified access controls
- ✅ Error handling and validations
- ⚠️ Not production-ready - needs proper access controls

### **For Production**
- [ ] Comprehensive access control
- [ ] Oracle integration for dynamic rates
- [ ] Slippage protection
- [ ] Emergency pause mechanisms
- [ ] Time-based yield calculations
- [ ] Smart contract audits

---

**🎉 River Fi is now ready for development and testing with complete Mock USDC integration!**

The platform provides a full DeFi yield aggregator experience with automatic allocation, compound yield generation, and transparent returns - perfect for demonstrating advanced DeFi concepts on Aptos! 🌊💰