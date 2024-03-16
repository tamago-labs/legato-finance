// A scaled-down version of OmniBTC's Sui AMM Swap with no fees taken
// https://github.com/OmniBTC/Sui-AMM-swap

// A primary marketplace based on AMM for trading PT, YT pairs with SUI or USDC


module legato::amm {

    use std::ascii::into_bytes;
    use std::type_name::{get, into_string};
    use std::string::{Self, String}; 
    use std::vector;

    use sui::bag::{Self, Bag};
    use sui::transfer;
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{ Self, TxContext};
    use sui::balance::{ Self, Supply, Balance};
    use sui::coin::{Self, Coin, value, split, destroy_zero};
    use sui::pay;
    use legato::event::{added_event, removed_event, swapped_event};

    use legato::comparator;
    use legato::math;

    // ======== Constants ========

    /// The max value that can be held in one of the Balances of
    /// a Pool. U64 MAX / FEE_SCALE
    const MAX_POOL_VALUE : u64 = 18446744073709551615;
    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u64 = 1000;
    /// Max u64 value.
    const U64_MAX: u64 = 18446744073709551615;

    // ======== Errors ========

    /// For when Coin is zero.
    const ERR_ZERO_AMOUNT: u64 = 0;
    /// For when someone tries to swap in an empty pool.
    const ERR_RESERVES_EMPTY: u64 = 1;
    /// For when someone attempts to add more liquidity than u128 Math allows.
    const ERR_POOL_FULL: u64 = 2;
    /// Insuficient amount in coin x reserves.
    const ERR_INSUFFICIENT_COIN_X: u64 = 3;
    /// Insuficient amount in coin y reserves.
    const ERR_INSUFFICIENT_COIN_Y: u64 = 4;
    /// Divide by zero while calling mul_div.
    const ERR_DIVIDE_BY_ZERO: u64 = 5;
    /// For when someone add liquidity with invalid parameters.
    const ERR_OVERLIMIT: u64 = 6;
    /// Amount out less than minimum.
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 7;
    /// Liquid not enough.
    const ERR_LIQUID_NOT_ENOUGH: u64 = 8;
    /// Coin X is the same as Coin Y
    const ERR_THE_SAME_COIN: u64 = 9;
    /// Pool X-Y has registered
    const ERR_POOL_HAS_REGISTERED: u64 = 10;
    /// Pool X-Y not register
    const ERR_POOL_NOT_REGISTER: u64 = 11;
    /// Coin X and Coin Y order
    const ERR_MUST_BE_ORDER: u64 = 12;
    /// Overflow for u64
    const ERR_U64_OVERFLOW: u64 = 13;
    /// Incorrect swap
    const ERR_INCORRECT_SWAP: u64 = 14;
    /// Insufficient liquidity
    const ERR_INSUFFICIENT_LIQUIDITY_MINTED: u64 = 15;

    const ERR_UNAUTHORISED: u64 = 16;
    const ERR_INVALID_INDEX: u64 = 17;
    const ERR_DUPLICATED_ENTRY: u64 = 18;
    const ERR_NOT_FOUND: u64 = 19;
    const ERR_NO_PERMISSIONS: u64 = 20;
    const ERR_EMERGENCY: u64 = 21;
    const ERR_GLOBAL_MISMATCH: u64 = 22;
    const ERR_UNEXPECTED_RETURN: u64 = 23;
    const ERR_EMPTY_COINS: u64 = 24;

    // ======== Structs =========

    /// The Pool token that will be used to mark the pool share
    /// of a liquidity provider. The parameter `X` and `Y` is for the
    /// coin held in the pool.
    struct LP<phantom X, phantom Y> has drop, store {}

    /// The pool with exchange.
    struct Pool<phantom X, phantom Y> has store {
        global: ID,
        coin_x: Balance<X>,
        coin_y: Balance<Y>,
        lp_supply: Supply<LP<X, Y>>,
        min_liquidity: Balance<LP<X, Y>>,
    }

    /// The global config for AMM
    struct AMMGlobal has key {
        id: UID,
        admin: vector<address>,
        has_paused: bool,
        pools: Bag
    }

