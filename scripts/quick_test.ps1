# River Fi Complete Test Script for PowerShell
Write-Host "🌊 River Fi Complete Test Script" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "1. Compiling contracts..." -ForegroundColor Yellow
$compileResult = & aptos move compile --dev
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Compilation successful!" -ForegroundColor Green
} else {
    Write-Host "❌ Compilation failed!" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "2. Deploying contracts..." -ForegroundColor Yellow
$deployResult = & aptos move publish --dev
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Deployment successful!" -ForegroundColor Green
} else {
    Write-Host "❌ Deployment failed!" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "3. Getting Mock USDC from faucet..." -ForegroundColor Yellow
& aptos move run --dev --function-id default::mock_usdc::faucet

Write-Host ""
Write-Host "4. Checking Mock USDC balance..." -ForegroundColor Yellow
$balance = & aptos move view --dev --function-id default::mock_usdc::get_balance --args address:0xFACE
Write-Host "Mock USDC Balance: $balance (should be 1000000000 = 1000 USDC)"

Write-Host ""
Write-Host "5. Making deposit to River Fi vault..." -ForegroundColor Yellow
& aptos move run --dev --function-id default::vault::deposit --args u64:100000000

Write-Host ""
Write-Host "6. Checking RUSDC position..." -ForegroundColor Yellow
& aptos move view --dev --function-id default::vault::get_user_position --args address:0xFACE

Write-Host ""
Write-Host "7. Checking vault allocation..." -ForegroundColor Yellow
& aptos move view --dev --function-id default::vault::get_allocation_config

Write-Host ""
Write-Host "8. Simulating yield generation..." -ForegroundColor Yellow
& aptos move run --dev --function-id default::tapp_exchange::compound_yield
& aptos move run --dev --function-id default::hyperion::compound_rewards
& aptos move run --dev --function-id default::vault::harvest_yield

Write-Host ""
Write-Host "9. Checking updated position (should show yield)..." -ForegroundColor Yellow
& aptos move view --dev --function-id default::vault::get_user_position --args address:0xFACE

Write-Host ""
Write-Host "10. Testing withdrawal..." -ForegroundColor Yellow
& aptos move run --dev --function-id default::vault::withdraw --args u64:50000000

Write-Host ""
Write-Host "11. Final Mock USDC balance (should be > 1000 due to yield)..." -ForegroundColor Yellow
$finalBalance = & aptos move view --dev --function-id default::mock_usdc::get_balance --args address:0xFACE
Write-Host "Final Mock USDC Balance: $finalBalance"

Write-Host ""
Write-Host "🎉 River Fi Test Complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Expected Results:" -ForegroundColor Cyan
Write-Host "- Initial USDC: 1,000,000,000 (1000 USDC)"
Write-Host "- After deposit: 100 RUSDC"
Write-Host "- After yield: RUSDC value > 100 USDC"
Write-Host "- After withdrawal: USDC > 1000 (original + yield)"
Write-Host ""
Write-Host "✅ All functions working correctly if no errors above!" -ForegroundColor Green