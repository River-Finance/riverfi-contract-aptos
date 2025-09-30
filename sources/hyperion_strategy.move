// LEGACY MODULE - Not used in mock protocol setup
// This module is kept for compilation compatibility but not functional
// The actual yield generation happens in hyperion.move (mock protocol)

module riverfi::hyperion_strategy {
    use std::signer;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{Metadata};

    // Mock types for compilation compatibility
    struct Info has key, store {}
    
    // Errors
    const E_INSUFFICIENT_AMOUNT: u64 = 1;
    
    // Mock position creation
    fun create_mock_position(): Object<Info> {
        let constructor_ref = &object::create_sticky_object(@riverfi);
        object::object_from_constructor_ref(constructor_ref)
    }

    // Mock functions for compilation compatibility (not functional)
    
    /// Mock deposit - returns dummy position
    public fun deposit_to_hyperion(
        _vault_signer: &signer,
        usdc_amount: u64,
        _usdc_metadata: Object<Metadata>
    ): Object<Info> {
        assert!(usdc_amount > 0, E_INSUFFICIENT_AMOUNT);
        // Return mock position - not functional
        create_mock_position()
    }

    /// Mock withdraw - returns 0
    public fun withdraw_from_hyperion(
        _vault_signer: &signer,
        _position: Object<Info>,
        _liquidity_amount: u128,
        _usdc_metadata: Object<Metadata>
    ): u64 {
        // Not functional in mock setup
        0
    }

    /// Mock yield claim - returns 0
    public fun claim_yields(
        _vault_signer: &signer,
        _position: Object<Info>,
        _usdc_metadata: Object<Metadata>
    ): u64 {
        // Not functional in mock setup
        0
    }

    /// Mock position liquidity - returns 0
    public fun get_position_liquidity(_position: Object<Info>): u128 {
        0
    }
}