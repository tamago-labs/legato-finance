

module legato::vault {
    
    use sui::math;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{ Self, Table};
    use sui::balance::{ Self, Supply , Balance };
    use sui::object::{ Self, ID, UID };
    use sui::coin::{Self , Coin };
    use sui::sui::SUI;
    use sui::transfer;
    use std::vector;
    use sui::event;
    
    use sui_system::staking_pool::{ Self, StakedSui};
    use sui_system::sui_system::{  Self, SuiSystemState };

    use legato::apy_reader::{Self};
    use legato::amm::{Self, Global};
    use legato::math::mul_div;

    // ======== Constants ========
    const MIST_PER_SUI : u64 = 1_000_000_000;
    const MIN_SUI_TO_STAKE : u64 = 1_000_000_000; // 1 Sui
    const MIN_YT_TO_DEPOSIT: u64 = 1_000_000_000;
    const MIN_PT_TO_REDEEM: u64 = 1_000_000_000; // 1 PT
    const MAX_EPOCH: u64 = 365;
    const COOLDOWN_EPOCH: u64 = 3;
    const CLAIM_EPOCH: u64 = 3; // able to claim at every 3 epoch
    const YT_TOTAL_SUPPLY: u64 = 100_000_000 * 1_000_000_000; // 100 Mil. 
    

    // ======== Errors ========
    const E_EMPTY_VECTOR: u64 = 1;
    const E_INVALID_MATURITY: u64 = 2;
    const E_DUPLICATED_ENTRY: u64 = 3;
    const E_NOT_FOUND: u64 = 4;
    const E_VAULT_MATURED: u64 = 5;
    const E_MIN_THRESHOLD: u64 = 6;
    const E_UNAUTHORIZED_USER: u64 = 7;
    const E_UNAUTHORIZED_POOL: u64 = 8;
    const E_VAULT_NOT_MATURED: u64 = 9;
    const E_INVALID_AMOUNT: u64 = 10;
    const E_INVALID_ADDRESS: u64 = 11;
    const E_FIRST_CLAIM_EPOCH: u64 = 12;
    const E_CLAIM_DISABLED: u64 = 13;
    const E_ALREADY_CLAIM: u64 = 14;
    const E_SURPLUS_ZERO: u64 = 15;

    // ======== Structs =========      

    struct ManagerCap has key {
        id: UID
    }

    struct PT has drop {}
    struct YT has drop {}

    struct TOKEN<phantom P, phantom T> has drop {}

    struct Vault<phantom P> has key {
        id: UID,
        created_epoch: u64,
        maturity_epoch: u64,
        vault_apy: u64,
        pools: vector<ID>, // supported staking pools
        whitelist: vector<address>, // whitelisting users (will be removed in the next version)
        holdings: Table<u64, StakedSui>,
        deposit_count: u64,
        pending_withdrawal: Balance<SUI>,
        pt_supply: Supply<TOKEN<P, PT>>,
        yt_supply: Supply<TOKEN<P, YT>>,
        principal_balance: u64,
        debt_balance: u64,
        claim_enabled: bool,
        claim_table: Table<u64, vector<address>>
    }

    struct MintEvent has copy, drop {
        vault_id: ID,
        pool_id: ID,
        input_amount: u64,
        pt_issued: u64,
        deposit_id: u64,
        asset_object_id: ID,
        sender: address,
        epoch: u64,
        principal_balance: u64,
        debt_balance: u64,
        earning_balance: u64,
        pending_balance: u64
    }

    struct RedeemEvent has copy, drop {
        vault_id: ID,
        pt_burned: u64,
        sui_amount: u64,
        sender: address,
        epoch: u64,
        principal_balance: u64,
        debt_balance: u64,
        earning_balance: u64,
        pending_balance: u64
    }

    struct NewVaultEvent has copy, drop {
        created_epoch: u64,
        maturity_epoch:u64,
        initial_apy: u64
    }

    struct UpdateVaultApy has copy, drop {
        vault_id: ID,
        vault_apy: u64,
        epoch: u64,
        principal_balance: u64,
        debt_balance: u64,
        earning_balance: u64,
        pending_balance: u64
    }

