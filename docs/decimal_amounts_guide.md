# River Finance Decimal Amounts Guide

## Understanding RUSD Decimals

RUSD uses **6 decimal places** (like USDC), so:

| Human-Readable | Raw Units | Description |
|----------------|-----------|-------------|
| 0.000001 RUSD | 1 | Smallest unit |
| 0.001 RUSD | 1,000 | One thousandth |
| 0.01 RUSD | 10,000 | One cent |
| 0.1 RUSD | 100,000 | One tenth |
| 1.0 RUSD | 1,000,000 | One RUSD |
| 10.0 RUSD | 10,000,000 | Ten RUSD |
| 100.0 RUSD | 100,000,000 | One hundred RUSD |
| 1,000.0 RUSD | 1,000,000,000 | One thousand RUSD |

---

## Common Transaction Amounts

### ✅ **Safe Testing Amounts:**

```bash
# Deposit 1 USDC (gets you 1 RUSD)
aptos move run --function-id "YOUR_ADDRESS::vault::deposit" --args u64:1000000 --profile dev5

# Withdraw 0.5 RUSD 
aptos move run --function-id "YOUR_ADDRESS::vault::withdraw" --args u64:500000 --profile dev5

# Transfer 0.1 RUSD to another user
aptos move run --function-id "YOUR_ADDRESS::vault::transfer" --args address:RECIPIENT_ADDRESS u64:100000 --profile dev5

# Admin add 100 USDC yield
aptos move run --function-id "YOUR_ADDRESS::vault::admin_increase_yield" --args u64:100000000 --profile dev5
```

### ❌ **Amounts That Will Cause Errors:**

```bash
# DON'T DO THIS - Trying to withdraw 1000 RUSD when you only have 1 RUSD
aptos move run --function-id "YOUR_ADDRESS::vault::withdraw" --args u64:1000000000 --profile dev5

# DON'T DO THIS - Trying to deposit 10,000 USDC without enough balance
aptos move run --function-id "YOUR_ADDRESS::vault::deposit" --args u64:10000000000 --profile dev5
```

---

## Quick Reference Commands

### Check Your Current Balance:
```bash
aptos move view --function-id "0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0::vault::get_user_balance" --args address:0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0 --url https://fullnode.testnet.aptoslabs.com
```

### Check Your Position (including claimable yield):
```bash
aptos move view --function-id "0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0::vault::get_user_position" --args address:0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0 --url https://fullnode.testnet.aptoslabs.com
```

### Check Vault Stats:
```bash
aptos move view --function-id "0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0::vault::get_vault_stats" --url https://fullnode.testnet.aptoslabs.com
```

---

## Testing the Yield System

Now that withdrawals work, test the yield distribution:

### 1. **Add Some Yield (as admin):**
```bash
aptos move run --function-id "0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0::vault::admin_increase_yield" --args u64:10000000 --profile dev5
```
*This adds 10 RUSD worth of yield*

### 2. **Check Your Claimable Rewards:**
```bash
aptos move view --function-id "0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0::vault::get_pending_yield_rewards" --args address:0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0 --url https://fullnode.testnet.aptoslabs.com
```

### 3. **Claim Your Rewards:**
```bash
aptos move run --function-id "0x59fa73b80b51aab1f42b66c973419fccee430b3d0154794b929f740aca4689b0::vault::claim_rewards" --profile dev5
```

---

## Pro Tips:

1. **Always start with small amounts** when testing
2. **Check your balance** before making large transactions
3. **Remember**: 1,000,000 units = 1.0 RUSD
4. **Use the view functions** to monitor state changes
5. **The contract is working correctly** - it was just a decimal confusion!
