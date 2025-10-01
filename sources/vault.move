module riverfi::vault {
    use std::signer;
    use std::error;
    use std::string;
    use std::option;
    use std::vector;
    use std::table;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, TransferRef, BurnRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp::now_seconds;

    use riverfi::storage;
    use riverfi::tapp_exchange;
    use riverfi::hyperion;
    use riverfi::mock_usdc;
    use riverfi::hyperion_strategy;

    // -- Constants
    const RUSD_TOKEN_NAME: vector<u8> = b"River USD";
    const RUSD_TOKEN_SYMBOL: vector<u8> = b"RUSD";
    const RUSD_TOKEN_DECIMALS: u8 = 6;
    const VAULT_SEED: vector<u8> = b"vault::VAULT";
    
    // Fixed 1:1 exchange rate with USDC
    const FIXED_EXCHANGE_RATE: u128 = 1000000000000; // 1.0 with precision (1e12)

    // (70% Hyperion, 30% Tapp, 0% Reserve)
    const DEFAULT_TAPP_ALLOCATION_PERCENT: u8 = 30;
    const DEFAULT_HYPERION_ALLOCATION_PERCENT: u8 = 70;
    const DEFAULT_RESERVE_ALLOCATION_PERCENT: u8 = 0;
    
    // Default yield settings
    const DEFAULT_ANNUAL_APY_BPS: u64 = 1000; // 10% APY = 1000 basis points
    const DAYS_PER_YEAR: u64 = 365;
    const SECONDS_PER_DAY: u64 = 86400; // 24 * 60 * 60
    const APT_ADDRESS: address = @0x1; // APT token address

    // -- Errors
    const E_ALREADY_INITIALIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_INSUFFICIENT_VAULT_BALANCE: u64 = 3;
    const E_ZERO_AMOUNT: u64 = 4;

    // -- Structs
    struct Config has key {
        enable_deposit: bool,
        enable_withdraw: bool,
    }

    struct AllocationConfig has key {
        tapp_percent: u8,
        hyperion_percent: u8,
        reserve_percent: u8,
        last_rebalance_ts: u64,
    }

    struct RUSDToken has key {
        token: Object<Metadata>,
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef,
        extend_ref: ExtendRef
    }
    
    // Yield pool for automatic yield distribution
    struct YieldPool has key {
        total_claimable_yield: u64,     // Total RUSD in yield pool (for manual claims)
        total_rusd_earning: u64,        // Total RUSD tokens earning yield
        annual_apy_bps: u64,            // Annual APY in basis points (e.g., 1000 = 10%)
        last_yield_accrual_ts: u64,     // Last time daily yield was accrued
        user_last_claim_ts: table::Table<address, u64>, // User's last claim timestamp
        auto_distribute_yield: bool,    // Whether to auto-distribute yield or require claims
        total_yield_distributed: u64,   // Total yield distributed automatically
        last_distribution_time: u64,    // Last automatic distribution timestamp
        yield_per_token_accumulated: u64, // Accumulated yield per token (scaled by 1e12)
        user_yield_debt: table::Table<address, u64>, // User's yield debt for reward calculation
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Vault has key {
        extend_ref: ExtendRef,
        total_usdc: u64,
        total_rusd_supply: u64,         // Total RUSD tokens in circulation
        
        // Mock Protocol Positions
        tapp_shares: u128,              // Shares in Tapp Exchange
        hyperion_lp_tokens: u128,       // LP tokens in Hyperion
        
        // Fixed exchange rate (always 1:1)
        exchange_rate: u128,            // Always FIXED_EXCHANGE_RATE
        last_harvest_ts: u64,           // Last time yields were harvested
        
        // Legacy fields (kept for backward compatibility but not used)
        hyperion_positions: vector<Object<riverfi::hyperion_strategy::Info>>,
        hyperion_usdc: u64,
        reserve_usdc: u64,              // Not used anymore (0% allocation)
    }

    // -- Events
    #[event]
    struct DepositedEvent has drop, store {
        user: address,
        usdc_amount: u64,
        rusd_amount: u64,
        timestamp: u64
    }

    #[event]
    struct WithdrawnEvent has drop, store {
        user: address,
        rusd_amount: u64,
        usdc_amount: u64,
        timestamp: u64
    }

    #[event]
    struct HyperionDepositEvent has drop, store {
        amount: u64,
        timestamp: u64
    }

    #[event]
    struct AllocationUpdateEvent has drop, store {
        old_tapp_percent: u8,
        old_hyperion_percent: u8,
        old_reserve_percent: u8,
        new_tapp_percent: u8,
        new_hyperion_percent: u8,
        new_reserve_percent: u8,
        admin: address,
        timestamp: u64
    }

    #[event]
    struct HarvestEvent has drop, store {
        tapp_value: u128,
        hyperion_value: u128,
        total_nav: u128,
        old_exchange_rate: u128,
        new_exchange_rate: u128,
        yield_earned: u128,
        timestamp: u64
    }

    #[event]
    struct ExchangeRateUpdateEvent has drop, store {
        old_rate: u128,
        new_rate: u128,
        timestamp: u64
    }
    
    // New Yield Events
    #[event]
    struct ManualYieldAddedEvent has drop, store {
        admin: address,
        usdc_amount: u64,
        rusd_minted: u64,
        timestamp: u64
    }
    
    #[event]
    struct DailyYieldAccruedEvent has drop, store {
        total_earning_rusd: u64,
        daily_rate_bps: u64,
        yield_accrued: u64,
        timestamp: u64
    }
    
    #[event]
    struct YieldClaimedEvent has drop, store {
        user: address,
        claimed_amount: u64,
        timestamp: u64
    }
    
    #[event]
    struct YieldRateChangedEvent has drop, store {
        old_rate_bps: u64,
        new_rate_bps: u64,
        admin: address,
        timestamp: u64
    }
    
    #[event]
    struct TransferEvent has drop, store {
        from: address,
        to: address,
        amount: u64,
        timestamp: u64
    }
    
    #[event]
    struct AutoYieldDistributedEvent has drop, store {
        total_yield_distributed: u64,
        recipients_count: u64,
        apy_rate_bps: u64,
        timestamp: u64
    }
    
    #[event]
    struct YieldDistributedEvent has drop, store {
        total_amount: u64,
        distributed_to_holders: bool,
        timestamp: u64
    }

    // -- Init
    fun init_module(sender: &signer) {
        let addr = signer::address_of(sender);
        assert!(addr == @riverfi);
        assert!(
            !exists<Config>(addr),
            error::already_exists(E_ALREADY_INITIALIZED)
        );

        init_vault();

        move_to(
            sender,
            Config {
                enable_deposit: true,
                enable_withdraw: true,
            }
        );

        // Initialize allocation config
        move_to(
            sender,
            AllocationConfig {
                tapp_percent: DEFAULT_TAPP_ALLOCATION_PERCENT,
                hyperion_percent: DEFAULT_HYPERION_ALLOCATION_PERCENT,
                reserve_percent: DEFAULT_RESERVE_ALLOCATION_PERCENT,
                last_rebalance_ts: now_seconds(),
            }
        );
        
        // Initialize yield pool
        move_to(
            sender,
            YieldPool {
                total_claimable_yield: 0,
                total_rusd_earning: 0,
                annual_apy_bps: DEFAULT_ANNUAL_APY_BPS, // Default 10% APY
                last_yield_accrual_ts: now_seconds(),
                user_last_claim_ts: table::new(),
                auto_distribute_yield: true, // Enable auto-distribution by default
                total_yield_distributed: 0,
                last_distribution_time: now_seconds(),
                yield_per_token_accumulated: 0,
                user_yield_debt: table::new(),
            }
        );

        init_rusd_token(sender);
    }

    // -- Public Entry Functions
    public entry fun deposit(sender: &signer, amount: u64) acquires Config, RUSDToken, Vault, AllocationConfig, YieldPool {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));

        let config = borrow_global<Config>(@riverfi);
        assert!(config.enable_deposit, error::permission_denied(E_ALREADY_INITIALIZED));

        let user_addr = signer::address_of(sender);
        let vault_addr = get_vault_address();
        
        // Accrue daily yield before new deposit
        accrue_daily_yield_internal();
        
        let vault = borrow_global_mut<Vault>(vault_addr);

        // 1. Transfer USDC from user to vault
        let usdc_metadata = mock_usdc::get_token();
        primary_fungible_store::transfer(sender, usdc_metadata, vault_addr, amount);

        // 2. Calculate allocation amounts (70% Hyperion, 30% Tapp, 0% Reserve)
        let allocation_config = borrow_global<AllocationConfig>(@riverfi);
        let tapp_amount = (amount * (allocation_config.tapp_percent as u64)) / 100;
        let hyperion_amount = (amount * (allocation_config.hyperion_percent as u64)) / 100;
        // No reserve allocation anymore

        // 3. Get vault signer for protocol deposits
        let vault_signer = get_vault_signer(vault);

        // 4. Deploy to Tapp Exchange
        if (tapp_amount > 0) {
            let new_tapp_shares = tapp_exchange::vault_deposit(&vault_signer, tapp_amount);
            vault.tapp_shares = vault.tapp_shares + new_tapp_shares;
        };

        // 5. Deploy to Hyperion mock protocol
        if (hyperion_amount > 0) {
            let new_lp_tokens = hyperion::vault_provide_liquidity(&vault_signer, hyperion_amount);
            vault.hyperion_lp_tokens = vault.hyperion_lp_tokens + new_lp_tokens;
        };

        // 6. Claim any pending yield rewards for the user before balance changes
        claim_yield_rewards(user_addr);
        
        // 7. Mint RUSD tokens 1:1 with USDC (fixed exchange rate)
        vault.exchange_rate = FIXED_EXCHANGE_RATE; // Always maintain 1:1 ratio
        let rusd_to_mint = amount; // 1:1 ratio with USDC
        mint_rusd(user_addr, rusd_to_mint);
        
        // 8. Update user's yield debt for the new balance
        let new_balance = get_user_balance(user_addr);
        update_user_yield_debt(user_addr, new_balance);
        
        // 9. Update vault state
        vault.total_usdc = vault.total_usdc + amount;
        vault.total_rusd_supply = vault.total_rusd_supply + rusd_to_mint;
        
        // 10. Track earning RUSD tokens (all deposited RUSD earns yield)
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        yield_pool.total_rusd_earning = yield_pool.total_rusd_earning + rusd_to_mint;
        
        // 11. Emit deposit event
        event::emit(DepositedEvent {
            user: user_addr,
            usdc_amount: amount,
            rusd_amount: rusd_to_mint,
            timestamp: now_seconds()
        });
    }

    public entry fun withdraw(sender: &signer, rusd_amount: u64) acquires Config, RUSDToken, Vault, AllocationConfig, YieldPool {
        assert!(rusd_amount > 0, error::invalid_argument(E_ZERO_AMOUNT));

        let config = borrow_global<Config>(@riverfi);
        assert!(config.enable_withdraw, error::permission_denied(E_ALREADY_INITIALIZED));

        let user_addr = signer::address_of(sender);
        let vault_addr = get_vault_address();
        
        // 1. Accrue daily yield first
        accrue_daily_yield_internal();
        
        let vault = borrow_global_mut<Vault>(vault_addr);

        // 2. Check user has enough RUSD
        let rusd_token = get_rusd_token();
        let user_rusd_balance = primary_fungible_store::balance(user_addr, rusd_token);
        assert!(user_rusd_balance >= rusd_amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // 3. Calculate USDC amount using fixed 1:1 exchange rate
        vault.exchange_rate = FIXED_EXCHANGE_RATE; // Ensure fixed rate
        let usdc_amount = rusd_amount; // 1:1 ratio

        // 4. Claim any pending yield rewards before balance changes
        claim_yield_rewards(user_addr);
        
        // 5. Always unwind positions from protocols (no reserve)
        let vault_signer = get_vault_signer(vault);
        unwind_positions_for_liquidity(&vault_signer, vault, usdc_amount);

        // 6. Burn RUSD from user
        burn_rusd(user_addr, rusd_amount);
        
        // 7. Update user's yield debt for the new balance
        let new_balance = get_user_balance(user_addr);
        update_user_yield_debt(user_addr, new_balance);

        // 8. Transfer USDC from riverfi to user (1:1 ratio)
        let usdc_metadata = mock_usdc::get_token();
        let riverfi_balance = primary_fungible_store::balance(@riverfi, usdc_metadata);
        assert!(riverfi_balance >= usdc_amount, error::resource_exhausted(E_INSUFFICIENT_VAULT_BALANCE));

        // Use vault signer to transfer from riverfi (since protocols store USDC there)
        primary_fungible_store::transfer(&vault_signer, usdc_metadata, user_addr, usdc_amount);

        // 9. Update vault stats and yield pool
        vault.total_usdc = if (vault.total_usdc >= usdc_amount) {
            vault.total_usdc - usdc_amount
        } else { 0 };
        vault.total_rusd_supply = vault.total_rusd_supply - rusd_amount;
        
        // Update yield pool - reduce earning RUSD tokens
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        yield_pool.total_rusd_earning = if (yield_pool.total_rusd_earning >= rusd_amount) {
            yield_pool.total_rusd_earning - rusd_amount
        } else { 0 };

        // 8. Emit event showing USDC received (1:1 ratio)
        event::emit(
            WithdrawnEvent {
                user: user_addr,
                rusd_amount,
                usdc_amount,
                timestamp: now_seconds()
            }
        );
    }

    /// Admin function to manually add yield and distribute to all users
    public entry fun admin_increase_yield(admin: &signer, usdc_amount: u64) acquires YieldPool, RUSDToken {
        assert!(signer::address_of(admin) == @riverfi, error::permission_denied(E_ALREADY_INITIALIZED));
        assert!(usdc_amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        // Transfer USDC from admin to protocol
        let usdc_metadata = mock_usdc::get_token();
        primary_fungible_store::transfer(admin, usdc_metadata, @riverfi, usdc_amount);
        
        // Mint equivalent RUSD and distribute proportionally to all users
        let rusd_amount = usdc_amount; // 1:1 ratio
        
        let yield_pool = borrow_global<YieldPool>(@riverfi);
        if (yield_pool.auto_distribute_yield) {
            // Distribute automatically to all token holders
            distribute_yield_automatically(rusd_amount);
        } else {
            // Add to claimable pool for manual claims
            mint_rusd_to_pool(rusd_amount);
        };
        
        event::emit(ManualYieldAddedEvent {
            admin: signer::address_of(admin),
            usdc_amount,
            rusd_minted: rusd_amount,
            timestamp: now_seconds()
        });
    }
    
    /// Admin function to set annual APY rate
    public entry fun admin_set_annual_apy(admin: &signer, apy_bps: u64) acquires YieldPool {
        assert!(signer::address_of(admin) == @riverfi, error::permission_denied(E_ALREADY_INITIALIZED));
        assert!(apy_bps <= 5000, error::invalid_argument(E_ZERO_AMOUNT)); // Max 50% APY
        
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        let old_rate = yield_pool.annual_apy_bps;
        yield_pool.annual_apy_bps = apy_bps;
        
        event::emit(YieldRateChangedEvent {
            old_rate_bps: old_rate,
            new_rate_bps: apy_bps,
            admin: signer::address_of(admin),
            timestamp: now_seconds()
        });
    }
    
    /// Admin function to toggle auto-yield distribution
    public entry fun admin_set_auto_yield(admin: &signer, auto_distribute: bool) acquires YieldPool {
        assert!(signer::address_of(admin) == @riverfi, error::permission_denied(E_ALREADY_INITIALIZED));
        
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        yield_pool.auto_distribute_yield = auto_distribute;
    }
    
    /// Transfer RUSD tokens to another user
    public entry fun transfer(sender: &signer, to: address, amount: u64) acquires RUSDToken, YieldPool {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let from = signer::address_of(sender);
        assert!(from != to, error::invalid_argument(E_ZERO_AMOUNT));
        
        // Accrue yield before transfer to ensure accurate balances
        accrue_daily_yield_internal();
        
        // Claim pending yield rewards for both sender and recipient
        claim_yield_rewards(from);
        claim_yield_rewards(to);
        
        // Check sender has sufficient balance
        let rusd_token = get_rusd_token();
        let sender_balance = primary_fungible_store::balance(from, rusd_token);
        assert!(sender_balance >= amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));
        
        // Transfer RUSD tokens
        let rusd = borrow_global<RUSDToken>(@riverfi);
        primary_fungible_store::transfer_with_ref(
            &rusd.transfer_ref,
            from,
            to,
            amount
        );
        
        // Update yield debt for both sender and recipient after balance changes
        let sender_new_balance = get_user_balance(from);
        let recipient_new_balance = get_user_balance(to);
        update_user_yield_debt(from, sender_new_balance);
        update_user_yield_debt(to, recipient_new_balance);
        
        // Emit transfer event
        event::emit(TransferEvent {
            from,
            to,
            amount,
            timestamp: now_seconds()
        });
    }
    
    /// User function to claim daily yield (for manual claim mode only)
    public entry fun claim_daily_yield(user: &signer) acquires YieldPool, RUSDToken {
        let user_addr = signer::address_of(user);
        
        // Accrue yield first
        accrue_daily_yield_internal();
        
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        
        // This function only works when auto-distribute is disabled
        assert!(!yield_pool.auto_distribute_yield, error::invalid_state(E_ZERO_AMOUNT));
        
        // Calculate pending yield for user
        let pending_yield = calculate_pending_yield_internal(user_addr, yield_pool);
        assert!(pending_yield > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        // Update user's last claim timestamp
        if (table::contains(&yield_pool.user_last_claim_ts, user_addr)) {
            *table::borrow_mut(&mut yield_pool.user_last_claim_ts, user_addr) = now_seconds();
        } else {
            table::add(&mut yield_pool.user_last_claim_ts, user_addr, now_seconds());
        };
        
        // Transfer yield from pool to user
        transfer_rusd_from_pool(user_addr, pending_yield);
        
        event::emit(YieldClaimedEvent {
            user: user_addr,
            claimed_amount: pending_yield,
            timestamp: now_seconds()
        });
    }
    
    /// User function to claim accumulated yield rewards (for auto-distribute mode)
    public entry fun claim_rewards(user: &signer) acquires RUSDToken, YieldPool {
        let user_addr = signer::address_of(user);
        
        // Accrue yield first
        accrue_daily_yield_internal();
        
        let yield_pool = borrow_global<YieldPool>(@riverfi);
        
        // This function only works when auto-distribute is enabled
        assert!(yield_pool.auto_distribute_yield, error::invalid_state(E_ZERO_AMOUNT));
        
        // Claim any pending rewards
        claim_yield_rewards(user_addr);
    }

    /// Set allocation percentages (admin only)
    public entry fun admin_set_allocation(
        admin: &signer,
        tapp_percent: u8,
        hyperion_percent: u8,
        reserve_percent: u8
    ) acquires AllocationConfig {
        assert!(signer::address_of(admin) == @riverfi, error::permission_denied(E_ALREADY_INITIALIZED));
        assert!(tapp_percent + hyperion_percent + reserve_percent == 100, error::invalid_argument(E_ZERO_AMOUNT));
        
        let allocation_config = borrow_global_mut<AllocationConfig>(@riverfi);
        
        let old_tapp = allocation_config.tapp_percent;
        let old_hyperion = allocation_config.hyperion_percent;
        let old_reserve = allocation_config.reserve_percent;
        
        allocation_config.tapp_percent = tapp_percent;
        allocation_config.hyperion_percent = hyperion_percent;
        allocation_config.reserve_percent = reserve_percent;
        allocation_config.last_rebalance_ts = now_seconds();
        
        event::emit(AllocationUpdateEvent {
            old_tapp_percent: old_tapp,
            old_hyperion_percent: old_hyperion,
            old_reserve_percent: old_reserve,
            new_tapp_percent: tapp_percent,
            new_hyperion_percent: hyperion_percent,
            new_reserve_percent: reserve_percent,
            admin: signer::address_of(admin),
            timestamp: now_seconds()
        });
    }

    // -- View Functions
    #[view]
    public fun get_vault_stats(): (u64, u64, u64, u64) acquires Vault {
        let vault_addr = get_vault_address();
        let vault = borrow_global<Vault>(vault_addr);

        (vault.total_usdc, vault.total_rusd_supply, vault.hyperion_usdc, vault.reserve_usdc)
    }

    #[view]
    public fun get_vault_nav(): (u128, u128) acquires Vault {
        let vault_addr = get_vault_address();
        let vault = borrow_global<Vault>(vault_addr);
        
        // Get current values from mock protocols
        let tapp_value = if (vault.tapp_shares > 0) {
            tapp_exchange::get_vault_value(vault_addr)
        } else { 0 };
        
        let hyperion_value = if (vault.hyperion_lp_tokens > 0) {
            hyperion::get_vault_value(vault_addr)
        } else { 0 };
        
        let total_nav = tapp_value + hyperion_value + (vault.reserve_usdc as u128);
        (total_nav, vault.exchange_rate)
    }

    #[view]
    public fun get_protocol_positions(): (u128, u128, u64) acquires Vault {
        let vault_addr = get_vault_address();
        let vault = borrow_global<Vault>(vault_addr);
        (vault.tapp_shares, vault.hyperion_lp_tokens, vault.reserve_usdc)
    }

    #[view]
    public fun get_allocation_config(): (u8, u8, u8) acquires AllocationConfig {
        let config = borrow_global<AllocationConfig>(@riverfi);
        (config.tapp_percent, config.hyperion_percent, config.reserve_percent)
    }

    #[view]
    public fun projected_apy(): (u64, u64) {
        // Return projected APY from both protocols
        let tapp_apr = tapp_exchange::get_apr();
        let hyperion_apr = hyperion::get_apr();
        (tapp_apr, hyperion_apr)
    }

    /// Get user's current position with claimable yield
    #[view]
    public fun get_user_position(user: address): (u64, u64, u64, u128) acquires RUSDToken, Vault, YieldPool {
        let rusd_balance = get_user_balance(user);
        if (rusd_balance == 0) {
            return (0, 0, 0, 0)
        };
        
        let vault_addr = get_vault_address();
        let vault = borrow_global<Vault>(vault_addr);
        
        // Calculate pending claimable yield based on distribution mode
        let yield_pool = borrow_global<YieldPool>(@riverfi);
        let claimable_yield = if (yield_pool.auto_distribute_yield) {
            // For auto-distribute mode, show pending rewards
            calculate_pending_yield_reward(user)
        } else {
            // For manual claim mode, use the traditional calculation
            calculate_pending_yield_internal(user, yield_pool)
        };
        
        let exchange_rate = FIXED_EXCHANGE_RATE; // Always 1:1
        let usdc_value = rusd_balance; // 1:1 ratio with USDC
        
        (rusd_balance, usdc_value, claimable_yield, exchange_rate)
        // Returns: (RUSD tokens, Current USDC value, Claimable yield, Fixed exchange rate)
    }

    #[view]
    public fun get_user_balance(user: address): u64 acquires RUSDToken {
        let rusd_token = get_rusd_token();
        primary_fungible_store::balance(user, rusd_token)
    }

    /// Get yield pool stats
    #[view]
    public fun get_yield_pool_stats(): (u64, u64, u64, u64, bool) acquires YieldPool {
        let yield_pool = borrow_global<YieldPool>(@riverfi);
        (yield_pool.total_claimable_yield, yield_pool.total_rusd_earning, 
         yield_pool.annual_apy_bps, yield_pool.last_yield_accrual_ts, yield_pool.auto_distribute_yield)
    }
    
    /// Get user's pending claimable yield
    #[view]
    public fun get_pending_yield(user: address): u64 acquires YieldPool, RUSDToken {
        let yield_pool = borrow_global<YieldPool>(@riverfi);
        if (yield_pool.auto_distribute_yield) {
            calculate_pending_yield_reward(user)
        } else {
            calculate_pending_yield_internal(user, yield_pool)
        }
    }
    
    /// Get user's pending yield rewards (for auto-distribute mode)
    #[view]
    public fun get_pending_yield_rewards(user: address): u64 acquires RUSDToken, YieldPool {
        calculate_pending_yield_reward(user)
    }

    // -- Public Functions
    public fun get_rusd_token(): Object<Metadata> acquires RUSDToken {
        let rusd = borrow_global<RUSDToken>(@riverfi);
        rusd.token
    }

    public fun get_vault_address(): address {
        storage::get_child_object_address(VAULT_SEED)
    }

    // -- Private Functions
    fun init_vault() {
        let account_addr = storage::get_child_object_address(VAULT_SEED);
        assert!(!exists<Vault>(account_addr));

        let extend_ref = storage::create_child_object_with_phantom_owner(VAULT_SEED);
        let account_signer = object::generate_signer_for_extending(&extend_ref);

        move_to(&account_signer, Vault {
            extend_ref,
            total_usdc: 0,
            total_rusd_supply: 0,
            
            // Mock Protocol Positions
            tapp_shares: 0,
            hyperion_lp_tokens: 0,
            
            // Fixed exchange rate (always 1:1)
            exchange_rate: FIXED_EXCHANGE_RATE,
            last_harvest_ts: now_seconds(),
            
            // Legacy fields (kept for compatibility)
            hyperion_usdc: 0,
            hyperion_positions: vector::empty(),
            reserve_usdc: 0,
        });
    }

    fun init_rusd_token(sender: &signer) {
        let constructor_ref = &object::create_sticky_object(@riverfi);
        let token_address = object::address_from_constructor_ref(constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            string::utf8(RUSD_TOKEN_NAME),
            string::utf8(RUSD_TOKEN_SYMBOL),
            RUSD_TOKEN_DECIMALS,
            string::utf8(b"https://river.finance/icon.png"),
            string::utf8(b"https://river.finance")
        );

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
        let extend_ref = object::generate_extend_ref(constructor_ref);

        move_to(
            sender,
            RUSDToken {
                token: object::address_to_object(token_address),
                mint_ref,
                transfer_ref,
                burn_ref,
                extend_ref
            }
        );
    }

    fun mint_rusd(recipient: address, amount: u64) acquires RUSDToken {
        let rusd = borrow_global<RUSDToken>(@riverfi);
        let fa = fungible_asset::mint(&rusd.mint_ref, amount);
        primary_fungible_store::deposit(recipient, fa);
    }

    fun burn_rusd(owner: address, amount: u64) acquires RUSDToken {
        let rusd = borrow_global<RUSDToken>(@riverfi);
        primary_fungible_store::burn(&rusd.burn_ref, owner, amount);
    }

    fun get_vault_signer(vault: &Vault): signer {
        object::generate_signer_for_extending(&vault.extend_ref)
    }
    
    /// Mint RUSD tokens to the yield pool
    fun mint_rusd_to_pool(amount: u64) acquires RUSDToken, YieldPool {
        let rusd = borrow_global<RUSDToken>(@riverfi);
        let fa = fungible_asset::mint(&rusd.mint_ref, amount);
        
        // Deposit to yield pool (held by protocol)
        primary_fungible_store::deposit(@riverfi, fa);
        
        // Update yield pool accounting
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        yield_pool.total_claimable_yield = yield_pool.total_claimable_yield + amount;
    }
    
    /// Transfer RUSD from yield pool to user
    fun transfer_rusd_from_pool(recipient: address, amount: u64) acquires RUSDToken, YieldPool {
        // Transfer from protocol's balance to user
        let rusd_token = get_rusd_token();
        primary_fungible_store::transfer_with_ref(
            &borrow_global<RUSDToken>(@riverfi).transfer_ref,
            @riverfi,
            recipient,
            amount
        );
        
        // Update yield pool accounting
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        yield_pool.total_claimable_yield = yield_pool.total_claimable_yield - amount;
    }

    /// Accrue daily yield based on APY and distribute automatically or to pool
    fun accrue_daily_yield_internal() acquires YieldPool, RUSDToken {
        let current_time = now_seconds();
        let (total_earning, annual_apy_bps, last_accrual, auto_distribute) = {
            let yield_pool = borrow_global<YieldPool>(@riverfi);
            (yield_pool.total_rusd_earning, yield_pool.annual_apy_bps, 
             yield_pool.last_yield_accrual_ts, yield_pool.auto_distribute_yield)
        };
        
        // Check if a day has passed since last accrual
        let time_since_last_accrual = current_time - last_accrual;
        let days_passed = time_since_last_accrual / SECONDS_PER_DAY;
        
        if (days_passed == 0 || total_earning == 0) {
            return
        };
        
        // Calculate daily yield from annual APY
        // Daily rate = Annual APY / 365 days
        let daily_rate_bps = annual_apy_bps / (DAYS_PER_YEAR as u64);
        let daily_yield = (total_earning * daily_rate_bps) / 10000;
        let total_yield_to_accrue = daily_yield * days_passed;
        
        if (total_yield_to_accrue > 0) {
            if (auto_distribute) {
                // Automatically distribute yield to all token holders proportionally
                distribute_yield_automatically(total_yield_to_accrue);
            } else {
                // Add to claimable pool for manual claims
                mint_rusd_to_pool(total_yield_to_accrue);
            };
            
            // Update last accrual timestamp
            let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
            yield_pool.last_yield_accrual_ts = current_time;
            
            event::emit(DailyYieldAccruedEvent {
                total_earning_rusd: total_earning,
                daily_rate_bps: daily_rate_bps,
                yield_accrued: total_yield_to_accrue,
                timestamp: current_time
            });
        };
    }
    
    /// Calculate pending yield for a user
    fun calculate_pending_yield_internal(user: address, yield_pool: &YieldPool): u64 acquires RUSDToken {
        // If auto-distribution is enabled, users don't need to claim manually
        if (yield_pool.auto_distribute_yield) {
            return 0 // Yield is automatically distributed
        };
        
        if (yield_pool.total_rusd_earning == 0 || yield_pool.total_claimable_yield == 0) {
            return 0
        };
        
        // Get user's RUSD balance (their share of earning tokens)
        let user_balance = if (exists<RUSDToken>(@riverfi)) {
            let rusd_token = borrow_global<RUSDToken>(@riverfi);
            primary_fungible_store::balance(user, rusd_token.token)
        } else {
            0
        };
        
        if (user_balance == 0) {
            return 0
        };
        
        // Calculate user's share of yield pool
        let user_yield_share = (user_balance * yield_pool.total_claimable_yield) / yield_pool.total_rusd_earning;
        
        // Check if user has claimed recently (only for manual claim mode)
        if (table::contains(&yield_pool.user_last_claim_ts, user)) {
            let last_claim_time = *table::borrow(&yield_pool.user_last_claim_ts, user);
            let time_since_claim = now_seconds() - last_claim_time;
            
            // Only allow claiming once per day (86400 seconds)
            if (time_since_claim < SECONDS_PER_DAY) {
                return 0
            };
        };
        
        user_yield_share
    }
    
    /// Automatically distribute yield to all RUSD token holders proportionally
    /// Using a reward pool mechanism where yield is accumulated per token
    fun distribute_yield_automatically(total_yield: u64) acquires RUSDToken, YieldPool {
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        
        // If no one is earning, add to claimable pool instead
        if (yield_pool.total_rusd_earning == 0) {
            mint_rusd_to_pool(total_yield);
            return
        };
        
        // Calculate yield per token (scaled by 1e12 for precision) - use safer math
        let yield_per_token = if (yield_pool.total_rusd_earning > 0) {
            let total_yield_u128 = (total_yield as u128);
            let scale_u128 = 1000000000000u128;
            let earning_u128 = (yield_pool.total_rusd_earning as u128);
            ((total_yield_u128 * scale_u128) / earning_u128 as u64)
        } else {
            0
        };
        yield_pool.yield_per_token_accumulated = yield_pool.yield_per_token_accumulated + yield_per_token;
        
        // Mint the yield tokens to the protocol balance (acts as reward pool)
        let rusd = borrow_global<RUSDToken>(@riverfi);
        let fa = fungible_asset::mint(&rusd.mint_ref, total_yield);
        primary_fungible_store::deposit(@riverfi, fa);
        
        // Update tracking
        yield_pool.total_yield_distributed = yield_pool.total_yield_distributed + total_yield;
        yield_pool.last_distribution_time = now_seconds();
        
        // Emit distribution event
        event::emit(YieldDistributedEvent {
            total_amount: total_yield,
            distributed_to_holders: true,
            timestamp: now_seconds()
        });
    }
    
    /// Calculate pending yield reward for a user based on their balance
    fun calculate_pending_yield_reward(user: address): u64 acquires RUSDToken, YieldPool {
        let yield_pool = borrow_global<YieldPool>(@riverfi);
        let user_balance = get_user_balance(user);
        
        if (user_balance == 0 || !yield_pool.auto_distribute_yield) {
            return 0
        };
        
        let user_yield_debt = if (table::contains(&yield_pool.user_yield_debt, user)) {
            *table::borrow(&yield_pool.user_yield_debt, user)
        } else {
            0
        };
        
        // Use safer math to prevent overflow: divide first, then multiply
        // This may reduce precision slightly but prevents overflow
        let accumulated_yield = if (yield_pool.yield_per_token_accumulated > 0) {
            let user_balance_u128 = (user_balance as u128);
            let yield_per_token_u128 = (yield_pool.yield_per_token_accumulated as u128);
            let result = user_balance_u128 * yield_per_token_u128 / 1000000000000;
            (result as u64)
        } else {
            0
        };
        
        if (accumulated_yield > user_yield_debt) {
            accumulated_yield - user_yield_debt
        } else {
            0
        }
    }
    
    /// Update user yield debt when their balance changes
    fun update_user_yield_debt(user: address, new_balance: u64) acquires YieldPool {
        let yield_pool = borrow_global_mut<YieldPool>(@riverfi);
        // Use safer math to prevent overflow
        let new_debt = if (yield_pool.yield_per_token_accumulated > 0) {
            let new_balance_u128 = (new_balance as u128);
            let yield_per_token_u128 = (yield_pool.yield_per_token_accumulated as u128);
            let result = new_balance_u128 * yield_per_token_u128 / 1000000000000;
            (result as u64)
        } else {
            0
        };
        
        if (table::contains(&yield_pool.user_yield_debt, user)) {
            *table::borrow_mut(&mut yield_pool.user_yield_debt, user) = new_debt;
        } else {
            table::add(&mut yield_pool.user_yield_debt, user, new_debt);
        };
    }
    
    /// Claim pending yield rewards for a user (for auto-distribute mode)
    fun claim_yield_rewards(user: address) acquires RUSDToken, YieldPool {
        let pending_yield = calculate_pending_yield_reward(user);
        
        if (pending_yield > 0) {
            // Check if protocol has enough balance to cover the reward
            let rusd_token = get_rusd_token();
            let protocol_balance = primary_fungible_store::balance(@riverfi, rusd_token);
            
            if (protocol_balance >= pending_yield) {
                // Transfer yield from protocol balance to user
                let rusd_ref = &borrow_global<RUSDToken>(@riverfi).transfer_ref;
                primary_fungible_store::transfer_with_ref(
                    rusd_ref,
                    @riverfi,
                    user,
                    pending_yield
                );
                
                // Update user's yield debt
                let user_balance = get_user_balance(user);
                update_user_yield_debt(user, user_balance);
            };
            // If protocol doesn't have enough balance, skip claiming (no error)
        };
    }

    // -- Private Functions
    
    /// Unwind protocol positions to provide liquidity for withdrawals
    fun unwind_positions_for_liquidity(vault_signer: &signer, vault: &mut Vault, needed_amount: u64) acquires AllocationConfig {
        let vault_addr = signer::address_of(vault_signer);
        let allocation_config = borrow_global<AllocationConfig>(@riverfi);
        let remaining_needed = needed_amount;
        
        // Try to get liquidity proportionally from protocols based on allocation
        let total_protocol_percent = allocation_config.tapp_percent + allocation_config.hyperion_percent;
        if (total_protocol_percent == 0) return; // No protocols to unwind
        
        // Calculate how much to withdraw from each protocol
        let tapp_target = (remaining_needed * (allocation_config.tapp_percent as u64)) / (total_protocol_percent as u64);
        let hyperion_target = remaining_needed - tapp_target;
        
        // Unwind from Tapp Exchange
        if (tapp_target > 0 && vault.tapp_shares > 0) {
            let tapp_current_value = tapp_exchange::get_vault_value(vault_addr);
            if (tapp_current_value > 0) {
                let shares_to_withdraw = if (tapp_target >= (tapp_current_value as u64)) {
                    // Withdraw all shares
                    vault.tapp_shares
                } else {
                    // Withdraw proportional shares
                    (vault.tapp_shares * (tapp_target as u128)) / tapp_current_value
                };
                
                if (shares_to_withdraw > 0) {
                    let received = tapp_exchange::vault_withdraw(vault_signer, shares_to_withdraw);
                    vault.tapp_shares = vault.tapp_shares - shares_to_withdraw;
                    vault.reserve_usdc = vault.reserve_usdc + received;
                };
            };
        };
        
        // Unwind from Hyperion
        if (hyperion_target > 0 && vault.hyperion_lp_tokens > 0) {
            let hyperion_current_value = hyperion::get_vault_value(vault_addr);
            if (hyperion_current_value > 0) {
                let lp_tokens_to_withdraw = if (hyperion_target >= (hyperion_current_value as u64)) {
                    // Withdraw all LP tokens
                    vault.hyperion_lp_tokens
                } else {
                    // Withdraw proportional LP tokens
                    (vault.hyperion_lp_tokens * (hyperion_target as u128)) / hyperion_current_value
                };
                
                if (lp_tokens_to_withdraw > 0) {
                    let received = hyperion::vault_remove_liquidity(vault_signer, lp_tokens_to_withdraw);
                    vault.hyperion_lp_tokens = vault.hyperion_lp_tokens - lp_tokens_to_withdraw;
                    vault.reserve_usdc = vault.reserve_usdc + received;
                };
            };
        };
    }
    
    /// Compound yields in protocols (for internal accounting)
    fun compound_protocol_yields_internal() acquires Vault {
        let vault_addr = get_vault_address();
        let vault = borrow_global_mut<Vault>(vault_addr);
        
        // Skip if no RUSD supply
        if (vault.total_rusd_supply == 0) {
            return
        };
        
        // Compound yields in both protocols (for their internal tracking)
        if (vault.tapp_shares > 0) {
            tapp_exchange::compound_yield();
        };
        
        if (vault.hyperion_lp_tokens > 0) {
            hyperion::compound_rewards();
        };
        
        // Calculate current NAV for event tracking
        let tapp_value = if (vault.tapp_shares > 0) {
            tapp_exchange::get_vault_value(vault_addr)
        } else { 0 };
        
        let hyperion_value = if (vault.hyperion_lp_tokens > 0) {
            hyperion::get_vault_value(vault_addr)
        } else { 0 };
        
        let total_nav = tapp_value + hyperion_value;
        
        // Exchange rate remains fixed
        vault.exchange_rate = FIXED_EXCHANGE_RATE;
        vault.last_harvest_ts = now_seconds();
        
        // Emit harvest event (without exchange rate changes)
        event::emit(HarvestEvent {
            tapp_value,
            hyperion_value,
            total_nav,
            old_exchange_rate: FIXED_EXCHANGE_RATE,
            new_exchange_rate: FIXED_EXCHANGE_RATE,
            yield_earned: 0, // No yield earned through exchange rate
            timestamp: now_seconds()
        });
    }

    // -- Test Only
    #[test_only]
    public fun init_module_for_testing(sender: &signer) {
        init_module(sender)
    }
    
    #[test_only]
    public fun get_fixed_exchange_rate(): u128 {
        FIXED_EXCHANGE_RATE
    }
}
