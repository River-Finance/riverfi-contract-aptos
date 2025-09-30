module riverfi::yield_math {
    // Constants
    const SECONDS_PER_YEAR: u128 = 31536000; // 365 * 24 * 60 * 60
    const SECONDS_PER_DAY: u128 = 86400; // 24 * 60 * 60
    const BPS_BASE: u128 = 10000; // 100.00% = 10000 basis points
    const PRECISION: u128 = 1000000000000; // 1e12 for precision

    // Errors
    const E_INVALID_APR: u64 = 1;
    const E_ZERO_PRINCIPAL: u64 = 2;

    /// Convert APR in basis points to daily compound rate
    /// @param apr_bps: APR in basis points (e.g., 1000 = 10%)
    /// @return Daily compound rate with precision
    public fun apr_to_daily_compound_rate(apr_bps: u64): u128 {
        assert!(apr_bps <= 1000, E_INVALID_APR); // Max 10% APR
        
        // Convert APR to daily rate: (1 + APR)^(1/365) - 1
        // Simplified for small rates: APR / 365
        let daily_rate = ((apr_bps as u128) * PRECISION) / (BPS_BASE * 365);
        daily_rate
    }

    /// Calculate compound yield over time
    /// @param principal: Initial amount
    /// @param daily_rate: Daily compound rate with precision
    /// @param elapsed_seconds: Time elapsed in seconds
    /// @return Total amount after compound interest
    public fun compound_yield(
        principal: u128,
        daily_rate: u128,
        elapsed_seconds: u128
    ): u128 {
        assert!(principal > 0, E_ZERO_PRINCIPAL);
        
        if (elapsed_seconds == 0) {
            return principal
        };

        // Calculate number of days (with precision)
        let days = (elapsed_seconds * PRECISION) / SECONDS_PER_DAY;
        
        // Simple compound: principal * (1 + daily_rate)^days
        // For small rates and short periods, approximate: principal * (1 + daily_rate * days)
        let yield_factor = PRECISION + (daily_rate * days) / PRECISION;
        (principal * yield_factor) / PRECISION
    }

    /// Calculate simple interest (non-compounding)
    /// @param principal: Initial amount
    /// @param apr_bps: APR in basis points
    /// @param elapsed_seconds: Time elapsed in seconds
    /// @return Interest earned
    public fun simple_interest(
        principal: u128,
        apr_bps: u64,
        elapsed_seconds: u128
    ): u128 {
        assert!(principal > 0, E_ZERO_PRINCIPAL);
        assert!(apr_bps <= 1000, E_INVALID_APR); // Max 10% APR
        
        // Interest = principal * apr * time / year
        let interest = (principal * (apr_bps as u128) * elapsed_seconds) / (BPS_BASE * SECONDS_PER_YEAR);
        interest
    }

    /// Calculate shares based on pool ratio
    /// @param amount: Deposit amount
    /// @param total_deposits: Total deposits in pool
    /// @param total_shares: Total shares outstanding
    /// @return Number of shares to mint
    public fun calculate_shares(
        amount: u128,
        total_deposits: u128,
        total_shares: u128
    ): u128 {
        if (total_shares == 0 || total_deposits == 0) {
            // First deposit: 1:1 ratio
            amount
        } else {
            // Maintain pool ratio: shares = amount * total_shares / total_deposits
            (amount * total_shares) / total_deposits
        }
    }

    /// Calculate withdrawal amount based on shares
    /// @param shares: Shares to redeem
    /// @param total_deposits: Total deposits in pool
    /// @param total_shares: Total shares outstanding
    /// @return Amount to withdraw
    public fun calculate_withdrawal(
        shares: u128,
        total_deposits: u128,
        total_shares: u128
    ): u128 {
        if (total_shares == 0) {
            0
        } else {
            // Proportional withdrawal: amount = shares * total_deposits / total_shares
            (shares * total_deposits) / total_shares
        }
    }

    /// Get current timestamp
    public fun now_seconds(): u64 {
        aptos_framework::timestamp::now_seconds()
    }

    // View functions for testing
    #[view]
    public fun get_precision(): u128 { PRECISION }

    #[view]
    public fun get_seconds_per_day(): u128 { SECONDS_PER_DAY }

    #[view]
    public fun get_seconds_per_year(): u128 { SECONDS_PER_YEAR }
}