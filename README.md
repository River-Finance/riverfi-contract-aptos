# River Fi MVP with Mock Protocols

River Fi is a DeFi yield aggregator built on Aptos that allocates user deposits across multiple yield-generating protocols to maximize returns while maintaining liquidity.

## 🚀 Overview

This MVP implementation includes mock versions of Tapp Exchange and Hyperion protocols that simulate real yield generation, allowing River Fi to demonstrate its core functionality:

- **Automatic yield allocation** across multiple protocols
- **Daily compound yield** up to 10% APR
- **Automatic exchange rate updates** that grow RUSDC value
- **Flexible allocation strategies** with admin controls
- **Comprehensive tracking** and analytics

## 📊 Architecture

```
User Deposits USDC
       ↓
   River Fi Vault
       ↓
Allocates across:
├── 50% → Tapp Exchange (8% APR + 0.1% fees)
├── 30% → Hyperion (9% APR + 0.3% fees + bonus rewards)  
└── 20% → Vault Reserve (instant liquidity)
       ↓
   Mints RUSDC 1:1
       ↓
Auto-harvesting grows RUSDC value over time
```

## 🏗️ Smart Contract Modules

### 1. **yield_math.move** - Core Yield Calculations
- Handles compound interest calculations
- Manages precision math for exchange rates
- Provides share calculation utilities

**Key Functions:**
- `apr_to_daily_compound_rate()` - Converts APR to daily rates
- `compound_yield()` - Calculates compound growth over time
- `calculate_shares()` - Determines shares for deposits/withdrawals

### 2. **tapp_exchange.move** - Mock Trading Protocol
- Simulates a DEX with trading fee rewards
- **8% base APR + 0.1% trading fees**
- Automatic yield compounding
- Share-based position tracking

**Key Functions:**
- `deposit()` - Deposit USDC, receive shares
- `withdraw()` - Burn shares, receive USDC + yield
- `compound_yield()` - Auto-compound accumulated rewards
- `admin_set_apr()` - Admin can adjust APR (max 10%)

### 3. **hyperion.move** - Mock Liquidity Protocol  
- Simulates liquidity pool with bonus rewards
- **9% base APR + 0.3% LP fees + variable bonus (0.01-0.05%)**
- Pseudo-random bonus rewards based on timestamp
- LP token-based position tracking

**Key Functions:**
- `provide_liquidity()` - Add liquidity, receive LP tokens
- `remove_liquidity()` - Burn LP tokens, receive USDC + rewards
- `compound_rewards()` - Auto-compound with bonus rewards
- `admin_set_apr()` - Admin can adjust APR (max 10%)

### 4. **vault.move** - Enhanced River Fi Vault
- Manages user deposits and RUSDC minting/burning
- **Automatic allocation** across protocols (50% Tapp, 30% Hyperion, 20% Reserve)
- **Dynamic exchange rate** that grows as yield is earned
- **Auto-harvesting** on deposits to update yields

**Key Functions:**
- `deposit()` - Deposit USDC, auto-allocate, mint RUSDC
- `withdraw()` - Burn RUSDC, withdraw proportional USDC + yield
- `harvest_yield()` - Manually trigger yield compounding and NAV update
- `admin_set_allocation()` - Admin can adjust protocol allocation percentages

## 💰 Yield Generation Features

### **Fixed APR with Daily Compounding**
- Tapp Exchange: 8% APR base + simulated trading fees
- Hyperion: 9% APR base + LP fees + bonus rewards
- Max combined yield: ~10% APR with auto-compounding

### **Exchange Rate Growth**
- RUSDC starts at 1:1 with USDC
- As yield is earned, exchange rate increases
- Users' RUSDC automatically grows in value
- Example: After 30 days at 8% APR, 1000 RUSDC ≈ 1006.5 USDC

### **Auto-Compounding**
- Yields compound daily automatically
- Manual `harvest_yield()` can be called anytime
- All protocols compound independently
- Vault NAV updates reflect total portfolio value

## 📋 User Flow Example

1. **Deposit**: User deposits 1000 USDC
   - 500 USDC → Tapp Exchange (receives shares)
   - 300 USDC → Hyperion (receives LP tokens)  
   - 200 USDC → Vault reserve
   - User receives 1000 RUSDC

2. **Yield Accrual**: Over 30 days
   - Tapp: ~500 * (8%/365) * 30 = ~3.29 USDC yield
   - Hyperion: ~300 * (9%/365) * 30 + bonuses = ~2.22+ USDC yield
   - Total portfolio value: ~1005.5+ USDC

3. **Harvest**: Exchange rate updates
   - Old rate: 1.000 USDC per RUSDC
   - New rate: 1.0055 USDC per RUSDC  
   - User's 1000 RUSDC now worth ~1005.5 USDC