    /// Init global config
    fun init(ctx: &mut TxContext) {
 
        let admin_list = vector::empty<address>();
        vector::push_back<address>(&mut admin_list, tx_context::sender(ctx));

        let global = AMMGlobal {
            id: object::new(ctx),
            admin: admin_list,
            has_paused: false,
            pools: bag::new(ctx)
        };

        transfer::share_object(global)
    }

    // ======== Public Functions =========

    public fun global_id<X, Y>(pool: &Pool<X, Y>): ID {
        pool.global
    }

    public fun id<X, Y>(global: &AMMGlobal): ID {
        object::uid_to_inner(&global.id)
    }

    public fun get_mut_pool<X, Y>(
        global: &mut AMMGlobal,
        is_order: bool,
    ): &mut Pool<X, Y> {
        assert!(is_order, ERR_MUST_BE_ORDER);

        let lp_name = generate_lp_name<X, Y>();
        let has_registered = bag::contains_with_type<String, Pool<X, Y>>(&global.pools, lp_name);
        assert!(has_registered, ERR_POOL_NOT_REGISTER);

        bag::borrow_mut<String, Pool<X, Y>>(&mut global.pools, lp_name)
    }

    public fun balance_x<X,Y>(pool: &Pool<X, Y>): u64 {
        balance::value<X>(&pool.coin_x)
    }

    public fun balance_y<X,Y>(pool: &Pool<X, Y>): u64 {
        balance::value<Y>(&pool.coin_y)
    }

    public fun has_registered<X, Y>(global: &AMMGlobal): bool {
        let lp_name = generate_lp_name<X, Y>();
        bag::contains_with_type<String, Pool<X, Y>>(&global.pools, lp_name)
    }

    public entry fun pause(global: &mut AMMGlobal, ctx: &mut TxContext) {
        check_admin(global, tx_context::sender(ctx));
        global.has_paused = true
    }

    public entry fun resume( global: &mut AMMGlobal, ctx: &mut TxContext) {
        check_admin(global, tx_context::sender(ctx));
        global.has_paused = false
    }

    public fun is_emergency(global: &AMMGlobal): bool {
        global.has_paused
    }

    public fun generate_lp_name<X, Y>(): String {
        let lp_name = string::utf8(b"");
        string::append_utf8(&mut lp_name, b"LP-");

        if (is_order<X, Y>()) {
            string::append_utf8(&mut lp_name, into_bytes(into_string(get<X>())));
            string::append_utf8(&mut lp_name, b"-");
            string::append_utf8(&mut lp_name, into_bytes(into_string(get<Y>())));
        } else {
            string::append_utf8(&mut lp_name, into_bytes(into_string(get<Y>())));
            string::append_utf8(&mut lp_name, b"-");
            string::append_utf8(&mut lp_name, into_bytes(into_string(get<X>())));
        };

        lp_name
    }

    public fun is_order<X, Y>(): bool {
        let comp = comparator::compare(&get<X>(), &get<Y>());
        assert!(!comparator::is_equal(&comp), ERR_THE_SAME_COIN);

        if (comparator::is_smaller_than(&comp)) {
            true
        } else {
            false
        }
    }

    /// Register pool
    public fun register_pool<X, Y>(
        global: &mut AMMGlobal,
        is_order: bool
    ) {
        assert!(is_order, ERR_MUST_BE_ORDER);

        let lp_name = generate_lp_name<X, Y>();
        let has_registered = bag::contains_with_type<String, Pool<X, Y>>(&global.pools, lp_name);
        assert!(!has_registered, ERR_POOL_HAS_REGISTERED);

        let lp_supply = balance::create_supply(LP<X, Y> {});
        let new_pool = Pool {
            global: object::uid_to_inner(&global.id),
            coin_x: balance::zero<X>(),
            coin_y: balance::zero<Y>(),
            lp_supply,
            min_liquidity: balance::zero<LP<X, Y>>()
        };
        bag::add(&mut global.pools, lp_name, new_pool);
    }

