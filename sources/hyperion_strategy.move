module riverfi::hyperion_strategy {
    use std::signer;
    use std::vector;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::fungible_asset::{Metadata};

    // Hyperion imports
    use dex_contract::router_v3;
    use dex_contract::pool_v3;
    use dex_contract::position_v3::{Self, Info};

    // Constants for USDC/USDT stable pair strategy
    const USDC_USDT_FEE_TIER: u8 = 1; // 0.05% fee tier (stable pairs usually lower)
    const SLIPPAGE_NUMERATOR: u256 = 998; // 0.2% slippage tolerance (tighter for stable)
    const SLIPPAGE_DENOMINATOR: u256 = 1000;

    // Stable token addresses
    const USDC_ADDRESS: address = @usdc;
    const USDT_ADDRESS: address = @usdt;

    // Errors
    const E_INSUFFICIENT_AMOUNT: u64 = 1;
    const E_POSITION_CREATION_FAILED: u64 = 2;

    /// Deposit USDC to USDC/USDT stable pair liquidity pool
    public fun deposit_to_hyperion(
        vault_signer: &signer,
        usdc_amount: u64,
        usdc_metadata: Object<Metadata>
    ): Object<Info> {
        assert!(usdc_amount > 0, E_INSUFFICIENT_AMOUNT);

        let vault_addr = signer::address_of(vault_signer);
        let usdt_metadata = object::address_to_object<Metadata>(USDT_ADDRESS);

        // 1. Swap 50% USDC to USDT for balanced stable liquidity
        let swap_amount = usdc_amount / 2;
        let remaining_usdc = usdc_amount - swap_amount;

        router_v3::exact_input_swap_entry(
            vault_signer,
            USDC_USDT_FEE_TIER,      // fee_tier for USDC/USDT pool (stable pair)
            swap_amount,             // amount_in (50% of USDC)
            0,                       // min_amount_out (0 = accept any, safe for stables)
            0,                       // sqrt_price_limit (0 = no limit)
            usdc_metadata,           // from_token (USDC)
            usdt_metadata,           // to_token (USDT)
            vault_addr,              // recipient (vault)
            0                        // deadline (0 = no deadline)
        );

        // 2. Get USDT balance after swap
        let usdt_balance = primary_fungible_store::balance(vault_addr, usdt_metadata);

        // 3. Create position first (MoneyFi proven approach)
        let position = pool_v3::open_position(
            vault_signer,
            usdc_metadata,           // token_a (USDC)
            usdt_metadata,           // token_b (USDT)
            USDC_USDT_FEE_TIER,      // fee_tier (0.05% for stable pair)
            get_stable_tick_lower(), // tick_lower (tight range for stable pair)
            get_stable_tick_upper()  // tick_upper (tight range for stable pair)
        );

        // 4. Add dual-asset liquidity using standard approach
        router_v3::add_liquidity(
            vault_signer,
            position,                // position object
            usdc_metadata,           // token_a
            usdt_metadata,           // token_b
            USDC_USDT_FEE_TIER,      // fee_tier
            remaining_usdc,          // amount_a_desired (remaining USDC)
            usdt_balance,            // amount_b_desired (all USDT from swap)
            0,                       // amount_a_min (0 = accept any)
            0,                       // amount_b_min (0 = accept any)
            0                        // deadline (0 = no deadline)
        );

        // Return the actual position object
        position
    }

    /// Withdraw liquidity from USDC/USDT stable pair and convert back to USDC
    public fun withdraw_from_hyperion(
        vault_signer: &signer,
        position: Object<Info>,
        liquidity_amount: u128,
        usdc_metadata: Object<Metadata>
    ): u64 {
        let vault_addr = signer::address_of(vault_signer);
        let usdt_metadata = object::address_to_object<Metadata>(USDT_ADDRESS);

        // Check USDC balance before withdrawal
        let usdc_balance_before = primary_fungible_store::balance(vault_addr, usdc_metadata);

        // Remove liquidity from USDC/USDT position
        router_v3::remove_liquidity(
            vault_signer,
            position,
            liquidity_amount,
            0,                       // amount_a_min (0 = accept any)
            0,                       // amount_b_min (0 = accept any)
            vault_addr,              // recipient
            0                        // deadline
        );

        // Get USDT balance after liquidity removal
        let usdt_balance = primary_fungible_store::balance(vault_addr, usdt_metadata);

        // Convert all USDT back to USDC if we have any
        if (usdt_balance > 0) {
            router_v3::exact_input_swap_entry(
                vault_signer,
                USDC_USDT_FEE_TIER,  // fee_tier for USDT/USDC swap
                usdt_balance,        // amount_in (all USDT)
                0,                   // min_amount_out (0 = accept any)
                0,                   // sqrt_price_limit (0 = no limit)
                usdt_metadata,       // from_token (USDT)
                usdc_metadata,       // to_token (USDC)
                vault_addr,          // recipient (vault)
                0                    // deadline (0 = no deadline)
            );
        };

        // Calculate total USDC received
        let usdc_balance_after = primary_fungible_store::balance(vault_addr, usdc_metadata);
        usdc_balance_after - usdc_balance_before
    }

    /// Claim fees and rewards from USDC/USDT stable pair position
    public fun claim_yields(
        vault_signer: &signer,
        position: Object<Info>,
        usdc_metadata: Object<Metadata>
    ): u64 {
        let vault_addr = signer::address_of(vault_signer);
        let usdt_metadata = object::address_to_object<Metadata>(USDT_ADDRESS);

        // Check balances before claiming
        let usdc_balance_before = primary_fungible_store::balance(vault_addr, usdc_metadata);
        let usdt_balance_before = primary_fungible_store::balance(vault_addr, usdt_metadata);

        // Claim fees from the USDC/USDT position
        let position_addresses = vector::empty<address>();
        vector::push_back(
            &mut position_addresses,
            object::object_address<Info>(&position)
        );

        router_v3::claim_fees(
            vault_signer,
            position_addresses,
            vault_addr               // to (recipient address)
        );

        // Get balances after claiming
        let usdc_balance_after = primary_fungible_store::balance(vault_addr, usdc_metadata);
        let usdt_balance_after = primary_fungible_store::balance(vault_addr, usdt_metadata);

        // Calculate claimed amounts
        let _usdc_claimed = usdc_balance_after - usdc_balance_before;
        let usdt_claimed = usdt_balance_after - usdt_balance_before;

        // Convert any claimed USDT to USDC for uniform yield calculation
        if (usdt_claimed > 0) {
            router_v3::exact_input_swap_entry(
                vault_signer,
                USDC_USDT_FEE_TIER,
                usdt_claimed,
                0,                   // min_amount_out (0 = accept any)
                0,                   // sqrt_price_limit (0 = no limit)
                usdt_metadata,       // from_token (USDT)
                usdc_metadata,       // to_token (USDC)
                vault_addr,          // recipient (vault)
                0                    // deadline (0 = no deadline)
            );
        };

        // Calculate total yield in USDC terms
        let final_usdc_balance = primary_fungible_store::balance(vault_addr, usdc_metadata);
        final_usdc_balance - usdc_balance_before
    }

    /// Get reasonable tick range for USDC/USDT stable pair liquidity
    /// Using tight range since both tokens are stable around 1:1
    fun get_stable_tick_lower(): u32 {
        // For stable pairs, use much tighter range around current price
        // USDC/USDT should stay close to 1:1 ratio
        // Using conservative range that allows for small price movements
        2147483647 - 2000 // Tighter lower bound for stable pair
    }

    fun get_stable_tick_upper(): u32 {
        // Tighter upper bound for stable pair
        // This allows for small deviations but captures most trading activity
        2147483647 + 2000 // Tighter upper bound for stable pair
    }

    /// Get current liquidity in a position
    public fun get_position_liquidity(position: Object<Info>): u128 {
        position_v3::get_liquidity(position)
    }
}
