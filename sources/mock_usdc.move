module riverfi::mock_usdc {
    use std::signer;
    use std::error;
    use std::string;
    use std::option;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, TransferRef, BurnRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::event;

    // Constants
    const USDC_TOKEN_NAME: vector<u8> = b"USDC";
    const USDC_TOKEN_SYMBOL: vector<u8> = b"USDC";
    const USDC_TOKEN_DECIMALS: u8 = 6;
    const INITIAL_SUPPLY: u64 = 1000000000000; // 1 million USDC (with 6 decimals)

    // Errors
    const E_ALREADY_INITIALIZED: u64 = 1;
    const E_NOT_ADMIN: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;

    // Structs
    struct MockUSDCToken has key {
        token: Object<Metadata>,
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef,
        extend_ref: ExtendRef,
        admin: address,
        total_supply: u64,
    }

    // Events
    #[event]
    struct MintEvent has drop, store {
        recipient: address,
        amount: u64,
        timestamp: u64
    }

    #[event]
    struct FaucetEvent has drop, store {
        recipient: address,
        amount: u64,
        timestamp: u64
    }

    // Initialization
    fun init_module(admin: &signer) acquires MockUSDCToken {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @riverfi, error::permission_denied(E_NOT_ADMIN));
        
        // Create the mock USDC token
        let constructor_ref = &object::create_sticky_object(@riverfi);
        let token_address = object::address_from_constructor_ref(constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            string::utf8(USDC_TOKEN_NAME),
            string::utf8(USDC_TOKEN_SYMBOL),
            USDC_TOKEN_DECIMALS,
            string::utf8(b"https://usdc.finance/icon.png"),
            string::utf8(b"https://usdc.finance")
        );

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
        let extend_ref = object::generate_extend_ref(constructor_ref);

        // Store the token control refs
        move_to(
            admin,
            MockUSDCToken {
                token: object::address_to_object(token_address),
                mint_ref,
                transfer_ref,
                burn_ref,
                extend_ref,
                admin: admin_addr,
                total_supply: 0,
            }
        );

        // Mint initial supply to admin
        mint_to_admin(admin_addr, INITIAL_SUPPLY);
    }

    // Public Entry Functions

    /// Faucet function - anyone can get 1000 USDC for testing
    public entry fun faucet(recipient: &signer) acquires MockUSDCToken {
        let recipient_addr = signer::address_of(recipient);
        let faucet_amount = 1000000000; // 1000 USDC (with 6 decimals)
        
        mint_usdc(recipient_addr, faucet_amount);
        
        event::emit(FaucetEvent {
            recipient: recipient_addr,
            amount: faucet_amount,
            timestamp: aptos_framework::timestamp::now_seconds()
        });
    }

    /// Admin mint function
    public entry fun admin_mint(admin: &signer, recipient: address, amount: u64) acquires MockUSDCToken {
        let mock_usdc = borrow_global<MockUSDCToken>(@riverfi);
        assert!(signer::address_of(admin) == mock_usdc.admin, error::permission_denied(E_NOT_ADMIN));
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        
        mint_usdc(recipient, amount);
        
        event::emit(MintEvent {
            recipient,
            amount,
            timestamp: aptos_framework::timestamp::now_seconds()
        });
    }

    /// Burn function (for testing)
    public entry fun burn(owner: &signer, amount: u64) acquires MockUSDCToken {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));
        let owner_addr = signer::address_of(owner);
        
        let mock_usdc = borrow_global_mut<MockUSDCToken>(@riverfi);
        let balance = primary_fungible_store::balance(owner_addr, mock_usdc.token);
        assert!(balance >= amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));
        
        primary_fungible_store::burn(&mock_usdc.burn_ref, owner_addr, amount);
        mock_usdc.total_supply -= amount;
    }

    // Public Functions

    /// Get mock USDC token metadata
    public fun get_token(): Object<Metadata> acquires MockUSDCToken {
        let mock_usdc = borrow_global<MockUSDCToken>(@riverfi);
        mock_usdc.token
    }

    // View Functions

    #[view]
    public fun get_balance(account: address): u64 acquires MockUSDCToken {
        let mock_usdc = borrow_global<MockUSDCToken>(@riverfi);
        primary_fungible_store::balance(account, mock_usdc.token)
    }

    #[view]
    public fun get_total_supply(): u64 acquires MockUSDCToken {
        borrow_global<MockUSDCToken>(@riverfi).total_supply
    }

    #[view]
    public fun get_token_info(): (string::String, string::String, u8) {
        (
            string::utf8(USDC_TOKEN_NAME),
            string::utf8(USDC_TOKEN_SYMBOL), 
            USDC_TOKEN_DECIMALS
        )
    }

    #[view]
    public fun get_admin(): address acquires MockUSDCToken {
        borrow_global<MockUSDCToken>(@riverfi).admin
    }

    // Private Functions

    fun mint_usdc(recipient: address, amount: u64) acquires MockUSDCToken {
        let mock_usdc = borrow_global_mut<MockUSDCToken>(@riverfi);
        let fa = fungible_asset::mint(&mock_usdc.mint_ref, amount);
        primary_fungible_store::deposit(recipient, fa);
        mock_usdc.total_supply += amount;
    }

    fun mint_to_admin(admin_addr: address, amount: u64) acquires MockUSDCToken {
        mint_usdc(admin_addr, amount);
    }

    // Test Functions
    #[test_only]
    public fun init_for_testing(admin: &signer) {
        init_module(admin);
    }

    #[test_only]
    public fun mint_for_testing(recipient: address, amount: u64) acquires MockUSDCToken {
        mint_usdc(recipient, amount);
    }
}