    /// Add liquidity to the `Pool`. Sender needs to provide both
    /// `Coin<X>` and `Coin<Y>`, and in exchange he gets `Coin<LP>` -
    /// liquidity provider tokens.
    public fun add_liquidity_non_entry<X, Y>(
        pool: &mut Pool<X, Y>,
        coin_x: Coin<X>,
        coin_x_min: u64,
        coin_y: Coin<Y>,
        coin_y_min: u64,
        is_order: bool,
        ctx: &mut TxContext
    ): (Coin<LP<X, Y>>, vector<u64>) {
        assert!(is_order, ERR_MUST_BE_ORDER);

        let coin_x_value = coin::value(&coin_x);
        let coin_y_value = coin::value(&coin_y);

        assert!(coin_x_value > 0 && coin_y_value > 0, ERR_ZERO_AMOUNT);

        let coin_x_balance = coin::into_balance(coin_x);
        let coin_y_balance = coin::into_balance(coin_y);

        let (coin_x_reserve, coin_y_reserve, lp_supply) = get_reserves_size(pool);
        let (optimal_coin_x, optimal_coin_y) = calc_optimal_coin_values(
            coin_x_value,
            coin_y_value,
            coin_x_min,
            coin_y_min,
            coin_x_reserve,
            coin_y_reserve
        );

        let provided_liq = if (0 == lp_supply) {
            let initial_liq = math::sqrt(math::mul_to_u128(optimal_coin_x, optimal_coin_y));
            assert!(initial_liq > MINIMAL_LIQUIDITY, ERR_LIQUID_NOT_ENOUGH);

            let minimal_liquidity = balance::increase_supply(
                &mut pool.lp_supply,
                MINIMAL_LIQUIDITY
            );
            balance::join(&mut pool.min_liquidity, minimal_liquidity);

            initial_liq - MINIMAL_LIQUIDITY
        } else {
            let x_liq = (lp_supply as u128) * (optimal_coin_x as u128) / (coin_x_reserve as u128);
            let y_liq = (lp_supply as u128) * (optimal_coin_y as u128) / (coin_y_reserve as u128);
            if (x_liq < y_liq) {
                assert!(x_liq < (U64_MAX as u128), ERR_U64_OVERFLOW);
                (x_liq as u64)
            } else {
                assert!(y_liq < (U64_MAX as u128), ERR_U64_OVERFLOW);
                (y_liq as u64)
            }
        };
        assert!(provided_liq > 0, ERR_INSUFFICIENT_LIQUIDITY_MINTED);

        if (optimal_coin_x < coin_x_value) {
            transfer::public_transfer(
                coin::from_balance(balance::split(&mut coin_x_balance, coin_x_value - optimal_coin_x), ctx),
                tx_context::sender(ctx)
            )
        };
        if (optimal_coin_y < coin_y_value) {
            transfer::public_transfer(
                coin::from_balance(balance::split(&mut coin_y_balance, coin_y_value - optimal_coin_y), ctx),
                tx_context::sender(ctx)
            )
        };

        let coin_x_amount = balance::join(&mut pool.coin_x, coin_x_balance);
        let coin_y_amount = balance::join(&mut pool.coin_y, coin_y_balance);

        assert!(coin_x_amount < MAX_POOL_VALUE, ERR_POOL_FULL);
        assert!(coin_y_amount < MAX_POOL_VALUE, ERR_POOL_FULL);

        let balance = balance::increase_supply(&mut pool.lp_supply, provided_liq);

        let return_values = vector::empty<u64>();
        vector::push_back(&mut return_values, coin_x_value);
        vector::push_back(&mut return_values, coin_y_value);
        vector::push_back(&mut return_values, provided_liq);

        (coin::from_balance(balance, ctx), return_values)
    }

