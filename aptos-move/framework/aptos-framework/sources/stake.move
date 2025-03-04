/**
 * Validator lifecycle:
 * 1. Prepare a validator node set up and call stake::initialize_validator
 * 2. Once ready to deposit stake (or have funds assigned by a staking service in exchange for ownership capability),
 * call stake::add_stake (or *_with_cap versions if called from the staking service)
 * 3. Call stake::join_validator_set (or _with_cap version) to join the active validator set. Changes are effective in
 * the next epoch.
 * 4. Validate and gain rewards. The stake will automatically be locked up for a fixed duration (set by governance) and
 * automatically renewed at expiration.
 * 5. At any point, if the validator operator wants to update the consensus key or network/fullnode addresses, they can
 * call stake::rotate_consensus_key and stake::update_network_and_fullnode_addresses. Similar to changes to stake, the
 * changes to consensus key/network/fullnode addresses are only effective in the next epoch.
 * 6. Validator can request to unlock their stake at any time. However, their stake will only become withdrawable when
 * their current lockup expires. This can be at most as long as the fixed lockup duration.
 * 7. After exiting, the validator can either explicitly leave the validator set by calling stake::leave_validator_set
 * or if their stake drops below the min required, they would get removed at the end of the epoch.
 * 8. Validator can always rejoin the validator set by going through steps 2-3 again.
 * 9. An owner can always switch operators by calling stake::set_operator.
 * 10. An owner can always switch designated voter by calling stake::set_designated_voter.
*/
module aptos_framework::stake {
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::signature;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self, Coin, MintCapability};
    use aptos_framework::timestamp;
    use aptos_framework::system_addresses;
    use aptos_framework::staking_config::{Self, StakingConfig};

    friend aptos_framework::block;
    friend aptos_framework::genesis;
    friend aptos_framework::reconfiguration;

    /// Lockup period is shorter than required.
    const ELOCK_TIME_TOO_SHORT: u64 = 1;
    /// Withdraw not allowed, the stake is still locked.
    const EWITHDRAW_NOT_ALLOWED: u64 = 2;
    /// Validator Config not published.
    const EVALIDATOR_CONFIG: u64 = 3;
    /// Not enough stake to join validator set.
    const ESTAKE_TOO_LOW: u64 = 4;
    /// Too much stake to join validator set.
    const ESTAKE_TOO_HIGH: u64 = 5;
    /// Account is already a validator or pending validator.
    const EALREADY_ACTIVE_VALIDATOR: u64 = 6;
    /// Account is not a validator.
    const ENOT_VALIDATOR: u64 = 7;
    /// Can't remove last validator.
    const ELAST_VALIDATOR: u64 = 8;
    /// Total stake exceeds maximum allowed.
    const ESTAKE_EXCEEDS_MAX: u64 = 9;
    /// Account is already registered as a validator candidate.
    const EALREADY_REGISTERED: u64 = 10;
    /// No coins in inactive state to withdraw from specified pool.
    const ENO_COINS_TO_WITHDRAW: u64 = 11;
    /// Account does not have the right operator capability.
    const ENOT_OPERATOR: u64 = 12;
    /// Lockup period is longer than allowed.
    const ELOCK_TIME_TOO_LONG: u64 = 13;
    const ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED: u64 = 14;
    /// Invalid consensus public key
    const EINVALID_PUBLIC_KEY: u64 = 15;
    /// Invalid stake amount (usuaully 0).
    const EINVALID_STAKE_AMOUNT: u64 = 16;
    /// Validator set exceeds the limit
    const EVALIDATOR_SET_TOO_LARGE: u64 = 17;

    /// Validator status enum. We can switch to proper enum later once Move supports it.
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    /// Limit the maximum size to u16::max, it's the current limit of the bitvec
    /// https://github.com/aptos-labs/aptos-core/blob/main/crates/aptos-bitvec/src/lib.rs#L20
    const MAX_VALIDATOR_SET_SIZE: u64 = 65536;

    /// Capability that represents ownership and can be used to control the validator and the associated stake pool.
    /// Having this be separate from the signer for the account that the validator resources are hosted at allows
    /// modules to have control over a validator.
    struct OwnerCapability has key, store {
        pool_address: address,
    }

    /// Each validator has a separate StakePool resource and can provide a stake.
    /// Changes in stake for an active validator:
    /// 1. If a validator calls add_stake, the newly added stake is moved to pending_active.
    /// 2. If validator calls unlock, their stake is moved to pending_inactive.
    /// 2. When the next epoch starts, any pending_inactive stake is moved to inactive and can be withdrawn.
    ///    Any pending_active stake is moved to active and adds to the validator's voting power.
    ///
    /// Changes in stake for an inactive validator:
    /// 1. If a validator calls add_stake, the newly added stake is moved directly to active.
    /// 2. If validator calls unlock, their stake is moved directly to inactive.
    /// 3. When the next epoch starts, the validator can be activated if their active stake is more than the minimum.
    struct StakePool has key {
        // active stake
        active: Coin<AptosCoin>,
        // inactive stake, can be withdrawn
        inactive: Coin<AptosCoin>,
        // pending activation for next epoch
        pending_active: Coin<AptosCoin>,
        // pending deactivation for next epoch
        pending_inactive: Coin<AptosCoin>,
        locked_until_secs: u64,
        // Track the current operator of the validator node.
        // This allows the operator to be different from the original account and allow for separation of
        // the validator operations and ownership.
        // Only the account holding OwnerCapability of the staking pool can update this.
        operator_address: address,

        // Track the current vote delegator of the staking pool.
        // Only the account holding OwnerCapability of the staking pool can update this.
        delegated_voter: address,

        // The events emitted for the entire StakePool's lifecycle.
        initialize_validator_events: EventHandle<RegisterValidatorCandidateEvent>,
        set_operator_events: EventHandle<SetOperatorEvent>,
        add_stake_events: EventHandle<AddStakeEvent>,
        rotate_consensus_key_events: EventHandle<RotateConsensusKeyEvent>,
        update_network_and_fullnode_addresses_events: EventHandle<UpdateNetworkAndFullnodeAddressesEvent>,
        increase_lockup_events: EventHandle<IncreaseLockupEvent>,
        join_validator_set_events: EventHandle<JoinValidatorSetEvent>,
        distribute_rewards_events: EventHandle<DistributeRewardsEvent>,
        unlock_stake_events: EventHandle<UnlockStakeEvent>,
        withdraw_stake_events: EventHandle<WithdrawStakeEvent>,
        leave_validator_set_events: EventHandle<LeaveValidatorSetEvent>,
    }

    /// Validator info stored in validator address.
    struct ValidatorConfig has key, copy, store, drop {
        consensus_pubkey: vector<u8>,
        network_addresses: vector<u8>,
        // to make it compatible with previous definition, remove later
        fullnode_addresses: vector<u8>,
        // Index in the active set if the validator corresponding to this stake pool is active.
        validator_index: u64,
    }

    /// Consensus information per validator, stored in ValidatorSet.
    struct ValidatorInfo has copy, store, drop {
        addr: address,
        voting_power: u64,
        config: ValidatorConfig,
    }

    /// Full ValidatorSet, stored in @aptos_framework.
    /// 1. join_validator_set adds to pending_active queue.
    /// 2. leave_valdiator_set moves from active to pending_inactive queue.
    /// 3. on_new_epoch processes two pending queues and refresh ValidatorInfo from the owner's address.
    struct ValidatorSet has key {
        consensus_scheme: u8,
        // active validators for the current epoch
        active_validators: vector<ValidatorInfo>,
        // pending validators to leave in next epoch (still active)
        pending_inactive: vector<ValidatorInfo>,
        // pending validators to join in next epoch
        pending_active: vector<ValidatorInfo>,
    }

    /// AptosCoin capabilities, set during genesis and stored in @CoreResource account.
    /// This allows the Stake module to mint rewards to stakers.
    struct AptosCoinCapabilities has key {
        mint_cap: MintCapability<AptosCoin>,
    }

    // TODO change all types to u32 ?
    struct IndividualValidatorPerformance has store, drop {
        successful_proposals: u64,
        failed_proposals: u64,
    }

    struct ValidatorPerformance has key {
        validators: vector<IndividualValidatorPerformance>,
    }

    struct RegisterValidatorCandidateEvent has drop, store {
        pool_address: address,
    }

    struct SetOperatorEvent has drop, store {
        pool_address: address,
        old_operator: address,
        new_operator: address,
    }

    struct AddStakeEvent has drop, store {
        pool_address: address,
        amount_added: u64,
    }

    struct RotateConsensusKeyEvent has drop, store {
        pool_address: address,
        old_consensus_pubkey: vector<u8>,
        new_consensus_pubkey: vector<u8>,
    }

    struct UpdateNetworkAndFullnodeAddressesEvent has drop, store {
        pool_address: address,
        old_network_addresses: vector<u8>,
        new_network_addresses: vector<u8>,
        old_fullnode_addresses: vector<u8>,
        new_fullnode_addresses: vector<u8>,
    }

    struct IncreaseLockupEvent has drop, store {
        pool_address: address,
        old_locked_until_secs: u64,
        new_locked_until_secs: u64,
    }

    struct JoinValidatorSetEvent has drop, store {
        pool_address: address,
    }

    struct DistributeRewardsEvent has drop, store {
        pool_address: address,
        rewards_amount: u64,
    }

    struct UnlockStakeEvent has drop, store {
        pool_address: address,
        amount_unlocked: u64,
    }

    struct WithdrawStakeEvent has drop, store {
        pool_address: address,
        amount_withdrawn: u64,
    }

    struct LeaveValidatorSetEvent has drop, store {
        pool_address: address,
    }

    /// Return the lockup expiration of the stake pool at `pool_address`.
    /// This will throw an error if there's no stake pool at `pool_address`.
    public fun get_lockup_secs(pool_address: address): u64 acquires StakePool {
        borrow_global<StakePool>(pool_address).locked_until_secs
    }

    /// Return the remaining lockup of the stake pool at `pool_address`.
    /// This will throw an error if there's no stake pool at `pool_address`.
    public fun get_remaining_lockup_secs(pool_address: address): u64 acquires StakePool {
        let lockup_time = borrow_global<StakePool>(pool_address).locked_until_secs;
        if (lockup_time <= timestamp::now_seconds()) {
            0
        } else {
            lockup_time - timestamp::now_seconds()
        }
    }

    /// Return the different stake amounts for `pool_address` (whether the validator is active or not).
    /// The returned amounts are for (active, inactive, pending_active, pending_inactive) stake respectively.
    public fun get_stake(pool_address: address): (u64, u64, u64, u64) acquires StakePool {
        let stake_pool = borrow_global<StakePool>(pool_address);
        (
            coin::value<AptosCoin>(&stake_pool.active),
            coin::value<AptosCoin>(&stake_pool.inactive),
            coin::value<AptosCoin>(&stake_pool.pending_active),
            coin::value<AptosCoin>(&stake_pool.pending_inactive),
        )
    }

    /// Returns the validator's state.
    public fun get_validator_state(pool_address: address): u64 acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        if (option::is_some(&find_validator(&validator_set.pending_active, pool_address))) {
            VALIDATOR_STATUS_PENDING_ACTIVE
        } else if (option::is_some(&find_validator(&validator_set.active_validators, pool_address))) {
            VALIDATOR_STATUS_ACTIVE
        } else if (option::is_some(&find_validator(&validator_set.pending_inactive, pool_address))) {
            VALIDATOR_STATUS_PENDING_INACTIVE
        } else {
            VALIDATOR_STATUS_INACTIVE
        }
    }

    /// Return the voting power of the validator in the current epoch.
    /// This is the same as the validator's total active and pending_inactive stake.
    public fun get_current_epoch_voting_power(pool_address: address): u64 acquires StakePool, ValidatorSet {
        let validator_state = get_validator_state(pool_address);
        // Both active and pending inactive validators can still vote in the current epoch.
        if (validator_state == VALIDATOR_STATUS_ACTIVE || validator_state == VALIDATOR_STATUS_PENDING_INACTIVE) {
            let active_stake = coin::value<AptosCoin>(&borrow_global<StakePool>(pool_address).active);
            let pending_inactive_stake = coin::value<AptosCoin>(&borrow_global<StakePool>(pool_address).pending_inactive);
            active_stake + pending_inactive_stake
        } else {
            0
        }
    }

    /// Return the delegated voter of the validator at `pool_address`.
    public fun get_delegated_voter(pool_address: address): address acquires StakePool {
        borrow_global<StakePool>(pool_address).delegated_voter
    }

    /// Return the operator of the validator at `pool_address`.
    public fun get_operator(pool_address: address): address acquires StakePool {
        borrow_global<StakePool>(pool_address).operator_address
    }

    /// Return the pool address in `owner_cap`.
    public fun get_owned_pool_address(owner_cap: &OwnerCapability): address {
        owner_cap.pool_address
    }

    /// Return the validator index for `pool_address`.
    public fun get_validator_index(pool_address: address): u64 acquires ValidatorConfig {
        borrow_global<ValidatorConfig>(pool_address).validator_index
    }

    /// Return the number of successful and failed proposals for the proposal at the given validator index.
    public fun get_current_epoch_proposal_counts(validator_index: u64): (u64, u64) acquires ValidatorPerformance {
        let validator_performances = &borrow_global<ValidatorPerformance>(@aptos_framework).validators;
        let validator_performance = vector::borrow(validator_performances, validator_index);
        (validator_performance.successful_proposals, validator_performance.failed_proposals)
    }

    /// Return the validator's config.
    public fun get_validator_config(pool_address: address): (vector<u8>, vector<u8>, vector<u8>) acquires ValidatorConfig {
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        (validator_config.consensus_pubkey, validator_config.network_addresses, validator_config.fullnode_addresses)
    }

    /// Initialize validator set to the core resource account.
    public(friend) fun initialize(aptos_framework: &signer) {
        system_addresses::assert_aptos_framework(aptos_framework);

        move_to(aptos_framework, ValidatorSet {
            consensus_scheme: 0,
            active_validators: vector::empty(),
            pending_active: vector::empty(),
            pending_inactive: vector::empty(),
        });

        move_to(aptos_framework, ValidatorPerformance {
            validators: vector::empty(),
        });
    }

    /// This is only called during Genesis, which is where MintCapability<AptosCoin> can be created.
    /// Beyond genesis, no one can create AptosCoin mint/burn capabilities.
    public(friend) fun store_aptos_coin_mint_cap(account: &signer, mint_cap: MintCapability<AptosCoin>) {
        system_addresses::assert_aptos_framework(account);
        move_to(account, AptosCoinCapabilities { mint_cap })
    }

    /// Initialize the validator account and give ownership to the signing account
    /// except it leaves the ValidatorConfig to be set by another entity.
    /// Note: this triggers setting the operator and owner, set it to the account's address
    /// to set later.
    public entry fun initialize_owner_only(
        owner: &signer,
        initial_stake_amount: u64,
        operator: address,
        voter: address,
    ) acquires OwnerCapability, StakePool, ValidatorSet {
        initialize_owner(owner);
        move_to(owner, ValidatorConfig {
            consensus_pubkey: vector::empty(),
            network_addresses: vector::empty(),
            fullnode_addresses: vector::empty(),
            validator_index: 0,
        });

        if (initial_stake_amount > 0) {
            add_stake(owner, initial_stake_amount);
        };

        let account_address = signer::address_of(owner);
        if (account_address != operator) {
            set_operator(owner, operator)
        };
        if (account_address != voter) {
            set_delegated_voter(owner, voter)
        };
    }

    /// Initialize the validator account and give ownership to the signing account.
    public entry fun initialize_validator(
        account: &signer,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        fullnode_addresses: vector<u8>,
    ) {
        assert!(signature::bls12381_verify_proof_of_possession(consensus_pubkey, proof_of_possession), error::invalid_argument(EINVALID_PUBLIC_KEY));

        initialize_owner(account);
        move_to(account, ValidatorConfig {
            consensus_pubkey,
            network_addresses,
            fullnode_addresses,
            validator_index: 0,
        });
    }

    fun initialize_owner(owner: &signer) {
        let owner_address = signer::address_of(owner);
        assert!(!exists<StakePool>(owner_address), error::invalid_argument(EALREADY_REGISTERED));

        move_to(owner, StakePool {
            active: coin::zero<AptosCoin>(),
            pending_active: coin::zero<AptosCoin>(),
            pending_inactive: coin::zero<AptosCoin>(),
            inactive: coin::zero<AptosCoin>(),
            locked_until_secs: 0,
            operator_address: owner_address,
            delegated_voter: owner_address,

            // Events.
            initialize_validator_events: event::new_event_handle<RegisterValidatorCandidateEvent>(owner),
            set_operator_events: event::new_event_handle<SetOperatorEvent>(owner),
            add_stake_events: event::new_event_handle<AddStakeEvent>(owner),
            rotate_consensus_key_events: event::new_event_handle<RotateConsensusKeyEvent>(owner),
            update_network_and_fullnode_addresses_events: event::new_event_handle<UpdateNetworkAndFullnodeAddressesEvent>(owner),
            increase_lockup_events: event::new_event_handle<IncreaseLockupEvent>(owner),
            join_validator_set_events: event::new_event_handle<JoinValidatorSetEvent>(owner),
            distribute_rewards_events: event::new_event_handle<DistributeRewardsEvent>(owner),
            unlock_stake_events: event::new_event_handle<UnlockStakeEvent>(owner),
            withdraw_stake_events: event::new_event_handle<WithdrawStakeEvent>(owner),
            leave_validator_set_events: event::new_event_handle<LeaveValidatorSetEvent>(owner),
        });

        move_to(owner, OwnerCapability { pool_address: owner_address });
    }

    /// Extract and return owner capability from the signing account.
    public fun extract_owner_cap(account: &signer): OwnerCapability acquires OwnerCapability {
        move_from<OwnerCapability>(signer::address_of(account))
    }

    /// Deposit `owner_cap` into `account`. This requires `account` to not already have owernship of another
    /// staking pool.
    public fun deposit_owner_cap(account: &signer, owner_cap: OwnerCapability) {
        move_to(account, owner_cap);
    }

    /// Allows an owner to change the operator of the stake pool.
    public entry fun set_operator(account: &signer, new_operator: address) acquires OwnerCapability, StakePool {
        let account_addr = signer::address_of(account);
        let ownership_cap = borrow_global<OwnerCapability>(account_addr);
        set_operator_with_cap(ownership_cap, new_operator);
    }

    /// Allows an account with ownership capability to change the operator of the stake pool.
    public fun set_operator_with_cap(owner_cap: &OwnerCapability, new_operator: address) acquires StakePool {
        let pool_address = owner_cap.pool_address;
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let old_operator = stake_pool.operator_address;
        stake_pool.operator_address = new_operator;

        event::emit_event<SetOperatorEvent>(
            &mut stake_pool.set_operator_events,
            SetOperatorEvent {
                pool_address,
                old_operator,
                new_operator,
            },
        );
    }

    /// Allows an owner to change the delegated voter of the stake pool.
    public entry fun set_delegated_voter(
        account: &signer, new_delegated_voter: address) acquires OwnerCapability, StakePool {
        let account_addr = signer::address_of(account);
        let ownership_cap = borrow_global<OwnerCapability>(account_addr);
        set_delegated_voter_with_cap(ownership_cap, new_delegated_voter);
    }

    /// Allows an owner to change the delegated voter of the stake pool.
    public fun set_delegated_voter_with_cap(
        owner_cap: &OwnerCapability, new_delegated_voter: address) acquires StakePool {
        let stake_pool = borrow_global_mut<StakePool>(owner_cap.pool_address);
        stake_pool.delegated_voter = new_delegated_voter;
    }

    /// Add `amount` of coins from the `account` owning the StakePool.
    public entry fun add_stake(
        account: &signer,
        amount: u64,
    ) acquires OwnerCapability, StakePool, ValidatorSet {
        let account_addr = signer::address_of(account);
        let ownership_cap = borrow_global<OwnerCapability>(account_addr);
        add_stake_with_cap(ownership_cap, coin::withdraw<AptosCoin>(account, amount));
    }

    /// Add `coins` into `pool_address`. this requires the corresponding `owner_cap` to be passed in.
    public fun add_stake_with_cap(
        owner_cap: &OwnerCapability, coins: Coin<AptosCoin>) acquires StakePool, ValidatorSet {
        let pool_address = owner_cap.pool_address;

        let amount = coin::value<AptosCoin>(&coins);
        assert!(amount > 0, error::invalid_argument(EINVALID_STAKE_AMOUNT));

        // Add to pending_active if it's a current validator because the stake is not counted until the next epoch.
        // Otherwise, the delegation can be added to active directly as the validator is also activated in the epoch.
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        if (is_current_epoch_validator(pool_address)) {
            coin::merge<AptosCoin>(&mut stake_pool.pending_active, coins);
        } else {
            coin::merge<AptosCoin>(&mut stake_pool.active, coins);
        };

        let (_, maximum_stake) = staking_config::get_required_stake(&staking_config::get());
        let next_epoch_stake = coin::value<AptosCoin>(&stake_pool.active) +
                          coin::value<AptosCoin>(&stake_pool.pending_inactive) +
                          coin::value<AptosCoin>(&stake_pool.pending_active);
        assert!(next_epoch_stake <= maximum_stake, error::invalid_argument(ESTAKE_EXCEEDS_MAX));

        event::emit_event<AddStakeEvent>(
            &mut stake_pool.add_stake_events,
            AddStakeEvent {
                pool_address,
                amount_added: amount,
            },
        );
    }

    /// Rotate the consensus key of the validator, it'll take effect in next epoch.
    public entry fun rotate_consensus_key(
        account: &signer,
        pool_address: address,
        new_consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
    ) acquires StakePool, ValidatorConfig {
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        assert!(signer::address_of(account) == stake_pool.operator_address, error::invalid_argument(ENOT_OPERATOR));

        assert!(exists<ValidatorConfig>(pool_address), error::not_found(EVALIDATOR_CONFIG));
        let validator_info = borrow_global_mut<ValidatorConfig>(pool_address);
        let old_consensus_pubkey = validator_info.consensus_pubkey;
        assert!(signature::bls12381_verify_proof_of_possession(new_consensus_pubkey, proof_of_possession), error::invalid_argument(EINVALID_PUBLIC_KEY));
        validator_info.consensus_pubkey = new_consensus_pubkey;

        event::emit_event<RotateConsensusKeyEvent>(
            &mut stake_pool.rotate_consensus_key_events,
            RotateConsensusKeyEvent {
                pool_address,
                old_consensus_pubkey,
                new_consensus_pubkey,
            },
        );
    }

    /// Update the network and full node addresses of the validator. This only takes effect in the next epoch.
    public entry fun update_network_and_fullnode_addresses(
        account: &signer,
        pool_address: address,
        new_network_addresses: vector<u8>,
        new_fullnode_addresses: vector<u8>,
    ) acquires StakePool, ValidatorConfig {
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        assert!(signer::address_of(account) == stake_pool.operator_address, error::invalid_argument(ENOT_OPERATOR));

        assert!(exists<ValidatorConfig>(pool_address), error::not_found(EVALIDATOR_CONFIG));
        let validator_info = borrow_global_mut<ValidatorConfig>(pool_address);
        let old_network_addresses = validator_info.network_addresses;
        validator_info.network_addresses = new_network_addresses;
        let old_fullnode_addresses = validator_info.fullnode_addresses;
        validator_info.fullnode_addresses = new_fullnode_addresses;

        event::emit_event<UpdateNetworkAndFullnodeAddressesEvent>(
            &mut stake_pool.update_network_and_fullnode_addresses_events,
            UpdateNetworkAndFullnodeAddressesEvent {
                pool_address,
                old_network_addresses,
                new_network_addresses,
                old_fullnode_addresses,
                new_fullnode_addresses,
            },
        );
    }

    /// Similar to increase_lockup_with_cap but will use ownership capability from the signing account.
    public entry fun increase_lockup(account: &signer) acquires OwnerCapability, StakePool {
        let account_addr = signer::address_of(account);
        let ownership_cap = borrow_global<OwnerCapability>(account_addr);
        increase_lockup_with_cap(ownership_cap);
    }

    /// Unlock from active delegation, it's moved to pending_inactive if locked_until_secs < current_time or
    /// directly inactive if it's not from an active validator.
    public fun increase_lockup_with_cap(owner_cap: &OwnerCapability) acquires StakePool {
        let pool_address = owner_cap.pool_address;
        let config = staking_config::get();

        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let old_locked_until_secs = stake_pool.locked_until_secs;
        stake_pool.locked_until_secs = timestamp::now_seconds() + staking_config::get_recurring_lockup_duration(&config);

        event::emit_event<IncreaseLockupEvent>(
            &mut stake_pool.increase_lockup_events,
            IncreaseLockupEvent {
                pool_address,
                old_locked_until_secs,
                new_locked_until_secs: stake_pool.locked_until_secs,
            },
        );
    }

    /// This can only called by the operator of the validator/staking pool.
    public entry fun join_validator_set(
        account: &signer, pool_address: address) acquires StakePool, ValidatorConfig, ValidatorSet {
        assert!(
            staking_config::get_allow_validator_set_change(&staking_config::get()),
            error::invalid_argument(ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED),
        );

        join_validator_set_internal(account, pool_address);
    }

    /// Request to have `pool_address` join the validator set. Can only be called after calling `initialize_validator`.
    /// If the validator has the required stake (more than minimum and less than maximum allowed), they will be
    /// added to the pending_active queue. All validators in this queue will be added to the active set when the next
    /// epoch starts (eligibility will be rechecked).
    ///
    /// This internal version can only be called by the Genesis module during Genesis.
    public(friend) fun join_validator_set_internal(
        account: &signer, pool_address: address) acquires StakePool, ValidatorConfig, ValidatorSet {
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        // Account has to be the operator.
        assert!(signer::address_of(account) == stake_pool.operator_address, error::invalid_argument(ENOT_OPERATOR));

        // Throw an error is the validator is already active.
        assert!(
            get_validator_state(pool_address) == VALIDATOR_STATUS_INACTIVE,
            error::invalid_argument(EALREADY_ACTIVE_VALIDATOR),
        );

        // Requires the validator to have a lockup more than the minimum.
        let config = staking_config::get();
        let (minimum_stake, maximum_stake) = staking_config::get_required_stake(&config);

        // The validator is not yet activated so all added stake should be in active.
        let voting_power = coin::value<AptosCoin>(&stake_pool.active);
        assert!(voting_power >= minimum_stake, error::invalid_argument(ESTAKE_TOO_LOW));
        assert!(voting_power <= maximum_stake, error::invalid_argument(ESTAKE_TOO_HIGH));

        // Add validator to pending_active, to be activated in the next epoch.
        let validator_config = borrow_global_mut<ValidatorConfig>(pool_address);
        assert!(!vector::is_empty(&validator_config.consensus_pubkey), error::invalid_argument(EINVALID_PUBLIC_KEY));

        let validator_set = borrow_global_mut<ValidatorSet>(@aptos_framework);
        let validator_set_size = vector::length(&validator_set.active_validators) + vector::length(&validator_set.pending_active);
        assert!( validator_set_size <= MAX_VALIDATOR_SET_SIZE, error::invalid_argument(EVALIDATOR_SET_TOO_LARGE));
        vector::push_back(&mut validator_set.pending_active, generate_validator_info(pool_address, stake_pool, *validator_config));

        event::emit_event<JoinValidatorSetEvent>(
            &mut stake_pool.join_validator_set_events,
            JoinValidatorSetEvent { pool_address },
        );
    }

    /// Similar to unlock_with_cap but will use ownership capability from the signing account.
    public entry fun unlock(account: &signer, amount: u64) acquires OwnerCapability, StakePool {
        let account_addr = signer::address_of(account);
        let ownership_cap = borrow_global<OwnerCapability>(account_addr);
        unlock_with_cap(amount, ownership_cap);
    }

    /// Unlock `amount` from the active stake. Only possible if the lockup has expired.
    public fun unlock_with_cap(amount: u64, owner_cap: &OwnerCapability) acquires StakePool {
        // Short-circuit if amount to unlock is 0 so we don't emit events.
        if (amount == 0) {
            return
        };

        // Unlocked coins are moved to pending_inactive. When the current lockup cycle expires, they will be moved into
        // inactive in the earliest possible epoch transition.
        let pool_address = owner_cap.pool_address;
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let unlocked_stake = coin::extract<AptosCoin>(&mut stake_pool.active, amount);
        coin::merge<AptosCoin>(&mut stake_pool.pending_inactive, unlocked_stake);

        event::emit_event<UnlockStakeEvent>(
            &mut stake_pool.unlock_stake_events,
            UnlockStakeEvent {
                pool_address,
                amount_unlocked: amount,
            },
        );
    }

    /// Withdraw from `account`'s inactive stake.
    public entry fun withdraw(
        account: &signer, withdraw_amount: u64) acquires OwnerCapability, StakePool, ValidatorSet {
        let account_addr = signer::address_of(account);
        let ownership_cap = borrow_global<OwnerCapability>(account_addr);
        let coins = withdraw_with_cap(ownership_cap, withdraw_amount);
        coin::deposit<AptosCoin>(account_addr, coins);
    }

    /// Withdraw from `pool_address`'s inactive stake with the corresponding `owner_cap`.
    public fun withdraw_with_cap(
        owner_cap: &OwnerCapability, withdraw_amount: u64): Coin<AptosCoin> acquires StakePool, ValidatorSet {
        let pool_address = owner_cap.pool_address;
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        // There's an edge case where a validator unlocks their stake and leaves the validator set before
        // the stake is fully unlocked (the current lockup cycle has not expired yet).
        // This can leave their stake stuck in pending_inactive even after the current lockup cycle expires.
        if (get_validator_state(pool_address) == VALIDATOR_STATUS_INACTIVE &&
            timestamp::now_seconds() >= stake_pool.locked_until_secs) {
            let pending_inactive_stake = coin::extract_all(&mut stake_pool.pending_inactive);
            coin::merge(&mut stake_pool.inactive, pending_inactive_stake);
        };

        let total_withdrawable_amount = coin::value<AptosCoin>(&stake_pool.inactive);
        // Cap withdraw amount by total withdrawable.
        if (withdraw_amount > total_withdrawable_amount) {
            withdraw_amount = total_withdrawable_amount;
        };
        assert!(withdraw_amount > 0, error::invalid_argument(ENO_COINS_TO_WITHDRAW));

        event::emit_event<WithdrawStakeEvent>(
            &mut stake_pool.withdraw_stake_events,
            WithdrawStakeEvent {
                pool_address,
                amount_withdrawn: withdraw_amount,
            },
        );

        coin::extract<AptosCoin>(&mut stake_pool.inactive, withdraw_amount)
    }

    /// Request to have `pool_address` leave the validator set. The validator is only actually removed from the set when
    /// the next epoch starts.
    /// The last validator in the set cannot leave. This is an edge case that should never happen as long as the network
    /// is still operational.
    ///
    /// Can only be called by the operator of the validator/staking pool.
    public entry fun leave_validator_set(
        account: &signer, pool_address: address) acquires StakePool, ValidatorSet {
        let config = staking_config::get();
        assert!(
            staking_config::get_allow_validator_set_change(&config),
            error::invalid_argument(ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED),
        );
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        // Account has to be the operator.
        assert!(signer::address_of(account) == stake_pool.operator_address, error::invalid_argument(ENOT_OPERATOR));

        let validator_set = borrow_global_mut<ValidatorSet>(@aptos_framework);
        // Validate that the validator is already part of the validator set.
        let maybe_index = find_validator(&validator_set.active_validators, pool_address);
        assert!(option::is_some(&maybe_index), error::invalid_argument(ENOT_VALIDATOR));
        let index = option::extract(&mut maybe_index);

        let validator_info = vector::swap_remove(&mut validator_set.active_validators, index);
        assert!(vector::length(&validator_set.active_validators) > 0, error::invalid_argument(ELAST_VALIDATOR));
        vector::push_back(&mut validator_set.pending_inactive, validator_info);

        event::emit_event<LeaveValidatorSetEvent>(
            &mut stake_pool.leave_validator_set_events,
            LeaveValidatorSetEvent {
                pool_address,
            },
        );
    }

    /// Returns true if the current validator can still vote in the current epoch.
    /// This includes validators that requested to leave but are still in the pending_inactive queue and will be removed
    /// when the epoch starts.
    public fun is_current_epoch_validator(pool_address: address): bool acquires ValidatorSet {
        let validator_state = get_validator_state(pool_address);
        validator_state == VALIDATOR_STATUS_ACTIVE || validator_state == VALIDATOR_STATUS_PENDING_INACTIVE
    }

    /// Update the validator performance (proposal statistics). This is only called by block::prologue().
    /// This function cannot abort.
    public(friend) fun update_performance_statistics(proposer_index_optional: vector<u64>, failed_proposer_indices: vector<u64>) acquires ValidatorPerformance {
        // Validator set cannot change until the end of the epoch, so the validator index in arguments should
        // match with those of the validators in ValidatorPerformance resource.
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@aptos_framework);
        let validator_len = vector::length(&validator_perf.validators);

        // proposer_indices is a vector because it can be missing (for NilBlocks)
        if (vector::length(&proposer_index_optional) >= 1) {
            let proposer_index = *vector::borrow(&proposer_index_optional, 0);
            // Here, and in all other vector::borrow, skip any validator indices that are out of bounds,
            // this ensures that this function doesn't abort if there are out of bounds errors.
            if (proposer_index < validator_len) {
                let validator = vector::borrow_mut(&mut validator_perf.validators, proposer_index);
                validator.successful_proposals = validator.successful_proposals + 1;
            };
        };

        let f = 0;
        let f_len = vector::length(&failed_proposer_indices);
        while (f < f_len) {
            let validator_index = *vector::borrow(&failed_proposer_indices, f);
            if (validator_index < validator_len) {
                let validator = vector::borrow_mut(&mut validator_perf.validators, validator_index);
                validator.failed_proposals = validator.failed_proposals + 1;
            };
            f = f + 1;
        };
    }

    /// Triggers at epoch boundary. This function shouldn't abort.
    ///
    /// 1. Distribute rewards to stake pools of active and pending inactive validators (requested to leave but not yet
    /// removed).
    /// 2. Officially move pending active stake to active and move pending inactive stake to inactive.
    /// The staking pool's voting power in this new epoch will be updated to the total active stake.
    /// 3. Add pending active validators to the active set if they satisfy requirements so they can vote and remove
    /// pending inactive validators so they no longer can vote.
    /// 4. The validator's voting power in the validator set is updated to be the corresponding staking pool's voting
    /// power.
    public(friend) fun on_new_epoch() acquires StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let validator_set = borrow_global_mut<ValidatorSet>(@aptos_framework);
        let config = staking_config::get();
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@aptos_framework);

        // Process pending stake and distribute rewards for each currently active validator.
        let i = 0;
        let len = vector::length(&validator_set.active_validators);
        while (i < len) {
            let validator = vector::borrow(&validator_set.active_validators, i);
            update_stake_pool(validator_perf, validator.addr, &config);
            i = i + 1;
        };

        // Process pending stake and distribute rewards for each currently pending_inactive validator (requested to
        // leave but not removed yet).
        let i = 0;
        let len = vector::length(&validator_set.pending_inactive);
        while (i < len) {
            let validator = vector::borrow(&validator_set.pending_inactive, i);
            update_stake_pool(validator_perf, validator.addr, &config);
            i = i + 1;
        };

        // Activate currently pending_active validators.
        append(&mut validator_set.active_validators, &mut validator_set.pending_active);

        // Officially deactivate all pending_inactive validators. They will now no longer receive rewards.
        validator_set.pending_inactive = vector::empty();

        let (minimum_stake, _) = staking_config::get_required_stake(&config);
        let recurring_lockup_duration_secs = staking_config::get_recurring_lockup_duration(&config);
        // Reset performance scores and update active validator set (so network address/public key change takes effect).
        let i = 0;
        let validator_index = 0;
        let len = vector::length(&validator_set.active_validators);
        let next_epoch_validators = vector::empty();
        validator_perf.validators = vector::empty();
        while (i < len) {
            let old_validator_info = vector::borrow_mut(&mut validator_set.active_validators, i);
            let pool_address = old_validator_info.addr;
            let validator_config = borrow_global_mut<ValidatorConfig>(pool_address);
            validator_config.validator_index = validator_index;
            let stake_pool = borrow_global_mut<StakePool>(pool_address);
            let new_validator_info = generate_validator_info(pool_address, stake_pool, *validator_config);

            // A validator needs at least the min stake required to join the validator set.
            i = i + 1;
            if (new_validator_info.voting_power < minimum_stake) {
                continue
            };
            // index only increments if the node joins the validator set
            validator_index = validator_index + 1;

            vector::push_back(&mut next_epoch_validators, new_validator_info);
            vector::push_back(&mut validator_perf.validators, IndividualValidatorPerformance {
                successful_proposals: 0,
                failed_proposals: 0,
            });

            // Automatically renew a validator's lockup for validators that will still be in the validator set in the
            // next epoch.
            let stake_pool = borrow_global_mut<StakePool>(pool_address);
            if (stake_pool.locked_until_secs <= timestamp::now_seconds()) {
                stake_pool.locked_until_secs =
                    timestamp::now_seconds() + recurring_lockup_duration_secs;
            };
        };

        validator_set.active_validators = next_epoch_validators;
    }

    /// Update individual validator's stake pool
    /// 1. distribute rewards to active/pending_inactive delegations
    /// 2. process pending_active, pending_inactive correspondingly
    /// This function shouldn't abort.
    fun update_stake_pool(
        validator_perf: &ValidatorPerformance,
        pool_address: address,
        staking_config: &StakingConfig,
    ) acquires StakePool, AptosCoinCapabilities, ValidatorConfig {
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        let cur_validator_perf = vector::borrow(&validator_perf.validators, validator_config.validator_index);
        let num_successful_proposals = cur_validator_perf.successful_proposals;
        let num_total_proposals = cur_validator_perf.successful_proposals + cur_validator_perf.failed_proposals;

        let (rewards_rate, rewards_rate_denominator) = staking_config::get_reward_rate(staking_config);
        let rewards_amount = distribute_rewards(
             &mut stake_pool.active,
            num_successful_proposals,
            num_total_proposals,
            rewards_rate,
            rewards_rate_denominator
        );
        rewards_amount = rewards_amount + distribute_rewards(
            &mut stake_pool.pending_inactive,
            num_successful_proposals,
            num_total_proposals,
            rewards_rate,
            rewards_rate_denominator
        );

        // Pending active stake can now be active.
        coin::merge<AptosCoin>(&mut stake_pool.active, coin::extract_all<AptosCoin>(&mut stake_pool.pending_active));

        // Pending inactive stake is only fully unlocked and moved into inactive if the current lockup cycle has expired
        let current_lockup_expiration = stake_pool.locked_until_secs;
        if (timestamp::now_seconds() >= current_lockup_expiration) {
            coin::merge<AptosCoin>(
                &mut stake_pool.inactive,
                coin::extract_all<AptosCoin>(&mut stake_pool.pending_inactive),
            );
        };

        event::emit_event<DistributeRewardsEvent>(
            &mut stake_pool.distribute_rewards_events,
            DistributeRewardsEvent {
                pool_address,
                rewards_amount,
            },
        );
    }

    /// Calculate the rewards amount.
    fun calculate_rewards_amount(
        stake_amount: u64,
        num_successful_proposals: u64,
        num_total_proposals: u64,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
    ): u64 {
        // The rewards amount is equal to (stake amount * rewards rate * performance multiplier).
        // We do multiplication in u128 before division to avoid the overflow and minimize the rounding error.
        let rewards_numerator = (stake_amount as u128) * (rewards_rate as u128) * (num_successful_proposals as u128);
        let rewards_denominator = (rewards_rate_denominator as u128) * (num_total_proposals as u128);
        if (rewards_denominator > 0) {
            ((rewards_numerator / rewards_denominator) as u64)
        } else {
            0
        }
    }

    /// Mint rewards corresponding to current epoch's `stake` and `num_successful_votes`.
    fun distribute_rewards(
        stake: &mut Coin<AptosCoin>,
        num_successful_proposals: u64,
        num_total_proposals: u64,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
    ): u64 acquires AptosCoinCapabilities {
        let stake_amount = coin::value<AptosCoin>(stake);
        let rewards_amount = if (stake_amount > 0) {
            calculate_rewards_amount(stake_amount, num_successful_proposals, num_total_proposals, rewards_rate, rewards_rate_denominator)
        } else {
            0
        };
        if (rewards_amount > 0) {
            let mint_cap = &borrow_global<AptosCoinCapabilities>(@aptos_framework).mint_cap;
            let rewards = coin::mint<AptosCoin>(rewards_amount, mint_cap);
            coin::merge(stake, rewards);
        };
        rewards_amount
    }

    fun append<T>(v1: &mut vector<T>, v2: &mut vector<T>) {
        while (!vector::is_empty(v2)) {
            vector::push_back(v1, vector::pop_back(v2));
        }
    }

    fun find_validator(v: &vector<ValidatorInfo>, addr: address): Option<u64> {
        let i = 0;
        let len = vector::length(v);
        while (i < len) {
            if (vector::borrow(v, i).addr == addr) {
                return option::some(i)
            };
            i = i + 1;
        };
        option::none()
    }

    fun generate_validator_info(addr: address, stake_pool: &StakePool, config: ValidatorConfig): ValidatorInfo {
        // As pending_active stake has been activated. The new epoch's voting power is just the pool's
        // total active stake and pending_inactive stake.
        let voting_power =
            coin::value<AptosCoin>(&stake_pool.active) + coin::value<AptosCoin>(&stake_pool.pending_inactive);
        ValidatorInfo {
            addr,
            voting_power,
            config,
        }
    }

    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    const CONSENSUS_KEY_1: vector<u8> = x"8a54b92288d4ba5073d3a52e80cc00ae9fbbc1cc5b433b46089b7804c38a76f00fc64746c7685ee628fc2d0b929c2294";
    #[test_only]
    const CONSENSUS_POP_1: vector<u8> = x"a9d6c1f1270f2d1454c89a83a4099f813a56dc7db55591d46aa4e6ccae7898b234029ba7052f18755e6fa5e6b73e235f14efc4e2eb402ca2b8f56bad69f965fc11b7b25eb1c95a06f83ddfd023eac4559b6582696cfea97b227f4ce5bdfdfed0";

    #[test_only]
    const CONSENSUS_KEY_2: vector<u8> = x"a344eb437bcd8096384206e1be9c80be3893fd7fdf867acce5a048e5b1546028bdac4caf419413fd16d4d6a609e0b0a3";
    #[test_only]
    const CONSENSUS_POP_2: vector<u8> = x"909d3a378ad5c17faf89f7a2062888100027eda18215c7735f917a4843cd41328b42fa4242e36dedb04432af14608973150acbff0c5d3f325ba04b287be9747398769a91d4244689cfa9c535a5a4d67073ee22090d5ab0a88ab8d2ff680e991e";

    #[test_only]
    const EPOCH_DURATION: u64 = 60;

    #[test_only]
    const LOCKUP_CYCLE_SECONDS: u64 = 3600;

    #[test_only]
    public entry fun test_setup(aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        initialize(aptos_framework);
        staking_config::initialize_for_test(aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 100);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10009)]
    public entry fun test_inactive_validator_cannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, ValidatorConfig, ValidatorSet {
        test_setup(&aptos_framework);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        let validator_address = signer::address_of(&validator);
        coin::deposit(validator_address, coin::mint(9901, &mint_cap));
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Add more stake to exceed max. This should fail.
        add_stake(&validator, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10009)]
    public entry fun test_pending_active_validator_cannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, ValidatorConfig, ValidatorSet {
        test_setup(&aptos_framework);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        let validator_address = signer::address_of(&validator);
        coin::deposit(validator_address, coin::mint(9901, &mint_cap));
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Join validator set but epoch has not ended so validator is in pending_active state.
        join_validator_set(&validator, validator_address);

        // Add more stake to exceed max. This should fail.
        add_stake(&validator, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10009)]
    public entry fun test_active_validator_cannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: signer,
        validator: signer,
    ) acquires AptosCoinCapabilities, OwnerCapability, StakePool, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        let validator_address = signer::address_of(&validator);
        coin::deposit(validator_address, coin::mint(9901, &mint_cap));
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Join validator set and wait for epoch end to become active.
        join_validator_set(&validator, validator_address);
        end_epoch();

        // Add more stake to exceed max. This should fail.
        add_stake(&validator, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10009)]
    public entry fun test_active_validator_with_pending_inactive_stake_cannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: signer,
        validator: signer,
    ) acquires AptosCoinCapabilities, OwnerCapability, StakePool, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        let validator_address = signer::address_of(&validator);
        coin::deposit(validator_address, coin::mint(9901, &mint_cap));
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Join validator set and wait for epoch end to become active.
        join_validator_set(&validator, validator_address);
        end_epoch();

        // Request to unlock 50 coins, which go to pending_inactive. Validator 50 remaining in active.
        unlock(&validator, 50);
        assert_validator_state(validator_address, 50, 0, 0, 50, 0);

        // Add 9901 more. Total stake is 50 (active) + 50 (pending_inactive) + 9901 > 10000 so still exceeding max.
        add_stake(&validator, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123, other_validator = @0x234)]
    #[expected_failure(abort_code = 0x10009)]
    public entry fun test_pending_inactivecannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: signer,
        validator: signer,
        other_validator: signer,
    ) acquires AptosCoinCapabilities, OwnerCapability, StakePool, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        register_mint_stake(&other_validator, &mint_cap);
        let validator_address = signer::address_of(&validator);
        coin::deposit(validator_address, coin::mint(9901, &mint_cap));
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Join validator set and wait for epoch end to become active.
        join_validator_set(&validator, validator_address);
        // Need another validator in the set so the first validator can leave later.
        join_validator_set(&other_validator, signer::address_of(&other_validator));
        end_epoch();

        // Leave validator set so validator is in pending_inactive state.
        leave_validator_set(&validator, validator_address);

        // Add 9901 more. Total stake is 50 (active) + 50 (pending_inactive) + 9901 > 10000 so still exceeding max.
        add_stake(&validator, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_end_to_end(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        let validator_address = signer::address_of(&validator);
        join_test_staking(&aptos_framework, &validator, true);

        // Validator has a lockup now that they've joined the validator set.
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 1);

        // Validator adds more stake while already being active.
        // The added stake should go to pending_active to wait for activation when next epoch starts.
        add_stake(&validator, 100);
        assert!(coin::balance<AptosCoin>(validator_address) == 800, 2);
        assert_validator_state(validator_address, 100, 0, 100, 0, 0);

        // Pending_active stake is activated in the new epoch.
        // Rewards of 1 coin are also distributed for the existing active stake of 100 coins.
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 3);
        assert_validator_state(validator_address, 201, 0, 0, 0, 0);

        // Request unlock of 100 coins. These 100 coins are moved to pending_inactive and will be unlocked when the
        // current lockup expires.
        unlock(&validator, 100);
        assert_validator_state(validator_address, 101, 0, 0, 100, 0);

        // Enough time has passed so the current lockup cycle should have ended.
        // The first epoch after the lockup cycle ended should automatically move unlocked (pending_inactive) stake
        // to inactive.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        // Rewards were also minted to pending_inactive, which got all moved to inactive.
        assert_validator_state(validator_address, 102, 101, 0, 0, 0);
        // Lockup is renewed and validator is still active.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 4);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 5);

        // Validator withdraws from inactive stake multiple times.
        withdraw(&validator, 50);
        assert!(coin::balance<AptosCoin>(validator_address) == 850, 6);
        assert_validator_state(validator_address, 102, 51, 0, 0, 0);
        withdraw(&validator, 51);
        assert!(coin::balance<AptosCoin>(validator_address) == 901, 7);
        assert_validator_state(validator_address, 102, 0, 0, 0, 0);

        // Enough time has passed again and the validator's lockup is renewed once more. Validator is still active.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 8);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 9);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_inactive_validator_with_existing_lockup_join_validator_set(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);

        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Validator sets lockup before even joining the set and lets half of lockup pass by.
        increase_lockup(&validator);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS / 2);
        let validator_address = signer::address_of(&validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS / 2, 1);

        // Join the validator set with an existing lockup
        join_validator_set(&validator, validator_address);

        // Validator is added to the set but lockup time shouldn't have changed.
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 2);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS / 2 - EPOCH_DURATION, 3);
        assert_validator_state(validator_address, 100, 0, 0, 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_pending_active_validator_can_add_more_stake(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        join_test_staking(&aptos_framework, &validator, false);

        // Add more stake while still pending_active.
        let validator_address = signer::address_of(&validator);
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_PENDING_ACTIVE, 0);
        add_stake(&validator, 100);
        assert_validator_state(validator_address, 200, 0, 0, 0, 0);

        // Validator is added to the set with all added stake in the next epoch.
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 1);
        assert_validator_state(validator_address, 200, 0, 0, 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_active_validator_unlock_partial_stake(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        initialize(&aptos_framework);
        // Reward rate = 10%.
        staking_config::initialize_for_test(&aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 10);
        join_test_staking(&aptos_framework, &validator, true);

        // Unlock half of the coins.
        let validator_address = signer::address_of(&validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 1);
        unlock(&validator, 50);
        assert_validator_state(validator_address, 50, 0, 0, 50, 0);

        // Enough time has passed so the current lockup cycle should have ended.
        // 50 coins should have unlocked while the remaining 51 (50 + rewards) should stay locked for another cycle.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 2);
        // Validator received rewards in both active and pending inactive.
        assert_validator_state(validator_address, 55, 55, 0, 0, 0);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 3);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_active_validator_can_withdraw_all_stake_and_rewards_at_once(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        join_test_staking(&aptos_framework, &validator, true);
        let validator_address = signer::address_of(&validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 0);

        // One more epoch passes to generate rewards.
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 1);
        assert_validator_state(validator_address, 101, 0, 0, 0, 0);

        // Unlock all coins while still having a lockup.
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS - EPOCH_DURATION, 2);
        unlock(&validator, 101);
        assert_validator_state(validator_address, 0, 0, 0, 101, 0);

        // One more epoch passes while the current lockup cycle (3600 secs) has not ended.
        timestamp::fast_forward_seconds(1000);
        end_epoch();
        // Validator should not be removed from the validator set since their 100 coins in pending_inactive state should
        // still count toward voting power.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 3);
        assert_validator_state(validator_address, 0, 0, 0, 102, 0);

        // Enough time has passed so the current lockup cycle should have ended. Funds are now fully unlocked.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert_validator_state(validator_address, 0, 103, 0, 0, 0);
        // Validator ahs been kicked out of the validator set as their stake is 0 now.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_INACTIVE, 4);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10005)]
    public entry fun test_active_validator_unlocking_more_than_available_stake_should_error_out(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        join_test_staking(&aptos_framework, &validator, true);

        // Validator unlocks more stake than they have active. This should error out.
        unlock(&validator, 200);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_active_validator_withdraw_should_cap_by_inactive_stake(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        join_test_staking(&aptos_framework, &validator, true);

        // Validator unlocks stake.
        unlock(&validator, 100);
        // Enough time has passed so the stake is fully unlocked.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();

        // Validator can only withdraw a max of 100 unlocked coins even if they request to withdraw more than 100.
        withdraw(&validator, 200);
        let validator_address = signer::address_of(&validator);
        assert!(coin::balance<AptosCoin>(validator_address) == 1001, 2);
        assert_validator_state(validator_address, 0, 0, 0, 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_active_validator_having_insufficient_remaining_stake_after_withdrawal_gets_kicked(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        join_test_staking(&aptos_framework, &validator, true);

        // Unlock enough coins that the remaining is not enough to meet the min required.
        let validator_address = signer::address_of(&validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 1);
        unlock(&validator, 50);
        assert_validator_state(validator_address, 50, 0, 0, 50, 0);

        // Enough time has passed so the current lockup cycle should have ended.
        // 50 coins should have unlocked while the remaining 51 (50 + rewards) is not enough so the validator is kicked
        // from the validator set.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 2);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_INACTIVE, 2);
        assert_validator_state(validator_address, 50, 50, 0, 0, 0);
        // Lockup is no longer renewed since the validator is no longer a part of the validator set.
        assert!(get_remaining_lockup_secs(validator_address) == 0, 3);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123, validator_2 = @0x234)]
    public entry fun test_active_validator_leaves_staking_but_still_has_a_lockup(
        aptos_framework: signer,
        validator: signer,
        validator_2: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        register_mint_stake(&validator_2, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);
        let validator_address = signer::address_of(&validator);
        join_validator_set(&validator, validator_address);
        // We need a second validator here just so the first validator can leave.
        join_validator_set(&validator_2, signer::address_of(&validator_2));
        end_epoch();

        // Leave the validator set while still having a lockup.
        let validator_address = signer::address_of(&validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 0);
        leave_validator_set(&validator, validator_address);
        // Validator is in pending_inactive state but is technically still part of the validator set.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_PENDING_INACTIVE, 2);
        assert_validator_state(validator_address, 100, 0, 0, 0, 1);
        end_epoch();

        // Epoch has ended so validator is no longer part of the validator set.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_INACTIVE, 3);
        // However, their stake, including rewards, should still subject to the existing lockup.
        assert_validator_state(validator_address, 101, 0, 0, 0, 1);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS - EPOCH_DURATION, 4);

        // If they try to unlock, their stake is moved to pending_inactive and would only be withdrawable after the
        // lockup has expired.
        unlock(&validator, 50);
        assert_validator_state(validator_address, 51, 0, 0, 50, 1);
        // A couple of epochs passed but lockup has not expired so the validator's stake remains the same.
        end_epoch();
        end_epoch();
        end_epoch();
        assert_validator_state(validator_address, 51, 0, 0, 50, 1);
        // Fast forward enough so the lockup expires. Now the validator can just call withdraw directly to withdraw
        // pending_inactive stakes.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        withdraw(&validator, 50);
        assert_validator_state(validator_address, 51, 0, 0, 0, 1);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123, validator_2 = @0x234)]
    public entry fun test_active_validator_leaves_staking_and_rejoins_with_expired_lockup_should_be_renewed(
        aptos_framework: signer,
        validator: signer,
        validator_2: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        register_mint_stake(&validator_2, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);
        let validator_address = signer::address_of(&validator);
        join_validator_set(&validator, validator_address);
        // We need a second validator here just so the first validator can leave.
        join_validator_set(&validator_2, signer::address_of(&validator_2));
        end_epoch();

        // Leave the validator set while still having a lockup.
        let validator_address = signer::address_of(&validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 0);
        leave_validator_set(&validator, validator_address);
        end_epoch();

        // Fast forward enough so the lockup expires.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        assert!(get_remaining_lockup_secs(validator_address) == 0, 1);

        // Validator rejoins the validator set. Once the current epoch ends, their lockup should be automatically
        // renewed.
        join_validator_set(&validator, validator_address);
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 2);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 2);
    }

    #[test(aptos_framework = @aptos_framework, validator_1 = @0x123, validator_2 = @0x234, validator_3 = @0x345)]
    public entry fun test_multiple_validators_join_and_leave(
        aptos_framework: signer,
        validator_1: signer,
        validator_2: signer,
        validator_3: signer
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let validator_1_address = signer::address_of(&validator_1);
        let validator_2_address = signer::address_of(&validator_2);
        let validator_3_address = signer::address_of(&validator_3);

        initialize(&aptos_framework);
        staking_config::initialize_for_test(&aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 100);

        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator_1, &mint_cap);
        register_mint_stake(&validator_2, &mint_cap);
        register_mint_stake(&validator_3, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Validator 1 and 2 join the validator set.
        join_validator_set(&validator_2, validator_2_address);
        join_validator_set(&validator_1, validator_1_address);
        end_epoch();
        assert!(get_validator_state(validator_1_address) == VALIDATOR_STATUS_ACTIVE, 0);
        assert!(get_validator_state(validator_2_address) == VALIDATOR_STATUS_ACTIVE, 1);

        // Validator indices is the reverse order of the joining order.
        assert_validator_state(validator_1_address, 100, 0, 0, 0, 0);
        assert_validator_state(validator_2_address, 100, 0, 0, 0, 1);
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        let validator_config_1 = vector::borrow(&validator_set.active_validators, 0);
        assert!(validator_config_1.addr == validator_1_address, 2);
        assert!(validator_config_1.config.validator_index == 0, 3);
        let validator_config_2 = vector::borrow(&validator_set.active_validators, 1);
        assert!(validator_config_2.addr == validator_2_address, 4);
        assert!(validator_config_2.config.validator_index == 1, 5);

        // Validator 1 rotates consensus key. Validator 2 leaves. Validator 3 joins.
        rotate_consensus_key(&validator_1, validator_1_address, CONSENSUS_KEY_2, CONSENSUS_POP_2);
        leave_validator_set(&validator_2, validator_2_address);
        join_validator_set(&validator_3, validator_3_address);
        // Validator 2 is not effectively removed until next epoch.
        assert!(get_validator_state(validator_2_address) == VALIDATOR_STATUS_PENDING_INACTIVE, 6);
        assert!(vector::borrow(&borrow_global<ValidatorSet>(@aptos_framework).pending_inactive, 0).addr == validator_2_address, 0);
        // Validator 3 is not effectively added until next epoch.
        assert!(get_validator_state(validator_3_address) == VALIDATOR_STATUS_PENDING_ACTIVE, 7);
        assert!(vector::borrow(&borrow_global<ValidatorSet>(@aptos_framework).pending_active, 0).addr == validator_3_address, 0);
        assert!(vector::borrow(&borrow_global<ValidatorSet>(@aptos_framework).active_validators, 0).config.consensus_pubkey == CONSENSUS_KEY_1, 0);

        // Changes applied after new epoch
        end_epoch();
        assert!(get_validator_state(validator_1_address) == VALIDATOR_STATUS_ACTIVE, 8);
        assert_validator_state(validator_1_address, 101, 0, 0, 0, 0);
        assert!(get_validator_state(validator_2_address) == VALIDATOR_STATUS_INACTIVE, 9);
        // The validator index of validator 2 stays the same but this doesn't matter as the next time they rejoin the
        // validator set, their index will get set correctly.
        assert_validator_state(validator_2_address, 101, 0, 0, 0, 1);
        assert!(get_validator_state(validator_3_address) == VALIDATOR_STATUS_ACTIVE, 10);
        assert_validator_state(validator_3_address, 100, 0, 0, 0, 1);
        assert!(vector::borrow(&borrow_global<ValidatorSet>(@aptos_framework).active_validators, 0).config.consensus_pubkey == CONSENSUS_KEY_2, 0);

        // Validators without enough stake will be removed.
        unlock(&validator_1, 50);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert!(get_validator_state(validator_1_address) == VALIDATOR_STATUS_INACTIVE, 11);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_delegated_staking_with_owner_cap(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        initialize(&aptos_framework);
        staking_config::initialize_for_test(&aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 100);

        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        let stake = coin::mint<AptosCoin>(100, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);

        let pool_address = signer::address_of(&validator);
        initialize_validator(&validator, CONSENSUS_KEY_1, CONSENSUS_POP_1, vector::empty(), vector::empty());
        let owner_cap = extract_owner_cap(&validator);

        // Add stake when the validator is not yet activated.
        add_stake_with_cap(&owner_cap, stake);
        assert_validator_state(pool_address, 100, 0, 0, 0, 0);

        // Join the validator set with enough stake.
        join_validator_set(&validator, pool_address);
        end_epoch();
        assert!(get_validator_state(pool_address) == VALIDATOR_STATUS_ACTIVE, 0);

        // Unlock the entire stake.
        unlock_with_cap(100, &owner_cap);
        assert_validator_state(pool_address, 0, 0, 0, 100, 0);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();

        // Withdraw stake + rewards.
        assert_validator_state(pool_address, 0, 101, 0, 0, 0);
        let coins = withdraw_with_cap(&owner_cap, 101);
        assert!(coin::value<AptosCoin>(&coins) == 101, 1);
        assert_validator_state(pool_address, 0, 0, 0, 0, 0);

        // Operator can separately rotate consensus key.
        rotate_consensus_key(&validator, pool_address, CONSENSUS_KEY_2, CONSENSUS_POP_2);
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        assert!(validator_config.consensus_pubkey == CONSENSUS_KEY_2, 2);

        // Operator can update network and fullnode addresses.
        update_network_and_fullnode_addresses(&validator, pool_address, b"1", b"2");
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        assert!(validator_config.network_addresses == b"1", 3);
        assert!(validator_config.fullnode_addresses == b"2", 4);

        let OwnerCapability { pool_address: _ } = owner_cap;
        coin::burn(coins, &burn_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000E)]
    public entry fun test_validator_cannot_join_post_genesis(
        aptos_framework: signer,
        validator: signer,
    ) acquires AptosCoinCapabilities, OwnerCapability, StakePool, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        initialize(&aptos_framework);
        staking_config::initialize_for_test(&aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, false, 1, 100);

        // Joining the validator set should fail as post genesis validator set change is not allowed.
        join_test_staking(&aptos_framework, &validator, true);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000E)]
    public entry fun test_validator_cannot_leave_post_genesis(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        initialize(&aptos_framework);
        staking_config::initialize_for_test(&aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, false, 1, 100);

        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Bypass the check to join. This is the same function called during Genesis.
        let validator_address = signer::address_of(&validator);
        join_validator_set_internal(&validator, validator_address);
        end_epoch();

        // Leaving the validator set should fail as post genesis validator set change is not allowed.
        leave_validator_set(&validator, validator_address);
    }

    #[test(
        aptos_framework = @aptos_framework,
        validator_1 = @aptos_framework,
        validator_2 = @0x2,
        validator_3 = @0x3,
        validator_4 = @0x4,
        validator_5 = @0x5
    )]
    public entry fun test_staking_validator_index(
        aptos_framework: signer,
        validator_1: signer,
        validator_2: signer,
        validator_3: signer,
        validator_4: signer,
        validator_5: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let v1_addr = signer::address_of(&validator_1);
        let v2_addr = signer::address_of(&validator_2);
        let v3_addr = signer::address_of(&validator_3);
        let v4_addr = signer::address_of(&validator_4);
        let v5_addr = signer::address_of(&validator_5);

        test_setup(&aptos_framework);

        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator_1, &mint_cap);
        register_mint_stake(&validator_2, &mint_cap);
        register_mint_stake(&validator_3, &mint_cap);
        register_mint_stake(&validator_4, &mint_cap);
        register_mint_stake(&validator_5, &mint_cap);

        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        join_validator_set(&validator_3, v3_addr);
        end_epoch();
        assert!(validator_index(v3_addr) == 0, 0);

        join_validator_set(&validator_4, v4_addr);
        end_epoch();
        assert!(validator_index(v3_addr) == 0, 1);
        assert!(validator_index(v4_addr) == 1, 2);

        join_validator_set(&validator_1, v1_addr);
        join_validator_set(&validator_2, v2_addr);
        // pending_inactive is appended in reverse order
        end_epoch();
        assert!(validator_index(v3_addr) == 0, 6);
        assert!(validator_index(v4_addr) == 1, 7);
        assert!(validator_index(v2_addr) == 2, 8);
        assert!(validator_index(v1_addr) == 3, 9);

        join_validator_set(&validator_5, v5_addr);
        end_epoch();
        assert!(validator_index(v3_addr) == 0, 10);
        assert!(validator_index(v4_addr) == 1, 11);
        assert!(validator_index(v2_addr) == 2, 12);
        assert!(validator_index(v1_addr) == 3, 13);
        assert!(validator_index(v5_addr) == 4, 14);

        // after swap remove, it's 3,4,2,5
        leave_validator_set(&validator_1, v1_addr);
        // after swap remove, it's 5,4,2
        leave_validator_set(&validator_3, v3_addr);
        end_epoch();

        assert!(validator_index(v5_addr) == 0, 15);
        assert!(validator_index(v4_addr) == 1, 16);
        assert!(validator_index(v2_addr) == 2, 17);
    }

    #[test(aptos_framework = @aptos_framework, validator_1 = @0x123, validator_2 = @0x234)]
    public entry fun test_validator_rewards_are_performance_based(
        aptos_framework: signer,
        validator_1: signer,
        validator_2: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);

        let validator_1_address = signer::address_of(&validator_1);
        let validator_2_address = signer::address_of(&validator_2);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator_1, &mint_cap);
        register_mint_stake(&validator_2, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Both validators join the set.
        join_validator_set(&validator_1, validator_1_address);
        join_validator_set(&validator_2, validator_2_address);
        end_epoch();

        // Validator 2 failed proposal.
        let failed_proposer_indices = vector::empty<u64>();
        let validator_1_index = borrow_global<ValidatorConfig>(validator_1_address).validator_index;
        let validator_2_index = borrow_global<ValidatorConfig>(validator_2_address).validator_index;
        vector::push_back(&mut failed_proposer_indices, validator_2_index);
        let proposer_indices = vector::empty<u64>();
        vector::push_back(&mut proposer_indices, validator_1_index);
        update_performance_statistics(proposer_indices, failed_proposer_indices);
        end_epoch();

        // Validator 2 received no rewards. Validator 1 didn't fail proposals, so it still receives rewards.
        assert_validator_state(validator_1_address, 101, 0, 0, 0, 1);
        assert_validator_state(validator_2_address, 100, 0, 0, 0, 0);

        // Validator 2 decides to leave. Both validators failed proposals.
        unlock(&validator_2, 100);
        leave_validator_set(&validator_2, validator_2_address);
        let failed_proposer_indices = vector::empty<u64>();
        let validator_1_index = borrow_global<ValidatorConfig>(validator_1_address).validator_index;
        let validator_2_index = borrow_global<ValidatorConfig>(validator_2_address).validator_index;
        vector::push_back(&mut failed_proposer_indices, validator_1_index);
        vector::push_back(&mut failed_proposer_indices, validator_2_index);
        update_performance_statistics(vector::empty<u64>(), failed_proposer_indices);
        // Fast forward so validator 2's stake is fully unlocked.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();

        // Validator 1 and 2 received no additional rewards due to failed proposals
        assert_validator_state(validator_1_address, 101, 0, 0, 0, 0);
        assert_validator_state(validator_2_address, 0, 100, 0, 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_update_performance_statistics_should_not_fail_due_to_out_of_bounds(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        test_setup(&aptos_framework);

        let validator_address = signer::address_of(&validator);
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_mint_stake(&validator, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);
        join_validator_set(&validator, validator_address);
        end_epoch();

        let valid_validator_index = borrow_global<ValidatorConfig>(validator_address).validator_index;
        let out_of_bounds_index = valid_validator_index + 100;

        // Invalid validator index in the failed proposers vector should not lead to abort.
        let failed_proposer_indices = vector::empty<u64>();
        vector::push_back(&mut failed_proposer_indices, valid_validator_index);
        vector::push_back(&mut failed_proposer_indices, out_of_bounds_index);
        update_performance_statistics(vector::empty<u64>(), failed_proposer_indices);
        end_epoch();

        // Validator received no rewards due to failing to propose.
        assert_validator_state(validator_address, 100, 0, 0, 0, 0);

        // Invalid validator index in the proposer should not lead to abort.
        let proposer_index_optional = vector::empty<u64>();
        vector::push_back(&mut proposer_index_optional, out_of_bounds_index);
        update_performance_statistics(proposer_index_optional, vector::empty<u64>());
        end_epoch();
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000F)]
    public entry fun test_invalid_config(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, ValidatorConfig, ValidatorSet {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        initialize(&aptos_framework);
        staking_config::initialize_for_test(&aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 100);

        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_owner_only(&validator, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Join the validator set with enough stake.
        let validator_address = signer::address_of(&validator);
        join_validator_set(&validator, validator_address);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_valid_config(
        aptos_framework: signer,
        validator: signer,
    ) acquires OwnerCapability, StakePool, ValidatorConfig, ValidatorSet {
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        initialize(&aptos_framework);
        staking_config::initialize_for_test(&aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 100);

        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(&aptos_framework);
        register_owner_only(&validator, &mint_cap);
        store_aptos_coin_mint_cap(&aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Set the valid to true
        let validator_address = signer::address_of(&validator);
        rotate_consensus_key(&validator, validator_address, CONSENSUS_KEY_2, CONSENSUS_POP_2);

        // Join the validator set with enough stake.
        join_validator_set(&validator, validator_address);
    }

    #[test]
    public entry fun test_rewards_calculation() {
        let stake_amount = 2000;
        let num_successful_proposals = 199;
        let num_total_proposals = 200;
        let rewards_rate = 700;
        let rewards_rate_denominator = 777;
        let rewards_amount = calculate_rewards_amount(
            stake_amount,
            num_successful_proposals,
            num_total_proposals,
            rewards_rate,
            rewards_rate_denominator
        );
        // Consider `amount_imprecise` and `amount_precise` defined as follows:
        // amount_imprecise = (stake_amount * rewards_rate / rewards_rate_denominator) * num_successful_proposals / num_total_proposals
        // amount_precise = stake_amount * rewards_rate * num_successful_proposals / (rewards_rate_denominator * num_total_proposals)
        // Although they are equivalent in the real arithmetic, they are not in the integer arithmetic due to a rounding error.
        // With the test parameters above, `amount_imprecise` is equal to 1791 because of an unbounded rounding error
        // while `amount_precise` is equal to 1792. We expect the output of `calculate_rewards_amount` to be 1792.
        assert!(rewards_amount == 1792, 0);

        let stake_amount = 100000000000000000;
        let num_successful_proposals = 9999;
        let num_total_proposals = 10000;
        let rewards_rate = 3141592;
        let rewards_rate_denominator = 10000000;
        // This should not abort due to an arithmetic overflow.
        let rewards_amount = calculate_rewards_amount(
            stake_amount,
            num_successful_proposals,
            num_total_proposals,
            rewards_rate,
            rewards_rate_denominator
        );
        assert!(rewards_amount == 31412778408000000, 0);
    }

    #[test_only]
    public entry fun register_mint_stake(
        account: &signer,
        mint_cap: &MintCapability<AptosCoin>,
    ) acquires OwnerCapability, StakePool, ValidatorConfig, ValidatorSet {
        aptos_framework::coin::register_for_test<AptosCoin>(account);
        let address = signer::address_of(account);
        coin::deposit<AptosCoin>(address, coin::mint<AptosCoin>(1000, mint_cap));
        initialize_validator(account, CONSENSUS_KEY_1, CONSENSUS_POP_1, vector::empty(), vector::empty());
        add_stake(account, 100);
        assert_validator_state(signer::address_of(account), 100, 0, 0, 0, 0);
    }

    #[test_only]
    public entry fun register_owner_only(
        account: &signer,
        mint_cap: &MintCapability<AptosCoin>,
    ) acquires OwnerCapability, StakePool, ValidatorConfig, ValidatorSet {
        aptos_framework::coin::register_for_test<AptosCoin>(account);
        let address = signer::address_of(account);
        coin::deposit<AptosCoin>(address, coin::mint<AptosCoin>(1000, mint_cap));
        initialize_owner_only(account, 0, address, address);
        add_stake(account, 100);
        assert_validator_state(signer::address_of(account), 100, 0, 0, 0, 0);
    }

    #[test_only]
    public entry fun join_test_staking(
        aptos_framework: &signer,
        validator: &signer,
        change_epoch: bool,
    ) acquires AptosCoinCapabilities, OwnerCapability, StakePool, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let (mint_cap, burn_cap) = aptos_coin::initialize_for_test(aptos_framework);
        register_mint_stake(validator, &mint_cap);
        store_aptos_coin_mint_cap(aptos_framework, mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);

        // Join the validator set with enough stake.
        let validator_address = signer::address_of(validator);
        join_validator_set(validator, validator_address);

        // Only change epoch if requested to do so. This allows tests to perform more operations while the validator
        // is still pending active.
        if (change_epoch) {
            end_epoch();
            assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 0);
        };
    }

    #[test_only]
    public fun set_validator_perf_at_least_one_block() acquires ValidatorPerformance {
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@aptos_framework);
        let len = vector::length(&validator_perf.validators);
        let i = 0;
        while (i < len) {
            let validator = vector::borrow_mut(&mut validator_perf.validators, i);
            if (validator.successful_proposals + validator.failed_proposals < 1) {
                validator.successful_proposals = 1;
            };
            i = i + 1;
        };
    }

    #[test_only]
    fun end_epoch() acquires StakePool, AptosCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // Set the number of blocks to 1, to give out rewards to non-failing validators.
        set_validator_perf_at_least_one_block();
        timestamp::fast_forward_seconds(EPOCH_DURATION);
        on_new_epoch();
    }

    #[test_only]
    fun validator_index(addr: address): u64 acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        option::extract(&mut find_validator(&validator_set.active_validators, addr))
    }

    #[test_only]
    fun assert_validator_state(
        pool_address: address,
        active_stake: u64,
        inactive_stake: u64,
        pending_active_stake: u64,
        pending_inactive_stake: u64,
        validator_index: u64,
    ) acquires StakePool, ValidatorConfig {
        let stake_pool = borrow_global<StakePool>(pool_address);
        let actual_active_stake = coin::value<AptosCoin>(&stake_pool.active);
        assert!(actual_active_stake == active_stake, actual_active_stake);
        let actual_inactive_stake = coin::value<AptosCoin>(&stake_pool.inactive);
        assert!(actual_inactive_stake == inactive_stake, actual_inactive_stake);
        let actual_pending_active_stake = coin::value<AptosCoin>(&stake_pool.pending_active);
        assert!(actual_pending_active_stake == pending_active_stake, actual_pending_active_stake);
        let actual_pending_inactive_stake = coin::value<AptosCoin>(&stake_pool.pending_inactive);
        assert!(actual_pending_inactive_stake == pending_inactive_stake, actual_pending_inactive_stake);
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        assert!(validator_config.validator_index == validator_index, validator_config.validator_index);
    }

    #[test_only]
    public fun create_validator_set(
        aptos_framework: &signer,
        active_validator_addresses: vector<address>
    ) {
        let active_validators = vector::empty<ValidatorInfo>();
        let i = 0;
        while (i < vector::length(&active_validator_addresses)) {
            let validator_address = vector::borrow(&active_validator_addresses, i);
            vector::push_back(&mut active_validators, ValidatorInfo {
                addr: *validator_address,
                voting_power: 0,
                config: ValidatorConfig {
                    consensus_pubkey: CONSENSUS_KEY_1,
                    network_addresses: b"",
                    fullnode_addresses: b"",
                    validator_index: 0,
                }
            });
            i = i + 1;
        };

        move_to(aptos_framework, ValidatorSet {
            consensus_scheme: 0,
            // active validators for the current epoch
            active_validators,
            // pending validators to leave in next epoch (still active)
            pending_inactive: vector::empty<ValidatorInfo>(),
            // pending validators to join in next epoch
            pending_active: vector::empty<ValidatorInfo>(),
        });
    }

    #[test_only]
    public fun create_stake_pool(
        account: &signer,
        active: Coin<AptosCoin>,
        pending_inactive: Coin<AptosCoin>,
        locked_until_secs: u64,
    ) acquires OwnerCapability, StakePool, ValidatorSet {
        let account_address = signer::address_of(account);
        initialize_owner_only(account, 0, account_address, account_address);
        let stake_pool = borrow_global_mut<StakePool>(account_address);
        coin::merge(&mut stake_pool.active, active);
        coin::merge(&mut stake_pool.pending_inactive, pending_inactive);
        stake_pool.locked_until_secs = locked_until_secs;
    }
}
