module aptos_framework::genesis {
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::aptos_governance;
    use aptos_framework::block;
    use aptos_framework::chain_id;
    use aptos_framework::coin::MintCapability;
    use aptos_framework::coins;
    use aptos_framework::consensus_config;
    use aptos_framework::gas_schedule;
    use aptos_framework::reconfiguration;
    use aptos_framework::stake;
    use aptos_framework::timestamp;
    use aptos_framework::transaction_fee;
    use aptos_framework::staking_config;
    use aptos_framework::version;

    /// Invalid epoch duration.
    const EINVALID_EPOCH_DURATION: u64 = 1;

    /// Genesis step 1: Initialize aptos framework account and core modules on chain.
    fun initialize(
        gas_schedule: vector<u8>,
        chain_id: u8,
        initial_version: u64,
        consensus_config: vector<u8>,
        epoch_interval: u64,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_duration_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
    ) {
        // Initialize the aptos framework account. This is the account where system resources and modules will be
        // deployed to. This will be entirely managed by on-chain governance and no entities have the key or privileges
        // to use this account.
        let (aptos_framework_account, framework_signer_cap) = account::create_aptos_framework_account();

        // Initialize account configs on aptos framework account.
        account::initialize(
            &aptos_framework_account,
            @aptos_framework,
            b"account",
            b"script_prologue",
            b"module_prologue",
            b"writeset_prologue",
            b"multi_agent_script_prologue",
            b"epilogue",
            b"writeset_epilogue",
        );

        // Give the decentralized on-chain governance control over the core framework account.
        aptos_governance::store_signer_cap(&aptos_framework_account, @aptos_framework, framework_signer_cap);

        consensus_config::initialize(&aptos_framework_account, consensus_config);
        version::initialize(&aptos_framework_account, initial_version);
        stake::initialize(&aptos_framework_account);
        staking_config::initialize(
            &aptos_framework_account,
            minimum_stake,
            maximum_stake,
            recurring_lockup_duration_secs,
            allow_validator_set_change,
            rewards_rate,
            rewards_rate_denominator,
        );
        gas_schedule::initialize(&aptos_framework_account, gas_schedule);

        // This needs to be called at the very end because earlier initializations might rely on timestamp not being
        // initialized yet.
        chain_id::initialize(&aptos_framework_account, chain_id);
        reconfiguration::initialize(&aptos_framework_account);
        block::initialize(&aptos_framework_account, epoch_interval);
        timestamp::set_time_has_started(&aptos_framework_account);
    }

    /// Genesis step 2: Initialize Aptos coin.
    fun initialize_aptos_coin(aptos_framework: &signer): MintCapability<AptosCoin> {
        let (mint_cap, burn_cap) = aptos_coin::initialize(aptos_framework);
        // Give stake module MintCapability<AptosCoin> so it can mint rewards.
        stake::store_aptos_coin_mint_cap(aptos_framework, mint_cap);

        // Give transaction_fee module BurnCapability<AptosCoin> so it can burn gas.
        transaction_fee::store_aptos_coin_burn_cap(aptos_framework, burn_cap);

        mint_cap
    }

    /// Only called for testnets and e2e tests.
    fun initialize_core_resources_and_aptos_coin(
        aptos_framework: &signer,
        core_resources_auth_key: vector<u8>,
    ) {
        let core_resources = account::create_account_internal(@core_resources);
        account::rotate_authentication_key_internal(&core_resources, core_resources_auth_key);
        let mint_cap = initialize_aptos_coin(aptos_framework);
        aptos_coin::configure_accounts_for_test(aptos_framework, &core_resources, mint_cap);
    }

    /// Sets up the initial validator set for the network.
    /// The validator "owner" accounts, and their authentication
    /// Addresses (and keys) are encoded in the `owners`
    /// Each validator signs consensus messages with the private key corresponding to the Ed25519
    /// public key in `consensus_pubkeys`.
    /// Finally, each validator must specify the network address
    /// (see types/src/network_address/mod.rs) for itself and its full nodes.
    ///
    /// Network address fields are a vector per account, where each entry is a vector of addresses
    /// encoded in a single BCS byte array.
    fun create_initialize_validators(
        aptos_framework_account: signer,
        owners: vector<address>,
        consensus_pubkeys: vector<vector<u8>>,
        proof_of_possession: vector<vector<u8>>,
        validator_network_addresses: vector<vector<u8>>,
        full_node_network_addresses: vector<vector<u8>>,
        staking_distribution: vector<u64>,
    ) {
        let num_owners = vector::length(&owners);
        let num_validator_network_addresses = vector::length(&validator_network_addresses);
        let num_full_node_network_addresses = vector::length(&full_node_network_addresses);
        assert!(num_validator_network_addresses == num_full_node_network_addresses, 0);
        let num_staking = vector::length(&staking_distribution);
        assert!(num_full_node_network_addresses == num_staking, 0);

        let i = 0;
        while (i < num_owners) {
            let owner = vector::borrow(&owners, i);
            // create each validator account and rotate its auth key to the correct value
            let owner_account = account::create_account_internal(*owner);

            // use the operator account set up the validator config
            let cur_validator_network_addresses = *vector::borrow(&validator_network_addresses, i);
            let cur_full_node_network_addresses = *vector::borrow(&full_node_network_addresses, i);
            let consensus_pubkey = *vector::borrow(&consensus_pubkeys, i);
            let pop = *vector::borrow(&proof_of_possession, i);
            stake::initialize_validator(
                &owner_account,
                consensus_pubkey,
                pop,
                cur_validator_network_addresses,
                cur_full_node_network_addresses,
            );
            stake::increase_lockup(&owner_account);
            let amount = *vector::borrow(&staking_distribution, i);
            // Transfer coins from the root account to the validator, so they can stake and have non-zero voting power
            // and can complete consensus on the genesis block.
            coins::register<AptosCoin>(&owner_account);
            aptos_coin::mint(&aptos_framework_account, *owner, amount);
            stake::add_stake(&owner_account, amount);
            stake::join_validator_set_internal(&owner_account, *owner);

            i = i + 1;
        };
        stake::on_new_epoch();
    }

    #[test_only]
    public fun setup() {
        initialize(
            x"00", // empty gas schedule
            4u8, // TESTING chain ID
            0,
            x"",
            1,
            0,
            1,
            1,
            true,
            1,
            1,
        )
    }

    #[test]
    fun test_setup() {
        use aptos_framework::account;

        setup();
        assert!(account::exists_at(@aptos_framework), 0);
    }
}