    /// Remove liquidity from the `Pool` by burning `Coin<LP>`.
    /// Returns `Coin<X>` and `Coin<Y>`.
    public fun remove_liquidity_non_entry<X, Y>(
        pool: &mut Pool<X, Y>,
        lp_coin: Coin<LP<X, Y>>,
        is_order: bool,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        assert!(is_order, ERR_MUST_BE_ORDER);

        let lp_val = coin::value(&lp_coin);
        assert!(lp_val > 0, ERR_ZERO_AMOUNT);

        let (coin_x_amount, coin_y_amount, lp_supply) = get_reserves_size(pool);
        let coin_x_out = math::mul_div(coin_x_amount, lp_val, lp_supply);
        let coin_y_out = math::mul_div(coin_y_amount, lp_val, lp_supply);

        balance::decrease_supply(&mut pool.lp_supply, coin::into_balance(lp_coin));

        (
            coin::take(&mut pool.coin_x, coin_x_out, ctx),
            coin::take(&mut pool.coin_y, coin_y_out, ctx)
        )
    }

    /// Swap Coin<X> for Coin<Y>
    /// Returns Coin<Y>
    public fun swap_out<X, Y>(
        global: &mut AMMGlobal,
        coin_in: Coin<X>,
        coin_out_min: u64,
        is_order: bool,
        ctx: &mut TxContext
    ): vector<u64> {
        assert!(coin::value<X>(&coin_in) > 0, ERR_ZERO_AMOUNT);

        if (is_order) {
            let pool = get_mut_pool<X, Y>(global, is_order);
            let (coin_x_reserve, coin_y_reserve, _lp) = get_reserves_size(pool);
            assert!(coin_x_reserve > 0 && coin_y_reserve > 0, ERR_RESERVES_EMPTY);
            let coin_x_in = coin::value(&coin_in);

            let coin_y_out = get_amount_out(
                coin_x_in,
                coin_x_reserve,
                coin_y_reserve,
            );
            assert!(
                coin_y_out >= coin_out_min,
                ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
            );

            let coin_x_balance = coin::into_balance(coin_in);
            balance::join(&mut pool.coin_x, coin_x_balance);
            let coin_out = coin::take(&mut pool.coin_y, coin_y_out, ctx);
            transfer::public_transfer(coin_out, tx_context::sender(ctx));

            // The division operation truncates the decimal,
            // Causing coin_out_value to be less than the calculated value.
            // Thus making the actual value of new_reserve_out be more.
            // So lp_value is increased.
            let (new_reserve_x, new_reserve_y, _lp) = get_reserves_size(pool);
            assert_lp_value_is_increased(
                coin_x_reserve,
                coin_y_reserve,
                new_reserve_x,
                new_reserve_y
            );

            let return_values = vector::empty<u64>();
            vector::push_back(&mut return_values, coin_x_in);
            vector::push_back(&mut return_values, 0);
            vector::push_back(&mut return_values, 0);
            vector::push_back(&mut return_values, coin_y_out);
            return_values
        } else {
            let pool = get_mut_pool<Y, X>(global, !is_order);
            let (coin_x_reserve, coin_y_reserve, _lp) = get_reserves_size(pool);
            assert!(coin_x_reserve > 0 && coin_y_reserve > 0, ERR_RESERVES_EMPTY);
            let coin_y_in = coin::value(&coin_in);

            let coin_x_out = get_amount_out(
                coin_y_in,
                coin_y_reserve,
                coin_x_reserve,
            );
            assert!(
                coin_x_out >= coin_out_min,
                ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
            );

            let coin_y_balance = coin::into_balance(coin_in);
            balance::join(&mut pool.coin_y, coin_y_balance);
            let coin_out = coin::take(&mut pool.coin_x, coin_x_out, ctx);
            transfer::public_transfer(coin_out, tx_context::sender(ctx));

            // The division operation truncates the decimal,
            // Causing coin_out_value to be less than the calculated value.
            // Thus making the actual value of new_reserve_out be more.
            // So lp_value is increased.
            let (new_reserve_x, new_reserve_y, _lp) = get_reserves_size(pool);
            assert_lp_value_is_increased(
                coin_x_reserve,
                coin_y_reserve,
                new_reserve_x,
                new_reserve_y
            );

            let return_values = vector::empty<u64>();
            vector::push_back(&mut return_values, 0);
            vector::push_back(&mut return_values, coin_x_out);
            vector::push_back(&mut return_values, coin_y_in);
            vector::push_back(&mut return_values, 0);
            return_values
        }

    }