4. **Withdraw**: User burns 1000 RUSDC
   - Receives ~1005.5 USDC (original + yield)
   - Protocols unwind positions proportionally

## 🔧 Admin Controls

### **Protocol Management**
- Set APR rates (capped at 10% for safety)
- Pause/unpause individual protocols
- Emergency controls for all modules

### **Vault Allocation**
```move
// Example: Set new allocation strategy
vault::admin_set_allocation(
    admin_signer,
    60,  // 60% to Tapp Exchange
    25,  // 25% to Hyperion
    15   // 15% to reserve
);
```

### **APR Management**
```move
// Set Tapp Exchange APR to 7.5%
tapp_exchange::admin_set_apr(admin_signer, 750);

// Set Hyperion APR to 8.5%  
hyperion::admin_set_apr(admin_signer, 850);
```

## 📊 View Functions & Analytics

### **Portfolio Overview**
```move
// Get total vault NAV and exchange rate
let (total_nav, exchange_rate) = vault::get_vault_nav();

// Get allocation breakdown
let (tapp_shares, hyperion_lp_tokens, reserve_usdc) = vault::get_protocol_positions();

// Get current allocation strategy
let (tapp_pct, hyperion_pct, reserve_pct) = vault::get_allocation_config();
```

### **Individual Protocol Stats**
```move
// Tapp Exchange
let (user_shares, current_value) = tapp_exchange::get_position(user_addr);
let tapp_apr = tapp_exchange::get_apr();
let tapp_tvl = tapp_exchange::get_tvl();

// Hyperion  
let (user_lp_tokens, current_value) = hyperion::get_position(user_addr);
let hyperion_apr = hyperion::get_apr();
let (liquidity, lp_tokens, rewards, bonuses) = hyperion::get_pool_stats();
```

### **Projected Returns**
```move
// Get current APR from both protocols
let (tapp_apr, hyperion_apr) = vault::projected_apy();
```

## 🚨 Events & Monitoring

Each module emits comprehensive events for monitoring:

### **Vault Events**
- `DepositedEvent` - User deposits with allocation details
- `WithdrawnEvent` - User withdrawals with yield earned  
- `HarvestEvent` - Yield harvesting and NAV updates
- `AllocationUpdateEvent` - Admin allocation changes

### **Protocol Events**  
- `TappDepositEvent` / `HyperionLiquidityAddedEvent` - Protocol deposits
- `TappCompoundEvent` / `HyperionCompoundEvent` - Auto-compounding
- `TappFeeEvent` / `HyperionTradingRewardEvent` - Fee/reward accrual

## 🛠️ Development & Testing

### **Compilation**
```bash
cd riverfi-contract-aptos
aptos move compile --dev
```

### **Key Development Notes**
1. **Address Configuration**: Uses dev addresses for testing
2. **Circular Dependencies**: Avoided by simplifying vault access controls
3. **Type Safety**: All calculations use u128 for precision
4. **Error Handling**: Comprehensive error codes and assertions

### **Testing Strategy**
1. Deploy contracts with test accounts
2. Fund test account with USDC
3. Test deposit → time passage → harvest → withdraw flow
4. Verify yield calculations and exchange rate updates
5. Test admin controls and edge cases

## 🎯 Production Considerations

### **Security Notes**
- Mock protocols for MVP - **NOT production ready**
- Simplified access controls - need proper vault authorization
- No oracle price feeds - uses fixed rates
- No slippage protection - simplified for demonstration

### **Future Enhancements**
1. **Real Protocol Integration**: Replace mocks with actual Tapp Exchange and Hyperion
2. **Oracle Integration**: Dynamic APR based on market conditions  
3. **Advanced Strategies**: Multi-asset pools, automated rebalancing
4. **Governance**: DAO-controlled parameter updates
5. **Security Audits**: Full security review before mainnet

## 🏁 Quick Start

1. **Deploy Contracts**:
   ```bash
   aptos move publish --dev
   ```

2. **Initialize Protocols**:
   - River Fi vault auto-initializes on deploy
   - Tapp Exchange and Hyperion auto-initialize with default APRs

3. **Make First Deposit**:
   ```bash
   aptos move run --dev --function-id default::vault::deposit --args u64:1000000
   ```

4. **Check Position**:
   ```bash
   aptos move view --dev --function-id default::vault::get_user_balance --args address:0x123...
   ```

5. **Harvest Yield** (simulate time passage):
   ```bash
   aptos move run --dev --function-id default::vault::harvest_yield  
   ```

---

**River Fi MVP** demonstrates a complete DeFi yield aggregator with realistic mock protocols, automatic compounding, and comprehensive analytics - ready for integration with real protocols! 🌊💰