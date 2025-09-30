# River Fi Mock Protocol Testing Flow

## 🧪 Manual Testing Guide

This guide walks through testing the River Fi MVP with mock Tapp Exchange and Hyperion protocols.

### Prerequisites
```bash
# Ensure you're in the project directory
cd riverfi-contract-aptos

# Compile contracts
aptos move compile --dev
```

## 📋 Test Sequence

### 1. Deploy Contracts
```bash
# Deploy all contracts (vault auto-initializes with mock protocols)
aptos move publish --dev
```

### 2. Check Initial State
```bash
# Check vault stats (should be all zeros initially)
aptos move view --dev --function-id default::vault::get_vault_stats

# Check allocation config (should be 50% Tapp, 30% Hyperion, 20% Reserve)
aptos move view --dev --function-id default::vault::get_allocation_config

# Check APR rates
aptos move view --dev --function-id default::tapp_exchange::get_apr
aptos move view --dev --function-id default::hyperion::get_apr
```

### 3. Test Direct Protocol Deposits (Optional)
```bash
# Test Tapp Exchange directly
aptos move run --dev --function-id default::tapp_exchange::deposit --args u64:100000  # 0.1 USDC

# Check Tapp position
aptos move view --dev --function-id default::tapp_exchange::get_position --args address:0xFACE

# Test Hyperion directly  
aptos move run --dev --function-id default::hyperion::provide_liquidity --args u64:100000  # 0.1 USDC

# Check Hyperion position
aptos move view --dev --function-id default::hyperion::get_position --args address:0xFACE
```

### 4. Test Vault Integration
```bash
# Make initial deposit through vault (should auto-allocate across protocols)
aptos move run --dev --function-id default::vault::deposit --args u64:1000000  # 1.0 USDC

# Check user's RUSDC balance (should be 1.0 RUSDC)
aptos move view --dev --function-id default::vault::get_user_balance --args address:0xFACE

# Check vault NAV (should be close to 1.0 USDC equivalent)
aptos move view --dev --function-id default::vault::get_vault_nav

# Check protocol positions
aptos move view --dev --function-id default::vault::get_protocol_positions
```

### 5. Simulate Time Passage & Yield Generation
```bash
# Wait or simulate time passage (protocols accrue yield based on block timestamp)
# In real testing, you would wait or use blockchain time manipulation

# Manually trigger yield harvesting
aptos move run --dev --function-id default::vault::harvest_yield

# Check updated NAV (should be higher due to mock yield)
aptos move view --dev --function-id default::vault::get_vault_nav

# Check individual protocol values
aptos move view --dev --function-id default::tapp_exchange::get_tvl
aptos move view --dev --function-id default::hyperion::get_tvl
```

### 6. Test Compound Yield
```bash
# Manually trigger compound yield in protocols
aptos move run --dev --function-id default::tapp_exchange::compound_yield
aptos move run --dev --function-id default::hyperion::compound_rewards

# Check updated values
aptos move view --dev --function-id default::vault::get_vault_nav
```

### 7. Test Withdrawal
```bash
# Check current RUSDC balance
aptos move view --dev --function-id default::vault::get_user_balance --args address:0xFACE

# Withdraw all RUSDC (amount should include yield if any time has passed)
aptos move run --dev --function-id default::vault::withdraw --args u64:1000000  # Withdraw 1.0 RUSDC

# Check final balances (user should receive original + any accumulated yield)
aptos move view --dev --function-id default::vault::get_user_balance --args address:0xFACE
```

### 8. Test Admin Functions
```bash
# Test APR updates (admin only)
aptos move run --dev --function-id default::tapp_exchange::admin_set_apr --args u64:900  # Set to 9%
aptos move run --dev --function-id default::hyperion::admin_set_apr --args u64:950      # Set to 9.5%

# Test allocation changes (admin only)
aptos move run --dev --function-id default::vault::admin_set_allocation --args u8:60 u8:30 u8:10  # 60/30/10

# Verify changes
aptos move view --dev --function-id default::tapp_exchange::get_apr
aptos move view --dev --function-id default::hyperion::get_apr  
aptos move view --dev --function-id default::vault::get_allocation_config
```

## 📊 Expected Results

### **Initial State**
- Vault stats: (0, 0, 0, 0)
- Allocation: (50, 30, 20)
- APR rates: Tapp=800bps, Hyperion=900bps

### **After 1.0 USDC Deposit**
- User RUSDC balance: ~1,000,000 (1.0 RUSDC)
- Vault NAV: ~1,000,000 (1.0 USDC equivalent)
- Protocol positions: Tapp~500,000 shares, Hyperion~300,000 LP tokens, Reserve~200,000 USDC

### **After Time/Harvest**
- Vault NAV: >1,000,000 (increased due to yield)
- Exchange rate: >1.0 (RUSDC worth more than 1 USDC)
- Protocol TVL: Increased due to accumulated rewards

### **After Withdrawal**
- User receives: Original deposit + accumulated yield
- Final RUSDC balance: 0

## 🚨 Troubleshooting

### **Common Issues**

1. **"Insufficient balance" errors**
   - Ensure test account has enough USDC
   - Check if contracts are properly initialized

2. **"Permission denied" errors**  
   - Use correct admin account for admin functions
   - Check account addresses match deployment

3. **"Zero amount" errors**
   - Ensure amounts are above minimum thresholds
   - Check proper decimal places (USDC uses 6 decimals)

### **Debug Commands**
```bash
# Check contract addresses
aptos account list --account default

# Check USDC balance
aptos move view --dev --function-id 0x1::coin::balance --args address:0xFACE --type-args 0x69091fbab5f7d635ee7ac5098cf0c1efbe31d68fec0f2cd565e8d168daf52832::FakeCoin::FakeCoin

# View all resources on account
aptos account show --account default
```

## 🎯 Success Criteria

✅ **Compilation**: All contracts compile without errors
✅ **Deployment**: Contracts deploy and initialize successfully  
✅ **Allocation**: Deposits are properly allocated across protocols
✅ **Yield Generation**: Mock protocols generate simulated yield
✅ **Harvesting**: Vault NAV increases with yield harvesting
✅ **Exchange Rate**: RUSDC value grows over time
✅ **Withdrawals**: Users receive principal + yield on withdrawal
✅ **Admin Controls**: APR and allocation updates work correctly

## 📈 Expected Yield Calculation

For 1.0 USDC deposited with default allocation:
- **Tapp Exchange (50%)**: 0.5 USDC at 8% APR = ~0.0011 USDC per day
- **Hyperion (30%)**: 0.3 USDC at 9% APR + bonuses = ~0.0007+ USDC per day  
- **Total Daily Yield**: ~0.0018+ USDC per day (~0.66% APY combined)

*Note: Actual yields depend on compound frequency and bonus reward randomization in Hyperion.*