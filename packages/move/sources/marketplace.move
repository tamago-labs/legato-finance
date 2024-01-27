// Copyright (c) Tamago Blockchain Labs, Inc.
// SPDX-License-Identifier: MIT

module legato::marketplace {

    // use std::debug;

    use sui::object::{ Self, ID, UID };
    use sui::balance::{ Self, Balance };
    use sui::bag::{ Self, Bag};
    use sui::table::{ Self, Table};
    use sui::tx_context::{ Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::event::{Self};

    use std::vector;
    use std::ascii::{  into_bytes};
    use std::type_name::{get, into_string};
    use std::string::{ Self, String };

    use legato::math::{mul_div};

    // ======== Constants ========
    const MIST_PER_SUI: u64 = 1_000_000_000;

    // ======== Errors ========
    const E_DUPLICATED_ENTRY: u64 = 301;
    const E_NOT_FOUND: u64 = 302;
    const E_UNAUTHORIZED_USER: u64 = 303;
    const E_ZERO_AMOUNT: u64 = 304;
    const E_INSUFFICIENT_AMOUNT: u64 = 305;
    const E_INVALID_QUOTE: u64 = 306;
    const E_INVALID_BASE: u64 = 307;
    const E_NO_ORDER_LISTING: u64 = 306;
    const E_INSUFFICIENT_BALANCE: u64 = 306;
    const E_INVALID_ORDER_ID: u64 = 307;

    // ======== Structs =========

    struct TransferRequest<phantom T> has drop {
        amount: u64,
        from_address: address,
        to_address: address
    }

    struct ReductionRequest<phantom T> has drop {
        amount: u64,
        owner_address: address
    }

    struct Order has  drop, store {
        order_id: u64,
        created_epoch: u64,
        amount: u64,
        unit_price: u64, // per 1 unit
        owner: address
    }

    struct Orders has store {
        token_name: String,
        bid_orders: vector<Order>,
        ask_orders: vector<Order>
    }

    // SUI or USDC
    struct QuoteMarket<phantom T> has store {
        id: UID,
        global: ID,
        token_name: String,
        orders: Bag
    }

    struct TokenDeposit<phantom T> has store {
        coin: Balance<T>,
        balances: Table<address,u64>,
        listing: Table<address,u64> // that has been listing
    }

    /// The global config for Marketplace
    struct GlobalMarketplace has key {
        id: UID,
        admin: vector<address>,
        treasury: address,
        has_paused: bool,
        user_balances: Bag,
        markets: Bag,
        order_count: u64
    }

    struct DepositEvent has copy, drop {
        global: ID,
        token_name: String,
        input_amount: u64,
        sender: address
    }

    struct WithdrawEvent has copy, drop {
        global: ID,
        token_name: String,
        withdraw_amount: u64,
        sender: address
    }

    struct TradeEvent has copy, drop {
        global: ID,
        from_token: String,
        to_token: String,
        input_amount: u64,
        output_amount: u64,
        sender: address
    }

    struct NewOrderEvent has copy, drop {
        global: ID,
        order_id: u64,
        is_bid: bool,
        base_token: String,
        quote_token: String,
        amount: u64,
        unit_price: u64, // per 1 unit
        owner: address
    }

    struct RemoveOrderEvent has copy, drop {
        global: ID,
        order_id: u64,
        owner: address
    }


    fun init(ctx: &mut TxContext) {

        let admin_list = vector::empty<address>();
        vector::push_back<address>(&mut admin_list, tx_context::sender(ctx));

        let global = GlobalMarketplace {
            id: object::new(ctx),
            admin: admin_list, 
            treasury: tx_context::sender(ctx),
            has_paused: false,
            user_balances: bag::new(ctx),
            markets: bag::new(ctx),
            order_count: 0
        };

        transfer::share_object(global)
    }

    // ======== Public Functions =========

    // pt -> usdc
    public entry fun sell_only<X, Y>(global :&mut GlobalMarketplace, base_token_amount: u64, ask_price: u64, ctx: &mut TxContext) {
        check_quote<Y>(global);

        matching_orders<X,Y>(global, base_token_amount, ask_price, false , ctx);
    }

    // pt -> usdc
    public entry fun sell_and_listing<X, Y>(global :&mut GlobalMarketplace, base_token_amount: u64, ask_price: u64, ctx: &mut TxContext) {
        check_quote<Y>(global);

        let remaining_amount = matching_orders<X,Y>(global, base_token_amount, ask_price, false , ctx);
        add_order<X, Y>(global, remaining_amount, ask_price, false, ctx);
    }

    // usdt -> pt
    public entry fun buy_only<X, Y>(global :&mut GlobalMarketplace, quote_token_amount: u64, bid_price: u64, ctx: &mut TxContext) {
        check_quote<X>(global);

        matching_orders<X,Y>(global, quote_token_amount, bid_price, true , ctx);
    }

    // usdt -> pt
    public entry fun buy_and_listing<X,Y>(global :&mut GlobalMarketplace, quote_token_amount: u64, bid_price: u64, ctx: &mut TxContext) {
        check_quote<X>(global);

        let remaining_amount = matching_orders<X,Y>(global, quote_token_amount, bid_price, true , ctx);
        add_order<X,Y>(global, remaining_amount, bid_price, true, ctx);
    }

    public entry fun deposit<T>(global :&mut GlobalMarketplace, input_coin: Coin<T>, ctx: &mut TxContext) {
        
        let token_name = token_to_name<T>();
        let input_amount = coin::value(&input_coin);
        let has_registered = bag::contains_with_type<String, TokenDeposit<T>>(&global.user_balances, token_name);

        if (!has_registered) {
            let init_coin = balance::zero<T>();
            balance::join<T>(&mut init_coin, coin::into_balance(input_coin));

            let new_token_deposit = TokenDeposit { coin: init_coin, balances: init_balance_table(input_amount, ctx), listing: init_balance_table(0, ctx)};
            bag::add(&mut global.user_balances, token_name, new_token_deposit);
        } else {
            let token_deposit = bag::borrow_mut<String, TokenDeposit<T>>(&mut global.user_balances, token_name);
            balance::join<T>(&mut token_deposit.coin, coin::into_balance(input_coin));

            if (table::contains(&token_deposit.balances, tx_context::sender(ctx))) {
                *table::borrow_mut( &mut token_deposit.balances, tx_context::sender(ctx) ) = *table::borrow( &token_deposit.balances, tx_context::sender(ctx) )+input_amount;
            } else {
                table::add(&mut token_deposit.balances, tx_context::sender(ctx), input_amount);
            };
        };

        // emit event
        event::emit( DepositEvent { global : object::id(global), token_name, input_amount, sender: tx_context::sender(ctx) })
    }

    public entry fun withdraw<T>(global :&mut GlobalMarketplace, withdraw_amount: u64, ctx: &mut TxContext) {

        let token_name = token_to_name<T>();
        let has_registered = bag::contains_with_type<String, TokenDeposit<T>>(&global.user_balances, token_name);
        assert!(has_registered, E_NOT_FOUND);

        let token_deposit = bag::borrow_mut<String, TokenDeposit<T>>(&mut global.user_balances, token_name);
        assert!(table::contains(&token_deposit.balances, tx_context::sender(ctx)), E_ZERO_AMOUNT);
        
        let available_amount = *table::borrow(&token_deposit.balances, tx_context::sender(ctx)); 
        let listing_amount = *table::borrow(&token_deposit.listing, tx_context::sender(ctx)); 
        assert!((available_amount-listing_amount) >= withdraw_amount, E_INSUFFICIENT_AMOUNT);

        *table::borrow_mut(&mut token_deposit.balances, tx_context::sender(ctx)) = *table::borrow(&token_deposit.balances, tx_context::sender(ctx))-withdraw_amount;

        let to_sender = balance::split(&mut token_deposit.coin, withdraw_amount);
        transfer::public_transfer( coin::from_balance(to_sender, ctx) , tx_context::sender(ctx));

        // emit event
        event::emit(WithdrawEvent { global : object::id(global), token_name, withdraw_amount, sender: tx_context::sender(ctx) })
    }

    public entry fun update_order<X, Y>(global : &mut GlobalMarketplace, order_id: u64, unit_price: u64, ctx: &mut TxContext) {

        let market = bag::borrow_mut<String, QuoteMarket<Y>>(&mut global.markets, token_to_name<Y>());
        assert!( bag::contains_with_type<String, Orders>(&market.orders, token_to_name<X>()), E_INVALID_BASE );
        let orders_set = bag::borrow_mut<String, Orders>(&mut market.orders, token_to_name<X>());

        let count = vector::length(&orders_set.ask_orders);
        let i = 0;
        while (i < count) {
            let order = vector::borrow_mut(&mut orders_set.ask_orders, i);
            if (order.order_id == order_id) {
                assert!( order.owner == tx_context::sender(ctx), E_UNAUTHORIZED_USER );
                order.unit_price = unit_price;
                break
            };
            i = i + 1;
        };

        count = vector::length(&orders_set.bid_orders);
        i = 0;
        while (i < count) {
            let order = vector::borrow_mut(&mut orders_set.bid_orders, i);
            assert!( order.owner == tx_context::sender(ctx), E_UNAUTHORIZED_USER );
            if (order.order_id == order_id) {
                order.unit_price = unit_price;
                break
            };
            i = i + 1;
        };
    }

    public entry fun cancel_order<X, Y>(global : &mut GlobalMarketplace, order_id: u64, ctx: &mut TxContext) {

        let global_id = object::id(global); 
        let market = bag::borrow_mut<String, QuoteMarket<Y>>(&mut global.markets, token_to_name<Y>());
        assert!( bag::contains_with_type<String, Orders>(&market.orders, token_to_name<X>()), E_INVALID_BASE );
        let orders_set = bag::borrow_mut<String, Orders>(&mut market.orders, token_to_name<X>());

        let count = vector::length(&orders_set.ask_orders);
        let i = 0;
        while (i < count) {
            let order = vector::borrow(&orders_set.ask_orders, i);
            if (order.order_id == order_id) {
                assert!( order.owner == tx_context::sender(ctx), E_UNAUTHORIZED_USER );
                vector::swap_remove(&mut orders_set.ask_orders, i);
                break
            };
            i = i + 1;
        };

        count = vector::length(&orders_set.bid_orders);
        i = 0;
        while (i < count) {
            let order = vector::borrow(&orders_set.bid_orders, i);
            if (order.order_id == order_id) {
                assert!( order.owner == tx_context::sender(ctx), E_UNAUTHORIZED_USER );
                vector::swap_remove(&mut orders_set.bid_orders, i);
                break
            };
            i = i + 1;
        };

        // emit event

        event::emit(
            RemoveOrderEvent {
                global : global_id,
                order_id,
                owner: tx_context::sender(ctx)
            }
        )

    }

    public fun token_to_name<T>(): String {
        string::utf8(into_bytes(into_string(get<T>())))
    }

    public fun token_available<T>(global :&mut GlobalMarketplace, user_address: address): u64 { 
        let token_name = token_to_name<T>();
        let has_registered = bag::contains_with_type<String, TokenDeposit<T>>(&global.user_balances, token_name);
        assert!(has_registered, E_NOT_FOUND);

        let token_deposit = bag::borrow_mut<String, TokenDeposit<T>>(&mut global.user_balances, token_name);
        
        if (table::contains(&token_deposit.balances, user_address)) 
            *table::borrow(&token_deposit.balances, user_address)
        else 0
    }

    // ======== Only Governance =========

    public entry fun setup_quote<T>( global :&mut GlobalMarketplace , ctx: &mut TxContext) {
        check_admin(global, tx_context::sender(ctx));

        let market_name = token_to_name<T>();
        let has_registered = bag::contains_with_type<String, QuoteMarket<T>>(&global.markets, market_name);
        assert!(!has_registered, E_DUPLICATED_ENTRY);

        let new_market = QuoteMarket<T> {
            id: object::new(ctx),
            token_name: market_name ,
            global: object::id(global),
            orders: bag::new(ctx)
        };
        bag::add(&mut global.markets, market_name, new_market);
    }

    // add new admin
    public entry fun add_admin(global: &mut GlobalMarketplace, user: address, ctx: &mut TxContext) {
        check_admin(global, tx_context::sender(ctx));
        assert!(!vector::contains(&global.admin, &user),E_DUPLICATED_ENTRY);
        vector::push_back<address>(&mut global.admin, user);
    }

    // remove admin
    public entry fun remove_admin(global: &mut GlobalMarketplace, user: address, ctx: &mut TxContext) {
        check_admin(global, tx_context::sender(ctx));
        let (contained, index) = vector::index_of<address>(&global.admin, &user);
        assert!(contained,E_NOT_FOUND);
        vector::remove<address>(&mut global.admin, index);
    }

    // ======== Internal Functions =========

    fun check_admin(global: &GlobalMarketplace, sender: address) {
        let (contained, _) = vector::index_of<address>(&global.admin, &sender);
        assert!(contained,E_UNAUTHORIZED_USER);
    }

    fun check_quote<T>(global: &GlobalMarketplace) {
        assert!(bag::contains_with_type<String, QuoteMarket<T>>(&global.markets, token_to_name<T>()), E_INVALID_QUOTE);
    }

    fun init_balance_table(amount: u64,  ctx: &mut TxContext): Table<address, u64> {
        let init_table = table::new(ctx);
        table::add(&mut init_table, tx_context::sender(ctx), amount);
        init_table
    }

    fun sort_orders(orders: &mut vector<Order>) {
        let length = vector::length(orders);
        let i = 1;
        while (i < length) {
            let cur = vector::borrow(orders, i);
            let cur_unit_price = cur.unit_price;
            let j = i;
            while (j > 0) {
                j = j - 1;
                let item = vector::borrow(orders, j);
                let unit_price = item.unit_price;
                if (unit_price > cur_unit_price) {
                    vector::swap(orders, j, j + 1);
                } else {
                    break
                };
            };
            i = i + 1;
        };
    }

    fun eligible_orders(orders: &vector<Order>, from_price: u64, is_bid: bool) : vector<u64> {
        let count = vector::length(orders);
        let i = 0;
        let order_ids = vector::empty<u64>();
        while (i < count) {
            let order = vector::borrow(orders, i);
            if (!is_bid) {
                if (from_price >= order.unit_price) {
                    vector::push_back<u64>(&mut order_ids, i);
                };
            } else {
                if (order.unit_price >= from_price) {
                    vector::push_back<u64>(&mut order_ids, i);
                };
            };
            i = i + 1;
        };
        order_ids
    }

    fun matching_orders<X, Y>(global : &mut GlobalMarketplace, amount: u64, from_price: u64, is_buy: bool, ctx: &mut TxContext ): u64 {
        let global_id = object::id(global);
        let sender = tx_context::sender(ctx);

        if (is_buy) {
            // matching with ask orders
            let available_amount = token_available<X>(global, sender);
            assert!(available_amount >= amount, E_INSUFFICIENT_BALANCE);

            let market = bag::borrow_mut<String, QuoteMarket<X>>(&mut global.markets, token_to_name<X>());
            check_base_market<X>(market, token_to_name<Y>());

            let orders_set = bag::borrow_mut<String, Orders>(&mut market.orders, token_to_name<Y>());

            if (vector::length(&orders_set.ask_orders) > 0) {
                sort_orders(&mut orders_set.ask_orders);

                let order_ids = eligible_orders(&orders_set.ask_orders, from_price, false);
                let transfer_list_x = vector::empty<TransferRequest<X>>();
                let transfer_list_y = vector::empty<TransferRequest<Y>>();
                let reducer_list = vector::empty<ReductionRequest<Y>>(); 

                let input_amount = 0;
                let output_amount = 0;

                while (vector::length(&order_ids) > 0) {
                    let order_id = vector::remove( &mut order_ids, 0);
                    let order = vector::borrow_mut(&mut orders_set.ask_orders, order_id);
                    let order_id_for_update = order.order_id;
                    let order_owner = order.owner;
                    let available_base_in_quote = mul_div(order.amount, order.unit_price, MIST_PER_SUI);

                    if (amount >= available_base_in_quote) {
                        vector::push_back<TransferRequest<X>>(&mut transfer_list_x, TransferRequest { amount: available_base_in_quote, from_address: sender, to_address: order.owner });
                        vector::push_back<TransferRequest<Y>>(&mut transfer_list_y, TransferRequest { amount: order.amount, from_address: order.owner, to_address: sender });
                        vector::push_back<ReductionRequest<Y>>(&mut reducer_list, ReductionRequest { amount: order.amount, owner_address: order.owner });

                        input_amount = input_amount+available_base_in_quote;
                        output_amount = output_amount+order.amount;

                        amount = 
                                if (amount >= available_base_in_quote) 
                                    amount-available_base_in_quote
                                else 0;
                        order.amount = 0;
                    } else {
                        let amount_in_base = mul_div(amount, MIST_PER_SUI, order.unit_price);
                        vector::push_back<TransferRequest<X>>(&mut transfer_list_x, TransferRequest { amount, from_address: sender, to_address: order.owner });
                        vector::push_back<TransferRequest<Y>>(&mut transfer_list_y, TransferRequest { amount: amount_in_base, from_address: order.owner, to_address: sender });
                        vector::push_back<ReductionRequest<Y>>(&mut reducer_list, ReductionRequest { amount: amount_in_base, owner_address: order.owner });
                        
                        input_amount = input_amount+amount;
                        output_amount = output_amount+amount_in_base;

                        order.amount = 
                                if (order.amount >= amount_in_base) 
                                    order.amount-amount_in_base
                                else 0;
                        amount = 0;
                    };

                    // remove the order
                    if (order.amount == 0) {
                        vector::swap_remove(&mut orders_set.ask_orders, order_id);
                        // emit event

                        event::emit(
                            RemoveOrderEvent {
                                global : global_id,
                                order_id: order_id_for_update,
                                owner: order_owner
                            }
                        )
                    };

                    if (amount == 0) break
                };

                // clearing
                transfer_balance<X>(global, transfer_list_x );
                transfer_balance<Y>(global, transfer_list_y );
                reduce_listing_token<Y>(global, reducer_list);

                // emit event
                event::emit( 
                    TradeEvent { 
                        global : global_id,
                        from_token: token_to_name<X>(),
                        to_token: token_to_name<Y>(),
                        input_amount,
                        output_amount,
                        sender: tx_context::sender(ctx) 
                    });

            };


        } else {
            // matching with bid orders
            let available_base_amount = token_available<X>(global, sender);
            assert!(available_base_amount >= amount, E_INSUFFICIENT_AMOUNT);
            
            let market = bag::borrow_mut<String, QuoteMarket<Y>>(&mut global.markets, token_to_name<Y>());
            check_base_market<Y>(market, token_to_name<X>());

            let orders_set = bag::borrow_mut<String, Orders>(&mut market.orders, token_to_name<X>());

            if (vector::length(&orders_set.bid_orders) > 0) {
                sort_orders(&mut orders_set.bid_orders);

                let order_ids = eligible_orders(&orders_set.bid_orders, from_price, true);
                let transfer_list_x = vector::empty<TransferRequest<X>>();
                let transfer_list_y = vector::empty<TransferRequest<Y>>();
                let reducer_list = vector::empty<ReductionRequest<Y>>(); 

                let input_amount = 0;
                let output_amount = 0;

                while (vector::length(&order_ids) > 0) {
                    let order_id = vector::remove( &mut order_ids, 0);
                    let order = vector::borrow_mut(&mut orders_set.bid_orders, order_id);
                    let available_base_in_quote = mul_div(order.amount, order.unit_price, MIST_PER_SUI);
                    
                    if (amount >= order.amount) {
                        vector::push_back<TransferRequest<X>>(&mut transfer_list_x, TransferRequest { amount: order.amount, from_address: sender, to_address: order.owner });
                        vector::push_back<TransferRequest<Y>>(&mut transfer_list_y, TransferRequest { amount: available_base_in_quote, from_address: order.owner, to_address: sender });
                        vector::push_back<ReductionRequest<Y>>(&mut reducer_list, ReductionRequest { amount: available_base_in_quote, owner_address: order.owner });

                        input_amount = input_amount+order.amount;
                        output_amount = output_amount+available_base_in_quote;

                        amount = amount-order.amount;
                        order.amount = 0;
                    } else {
                        let amount_in_quote = mul_div(amount, order.unit_price, MIST_PER_SUI);
                        vector::push_back<TransferRequest<X>>(&mut transfer_list_x, TransferRequest { amount, from_address: sender, to_address: order.owner });
                        vector::push_back<TransferRequest<Y>>(&mut transfer_list_y, TransferRequest { amount: amount_in_quote, from_address: order.owner, to_address: sender });
                        vector::push_back<ReductionRequest<Y>>(&mut reducer_list, ReductionRequest { amount: order.amount, owner_address: order.owner });

                        input_amount = input_amount+amount;
                        output_amount = output_amount+amount_in_quote;
                        
                        order.amount = order.amount-amount;
                        amount = 0;
                    };

                    // remove the order
                    if (order.amount == 0) {
                        vector::swap_remove(&mut orders_set.bid_orders, order_id);
                        // todo: emit event
                    };

                    if (amount == 0) break
                };

                // clearing
                transfer_balance<X>(global, transfer_list_x );
                transfer_balance<Y>(global, transfer_list_y );
                reduce_listing_token<Y>(global, reducer_list);

                // emit event
                event::emit( 
                    TradeEvent { 
                        global : global_id,
                        from_token: token_to_name<X>(),
                        to_token: token_to_name<Y>(),
                        input_amount,
                        output_amount,
                        sender: tx_context::sender(ctx) 
                    });

            };

            

        };

        amount
    }

    // pt -> usdc
    fun add_order<X, Y>(global : &mut GlobalMarketplace, amount: u64, unit_price: u64, is_buy: bool, ctx: &mut TxContext) {
        
        let sender = tx_context::sender(ctx);
        let order_id = global.order_count+1;
        let new_order = Order { order_id, created_epoch: tx_context::epoch(ctx), amount, unit_price, owner: sender };
        
        if (!is_buy) {

            let token_name = token_to_name<X>();
            let market = bag::borrow_mut<String, QuoteMarket<Y>>(&mut global.markets, token_to_name<Y>());
            let has_registered = bag::contains_with_type<String, Orders>(&market.orders, token_name);

            if (!has_registered) {
                let bid_orders = vector::empty<Order>();
                let ask_orders = vector::empty<Order>();
                
                vector::push_back<Order>(&mut ask_orders, new_order);

                let new_orders_set = Orders {
                    token_name,
                    bid_orders,
                    ask_orders
                };
            
                bag::add(&mut market.orders, token_name, new_orders_set);

            } else {
                let orders_set = bag::borrow_mut<String, Orders>(&mut market.orders, token_name);
                vector::push_back<Order>(&mut orders_set.ask_orders, new_order);
            };

            // increase listing balance
            let token_deposit = bag::borrow_mut<String, TokenDeposit<X>>(&mut global.user_balances, token_name);
            *table::borrow_mut(&mut token_deposit.listing, tx_context::sender(ctx)) = *table::borrow(&token_deposit.listing, tx_context::sender(ctx))+amount;

            // emit event

            event::emit( 
                NewOrderEvent { 
                    global: object::id(global),
                    order_id,
                    is_bid: false,
                    base_token: token_to_name<X>(),
                    quote_token: token_to_name<Y>(),
                    amount,
                    unit_price,
                    owner: sender
                });
        } else {
            // usdc -> pt
            let token_name = token_to_name<Y>();
            let market = bag::borrow_mut<String, QuoteMarket<X>>(&mut global.markets, token_to_name<X>());
            let has_registered = bag::contains_with_type<String, Orders>(&market.orders, token_name);

            if (!has_registered) {
                let bid_orders = vector::empty<Order>();
                let ask_orders = vector::empty<Order>();
                
                vector::push_back<Order>(&mut bid_orders, new_order);

                let new_orders_set = Orders {
                    token_name,
                    bid_orders,
                    ask_orders
                };
            
                bag::add(&mut market.orders, token_name, new_orders_set);

            } else {
                let orders_set = bag::borrow_mut<String, Orders>(&mut market.orders, token_name);
                vector::push_back<Order>(&mut orders_set.bid_orders, new_order);
            };

            // increase listing balance
            let token_deposit = bag::borrow_mut<String, TokenDeposit<X>>(&mut global.user_balances, token_to_name<X>());
            *table::borrow_mut(&mut token_deposit.listing, tx_context::sender(ctx)) = *table::borrow(&token_deposit.listing, tx_context::sender(ctx))+amount;

            // emit event
            event::emit( 
                NewOrderEvent { 
                    global: object::id(global),
                    order_id,
                    is_bid: true,
                    base_token: token_to_name<Y>(),
                    quote_token: token_to_name<X>(),
                    amount,
                    unit_price,
                    owner: sender
                });

        };

    }

    fun transfer_balance<T>( global: &mut GlobalMarketplace , transfer_list: vector<TransferRequest<T>>) {

        let token_name = token_to_name<T>();
        let token_deposit = bag::borrow_mut<String, TokenDeposit<T>>(&mut global.user_balances, token_name);

        while (vector::length(&transfer_list) > 0) {
            let transfer_request = vector::remove( &mut transfer_list, 0);
            let from_user_balance = *table::borrow(&token_deposit.balances, transfer_request.from_address);

            if (from_user_balance >= transfer_request.amount) {
                *table::borrow_mut(&mut token_deposit.balances, transfer_request.from_address) = *table::borrow(&token_deposit.balances, transfer_request.from_address)-transfer_request.amount;
            } else {
                *table::borrow_mut(&mut token_deposit.balances, transfer_request.from_address) = 0;
            };

            if (table::contains(&token_deposit.balances, transfer_request.to_address)) {
                *table::borrow_mut( &mut token_deposit.balances, transfer_request.to_address ) = *table::borrow(&token_deposit.balances, transfer_request.to_address )+transfer_request.amount;
            } else {
                table::add(&mut token_deposit.balances, transfer_request.to_address, transfer_request.amount);
            };

        };

    }

    fun reduce_listing_token<T>(global: &mut GlobalMarketplace, reduction_list: vector<ReductionRequest<T>>) {

        let token_name = token_to_name<T>();
        let token_deposit = bag::borrow_mut<String, TokenDeposit<T>>(&mut global.user_balances, token_name);

        while (vector::length(&reduction_list) > 0) {
            let request = vector::remove( &mut reduction_list, 0);
            let owner_balance = *table::borrow(&token_deposit.balances, request.owner_address);

            if (owner_balance >= request.amount) {
                *table::borrow_mut(&mut token_deposit.balances, request.owner_address) = *table::borrow(&token_deposit.balances, request.owner_address)-request.amount;
            } else {
                *table::borrow_mut(&mut token_deposit.balances, request.owner_address) = 0;
            };
        
        };

    }

    fun check_base_market<T>(market: &mut QuoteMarket<T>, base_token_name: String) {
        if (!bag::contains_with_type<String, Orders>(&market.orders, base_token_name)) { 
            let new_orders_set = Orders { token_name: base_token_name, bid_orders: vector::empty<Order>(), ask_orders: vector::empty<Order>() };
            bag::add(&mut market.orders, base_token_name, new_orders_set);
        };
    }

    // ======== Test-related Functions =========

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }
}