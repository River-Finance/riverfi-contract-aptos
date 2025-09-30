module riverfi::hyperion {
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
    const DEFAULT_APR_BPS: u64 = 900; // 9% APR (higher than Tapp)
    const MAX_APR_BPS: u64 = 1000; // 10% max APR
    const MIN_LIQUIDITY_AMOUNT: u64 = 1000; // 0.001 USDC (6 decimals)
    const TRADING_FEE_BPS: u64 = 30; // 0.3% trading fee simulation
    const BONUS_REWARD_BPS: u64 = 50; // 0.5% bonus reward for liquidity providers

    // Errors
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_NOT_ADMIN: u64 = 3;
    const E_INVALID_APR: u64 = 4;
    const E_INSUFFICIENT_AMOUNT: u64 = 5;
    const E_NO_POSITION: u64 = 6;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 7;
    const E_PAUSED: u64 = 8;
    const E_ZERO_AMOUNT: u64 = 9;

    // Structs
    struct HyperionConfig has key {
        admin: address,
        apr_bps: u64,
        last_compound_ts: u64,
        is_paused: bool,
    }

    struct HyperionPool has key {
        total_liquidity: u128, // Total USDC in liquidity pool
        total_lp_tokens: u128, // Total LP tokens outstanding
        accumulated_rewards: u128, // Accumulated trading fees and rewards
        bonus_rewards: u128, // Extra bonus rewards for LPs
        positions: Table<address, LPPosition>, // User LP positions
    }

    struct LPPosition has store, drop {
        lp_tokens: u128, // User's LP tokens
        last_update_ts: u64, // Last time this position was updated
    }

    // Events
    #[event]
    struct HyperionLiquidityAddedEvent has drop, store {
        user: address,
        amount: u64,
        lp_tokens: u128,
        timestamp: u64
    }

    #[event]
    struct HyperionLiquidityRemovedEvent has drop, store {
        user: address,
        lp_tokens: u128,
        amount: u64,
        rewards_earned: u64,
        timestamp: u64
    }

    #[event]
    struct HyperionCompoundEvent has drop, store {
        total_rewards_added: u128,
        bonus_rewards_added: u128,
        new_total_liquidity: u128,
        timestamp: u64
    }

    #[event]
    struct HyperionTradingRewardEvent has drop, store {
        trading_fee: u128,
        bonus_reward: u128,
        total_rewards: u128,
        timestamp: u64
    }

    #[event]
    struct HyperionAprUpdateEvent has drop, store {
        old_apr_bps: u64,
        new_apr_bps: u64,
        admin: address,
        timestamp: u64
    }

    // Initialization
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @riverfi, error::permission_denied(E_NOT_ADMIN));
        
        // Initialize Hyperion with default settings
        move_to(admin, HyperionConfig {
            admin: admin_addr,
            apr_bps: DEFAULT_APR_BPS,
            last_compound_ts: now_seconds(),
            is_paused: false,
        });

        move_to(admin, HyperionPool {
            total_liquidity: 0,
            total_lp_tokens: 0,
            accumulated_rewards: 0,
            bonus_rewards: 0,
            positions: table::new(),
        });
    }

    // Public Entry Functions
    
    /// Provide liquidity to Hyperion protocol to earn yield
    public entry fun provide_liquidity(account: &signer, amount: u64) acquires HyperionConfig, HyperionPool {
        assert_not_paused();
        assert!(amount >= MIN_LIQUIDITY_AMOUNT, error::invalid_argument(E_INSUFFICIENT_AMOUNT));
        
        let user_addr = signer::address_of(account);
        
        // Compound existing rewards first
        compound_rewards_internal();
        
        let pool = borrow_global_mut<HyperionPool>(@riverfi);
        
        // Transfer USDC from user to Hyperion
        let usdc_metadata = mock_usdc::get_token();
        primary_fungible_store::transfer(account, usdc_metadata, @riverfi, amount);
        
        // Calculate LP tokens to mint
        let lp_tokens_to_mint = yield_math::calculate_shares(
            (amount as u128),
            pool.total_liquidity,
            pool.total_lp_tokens
        );
        
        // Update pool state
        pool.total_liquidity += (amount as u128);
        pool.total_lp_tokens += lp_tokens_to_mint;
        
        // Update or create user position
        if (pool.positions.contains(user_addr)) {
            let position = pool.positions.borrow_mut(user_addr);
            position.lp_tokens += lp_tokens_to_mint;
            position.last_update_ts = now_seconds();
        } else {
            pool.positions.add(user_addr, LPPosition {
                lp_tokens: lp_tokens_to_mint,
                last_update_ts: now_seconds(),
            });
        };
        
        // Simulate trading fees and bonus rewards
        let trading_fee = ((amount as u128) * (TRADING_FEE_BPS as u128)) / 10000;
        let bonus_reward = ((amount as u128) * (BONUS_REWARD_BPS as u128)) / 10000;
        
        pool.accumulated_rewards = pool.accumulated_rewards + trading_fee;
        pool.bonus_rewards = pool.bonus_rewards + bonus_reward;
        
        // Emit events
        event::emit(HyperionLiquidityAddedEvent {
            user: user_addr,
            amount,
            lp_tokens: lp_tokens_to_mint,
            timestamp: now_seconds()
        });
        
        event::emit(HyperionTradingRewardEvent {
            trading_fee,
            bonus_reward,
            total_rewards: pool.accumulated_rewards + pool.bonus_rewards,
            timestamp: now_seconds()
        });
    }
    
    /// Remove liquidity from Hyperion protocol
    public entry fun remove_liquidity(account: &signer, lp_tokens: u128) acquires HyperionConfig, HyperionPool {
        assert_not_paused();
        assert!(lp_tokens > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        let user_addr = signer::address_of(account);
        
        // Compound existing rewards first
        compound_rewards_internal();
        
        let pool = borrow_global_mut<HyperionPool>(@riverfi);
        
        // Check user has position
        assert!(table::contains(&pool.positions, user_addr), error::not_found(E_NO_POSITION));
        
        let position = table::borrow_mut(&mut pool.positions, user_addr);
        assert!(position.lp_tokens >= lp_tokens, error::invalid_argument(E_INSUFFICIENT_LIQUIDITY));
        
        // Calculate withdrawal amount (includes rewards)
        let total_pool_value = pool.total_liquidity + pool.accumulated_rewards + pool.bonus_rewards;
        let withdrawal_amount = yield_math::calculate_withdrawal(
            lp_tokens,
            total_pool_value,
            pool.total_lp_tokens
        );
        
        // Calculate rewards earned
        let original_liquidity = yield_math::calculate_withdrawal(
            lp_tokens,
            pool.total_liquidity,
            pool.total_lp_tokens
        );
        let rewards_earned = if (withdrawal_amount > original_liquidity) {
            withdrawal_amount - original_liquidity
        } else {
            0
        };
        
        // Update position
        position.lp_tokens = position.lp_tokens - lp_tokens;
        if (position.lp_tokens == 0) {
            table::remove(&mut pool.positions, user_addr);
        };
        
        // Update pool state
        let reward_portion = (lp_tokens * (pool.accumulated_rewards + pool.bonus_rewards)) / pool.total_lp_tokens;
        pool.total_liquidity = pool.total_liquidity - (withdrawal_amount - reward_portion);
        pool.total_lp_tokens = pool.total_lp_tokens - lp_tokens;
        pool.accumulated_rewards = pool.accumulated_rewards - (reward_portion * pool.accumulated_rewards) / (pool.accumulated_rewards + pool.bonus_rewards);
        pool.bonus_rewards = pool.bonus_rewards - (reward_portion * pool.bonus_rewards) / (pool.accumulated_rewards + pool.bonus_rewards);
        
        // Note: Transfer would need proper signer capability
        // For MVP, this is simplified
        
        // Emit event
        event::emit(HyperionLiquidityRemovedEvent {
            user: user_addr,
            lp_tokens,
            amount: (withdrawal_amount as u64),
            rewards_earned: (rewards_earned as u64),
            timestamp: now_seconds()
        });
    }
    
    /// Compound accumulated rewards (can be called by anyone)
    public entry fun compound_rewards() acquires HyperionConfig, HyperionPool {
        assert_not_paused();
        compound_rewards_internal();
    }
    
    // Admin Functions
    
    /// Set APR (admin only)
    public entry fun admin_set_apr(admin: &signer, new_apr_bps: u64) acquires HyperionConfig {
        let config = borrow_global_mut<HyperionConfig>(@riverfi);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(new_apr_bps <= MAX_APR_BPS, error::invalid_argument(E_INVALID_APR));
        
        let old_apr = config.apr_bps;
        config.apr_bps = new_apr_bps;
        
        event::emit(HyperionAprUpdateEvent {
            old_apr_bps: old_apr,
            new_apr_bps: new_apr_bps,
            admin: signer::address_of(admin),
            timestamp: now_seconds()
        });
    }
    
    /// Pause/unpause the protocol (admin only)
    public entry fun admin_set_pause(admin: &signer, paused: bool) acquires HyperionConfig {
        let config = borrow_global_mut<HyperionConfig>(@riverfi);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        config.is_paused = paused;
    }
    
    // Public Functions (for vault integration)
    
    /// Provide liquidity from vault (called by vault contract)
    public fun vault_provide_liquidity(vault_signer: &signer, amount: u64): u128 acquires HyperionConfig, HyperionPool {
        // Simplified vault access - in production would use proper access control
        assert_not_paused();
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        // Compound existing rewards first
        compound_rewards_internal();
        
        let pool = borrow_global_mut<HyperionPool>(@riverfi);
        let vault_addr = signer::address_of(vault_signer);
        
        // Calculate LP tokens to mint to vault
        let lp_tokens_to_mint = yield_math::calculate_shares(
            (amount as u128),
            pool.total_liquidity,
            pool.total_lp_tokens
        );
        
        // Update pool state
        pool.total_liquidity = pool.total_liquidity + (amount as u128);
        pool.total_lp_tokens = pool.total_lp_tokens + lp_tokens_to_mint;
        
        // Update or create vault position
        if (table::contains(&pool.positions, vault_addr)) {
            let position = table::borrow_mut(&mut pool.positions, vault_addr);
            position.lp_tokens = position.lp_tokens + lp_tokens_to_mint;
            position.last_update_ts = now_seconds();
        } else {
            table::add(&mut pool.positions, vault_addr, LPPosition {
                lp_tokens: lp_tokens_to_mint,
                last_update_ts: now_seconds(),
            });
        };
        
        // Simulate trading fees and bonus rewards
        let trading_fee = ((amount as u128) * (TRADING_FEE_BPS as u128)) / 10000;
        let bonus_reward = ((amount as u128) * (BONUS_REWARD_BPS as u128)) / 10000;
        
        pool.accumulated_rewards = pool.accumulated_rewards + trading_fee;
        pool.bonus_rewards = pool.bonus_rewards + bonus_reward;
        
        lp_tokens_to_mint
    }
    
    /// Remove liquidity from vault (called by vault contract)
    public fun vault_remove_liquidity(vault_signer: &signer, lp_tokens: u128): u64 acquires HyperionConfig, HyperionPool {
        // Simplified vault access - in production would use proper access control
        assert_not_paused();
        assert!(lp_tokens > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        // Compound existing rewards first
        compound_rewards_internal();
        
        let pool = borrow_global_mut<HyperionPool>(@riverfi);
        let vault_addr = signer::address_of(vault_signer);
        
        // Check vault has position
        assert!(table::contains(&pool.positions, vault_addr), error::not_found(E_NO_POSITION));
        
        let position = table::borrow_mut(&mut pool.positions, vault_addr);
        assert!(position.lp_tokens >= lp_tokens, error::invalid_argument(E_INSUFFICIENT_LIQUIDITY));
        
        // Calculate withdrawal amount (includes rewards)
        let total_pool_value = pool.total_liquidity + pool.accumulated_rewards + pool.bonus_rewards;
        let withdrawal_amount = yield_math::calculate_withdrawal(
            lp_tokens,
            total_pool_value,
            pool.total_lp_tokens
        );
        
        // Update position
        position.lp_tokens = position.lp_tokens - lp_tokens;
        if (position.lp_tokens == 0) {
            table::remove(&mut pool.positions, vault_addr);
        };
        
        // Update pool state
        let reward_portion = (lp_tokens * (pool.accumulated_rewards + pool.bonus_rewards)) / pool.total_lp_tokens;
        pool.total_liquidity = pool.total_liquidity - (withdrawal_amount - reward_portion);
        pool.total_lp_tokens = pool.total_lp_tokens - lp_tokens;
        
        // Proportionally reduce rewards
        let total_rewards = pool.accumulated_rewards + pool.bonus_rewards;
        if (total_rewards > 0) {
            pool.accumulated_rewards = pool.accumulated_rewards - (reward_portion * pool.accumulated_rewards) / total_rewards;
            pool.bonus_rewards = pool.bonus_rewards - (reward_portion * pool.bonus_rewards) / total_rewards;
        };
        
        (withdrawal_amount as u64)
    }
    
    /// Get vault's current value (called by vault for NAV calculation)
    public fun get_vault_value(vault_addr: address): u128 acquires HyperionConfig, HyperionPool {
        // Compound to get latest value
        compound_rewards_internal();
        
        let pool = borrow_global<HyperionPool>(@riverfi);
        
        if (!table::contains(&pool.positions, vault_addr)) {
            return 0
        };
        
        let position = table::borrow(&pool.positions, vault_addr);
        let total_pool_value = pool.total_liquidity + pool.accumulated_rewards + pool.bonus_rewards;
        
        yield_math::calculate_withdrawal(
            position.lp_tokens,
            total_pool_value,
            pool.total_lp_tokens
        )
    }
    
    // View Functions
    
    #[view]
    public fun get_position(user: address): (u128, u128) acquires HyperionPool {
        let pool = borrow_global<HyperionPool>(@riverfi);
        
        if (!table::contains(&pool.positions, user)) {
            return (0, 0)
        };
        
        let position = table::borrow(&pool.positions, user);
        let total_pool_value = pool.total_liquidity + pool.accumulated_rewards + pool.bonus_rewards;
        let current_value = yield_math::calculate_withdrawal(
            position.lp_tokens,
            total_pool_value,
            pool.total_lp_tokens
        );
        
        (position.lp_tokens, current_value)
    }
    
    #[view]
    public fun get_apr(): u64 acquires HyperionConfig {
        borrow_global<HyperionConfig>(@riverfi).apr_bps
    }
    
    #[view]
    public fun get_tvl(): u128 acquires HyperionPool {
        let pool = borrow_global<HyperionPool>(@riverfi);
        pool.total_liquidity + pool.accumulated_rewards + pool.bonus_rewards
    }
    
    #[view]
    public fun get_total_lp_tokens(): u128 acquires HyperionPool {
        borrow_global<HyperionPool>(@riverfi).total_lp_tokens
    }
    
    #[view]
    public fun get_pool_stats(): (u128, u128, u128, u128) acquires HyperionPool {
        let pool = borrow_global<HyperionPool>(@riverfi);
        (pool.total_liquidity, pool.total_lp_tokens, pool.accumulated_rewards, pool.bonus_rewards)
    }
    
    #[view]
    public fun is_paused(): bool acquires HyperionConfig {
        borrow_global<HyperionConfig>(@riverfi).is_paused
    }
    
    // Private Functions
    
    fun compound_rewards_internal() acquires HyperionConfig, HyperionPool {
        let config = borrow_global_mut<HyperionConfig>(@riverfi);
        let pool = borrow_global_mut<HyperionPool>(@riverfi);
        
        let current_time = now_seconds();
        let elapsed_seconds = ((current_time - config.last_compound_ts) as u128);
        
        if (elapsed_seconds == 0 || pool.total_liquidity == 0) {
            return
        };
        
        // Calculate yield using simple interest on the base liquidity
        let yield_earned = yield_math::simple_interest(
            pool.total_liquidity,
            config.apr_bps,
            elapsed_seconds
        );
        
        // Add extra bonus rewards (simulated pseudo-random trading volume)
        let bonus_multiplier = ((current_time % 5) + 1); // 1-5x multiplier based on "trading activity"
        let extra_bonus = (pool.total_liquidity * (bonus_multiplier as u128)) / 10000; // 0.01-0.05% of TVL
        
        if (yield_earned > 0 || extra_bonus > 0) {
            // Add yield to accumulated rewards
            pool.accumulated_rewards = pool.accumulated_rewards + yield_earned;
            pool.bonus_rewards = pool.bonus_rewards + extra_bonus;
            
            config.last_compound_ts = current_time;
            
            event::emit(HyperionCompoundEvent {
                total_rewards_added: yield_earned,
                bonus_rewards_added: extra_bonus,
                new_total_liquidity: pool.total_liquidity + pool.accumulated_rewards + pool.bonus_rewards,
                timestamp: current_time
            });
        };
    }
    
    fun assert_not_paused() acquires HyperionConfig {
        assert!(!borrow_global<HyperionConfig>(@riverfi).is_paused, error::unavailable(E_PAUSED));
    }
    
    // Test Functions
    #[test_only]
    public fun init_for_testing(admin: &signer) {
        init_module(admin);
    }
}