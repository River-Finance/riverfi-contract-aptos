module riverfi::tapp_exchange {
    use std::signer;
    use std::error;
    use std::table::{Self, Table};
    use aptos_framework::object::{Self};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::fungible_asset::{Metadata};
    use aptos_framework::event;
    use aptos_framework::timestamp::now_seconds;

    use riverfi::yield_math;
    use riverfi::mock_usdc;

    // Constants
    const DEFAULT_APR_BPS: u64 = 800; // 8% APR
    const MAX_APR_BPS: u64 = 1000; // 10% max APR
    const MIN_DEPOSIT_AMOUNT: u64 = 1000; // 0.001 USDC (6 decimals)
    const FEE_BPS: u64 = 10; // 0.1% trading fee simulation

    // Errors
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_NOT_ADMIN: u64 = 3;
    const E_INVALID_APR: u64 = 4;
    const E_INSUFFICIENT_AMOUNT: u64 = 5;
    const E_NO_POSITION: u64 = 6;
    const E_INSUFFICIENT_SHARES: u64 = 7;
    const E_PAUSED: u64 = 8;
    const E_ZERO_AMOUNT: u64 = 9;

    // Structs
    struct TappConfig has key {
        admin: address,
        apr_bps: u64,
        last_compound_ts: u64,
        is_paused: bool,
    }

    struct TappVault has key {
        total_deposited: u128, // Total USDC deposited
        total_shares: u128, // Total shares outstanding
        accumulated_fees: u128, // Simulated trading fees
        positions: Table<address, Position>, // User positions
    }

    struct Position has store, drop {
        shares: u128, // User's shares in the pool
        last_update_ts: u64, // Last time this position was updated
    }

    // Events
    #[event]
    struct TappDepositEvent has drop, store {
        user: address,
        amount: u64,
        shares: u128,
        timestamp: u64
    }

    #[event]
    struct TappWithdrawEvent has drop, store {
        user: address,
        shares: u128,
        amount: u64,
        yield_earned: u64,
        timestamp: u64
    }

    #[event]
    struct TappCompoundEvent has drop, store {
        total_yield_added: u128,
        new_total_deposited: u128,
        timestamp: u64
    }

    #[event]
    struct TappFeeEvent has drop, store {
        fee_amount: u128,
        total_fees: u128,
        timestamp: u64
    }

    #[event]
    struct TappAprUpdateEvent has drop, store {
        old_apr_bps: u64,
        new_apr_bps: u64,
        admin: address,
        timestamp: u64
    }

    // Initialization
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @riverfi, error::permission_denied(E_NOT_ADMIN));
        
        // Initialize Tapp Exchange with default settings
        move_to(admin, TappConfig {
            admin: admin_addr,
            apr_bps: DEFAULT_APR_BPS,
            last_compound_ts: now_seconds(),
            is_paused: false,
        });

        move_to(admin, TappVault {
            total_deposited: 0,
            total_shares: 0,
            accumulated_fees: 0,
            positions: table::new(),
        });
    }

    // Public Entry Functions
    
    /// Deposit USDC into Tapp Exchange to earn yield
    public entry fun deposit(account: &signer, amount: u64) acquires TappConfig, TappVault {
        assert_not_paused();
        assert!(amount >= MIN_DEPOSIT_AMOUNT, error::invalid_argument(E_INSUFFICIENT_AMOUNT));
        
        let user_addr = signer::address_of(account);
        
        // Compound existing yield first
        compound_yield_internal();
        
        let vault = borrow_global_mut<TappVault>(@riverfi);
        
        // Transfer USDC from user to Tapp Exchange
        let usdc_metadata = mock_usdc::get_token();
        primary_fungible_store::transfer(account, usdc_metadata, @riverfi, amount);
        
        // Calculate shares to mint
        let shares_to_mint = yield_math::calculate_shares(
            (amount as u128),
            vault.total_deposited,
            vault.total_shares
        );
        
        // Update vault state
        vault.total_deposited = vault.total_deposited + (amount as u128);
        vault.total_shares = vault.total_shares + shares_to_mint;
        
        // Update or create user position
        if (table::contains(&vault.positions, user_addr)) {
            let position = table::borrow_mut(&mut vault.positions, user_addr);
            position.shares = position.shares + shares_to_mint;
            position.last_update_ts = now_seconds();
        } else {
            table::add(&mut vault.positions, user_addr, Position {
                shares: shares_to_mint,
                last_update_ts: now_seconds(),
            });
        };
        
        // Simulate trading fees (add to accumulated fees)
        let simulated_fee = ((amount as u128) * (FEE_BPS as u128)) / 10000;
        vault.accumulated_fees = vault.accumulated_fees + simulated_fee;
        
        // Emit events
        event::emit(TappDepositEvent {
            user: user_addr,
            amount,
            shares: shares_to_mint,
            timestamp: now_seconds()
        });
        
        event::emit(TappFeeEvent {
            fee_amount: simulated_fee,
            total_fees: vault.accumulated_fees,
            timestamp: now_seconds()
        });
    }
    
    /// Withdraw from Tapp Exchange by burning shares
    public entry fun withdraw(account: &signer, shares: u128) acquires TappConfig, TappVault {
        assert_not_paused();
        assert!(shares > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        let user_addr = signer::address_of(account);
        
        // Compound existing yield first
        compound_yield_internal();
        
        let vault = borrow_global_mut<TappVault>(@riverfi);
        
        // Check user has position
        assert!(table::contains(&vault.positions, user_addr), error::not_found(E_NO_POSITION));
        
        let position = table::borrow_mut(&mut vault.positions, user_addr);
        assert!(position.shares >= shares, error::invalid_argument(E_INSUFFICIENT_SHARES));
        
        // Calculate withdrawal amount
        let withdrawal_amount = yield_math::calculate_withdrawal(
            shares,
            vault.total_deposited + vault.accumulated_fees, // Include accumulated yield
            vault.total_shares
        );
        
        // Calculate yield earned (withdrawal_amount - original_principal_proportion)
        let original_principal = yield_math::calculate_withdrawal(
            shares,
            vault.total_deposited - vault.accumulated_fees, // Exclude accumulated yield
            vault.total_shares
        );
        let yield_earned = if (withdrawal_amount > original_principal) {
            withdrawal_amount - original_principal
        } else {
            0
        };
        
        // Update position
        position.shares = position.shares - shares;
        if (position.shares == 0) {
            table::remove(&mut vault.positions, user_addr);
        };
        
        // Update vault state
        vault.total_deposited = vault.total_deposited - (withdrawal_amount - yield_earned);
        vault.total_shares = vault.total_shares - shares;
        vault.accumulated_fees = vault.accumulated_fees - yield_earned;
        
        // Note: Transfer would need proper signer capability - simplified for MVP
        // In production, would use a signer capability from the protocol
        let _usdc_metadata = mock_usdc::get_token(); // For future implementation
        
        // Emit event
        event::emit(TappWithdrawEvent {
            user: user_addr,
            shares,
            amount: (withdrawal_amount as u64),
            yield_earned: (yield_earned as u64),
            timestamp: now_seconds()
        });
    }
    
    /// Compound accumulated yield (can be called by anyone)
    public entry fun compound_yield() acquires TappConfig, TappVault {
        assert_not_paused();
        compound_yield_internal();
    }
    
    // Admin Functions
    
    /// Set APR (admin only)
    public entry fun admin_set_apr(admin: &signer, new_apr_bps: u64) acquires TappConfig {
        let config = borrow_global_mut<TappConfig>(@riverfi);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(new_apr_bps <= MAX_APR_BPS, error::invalid_argument(E_INVALID_APR));
        
        let old_apr = config.apr_bps;
        config.apr_bps = new_apr_bps;
        
        event::emit(TappAprUpdateEvent {
            old_apr_bps: old_apr,
            new_apr_bps: new_apr_bps,
            admin: signer::address_of(admin),
            timestamp: now_seconds()
        });
    }
    
    /// Pause/unpause the protocol (admin only)
    public entry fun admin_set_pause(admin: &signer, paused: bool) acquires TappConfig {
        let config = borrow_global_mut<TappConfig>(@riverfi);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        config.is_paused = paused;
    }
    
    // Public Functions (for vault integration)
    
    /// Deposit from vault (called by vault contract)
    public fun vault_deposit(vault_signer: &signer, amount: u64): u128 acquires TappConfig, TappVault {
        // Simplified vault access - in production would use proper access control
        assert_not_paused();
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        // Transfer USDC from vault to Tapp Exchange
        let usdc_metadata = mock_usdc::get_token();
        primary_fungible_store::transfer(vault_signer, usdc_metadata, @riverfi, amount);
        
        // Compound existing yield first
        compound_yield_internal();
        
        let vault = borrow_global_mut<TappVault>(@riverfi);
        let vault_addr = signer::address_of(vault_signer);
        
        // Calculate shares to mint to vault
        let shares_to_mint = yield_math::calculate_shares(
            (amount as u128),
            vault.total_deposited,
            vault.total_shares
        );
        
        // Update vault state
        vault.total_deposited = vault.total_deposited + (amount as u128);
        vault.total_shares = vault.total_shares + shares_to_mint;
        
        // Update or create vault position
        if (table::contains(&vault.positions, vault_addr)) {
            let position = vault.positions.borrow_mut(vault_addr);
            position.shares += shares_to_mint;
            position.last_update_ts = now_seconds();
        } else {
            vault.positions.add(vault_addr, Position {
                shares: shares_to_mint,
                last_update_ts: now_seconds(),
            });
        };
        
        // Simulate trading fees
        let simulated_fee = ((amount as u128) * (FEE_BPS as u128)) / 10000;
        vault.accumulated_fees += simulated_fee;
        
        shares_to_mint
    }
    
    /// Withdraw from vault (called by vault contract)
    public fun vault_withdraw(vault_signer: &signer, shares: u128): u64 acquires TappConfig, TappVault {
        // Simplified vault access - in production would use proper access control
        assert_not_paused();
        assert!(shares > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        // Compound existing yield first
        compound_yield_internal();
        
        let vault = borrow_global_mut<TappVault>(@riverfi);
        let vault_addr = signer::address_of(vault_signer);
        
        // Check vault has position
        assert!(vault.positions.contains(vault_addr), error::not_found(E_NO_POSITION));
        
        let position = vault.positions.borrow_mut(vault_addr);
        assert!(position.shares >= shares, error::invalid_argument(E_INSUFFICIENT_SHARES));
        
        // Calculate withdrawal amount (includes yield)
        let withdrawal_amount = yield_math::calculate_withdrawal(
            shares,
            vault.total_deposited + vault.accumulated_fees,
            vault.total_shares
        );
        
        // Update position
        position.shares -= shares;
        if (position.shares == 0) {
            vault.positions.remove(vault_addr);
        };
        
        // Update vault state
        let yield_portion = (shares * vault.accumulated_fees) / vault.total_shares;
        vault.total_deposited -= (withdrawal_amount - yield_portion);
        vault.total_shares -= shares;
        vault.accumulated_fees -= yield_portion;
        
        // Transfer USDC back to vault from protocol reserves
        let usdc_metadata = mock_usdc::get_token();
        let riverfi_balance = primary_fungible_store::balance(@riverfi, usdc_metadata);
        let transfer_amount = if (riverfi_balance >= (withdrawal_amount as u64)) {
            (withdrawal_amount as u64)
        } else {
            riverfi_balance
        };
        
        if (transfer_amount > 0) {
            // For MVP: Admin transfers from @riverfi reserves to vault
            // In production, this would be automated resource account transfer
        };
        
        (withdrawal_amount as u64)
    }
    
    /// Get vault's current value (called by vault for NAV calculation)
    public fun get_vault_value(vault_addr: address): u128 acquires TappConfig, TappVault {
        // Compound to get latest value
        compound_yield_internal();
        
        let vault = borrow_global<TappVault>(@riverfi);
        
        if (!vault.positions.contains(vault_addr)) {
            return 0
        };
        
        let position = vault.positions.borrow(vault_addr);
        
        yield_math::calculate_withdrawal(
            position.shares,
            vault.total_deposited + vault.accumulated_fees,
            vault.total_shares
        )
    }
    
    // View Functions
    
    #[view]
    public fun get_position(user: address): (u128, u128) acquires TappVault {
        let vault = borrow_global<TappVault>(@riverfi);
        
        if (!vault.positions.contains(user)) {
            return (0, 0)
        };
        
        let position = vault.positions.borrow(user);
        let current_value = yield_math::calculate_withdrawal(
            position.shares,
            vault.total_deposited + vault.accumulated_fees,
            vault.total_shares
        );
        
        (position.shares, current_value)
    }
    
    #[view]
    public fun get_apr(): u64 acquires TappConfig {
        borrow_global<TappConfig>(@riverfi).apr_bps
    }
    
    #[view]
    public fun get_tvl(): u128 acquires TappVault {
        let vault = borrow_global<TappVault>(@riverfi);
        vault.total_deposited + vault.accumulated_fees
    }
    
    #[view]
    public fun get_total_shares(): u128 acquires TappVault {
        borrow_global<TappVault>(@riverfi).total_shares
    }
    
    #[view]
    public fun is_paused(): bool acquires TappConfig {
        borrow_global<TappConfig>(@riverfi).is_paused
    }
    
    // Private Functions
    
    fun compound_yield_internal() acquires TappConfig, TappVault {
        let config = borrow_global_mut<TappConfig>(@riverfi);
        let vault = borrow_global_mut<TappVault>(@riverfi);
        
        let current_time = now_seconds();
        let elapsed_seconds = ((current_time - config.last_compound_ts) as u128);
        
        if (elapsed_seconds == 0 || vault.total_deposited == 0) {
            return
        };
        
        // Calculate yield using compound interest
        let yield_earned = yield_math::simple_interest(
            vault.total_deposited,
            config.apr_bps,
            elapsed_seconds
        );
        
        if (yield_earned > 0) {
            // Add yield to accumulated fees (representing trading fee earnings)
            vault.accumulated_fees += yield_earned;
            
            config.last_compound_ts = current_time;
            
            event::emit(TappCompoundEvent {
                total_yield_added: yield_earned,
                new_total_deposited: vault.total_deposited + vault.accumulated_fees,
                timestamp: current_time
            });
        };
    }
    
    fun assert_not_paused() acquires TappConfig {
        assert!(!borrow_global<TappConfig>(@riverfi).is_paused, error::unavailable(E_PAUSED));
    }
    
    fun get_admin_address(): address acquires TappConfig {
        borrow_global<TappConfig>(@riverfi).admin
    }
    
    // Test Functions
    #[test_only]
    public fun init_for_testing(admin: &signer) {
        init_module(admin);
    }
}
