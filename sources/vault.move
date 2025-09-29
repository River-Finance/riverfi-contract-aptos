module riverfi::vault {
    use std::signer;
    use std::error;
    use std::string;
    use std::option;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef, TransferRef, BurnRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp::now_seconds;

    use riverfi::storage;

    // -- Constants
    const RUSDC_TOKEN_NAME: vector<u8> = b"River USDC";
    const RUSDC_TOKEN_SYMBOL: vector<u8> = b"RUSDC";
    const RUSDC_TOKEN_DECIMALS: u8 = 6;
    const VAULT_SEED: vector<u8> = b"vault::VAULT";

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
        hyperion_usdc: u64,  // Amount deposited to Hyperion
        reserve_usdc: u64,   // Amount kept in vault for instant withdrawals
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

        init_rusdc_token(sender);
    }

    // -- Public Entry Functions
    public entry fun deposit(sender: &signer, amount: u64) acquires Config, RUSDCToken, Vault {
        assert!(amount > 0, error::invalid_argument(E_ZERO_AMOUNT));

        let config = borrow_global<Config>(@riverfi);
        assert!(config.enable_deposit, error::permission_denied(E_ALREADY_INITIALIZED));

        let user_addr = signer::address_of(sender);
        let vault_addr = get_vault_address();
        let vault = borrow_global_mut<Vault>(vault_addr);

        // 1. Transfer USDC from user to vault
        let usdc_metadata = object::address_to_object<Metadata>(@usdc);
        primary_fungible_store::transfer(sender, usdc_metadata, vault_addr, amount);

        // 2. Mint RUSDC 1:1 to user
        mint_rusdc(user_addr, amount);

        // 3. Update vault stats
        vault.total_usdc = vault.total_usdc + amount;
        vault.total_rusdc_supply = vault.total_rusdc_supply + amount;

        // For now, all goes to reserve (will add Hyperion integration later)
        vault.reserve_usdc = vault.reserve_usdc + amount;

        // 4. Emit event
        event::emit(
            DepositedEvent {
                user: user_addr,
                usdc_amount: amount,
                rusdc_amount: amount,
                timestamp: now_seconds()
            }
        );
    }

    public entry fun withdraw(sender: &signer, rusdc_amount: u64) acquires Config, RUSDCToken, Vault {
        assert!(rusdc_amount > 0, error::invalid_argument(E_ZERO_AMOUNT));

        let config = borrow_global<Config>(@riverfi);
        assert!(config.enable_withdraw, error::permission_denied(E_ALREADY_INITIALIZED));

        let user_addr = signer::address_of(sender);
        let vault_addr = get_vault_address();
        let vault = borrow_global_mut<Vault>(vault_addr);

        // Check user has enough RUSDC
        let rusdc_token = get_rusdc_token();
        let user_rusdc_balance = primary_fungible_store::balance(user_addr, rusdc_token);
        assert!(user_rusdc_balance >= rusdc_amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // Check vault has enough USDC
        assert!(vault.reserve_usdc >= rusdc_amount, error::invalid_argument(E_INSUFFICIENT_VAULT_BALANCE));

        // 1. Burn RUSDC from user
        burn_rusdc(user_addr, rusdc_amount);

        // 2. Transfer USDC from vault to user (using vault signer - CRITICAL!)
        let vault_signer = get_vault_signer(vault);
        let usdc_metadata = object::address_to_object<Metadata>(@usdc);
        primary_fungible_store::transfer(&vault_signer, usdc_metadata, user_addr, rusdc_amount);

        // 3. Update vault stats
        vault.total_usdc = vault.total_usdc - rusdc_amount;
        vault.total_rusdc_supply = vault.total_rusdc_supply - rusdc_amount;
        vault.reserve_usdc = vault.reserve_usdc - rusdc_amount;

        // 4. Emit event
        event::emit(
            WithdrawnEvent {
                user: user_addr,
                rusdc_amount,
                usdc_amount: rusdc_amount,
                timestamp: now_seconds()
            }
        );
    }

    // -- View Functions
    #[view]
    public fun get_vault_stats(): (u64, u64, u64, u64) acquires Vault {
        let vault_addr = get_vault_address();
        let vault = borrow_global<Vault>(vault_addr);

        (vault.total_usdc, vault.total_rusdc_supply, vault.hyperion_usdc, vault.reserve_usdc)
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
            hyperion_usdc: 0,
            reserve_usdc: 0,
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

    // -- Test Only
    #[test_only]
    public fun init_module_for_testing(sender: &signer) {
        init_module(sender)
    }
}
