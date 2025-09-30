module riverfi::vault {
    use std::signer;
    use std::error;
    use std::string;
    use std::option;
    use std::vector;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, TransferRef, BurnRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp::now_seconds;

    use riverfi::storage;
    use riverfi::tapp_exchange;
    use riverfi::hyperion;
    use riverfi::yield_math;
    use riverfi::mock_usdc;
    use riverfi::hyperion_strategy;

    // -- Constants
    const RUSDC_TOKEN_NAME: vector<u8> = b"River USDC";
    const RUSDC_TOKEN_SYMBOL: vector<u8> = b"RUSDC";
    const RUSDC_TOKEN_DECIMALS: u8 = 6;
    const VAULT_SEED: vector<u8> = b"vault::VAULT";

    // Mock Protocol allocation (50% Tapp, 30% Hyperion, 20% Reserve)
    const DEFAULT_TAPP_ALLOCATION_PERCENT: u8 = 50;   // 50% to Tapp Exchange
    const DEFAULT_HYPERION_ALLOCATION_PERCENT: u8 = 30; // 30% to Hyperion
    const DEFAULT_RESERVE_ALLOCATION_PERCENT: u8 = 20; // 20% instant liquidity
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

    struct RUSDCToken has key {
        token: Object<Metadata>,
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef,
        extend_ref: ExtendRef
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Vault has key {
        extend_ref: ExtendRef,
        total_usdc: u64,
        total_rusdc_supply: u64,
        reserve_usdc: u64,   // Amount kept in vault for instant withdrawals
        
        // Mock Protocol Positions
        tapp_shares: u128,      // Shares in Tapp Exchange
        hyperion_lp_tokens: u128, // LP tokens in Hyperion
        
        // NAV tracking
        exchange_rate: u128,    // USDC per RUSDC (scaled by 1e12)
        last_harvest_ts: u64,   // Last time yields were harvested
        
        // Legacy Hyperion positions (for backward compatibility)
        hyperion_positions: vector<Object<riverfi::hyperion_strategy::Info>>,
        hyperion_usdc: u64,  // Amount deposited to real Hyperion
    }

    // -- Events
    #[event]
    struct DepositedEvent has drop, store {
        user: address,
        usdc_amount: u64,
        rusdc_amount: u64,
        timestamp: u64
    }

    #[event]
    struct WithdrawnEvent has drop, store {
        user: address,
        rusdc_amount: u64,
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

        init_rusdc_token(sender);
    }

    // -- Public Entry Functions
    public entry fun deposit(sender: &signer, amount: u64) acquires Config, RUSDCToken, Vault, AllocationConfig {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));

        let config = borrow_global<Config>(@riverfi);
        assert!(config.enable_deposit, error::permission_denied(E_ALREADY_INITIALIZED));

        let user_addr = signer::address_of(sender);
        let vault_addr = get_vault_address();
        
        // Harvest existing yield before new deposit
        harvest_yield_internal();
        
        let vault = borrow_global_mut<Vault>(vault_addr);

        // 1. Transfer USDC from user to vault
        let usdc_metadata = mock_usdc::get_token();
        primary_fungible_store::transfer(sender, usdc_metadata, vault_addr, amount);

        // 2. Calculate allocation amounts
        let allocation_config = borrow_global<AllocationConfig>(@riverfi);
        let tapp_amount = (amount * (allocation_config.tapp_percent as u64)) / 100;
        let hyperion_amount = (amount * (allocation_config.hyperion_percent as u64)) / 100;
        let reserve_amount = amount - tapp_amount - hyperion_amount;

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

        // 6. Keep remainder in reserve
        vault.reserve_usdc = vault.reserve_usdc + reserve_amount;

        // 7. Mint RUSDC based on current exchange rate
        let rusdc_to_mint = if (vault.exchange_rate == 0) {
            // First deposit: 1:1 ratio
            vault.exchange_rate = yield_math::get_precision(); // 1.0 with precision
            (amount as u128)
        } else {
            // Calculate RUSDC amount based on current exchange rate
            ((amount as u128) * yield_math::get_precision()) / vault.exchange_rate
        };
        
        mint_rusdc(user_addr, (rusdc_to_mint as u64));

        // 8. Update total stats
        vault.total_usdc = vault.total_usdc + amount;
        vault.total_rusdc_supply = vault.total_rusdc_supply + (rusdc_to_mint as u64);

        // 9. Emit event
        event::emit(
            DepositedEvent {
                user: user_addr,
                usdc_amount: amount,
                rusdc_amount: (rusdc_to_mint as u64),
                timestamp: now_seconds()
            }
        );
    }

    public entry fun withdraw(sender: &signer, rusdc_amount: u64) acquires Config, RUSDCToken, Vault, AllocationConfig {
        assert!(rusdc_amount > 0, error::invalid_argument(E_ZERO_AMOUNT));

        let config = borrow_global<Config>(@riverfi);
        assert!(config.enable_withdraw, error::permission_denied(E_ALREADY_INITIALIZED));

        let user_addr = signer::address_of(sender);
        let vault_addr = get_vault_address();
        
        // 1. Harvest yield first to get latest exchange rate
        harvest_yield_internal();
        
        let vault = borrow_global_mut<Vault>(vault_addr);

        // 2. Check user has enough RUSDC
        let rusdc_token = get_rusdc_token();
        let user_rusdc_balance = primary_fungible_store::balance(user_addr, rusdc_token);
        assert!(user_rusdc_balance >= rusdc_amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // 3. Calculate USDC amount using current exchange rate (INCLUDING YIELD!)
        let usdc_to_receive = if (vault.exchange_rate == 0) {
            vault.exchange_rate = yield_math::get_precision(); // Initialize if needed
            (rusdc_amount as u128)
        } else {
            // USDC = RUSDC × exchange_rate ÷ precision
            ((rusdc_amount as u128) * vault.exchange_rate) / yield_math::get_precision()
        };
        let usdc_amount = (usdc_to_receive as u64);

        // 4. Ensure we have enough liquidity - unwind positions if needed
        let vault_signer = get_vault_signer(vault);
        
        if (vault.reserve_usdc < usdc_amount) {
            // Need to withdraw from protocols to cover the shortfall
            let shortfall = usdc_amount - vault.reserve_usdc;
            unwind_positions_for_liquidity(&vault_signer, vault, shortfall);
        };

        // 5. Burn RUSDC from user
        burn_rusdc(user_addr, rusdc_amount);

        // 6. Transfer USDC to user (with yield included!)
        let usdc_metadata = mock_usdc::get_token();
        primary_fungible_store::transfer(&vault_signer, usdc_metadata, user_addr, usdc_amount);

        // 7. Update vault stats
        vault.total_usdc = if (vault.total_usdc >= usdc_amount) {
            vault.total_usdc - usdc_amount
        } else { 0 };
        vault.total_rusdc_supply = vault.total_rusdc_supply - rusdc_amount;
        vault.reserve_usdc = if (vault.reserve_usdc >= usdc_amount) {
            vault.reserve_usdc - usdc_amount
        } else { 0 };

        // 8. Emit event showing actual USDC received (including yield)
        event::emit(
            WithdrawnEvent {
                user: user_addr,
                rusdc_amount,
                usdc_amount,
                timestamp: now_seconds()
            }
        );
    }

    /// Harvest yield from mock protocols and update RUSDC exchange rate
    public entry fun harvest_yield() acquires Vault {
        harvest_yield_internal();
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

        (vault.total_usdc, vault.total_rusdc_supply, vault.hyperion_usdc, vault.reserve_usdc)
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

    /// Get user's current position with yield preview
    #[view]
    public fun get_user_position(user: address): (u64, u64, u64, u128) acquires RUSDCToken, Vault {
        let rusdc_balance = get_user_balance(user);
        if (rusdc_balance == 0) {
            return (0, 0, 0, 0)
        };
        
        let vault_addr = get_vault_address();
        let vault = borrow_global<Vault>(vault_addr);
        
        let exchange_rate = if (vault.exchange_rate == 0) {
            yield_math::get_precision() // 1.0
        } else {
            vault.exchange_rate
        };
        
        let usdc_value = (((rusdc_balance as u128) * exchange_rate) / yield_math::get_precision() as u64);
        let yield_earned = if (usdc_value > rusdc_balance) {
            usdc_value - rusdc_balance
        } else { 0 };
        
        (rusdc_balance, usdc_value, yield_earned, exchange_rate)
        // Returns: (RUSDC tokens, Current USDC value, Yield earned, Current exchange rate)
    }

    #[view]
    public fun get_user_balance(user: address): u64 acquires RUSDCToken {
        let rusdc_token = get_rusdc_token();
        primary_fungible_store::balance(user, rusdc_token)
    }

    // -- Public Functions
    public fun get_rusdc_token(): Object<Metadata> acquires RUSDCToken {
        let rusdc = borrow_global<RUSDCToken>(@riverfi);
        rusdc.token
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
            total_rusdc_supply: 0,
            reserve_usdc: 0,
            
            // Mock Protocol Positions
            tapp_shares: 0,
            hyperion_lp_tokens: 0,
            
            // NAV tracking
            exchange_rate: 0,
            last_harvest_ts: now_seconds(),
            
            // Legacy fields
            hyperion_usdc: 0,
            hyperion_positions: vector::empty(),
        });
    }

    fun init_rusdc_token(sender: &signer) {
        let constructor_ref = &object::create_sticky_object(@riverfi);
        let token_address = object::address_from_constructor_ref(constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            string::utf8(RUSDC_TOKEN_NAME),
            string::utf8(RUSDC_TOKEN_SYMBOL),
            RUSDC_TOKEN_DECIMALS,
            string::utf8(b"https://river.finance/icon.png"),
            string::utf8(b"https://river.finance")
        );

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
        let extend_ref = object::generate_extend_ref(constructor_ref);

        move_to(
            sender,
            RUSDCToken {
                token: object::address_to_object(token_address),
                mint_ref,
                transfer_ref,
                burn_ref,
                extend_ref
            }
        );
    }

    fun mint_rusdc(recipient: address, amount: u64) acquires RUSDCToken {
        let rusdc = borrow_global<RUSDCToken>(@riverfi);
        let fa = fungible_asset::mint(&rusdc.mint_ref, amount);
        primary_fungible_store::deposit(recipient, fa);
    }

    fun burn_rusdc(owner: address, amount: u64) acquires RUSDCToken {
        let rusdc = borrow_global<RUSDCToken>(@riverfi);
        primary_fungible_store::burn(&rusdc.burn_ref, owner, amount);
    }

    fun get_vault_signer(vault: &Vault): signer {
        object::generate_signer_for_extending(&vault.extend_ref)
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
    
    fun harvest_yield_internal() acquires Vault {
        let vault_addr = get_vault_address();
        let vault = borrow_global_mut<Vault>(vault_addr);
        
        // Skip if no RUSDC supply
        if (vault.total_rusdc_supply == 0) {
            return
        };
        
        // Compound yields in both protocols
        if (vault.tapp_shares > 0) {
            tapp_exchange::compound_yield();
        };
        
        if (vault.hyperion_lp_tokens > 0) {
            hyperion::compound_rewards();
        };
        
        // Calculate current NAV
        let tapp_value = if (vault.tapp_shares > 0) {
            tapp_exchange::get_vault_value(vault_addr)
        } else { 0 };
        
        let hyperion_value = if (vault.hyperion_lp_tokens > 0) {
            hyperion::get_vault_value(vault_addr)
        } else { 0 };
        
        let total_nav = tapp_value + hyperion_value + (vault.reserve_usdc as u128);
        
        // Calculate new exchange rate
        let old_exchange_rate = vault.exchange_rate;
        if (old_exchange_rate == 0) {
            vault.exchange_rate = yield_math::get_precision(); // Initialize to 1.0
        } else {
            // New rate = total_nav / total_rusdc_supply
            vault.exchange_rate = (total_nav * yield_math::get_precision()) / (vault.total_rusdc_supply as u128);
        };
        
        let yield_earned = if (vault.exchange_rate > old_exchange_rate && old_exchange_rate > 0) {
            // Calculate yield in USDC terms
            let old_nav = (old_exchange_rate * (vault.total_rusdc_supply as u128)) / yield_math::get_precision();
            total_nav - old_nav
        } else {
            0
        };
        
        vault.last_harvest_ts = now_seconds();
        
        // Emit harvest event
        event::emit(HarvestEvent {
            tapp_value,
            hyperion_value,
            total_nav,
            old_exchange_rate,
            new_exchange_rate: vault.exchange_rate,
            yield_earned,
            timestamp: now_seconds()
        });
        
        if (vault.exchange_rate != old_exchange_rate) {
            event::emit(ExchangeRateUpdateEvent {
                old_rate: old_exchange_rate,
                new_rate: vault.exchange_rate,
                timestamp: now_seconds()
            });
        };
    }

    // -- Test Only
    #[test_only]
    public fun init_module_for_testing(sender: &signer) {
        init_module(sender)
    }
}