    // clone from swap_out() but return a Coin object
    public fun swap_out_for_coin<X, Y>(
        global: &mut AMMGlobal,
        coin_in: Coin<X>,
        coin_out_min: u64,
        is_order: bool,
        ctx: &mut TxContext
    ): Coin<Y> {
        assert!(coin::value<X>(&coin_in) > 0, ERR_ZERO_AMOUNT);

        if (is_order) {
            let pool = get_mut_pool<X, Y>(global, is_order);
            let (coin_x_reserve, coin_y_reserve, _lp) = get_reserves_size(pool);
            assert!(coin_x_reserve > 0 && coin_y_reserve > 0, ERR_RESERVES_EMPTY);
            let coin_x_in = coin::value(&coin_in);

            let coin_y_out = get_amount_out(
                coin_x_in,
                coin_x_reserve,
                coin_y_reserve,
            );
            assert!(
                coin_y_out >= coin_out_min,
                ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
            );

            let coin_x_balance = coin::into_balance(coin_in);
            balance::join(&mut pool.coin_x, coin_x_balance);
            let coin_out = coin::take(&mut pool.coin_y, coin_y_out, ctx);

            let (new_reserve_x, new_reserve_y, _lp) = get_reserves_size(pool);
            assert_lp_value_is_increased(
                coin_x_reserve,
                coin_y_reserve,
                new_reserve_x,
                new_reserve_y
            );

            coin_out
        } else {
            let pool = get_mut_pool<Y, X>(global, !is_order);
            let (coin_x_reserve, coin_y_reserve, _lp) = get_reserves_size(pool);
            assert!(coin_x_reserve > 0 && coin_y_reserve > 0, ERR_RESERVES_EMPTY);
            let coin_y_in = coin::value(&coin_in);

            let coin_x_out = get_amount_out(
                coin_y_in,
                coin_y_reserve,
                coin_x_reserve,
            );
            assert!(
                coin_x_out >= coin_out_min,
                ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
            );

            let coin_y_balance = coin::into_balance(coin_in);
            balance::join(&mut pool.coin_y, coin_y_balance);
            let coin_out = coin::take(&mut pool.coin_x, coin_x_out, ctx); 

            let (new_reserve_x, new_reserve_y, _lp) = get_reserves_size(pool);
            assert_lp_value_is_increased(
                coin_x_reserve,
                coin_y_reserve,
                new_reserve_x,
                new_reserve_y
            );

            coin_out
        }
    }

    // swap across 2 pools
    public fun swap_xyz_non_entry<X, Y, Z>(
        global: &mut AMMGlobal,
        coin_x_in: Coin<X>,
        coin_z_out_min: u64,
        ctx: &mut TxContext
    ) : u64 {
        let coin_y = swap_out_for_coin<X,Y>(
            global,
            coin_x_in,
            1,
            is_order<X, Y>(),
            ctx
        );

        let coin_z = swap_out_for_coin<Y,Z>(
            global,
            coin_y,
            coin_z_out_min,
            is_order<Y, Z>(),
            ctx
        );

        let output_amount = coin::value(&coin_z);

        transfer::public_transfer(
            coin_z,
            tx_context::sender(ctx)
        );

        output_amount
    }

