#!/bin/bash

# River Fi Complete Test Script
echo "🌊 River Fi Complete Test Script"
echo "================================="

echo ""
echo "1. Compiling contracts..."
aptos move compile --dev

if [ $? -eq 0 ]; then
    echo "✅ Compilation successful!"
else
    echo "❌ Compilation failed!"
    exit 1
fi

echo ""
echo "2. Deploying contracts..."
aptos move publish --dev

if [ $? -eq 0 ]; then
    echo "✅ Deployment successful!"
else
    echo "❌ Deployment failed!"
    exit 1
fi

echo ""
echo "3. Getting Mock USDC from faucet..."
aptos move run --dev --function-id default::mock_usdc::faucet

echo ""
echo "4. Checking Mock USDC balance..."
BALANCE=$(aptos move view --dev --function-id default::mock_usdc::get_balance --args address:0xFACE | grep -oP '"\K[0-9]+')
echo "Mock USDC Balance: $BALANCE (should be 1000000000 = 1000 USDC)"

echo ""
echo "5. Making deposit to River Fi vault..."
aptos move run --dev --function-id default::vault::deposit --args u64:100000000

echo ""
echo "6. Checking RUSDC position..."
aptos move view --dev --function-id default::vault::get_user_position --args address:0xFACE

echo ""
echo "7. Checking vault allocation..."
aptos move view --dev --function-id default::vault::get_allocation_config

echo ""
echo "8. Simulating yield generation..."
aptos move run --dev --function-id default::tapp_exchange::compound_yield
aptos move run --dev --function-id default::hyperion::compound_rewards
aptos move run --dev --function-id default::vault::harvest_yield

echo ""
echo "9. Checking updated position (should show yield)..."
aptos move view --dev --function-id default::vault::get_user_position --args address:0xFACE

echo ""
echo "10. Testing withdrawal..."
aptos move run --dev --function-id default::vault::withdraw --args u64:50000000

echo ""
echo "11. Final Mock USDC balance (should be > 1000 due to yield)..."
FINAL_BALANCE=$(aptos move view --dev --function-id default::mock_usdc::get_balance --args address:0xFACE | grep -oP '"\K[0-9]+')
echo "Final Mock USDC Balance: $FINAL_BALANCE"

echo ""
echo "🎉 River Fi Test Complete!"
echo ""
echo "Expected Results:"
echo "- Initial USDC: 1,000,000,000 (1000 USDC)"
echo "- After deposit: 100 RUSDC"
echo "- After yield: RUSDC value > 100 USDC"
echo "- After withdrawal: USDC > 1000 (original + yield)"
echo ""
echo "✅ All functions working correctly if no errors above!"