    struct ClaimEvent has copy, drop {
        vault_id: ID,
        sender: address,
        epoch: u64,
        claim_epoch: u64,
        input_amount: u64,
        output_amount: u64,
        is_pt: bool,
        principal_balance: u64,
        debt_balance: u64,
        earning_balance: u64,
        pending_balance: u64
    }

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            ManagerCap {id: object::new(ctx)},
            tx_context::sender(ctx)
        );
    }
 
    // ======== Public Functions =========


    // convert Staked SUI to PT
    public entry fun mint<P>(
        wrapper: &mut SuiSystemState,
        vault: &mut Vault<P>,
        staked_sui: StakedSui,
        ctx: &mut TxContext
    ) {
        assert!(vault.maturity_epoch-COOLDOWN_EPOCH > tx_context::epoch(ctx), E_VAULT_MATURED);
        assert!(staking_pool::staked_sui_amount(&staked_sui) >= MIN_SUI_TO_STAKE, E_MIN_THRESHOLD);

        let sender = tx_context::sender(ctx);
        assert!(vector::contains(&vault.whitelist, &sender), E_UNAUTHORIZED_USER);
        
        let pool_id = staking_pool::pool_id(&staked_sui);
        assert!(vector::contains(&vault.pools, &pool_id), E_UNAUTHORIZED_POOL);

        let asset_object_id = object::id(vault);

        // Take the Staked SUI
        let principal_amount = staking_pool::staked_sui_amount(&staked_sui); 
        let deposit_id = receive_staked_sui(vault, staked_sui); 

        // Calculate PT to send out
        let topup_amount = future_pt(vault, tx_context::epoch(ctx), principal_amount);

        vault.principal_balance = vault.principal_balance+principal_amount;
        vault.debt_balance = vault.debt_balance+topup_amount;

        let pt_amount = principal_amount+topup_amount;

        // Mint to the user
        mint_pt(vault, pt_amount, ctx);

        let earning_balance = vault_rewards(wrapper, vault, tx_context::epoch(ctx));

        event::emit(MintEvent {
            vault_id: object::id(vault),
            pool_id,
            input_amount: principal_amount,
            pt_issued : pt_amount,
            deposit_id,
            asset_object_id,
            sender,
            epoch: tx_context::epoch(ctx),
            principal_balance: vault.principal_balance,
            debt_balance: vault.debt_balance,
            earning_balance,
            pending_balance: balance::value(&vault.pending_withdrawal)
        });
    }   

    // redeem when the vault reaches its maturity date
    public entry fun redeem<P>(
        wrapper: &mut SuiSystemState,
        vault: &mut Vault<P>,
        pt: Coin<TOKEN<P,PT>>,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::epoch(ctx) > vault.maturity_epoch, E_VAULT_NOT_MATURED);
        assert!(coin::value<TOKEN<P,PT>>(&pt) >= MIN_PT_TO_REDEEM, E_MIN_THRESHOLD);

        let paidout_amount = coin::value<TOKEN<P,PT>>(&pt);

        prepare_withdraw<P>(wrapper, vault, paidout_amount, ctx);

        // withdraw 
        withdraw_sui(vault, paidout_amount, tx_context::sender(ctx) , ctx );

        // burn PT tokens
        let burned_balance = balance::decrease_supply(&mut vault.pt_supply, coin::into_balance(pt));

        let earning_balance = vault_rewards(wrapper, vault, tx_context::epoch(ctx));

        event::emit(RedeemEvent {
            vault_id: object::id(vault),
            pt_burned : burned_balance,
            sui_amount: paidout_amount,
            sender : tx_context::sender(ctx),
            epoch: tx_context::epoch(ctx),
            principal_balance: vault.principal_balance,
            debt_balance: vault.debt_balance,
            earning_balance,
            pending_balance: balance::value(&vault.pending_withdrawal)
        });
    }

    // claim yield from the surplus
    public entry fun claim<P>(
        wrapper: &mut SuiSystemState,
        vault: &mut Vault<P>,
        global: &mut Global,
        yt: &Coin<TOKEN<P,YT>>,
        ctx: &mut TxContext
    ) {
        assert!( vault.claim_enabled == true , E_CLAIM_DISABLED);

        let current_claim_epoch = find_claim_epoch( vault, tx_context::epoch(ctx) );
        assert!( current_claim_epoch > 1 , E_FIRST_CLAIM_EPOCH);

        let total_claim_epoch = total_claim_epoch(vault);
        let epoch_to_considered = vault.created_epoch+((current_claim_epoch-1)*CLAIM_EPOCH);

        let accumulated_rewards = vault_rewards(wrapper, vault, epoch_to_considered );
        let outstanding_debts = vault.debt_balance;

        let input_amount = coin::value<TOKEN<P,YT>>(yt);
        let yt_circulation = yt_circulation<P>(vault, global);

        let surplus = 
            if (accumulated_rewards >= outstanding_debts)
                accumulated_rewards - outstanding_debts
            else 0;

        assert!( surplus > 0 , E_SURPLUS_ZERO);

        if (vault.maturity_epoch >= tx_context::epoch(ctx) ) {
            // sending PT before matures
            let remaining_claim_epoch = total_claim_epoch-current_claim_epoch;
            let allocation = surplus/remaining_claim_epoch;
            let output_amount = mul_div(allocation, input_amount, yt_circulation);

            let claimer_list = 
                if (table::contains( &vault.claim_table, current_claim_epoch ))
                    table::remove(&mut vault.claim_table, current_claim_epoch)
                else vector::empty<address>();

            assert!( vector::contains(&claimer_list, &tx_context::sender(ctx) ) == false , E_ALREADY_CLAIM);

            vector::push_back<address>(&mut claimer_list, tx_context::sender(ctx));
            table::add(&mut vault.claim_table, current_claim_epoch, claimer_list);

            mint_pt(vault, output_amount, ctx);

            // emit event
            let earning_balance = vault_rewards(wrapper, vault, tx_context::epoch(ctx));

            event::emit(ClaimEvent {
                vault_id: object::id(vault),
                sender: tx_context::sender(ctx),
                epoch: tx_context::epoch(ctx),
                claim_epoch: current_claim_epoch,
                input_amount,
                output_amount,
                is_pt: true,
                principal_balance: vault.principal_balance,
                debt_balance: vault.debt_balance,
                earning_balance,
                pending_balance: balance::value(&vault.pending_withdrawal)
            });

        } else {
            // sending SUI after matures 
            let allocation = surplus/COOLDOWN_EPOCH;
            let output_amount = mul_div(allocation, input_amount, yt_circulation);

            let claimer_list = 
                if (table::contains( &vault.claim_table, current_claim_epoch ))
                    table::remove(&mut vault.claim_table, current_claim_epoch)
                else vector::empty<address>();

            assert!( vector::contains(&claimer_list, &tx_context::sender(ctx) ) == false , E_ALREADY_CLAIM);

            vector::push_back<address>(&mut claimer_list, tx_context::sender(ctx));
            table::add(&mut vault.claim_table, current_claim_epoch, claimer_list);

            prepare_withdraw<P>(wrapper, vault, surplus, ctx);

            // withdraw
            withdraw_sui(vault, output_amount, tx_context::sender(ctx) , ctx );

            // emit event
            let earning_balance = vault_rewards(wrapper, vault, tx_context::epoch(ctx));

            event::emit(ClaimEvent {
                vault_id: object::id(vault),
                sender: tx_context::sender(ctx),
                epoch: tx_context::epoch(ctx),
                claim_epoch: current_claim_epoch,
                input_amount,
                output_amount,
                is_pt: false,
                principal_balance: vault.principal_balance,
                debt_balance: vault.debt_balance,
                earning_balance,
                pending_balance: balance::value(&vault.pending_withdrawal)
            });
        };


    }

    public fun vault_rewards<P>(wrapper: &mut SuiSystemState, vault: &Vault<P>, epoch: u64): u64 {
        let count = table::length(&vault.holdings);
        let i = 0;
        let total_sum = 0;
        while (i < count) {
            if (table::contains(&vault.holdings, i)) {
                let staked_sui = table::borrow(&vault.holdings, i);
                let activation_epoch = staking_pool::stake_activation_epoch(staked_sui);
                if (epoch > activation_epoch) total_sum = total_sum+apy_reader::earnings_from_staked_sui(wrapper, staked_sui, epoch);
            };
            i = i + 1;
        };
        total_sum
    }

    public fun vault_principals<P>(vault: &Vault<P>): u64 {
        vault.principal_balance
    }

    public fun vault_debts<P>(vault: &Vault<P>): u64 {
        vault.debt_balance
    }
    
    public fun vault_pending<P>(vault: &Vault<P>): u64 {
        balance::value(&vault.pending_withdrawal)
    }

    public fun vault_apy<P>(vault: &Vault<P>): u64 {
        vault.vault_apy
    }

    // ======== Only Governance =========

    // create new vault
    public entry fun new_vault<P>(
        _manager_cap: &mut ManagerCap,
        initial_apy: u64,
        maturity_epoch: u64,
        global: &mut Global,
        initial_liquidity: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!( maturity_epoch > tx_context::epoch(ctx) , E_INVALID_MATURITY);

        // setup PT
        let pt_supply = balance::create_supply(TOKEN<P,PT> {});
        // setup YT
        let yt_supply = balance::create_supply(TOKEN<P,YT> {});

        // TODO: YT supposed to be global 
        let minted_yt = balance::increase_supply(&mut yt_supply, YT_TOTAL_SUPPLY);
  
        // TODO: Add Coin Metadata

        // setup AMM pool
        let is_order = amm::is_order<SUI, TOKEN<P,YT>>();
        if (!amm::has_registered<SUI, TOKEN<P,YT>>(global)) {
            amm::register_pool<SUI, TOKEN<P,YT>>(global, is_order)
        };
        let pool = amm::get_mut_pool<SUI, TOKEN<P,YT>>(global, is_order);

        let (lp, _pool_id) = amm::add_liquidity<SUI, TOKEN<P,YT>>(
            pool,
            initial_liquidity,
            1,
            coin::from_balance(minted_yt, ctx),
            1,
            is_order,
            ctx
        );

        transfer::public_transfer( lp , tx_context::sender(ctx));

        let vault = Vault {
            id: object::new(ctx),
            created_epoch: tx_context::epoch(ctx),
            maturity_epoch,
            vault_apy: initial_apy,
            pools : vector::empty<ID>(),
            whitelist: vector::empty<address>(),
            holdings: table::new(ctx),
            deposit_count: 0,
            pending_withdrawal: balance::zero(),
            pt_supply,
            yt_supply,
            principal_balance: 0,
            debt_balance: 0,
            claim_enabled: true,
            claim_table: table::new(ctx)
        };

        transfer::share_object(vault);

        // emit event
        event::emit(NewVaultEvent {
            created_epoch: tx_context::epoch(ctx),
            maturity_epoch,
            initial_apy
        });

    }

    // add user to the whitelist
    public entry fun add_user<P>(
        vault: &mut Vault<P>,
        _manager_cap: &ManagerCap,
        user: address
    ) {
        assert!(
            !vector::contains(&vault.whitelist, &user),
            E_DUPLICATED_ENTRY
        );
        vector::push_back<address>(&mut vault.whitelist, user);
    }

    // remove user from the whitelist
    public entry fun remove_user<P>(
        vault: &mut Vault<P>,
        _manager_cap: &ManagerCap,
        user: address
    ) {
        let (contained, index) = vector::index_of<address>(&vault.whitelist, &user);
        assert!(
            contained,
            E_NOT_FOUND
        );
        vector::remove<address>(&mut vault.whitelist, index);
    }

    // add pool
    public entry fun add_pool<P>(
        vault: &mut Vault<P>,
        _manager_cap: &ManagerCap,
        pool_id: ID
    ) {
        assert!(
            !vector::contains(&vault.pools, &pool_id),
            E_DUPLICATED_ENTRY
        );
        vector::push_back<ID>(&mut vault.pools, pool_id);
    }

    // remove pool
    public entry fun remove_pool<P>(
        vault: &mut Vault<P>,
        _manager_cap: &ManagerCap,
        pool_id: ID
    ) {
        let (contained, index) = vector::index_of<ID>(&vault.pools, &pool_id);
        assert!(
            contained,
            E_NOT_FOUND
        );
        vector::remove<ID>(&mut vault.pools, index);
    }

    // update vault APY
    public entry fun update_vault_apy<P>(
        wrapper: &mut SuiSystemState,
        vault: &mut Vault<P>,
        _manager_cap: &ManagerCap,
        value: u64,
        ctx: &mut TxContext
    ) {
        vault.vault_apy = value;
        
        let earning = vault_rewards(wrapper, vault, tx_context::epoch(ctx));

        event::emit(UpdateVaultApy {
            vault_id: object::id(vault),
            vault_apy: value,
            epoch: tx_context::epoch(ctx),
            principal_balance: vault.principal_balance,
            debt_balance: vault.debt_balance,
            pending_balance: balance::value(&vault.pending_withdrawal),
            earning_balance: earning
        });
    }

    // top-up pending pool
    public entry fun topup<P>(
        vault: &mut Vault<P>,
        _manager_cap: &ManagerCap,
        sui: Coin<SUI>
    ) {
        let balance = coin::into_balance(sui);
        balance::join<SUI>(&mut vault.pending_withdrawal, balance);
    }

    public entry fun enable_claim<P>(vault: &mut Vault<P>, _manager_cap: &ManagerCap) {
        vault.claim_enabled = true;
    }

    public entry fun disable_claim<P>(vault: &mut Vault<P>, _manager_cap: &ManagerCap) {
        vault.claim_enabled = false;
    }


    // ======== Internal Functions ========='

    fun receive_staked_sui<P>(vault: &mut Vault<P>, staked_sui: StakedSui) : u64 {
        let deposit_id = vault.deposit_count;

        table::add(
            &mut vault.holdings,
            deposit_id,
            staked_sui
        );

        vault.deposit_count = vault.deposit_count + 1;
        deposit_id
    }

    fun mint_pt<P>(vault: &mut Vault<P>, amount: u64, ctx: &mut TxContext) {
        let minted_balance = balance::increase_supply(&mut vault.pt_supply, amount);
        transfer::public_transfer(coin::from_balance(minted_balance, ctx), tx_context::sender(ctx));
    }

    fun future_pt<P>(vault: &Vault<P>, from_epoch: u64, principal: u64): u64 {
        let for_epoch = vault.maturity_epoch-from_epoch;

        let (for_epoch, apy, principal) = ((for_epoch as u128), (vault.vault_apy as u128), (principal as u128));
        let result = (for_epoch*apy*principal) / (365_000_000_000);

        (result as u64)
    }

    fun locate_withdrawable_asset<P>(wrapper: &mut SuiSystemState, vault: &mut Vault<P>, paidout_amount: u64, epoch: u64):  vector<u64> {

        let count = 0;
        let asset_ids = vector::empty();
        let amount_to_unwrap = paidout_amount-balance::value(&vault.pending_withdrawal);

        while (amount_to_unwrap > 0) {
            if (table::contains(&vault.holdings, count)) {
                let staked_sui = table::borrow(&vault.holdings, count);
                let amount_with_rewards = staking_pool::staked_sui_amount(staked_sui)+apy_reader::earnings_from_staked_sui(wrapper, staked_sui, epoch);

                vector::push_back<u64>(&mut asset_ids, count);

                amount_to_unwrap =
                    if (paidout_amount >= amount_with_rewards)
                        paidout_amount - amount_with_rewards
                    else 0;
            };

            count = count + 1;

            if (count == vault.deposit_count) amount_to_unwrap = 0
            
        };

        asset_ids
    }

    fun unstake_staked_sui<P>(wrapper: &mut SuiSystemState, vault: &mut Vault<P>, asset_ids: vector<u64>, ctx: &mut TxContext) : Balance<SUI> {

        let balance_sui = balance::zero();

        while (vector::length<u64>(&asset_ids) > 0) {
            let asset_id = vector::pop_back(&mut asset_ids);
            let staked_sui = table::remove(&mut vault.holdings, asset_id);

            let principal_amount = staking_pool::staked_sui_amount(&staked_sui);
            let balance_each = sui_system::request_withdraw_stake_non_entry(wrapper, staked_sui, ctx);

            let reward_amount =
                if (balance::value(&balance_each) >= principal_amount)
                    balance::value(&balance_each) - principal_amount
                else 0;

            balance::join<SUI>(&mut balance_sui, balance_each);

            vault.principal_balance = vault.principal_balance-principal_amount;
            vault.debt_balance = 
                if (vault.debt_balance >= reward_amount)
                    vault.debt_balance - reward_amount
                else 0;
        };

        balance_sui
    }

    fun withdraw_sui<P>(vault: &mut Vault<P>, amount: u64, recipient: address , ctx: &mut TxContext) {
        assert!( balance::value(&vault.pending_withdrawal) >= amount, E_INVALID_AMOUNT);
        
        let payout_balance = balance::split(&mut vault.pending_withdrawal, amount);
        transfer::public_transfer(coin::from_balance(payout_balance, ctx), recipient);
    }

    fun prepare_withdraw<P>(wrapper: &mut SuiSystemState, vault: &mut Vault<P>, paidout_amount: u64, ctx: &mut TxContext) {

        if (paidout_amount > balance::value(&vault.pending_withdrawal)) {
             // extract all asset IDs to be withdrawn
            let asset_ids = locate_withdrawable_asset(wrapper, vault, paidout_amount, tx_context::epoch(ctx));

            // unstake assets
            let sui_balance = unstake_staked_sui(wrapper, vault, asset_ids, ctx);
            balance::join<SUI>(&mut vault.pending_withdrawal, sui_balance);
            
        };

    }

    fun find_claim_epoch<P>(vault: &Vault<P>, current_epoch: u64): u64 {
        math::divide_and_round_up( current_epoch-vault.created_epoch , CLAIM_EPOCH)
    }

    fun total_claim_epoch<P>(vault: &Vault<P>): u64 {
        math::divide_and_round_up( vault.maturity_epoch-vault.created_epoch, CLAIM_EPOCH)
    }

    fun yt_circulation<P>(vault: &mut Vault<P>, global: &mut Global): u64 {
        let pool = amm::get_mut_pool<SUI, TOKEN<P,YT>>(global, amm::is_order<SUI, TOKEN<P, YT>>());
        let yt_total_supply = balance::supply_value<TOKEN<P,YT>>(&vault.yt_supply);
        let yt_amount_in_pool = amm::balance_y<SUI, TOKEN<P,YT>>(pool);
        yt_total_supply-yt_amount_in_pool
    }

    // ======== Test-related Functions =========

    #[test_only]
    public fun median_apy<P>(wrapper: &mut SuiSystemState, vault: &Vault<P>, epoch: u64): u64 {
        let count = vector::length(&vault.pools);
        let i = 0;
        let total_sum = 0;
        while (i < count) {
            let pool_id = vector::borrow(&vault.pools, i);
            total_sum = total_sum+apy_reader::pool_apy(wrapper, pool_id, epoch);
            i = i + 1;
        };
        total_sum / i
    }

    #[test_only]
    public fun ceil_apy<P>(wrapper: &mut SuiSystemState, vault: &Vault<P>, epoch: u64): u64 {
        let count = vector::length(&vault.pools);
        let i = 0;
        let output = 0;
        while (i < count) {
            let pool_id = vector::borrow(&vault.pools, i);
            output = math::max( output, apy_reader::pool_apy(wrapper, pool_id, epoch) );
            i = i + 1;
        };
        output
    }

    #[test_only]
    public fun floor_apy<P>(wrapper: &mut SuiSystemState, vault: &Vault<P>, epoch: u64): u64 {
        let count = vector::length(&vault.pools);
        let i = 0;
        let output = 0;
        while (i < count) {
            let pool_id = vector::borrow(&vault.pools, i);
            if (output == 0)
                    output = apy_reader::pool_apy(wrapper, pool_id, epoch)
                else output = math::min( output, apy_reader::pool_apy(wrapper, pool_id, epoch) );
            i = i + 1;
        };
        output
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

}