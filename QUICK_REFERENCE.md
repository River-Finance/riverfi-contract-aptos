# River Finance Protocol - Quick Reference Card

## 🚀 **Contract Address**
**Testnet**: `0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0`

---

## 💰 **Decimal System**
- **RUSD uses 6 decimals** (like USDC)
- **1 RUSD** = 1,000,000 units
- **100 RUSD** = 100,000,000 units
- **Always multiply by 1,000,000** for contract calls

---

## 🔧 **Essential Functions**

### **User Functions**
```javascript
// Deposit 100 USDC → Get 100 RUSD
deposit(userAccount, "100000000")

// Withdraw 50 RUSD → Get 50 USDC  
withdraw(userAccount, "50000000")

// Transfer 10 RUSD to another user
transfer(userAccount, recipientAddress, "10000000")

// Claim yield rewards
claim_rewards()
```

### **View Functions (Most Important)**
```javascript
// Get user's RUSD balance
get_user_balance(userAddress) → "100000000" (100 RUSD)

// Get complete user position
get_user_position(userAddress) → [rusdBalance, usdcValue, claimableYield, exchangeRate]

// Get pending rewards
get_pending_yield_rewards(userAddress) → "5000000" (5 RUSD)

// Get vault stats
get_vault_stats() → [totalUsdc, totalRusdSupply, legacy, legacy]

// Get yield pool info
get_yield_pool_stats() → [claimable, earning, apyBps, timestamp, autoMode]
```

### **Admin Functions**
```javascript
// Add 10 RUSD worth of yield
admin_increase_yield(adminAccount, "10000000")

// Set 15% APY (1500 basis points)
admin_set_annual_apy(adminAccount, "1500")

// Toggle auto-distribution
admin_set_auto_yield(adminAccount, true)
```

---

## ⚡ **Frontend SDK Template**

```javascript
class RiverFinanceSDK {
    constructor(aptosClient) {
        this.aptos = aptosClient;
        this.address = "0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0";
    }
    
    // Convert 100.5 → "100500000"
    toUnits(amount) { 
        return (parseFloat(amount) * 1000000).toString(); 
    }
    
    // Convert "100500000" → "100.500000"
    fromUnits(units) { 
        return (parseInt(units) / 1000000).toFixed(6); 
    }
    
    // Deposit USDC
    async deposit(account, amount) {
        return this.callFunction(account, 'deposit', [this.toUnits(amount)]);
    }
    
    // Get user balance
    async getBalance(userAddress) {
        const result = await this.viewFunction('get_user_balance', [userAddress]);
        return this.fromUnits(result[0]);
    }
    
    // Helper for transactions
    async callFunction(account, func, args = []) {
        const transaction = {
            type: "entry_function_payload",
            function: `${this.address}::vault::${func}`,
            arguments: args,
            type_arguments: []
        };
        return await this.aptos.signAndSubmitTransaction({
            signer: account, transaction
        });
    }
    
    // Helper for view calls
    async viewFunction(func, args = []) {
        return await this.aptos.view({
            function: `${this.address}::vault::${func}`,
            arguments: args
        });
    }
}
```

---

## ❌ **Common Errors & Solutions**

| Error | Cause | Solution |
|-------|--------|----------|
| `E_INSUFFICIENT_BALANCE` | Not enough RUSD/USDC | Check balance first |
| `E_ZERO_AMOUNT` | Amount is 0 | Use amount > 0 |
| `Multiplication overflow` | Number too large | Use smaller amounts |
| `Subtraction overflow` | No yield to claim | Check pending rewards |
| `Permission denied` | Not admin | Use admin account |

---

## 🎯 **Key Concepts**

### **Yield Distribution**
- **Auto Mode (Default)**: Rewards accumulate, claimed on interactions
- **Manual Mode**: Users must call `claim_daily_yield` 
- **Proportional**: Your share = Your RUSD / Total RUSD

### **Exchange Rate**
- **Always 1:1** USDC ↔ RUSD
- **No slippage** or price changes
- **Yield = Additional tokens**, not price appreciation

### **Protocol Allocation**
- **30%** → Tapp Exchange
- **70%** → Hyperion Protocol  
- **0%** → Reserve (unused)

---

## 🧪 **Testing Commands**

```bash
# Set contract variable
CONTRACT="0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0"

# Deposit 1 USDC
aptos move run --function-id "$CONTRACT::vault::deposit" --args u64:1000000 --profile testnet

# Check balance  
aptos move view --function-id "$CONTRACT::vault::get_user_balance" --args address:YOUR_ADDRESS --url https://fullnode.testnet.aptoslabs.com

# Add yield (admin)
aptos move run --function-id "$CONTRACT::vault::admin_increase_yield" --args u64:1000000 --profile admin

# Claim rewards
aptos move run --function-id "$CONTRACT::vault::claim_rewards" --profile testnet

# Withdraw 0.5 RUSD
aptos move run --function-id "$CONTRACT::vault::withdraw" --args u64:500000 --profile testnet
```

---

## 📊 **Return Values Guide**

| Function | Returns | Example |
|----------|---------|---------|
| `get_user_balance` | `u64` | `"100000000"` (100 RUSD) |
| `get_user_position` | `(u64,u64,u64,u128)` | `["100000000","100000000","5000000","1000000000000"]` |
| `get_vault_stats` | `(u64,u64,u64,u64)` | `["999500000","999500000","0","0"]` |
| `get_yield_pool_stats` | `(u64,u64,u64,u64,bool)` | `["0","999500000","1000","1759305976",true]` |

---

## 🔄 **Typical User Flow**

1. **Connect Wallet** → Get user address
2. **Check USDC Balance** → Validate deposit amount
3. **Deposit USDC** → `deposit(amount)`
4. **Monitor Position** → `get_user_position()`
5. **Check Rewards** → `get_pending_yield_rewards()`
6. **Claim Rewards** → `claim_rewards()` (optional)
7. **Withdraw** → `withdraw(amount)`

---

## 📈 **Events to Listen For**

- `DepositedEvent` → User deposits
- `WithdrawnEvent` → User withdrawals  
- `YieldClaimedEvent` → Yield claimed
- `YieldDistributedEvent` → Admin adds yield
- `TransferEvent` → RUSD transfers