    /// Get most used values in a handy way:
    /// - amount of Coin<X>
    /// - amount of Coin<Y>
    /// - total supply of LP<X,Y>
    public fun get_reserves_size<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
        (
            balance::value(&pool.coin_x),
            balance::value(&pool.coin_y),
            balance::supply_value(&pool.lp_supply)
        )
    }

    /// Calculate amounts needed for adding new liquidity for both `X` and `Y`.
    /// Returns both `X` and `Y` coins amounts.
    public fun calc_optimal_coin_values(
        coin_x_desired: u64,
        coin_y_desired: u64,
        coin_x_min: u64,
        coin_y_min: u64,
        coin_x_reserve: u64,
        coin_y_reserve: u64
    ): (u64, u64) {
        if (coin_x_reserve == 0 && coin_y_reserve == 0) {
            return (coin_x_desired, coin_y_desired)
        } else {
            let coin_y_returned = math::mul_div(coin_x_desired, coin_y_reserve, coin_x_reserve);
            if (coin_y_returned <= coin_y_desired) {
                assert!(coin_y_returned >= coin_y_min, ERR_INSUFFICIENT_COIN_Y);
                return (coin_x_desired, coin_y_returned)
            } else {
                let coin_x_returned = math::mul_div(coin_y_desired, coin_x_reserve, coin_y_reserve);
                assert!(coin_x_returned <= coin_x_desired, ERR_OVERLIMIT);
                assert!(coin_x_returned >= coin_x_min, ERR_INSUFFICIENT_COIN_X);
                return (coin_x_returned, coin_y_desired)
            }
        }
    }

    public fun assert_lp_value_is_increased(
        old_reserve_x: u64,
        old_reserve_y: u64,
        new_reserve_x: u64,
        new_reserve_y: u64,
    ) {
        // never overflow
        assert!(
            (old_reserve_x as u128) * (old_reserve_y as u128)
                < (new_reserve_x as u128) * (new_reserve_y as u128),
            ERR_INCORRECT_SWAP
        )
    }

    /// Calculate the output amount
    public fun get_amount_out(
        coin_in: u64,
        reserve_in: u64,
        reserve_out: u64,
    ): u64 {
        
        let coin_in_val = (coin_in as u128);

        // reserve_in size after adding coin_in
        let new_reserve_in = (reserve_in as u128) + (coin_in as u128);

        // Multiply coin_in by the current exchange rate:
        // current_exchange_rate = reserve_out / reserve_in
        // amount_in_after_fees * current_exchange_rate -> amount_out
        math::mul_div_u128(coin_in_val, (reserve_out as u128), new_reserve_in)
    }

    fun check_admin(global: &AMMGlobal, sender: address) {
        let (contained, _) = vector::index_of<address>(&global.admin, &sender);
        assert!(contained,ERR_UNAUTHORISED);
    }

    // ======== Entry Functions =========

    /// Entrypoint for the `add_liquidity` method.
    /// Sends `LP<X,Y>` to the transaction sender.
    public entry fun add_liquidity<X, Y>(
        global: &mut AMMGlobal,
        coin_x: Coin<X>,
        coin_x_min: u64,
        coin_y: Coin<Y>,
        coin_y_min: u64,
        ctx: &mut TxContext
    ) {
        assert!(!is_emergency(global), ERR_EMERGENCY);
        let is_order = is_order<X, Y>();

        if (!has_registered<X, Y>(global)) {
            register_pool<X, Y>(global, is_order)
        };
        let pool = get_mut_pool<X, Y>(global, is_order);

        let (lp, return_values) = add_liquidity_non_entry(
            pool,
            coin_x,
            coin_x_min,
            coin_y,
            coin_y_min,
            is_order,
            ctx
        );
        assert!(vector::length(&return_values) == 3, ERR_UNEXPECTED_RETURN);

        let lp_val = vector::pop_back(&mut return_values);
        let coin_x_val = vector::pop_back(&mut return_values);
        let coin_y_val = vector::pop_back(&mut return_values);

        transfer::public_transfer(
            lp,
            tx_context::sender(ctx)
        );

        let global = global_id<X, Y>(pool);
        let lp_name = generate_lp_name<X, Y>();

        added_event(
            global,
            lp_name,
            coin_x_val,
            coin_y_val,
            lp_val
        )
    }

    /// Entrypoint for the `remove_liquidity` method.
    /// Transfers Coin<X> and Coin<Y> to the sender.
    public entry fun remove_liquidity<X, Y>(
        global: &mut AMMGlobal,
        lp_coin: Coin<LP<X, Y>>,
        ctx: &mut TxContext
    ) {
        assert!(!is_emergency(global), ERR_EMERGENCY);
        let is_order = is_order<X, Y>();
        let pool = get_mut_pool<X, Y>(global, is_order);

        let lp_val = value(&lp_coin);
        let (coin_x, coin_y) = remove_liquidity_non_entry(pool, lp_coin, is_order, ctx);
        let coin_x_val = value(&coin_x);
        let coin_y_val = value(&coin_y);

        transfer::public_transfer(
            coin_x,
            tx_context::sender(ctx)
        );

        transfer::public_transfer(
            coin_y,
            tx_context::sender(ctx)
        );

        let global = global_id<X, Y>(pool);
        let lp_name = generate_lp_name<X, Y>();

        removed_event(
            global,
            lp_name,
            coin_x_val,
            coin_y_val,
            lp_val
        )
    }

    /// Entry point for the `swap` method.
    /// Sends swapped Coin to the sender.
    public entry fun swap<X, Y>(
        global: &mut AMMGlobal,
        coin_in: Coin<X>,
        coin_out_min: u64,
        ctx: &mut TxContext
    ) {
        assert!(!is_emergency(global), ERR_EMERGENCY);
        let is_order = is_order<X, Y>();

        let return_values = swap_out<X, Y>(
            global,
            coin_in,
            coin_out_min,
            is_order,
            ctx
        );

        let coin_y_out = vector::pop_back(&mut return_values);
        let coin_y_in = vector::pop_back(&mut return_values);
        let coin_x_out = vector::pop_back(&mut return_values);
        let coin_x_in = vector::pop_back(&mut return_values);

        let global =  id<X, Y>(global);
        let lp_name = generate_lp_name<X, Y>();

        swapped_event(
            global,
            lp_name,
            coin_x_in,
            coin_x_out,
            coin_y_in,
            coin_y_out
        )
    }

    public entry fun swap_xyz<X, Y, Z>(
        global: &mut AMMGlobal,
        coin_x_in: Coin<X>,
        coin_z_out_min: u64,
        ctx: &mut TxContext
    ) {
        assert!(!is_emergency(global), ERR_EMERGENCY);

        let input_amount = value(&coin_x_in);

        let output_amount =  swap_xyz_non_entry<X, Y, Z>(
            global,
            coin_x_in,
            coin_z_out_min,
            ctx
        );

        let global =  id<X, Z>(global);
        let lp_name =  generate_lp_name<X, Z>();

        swapped_event(
            global,
            lp_name,
            input_amount,
            0,
            0,
            output_amount
        )
    }

    public entry fun multi_add_liquidity<X, Y>(
        global: &mut AMMGlobal,
        coins_x: vector<Coin<X>>,
        coins_x_value: u64,
        coin_x_min: u64,
        coins_y: vector<Coin<Y>>,
        coins_y_value: u64,
        coin_y_min: u64,
        ctx: &mut TxContext
    ) {
        assert!(!is_emergency(global), ERR_EMERGENCY);
        assert!(
            !vector::is_empty(&coins_x) && !vector::is_empty(&coins_y),
            ERR_EMPTY_COINS
        );

        // 1. merge coins
        let merged_coin_x = vector::pop_back(&mut coins_x);
        pay::join_vec(&mut merged_coin_x, coins_x);
        let coin_x = split(&mut merged_coin_x, coins_x_value, ctx);

        let merged_coin_y = vector::pop_back(&mut coins_y);
        pay::join_vec(&mut merged_coin_y, coins_y);
        let coin_y = split(&mut merged_coin_y, coins_y_value, ctx);

        // 2. add liquidity
        add_liquidity<X, Y>(
            global,
            coin_x,
            coin_x_min,
            coin_y,
            coin_y_min,
            ctx
        );

        // 3. handle remain coins
        if (value(&merged_coin_x) > 0) {
            transfer::public_transfer(
                merged_coin_x,
                tx_context::sender(ctx)
            )
        } else {
            destroy_zero(merged_coin_x)
        };

        if (value(&merged_coin_y) > 0) {
            transfer::public_transfer(
                merged_coin_y,
                tx_context::sender(ctx)
            )
        } else {
            destroy_zero(merged_coin_y)
        }
    }

    public entry fun multi_remove_liquidity<X, Y>(
        global: &mut AMMGlobal,
        lp_coin: vector<Coin<LP<X, Y>>>,
        ctx: &mut TxContext
    ) {
        assert!(!is_emergency(global), ERR_EMERGENCY);
        assert!(!vector::is_empty(&lp_coin), ERR_EMPTY_COINS);

        // 1. merge coins
        let merged_lp = vector::pop_back(&mut lp_coin);
        pay::join_vec(&mut merged_lp, lp_coin);

        // 2. remove liquidity
        remove_liquidity(
            global,
            merged_lp,
            ctx
        )
    }

    public entry fun multi_swap<X, Y>(
        global: &mut AMMGlobal,
        coins_in: vector<Coin<X>>,
        coins_in_value: u64,
        coin_out_min: u64,
        ctx: &mut TxContext
    ) {
        assert!(!is_emergency(global), ERR_EMERGENCY);
        assert!(!vector::is_empty(&coins_in), ERR_EMPTY_COINS);

        // 1. merge coins
        let merged_coins_in = vector::pop_back(&mut coins_in);
        pay::join_vec(&mut merged_coins_in, coins_in);
        let coin_in = split(&mut merged_coins_in, coins_in_value, ctx);

        // 2. swap coin
        swap<X, Y>(
            global,
            coin_in,
            coin_out_min,
            ctx
        );

        // 3. handle remain coin
        if (value(&merged_coins_in) > 0) {
            transfer::public_transfer(
                merged_coins_in,
                tx_context::sender(ctx)
            )
        } else {
            destroy_zero(merged_coins_in)
        }
    }


    // add new admin
    public entry fun add_admin(global: &mut AMMGlobal, user: address, ctx: &mut TxContext) {
        check_admin(global, tx_context::sender(ctx));
        assert!(!vector::contains(&global.admin, &user),ERR_DUPLICATED_ENTRY);
        vector::push_back<address>(&mut global.admin, user);
    }

    // remove admin
    public entry fun remove_admin(global: &mut AMMGlobal, user: address, ctx: &mut TxContext) {
        check_admin(global, tx_context::sender(ctx));
        let (contained, index) = vector::index_of<address>(&global.admin, &user);
        assert!(contained,ERR_NOT_FOUND);
        vector::remove<address>(&mut global.admin, index);
    }

    #[test_only]
    public fun init_for_testing(
        ctx: &mut TxContext
    ) {
        init(ctx)
    }

    #[test_only]
    public fun add_liquidity_for_testing<X, Y>(
        global: &mut AMMGlobal,
        coin_x: Coin<X>,
        coin_y: Coin<Y>,
        ctx: &mut TxContext
    ): (Coin<LP<X, Y>>, vector<u64>) {
        let is_order = is_order<X, Y>();
        if (!has_registered<X, Y>(global)) {
            register_pool<X, Y>(global, is_order)
        };
        let pool = get_mut_pool<X, Y>(global, is_order);

        add_liquidity_non_entry(
            pool,
            coin_x,
            1,
            coin_y,
            1,
            is_order,
            ctx
        )
    }

    public fun get_mut_pool_for_testing<X, Y>(
        global: &mut AMMGlobal
    ): &mut Pool<X, Y> {
        get_mut_pool<X, Y>(global, is_order<X, Y>())
    }

    #[test_only]
    public fun swap_for_testing<X, Y>(
        global: &mut AMMGlobal,
        coin_in: Coin<X>,
        coin_out_min: u64,
        ctx: &mut TxContext
    ): vector<u64> {
        swap_out<X, Y>(
            global,
            coin_in,
            coin_out_min,
            is_order<X, Y>(),
            ctx
        )
    }

    #[test_only]
    public fun remove_liquidity_for_testing<X, Y>(
        pool: &mut Pool<X, Y>,
        lp_coin: Coin<LP<X, Y>>,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        remove_liquidity_non_entry<X, Y>(
            pool,
            lp_coin,
            is_order<X, Y>(),
            ctx
        )
    }

}