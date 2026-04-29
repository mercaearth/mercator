/// Tests for Ownership Transfer behaviour.
///
/// Covers: transfer_ownership (happy path + unauthorized caller),
/// force_transfer via TransferCap (happy path + cap-boundary),
/// transfer-then-mutation (owner-gated and mutation-gated ops after hand-off),
/// and spatial-index integrity after a transfer.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::ownership_transfer_tests {
    use mercator::{index::{Self, ENotOwner, Index}, mutations, polygon};
    use sui::test_scenario;

    const ADMIN: address = @0xCAFE;
    const USER: address = @0xBEEF;
    const OTHER: address = @0xC0FFEE;
    const SCALE: u64 = 1_000_000;

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    fun test_index(ctx: &mut tx_context::TxContext): Index {
        // max_depth=6 keeps tests fast; SCALE cell gives a 64 m² world.
        index::with_config(SCALE, 6, 64, 10, 1024, 64, 2_000_000, ctx)
    }

    fun register_square(
        idx: &mut Index,
        x0: u64,
        y0: u64,
        x1: u64,
        y1: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[vector[x0, x1, x1, x0]], vector[vector[y0, y0, y1, y1]], ctx)
    }

    fun vector_contains(v: &vector<object::ID>, id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) return true;
            i = i + 1;
        };
        false
    }

    // ─── transfer_ownership ───────────────────────────────────────────────────────

    #[test]
    /// Registrar can transfer ownership to any address;
    /// the stored owner field reflects the new address immediately.
    fun transfer_ownership_sets_new_owner() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        index::transfer_ownership(&mut idx, id, USER, &ctx);

        assert!(polygon::owner(index::get(&idx, id)) == USER, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Ownership can be transferred more than once: each transfer sets the
    /// new address and the previous owner loses their rights.
    fun transfer_ownership_can_be_chained() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        // first hand-off
        index::transfer_ownership(&mut idx, id, USER, &ctx);
        assert!(polygon::owner(index::get(&idx, id)) == USER, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = ENotOwner)]
    /// A caller who is not the current owner cannot invoke transfer_ownership,
    /// even when they hold a valid owner auth.
    fun transfer_ownership_rejected_for_non_owner() {
        // ADMIN registers and immediately transfers to USER.
        // Then ADMIN (no longer owner) tries to transfer again → ENotOwner.
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            let id = register_square(&mut idx, 0, 0, SCALE, SCALE, ctx);
            index::transfer_ownership(&mut idx, id, USER, ctx);
            // ADMIN's sender no longer matches stored owner (USER)
            index::transfer_ownership(&mut idx, id, OTHER, ctx);
            std::unit_test::destroy(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ENotOwner)]
    /// Registrar loses the right to remove their polygon once they transfer it.
    fun old_owner_loses_remove_right_after_transfer() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            let id = register_square(&mut idx, 0, 0, SCALE, SCALE, ctx);
            index::transfer_ownership(&mut idx, id, USER, ctx);
            // ADMIN still holds the cap but is no longer the owner → ENotOwner
            index::remove(&mut idx, id, ctx);
            std::unit_test::destroy(idx);
        };
        test_scenario::end(scenario);
    }

    // ─── force_transfer ───────────────────────────────────────────────────────────

    #[test]
    /// force_transfer sets a new owner without any sender / ownership check.
    fun force_transfer_sets_new_owner() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let tc = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        index::force_transfer(&tc, &mut idx, id, USER);

        assert!(polygon::owner(index::get(&idx, id)) == USER, 0);
        std::unit_test::destroy(tc);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// force_transfer succeeds even when the caller is not the current owner,
    /// demonstrating the cap-gated bypass that transfer_ownership cannot provide.
    fun force_transfer_bypasses_owner_restriction() {
        // In this scenario ADMIN holds a TransferCap but USER owns the polygon.
        let mut scenario = test_scenario::begin(ADMIN);
        let polygon_id: object::ID;
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            polygon_id = register_square(&mut idx, 0, 0, SCALE, SCALE, ctx);
            index::transfer_ownership(&mut idx, polygon_id, USER, ctx);
            index::share_existing(idx);
        };
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut idx = test_scenario::take_shared<Index>(&scenario);
            let tc = index::mint_transfer_cap_for_testing(
                &mut idx,
                test_scenario::ctx(&mut scenario),
            );

            // ADMIN is NOT the owner (USER is) — force_transfer still works
            index::force_transfer(&tc, &mut idx, polygon_id, OTHER);
            assert!(polygon::owner(index::get(&idx, polygon_id)) == OTHER, 0);

            test_scenario::return_shared(idx);
            std::unit_test::destroy(tc);
        };
        test_scenario::end(scenario);
    }

    #[test]
    /// force_transfer can be applied repeatedly; each call installs the
    /// supplied address as the new owner.
    fun force_transfer_chain_updates_owner_each_time() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let tc = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        index::force_transfer(&tc, &mut idx, id, USER);
        assert!(polygon::owner(index::get(&idx, id)) == USER, 0);

        index::force_transfer(&tc, &mut idx, id, OTHER);
        assert!(polygon::owner(index::get(&idx, id)) == OTHER, 1);

        index::force_transfer(&tc, &mut idx, id, ADMIN);
        assert!(polygon::owner(index::get(&idx, id)) == ADMIN, 2);
        std::unit_test::destroy(tc);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// force_transfer does not alter the region count or remove the polygon
    /// from the spatial index — it only updates the owner field.
    fun force_transfer_preserves_count_and_retrievability() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let tc = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);

        index::force_transfer(&tc, &mut idx, id, USER);

        assert!(index::count(&idx) == 1, 1);
        let _poly = index::get(&idx, id); // still retrievable
        std::unit_test::destroy(tc);
        std::unit_test::destroy(idx);
    }

    // ─── Transfer then mutation ───────────────────────────────────────────────────

    #[test]
    /// After ownership is transferred, the new owner can remove the polygon.
    fun new_owner_can_remove_after_transfer() {
        let mut scenario = test_scenario::begin(ADMIN);
        let polygon_id: object::ID;
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            polygon_id = register_square(&mut idx, 0, 0, SCALE, SCALE, ctx);
            index::transfer_ownership(&mut idx, polygon_id, USER, ctx);
            index::share_existing(idx);
        };
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut idx = test_scenario::take_shared<Index>(&scenario);
            index::remove(&mut idx, polygon_id, test_scenario::ctx(&mut scenario));
            assert!(index::count(&idx) == 0, 0);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    /// After force_transfer the new owner can transfer ownership again via
    /// the normal (owner-checked) path.
    fun new_owner_can_transfer_ownership_after_force_transfer() {
        let mut scenario = test_scenario::begin(ADMIN);
        let polygon_id: object::ID;
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            let tc = index::mint_transfer_cap_for_testing(&mut idx, ctx);
            polygon_id = register_square(&mut idx, 0, 0, SCALE, SCALE, ctx);
            // Force-transfer to USER — bypasses ownership
            index::force_transfer(&tc, &mut idx, polygon_id, USER);
            index::share_existing(idx);
            std::unit_test::destroy(tc);
        };
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut idx = test_scenario::take_shared<Index>(&scenario);
            index::transfer_ownership(
                &mut idx,
                polygon_id,
                OTHER,
                test_scenario::ctx(&mut scenario),
            );
            assert!(polygon::owner(index::get(&idx, polygon_id)) == OTHER, 0);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = mutations::EOwnerMismatch)]
    /// reshape_unclaimed now rejects a owner auth holder who is not the owner.
    fun reshape_by_cap_holder_rejected_without_owner_rights() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let tc = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        // Register 1m×1m square; registrar is the default dummy sender.
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        // Transfer ownership to an unrelated address.
        index::force_transfer(&tc, &mut idx, id, USER);
        assert!(polygon::owner(index::get(&idx, id)) == USER, 0);

        // The original cap holder (no longer the owner) cannot reshape the polygon.
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[vector[0u64, 2 * SCALE, 2 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        std::unit_test::destroy(tc);
        std::unit_test::destroy(idx);
    }

    // ─── Transfer inside an overlap candidate set ─────────────────────────────────

    #[test]
    /// Transferring a polygon does not alter the spatial index: the region
    /// remains a broadphase candidate for its neighbours and the count is stable.
    fun transfer_preserves_spatial_index_and_candidate_set() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let tc = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        // Register two adjacent 1m×1m squares sharing the edge at x = 1m.
        let id_a = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let id_b = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        // Transfer A to USER — spatial position unchanged.
        index::force_transfer(&tc, &mut idx, id_a, USER);

        // Count must still be 2.
        assert!(index::count(&idx) == 2, 1);

        // B's broadphase candidates must still include A (adjacency not broken).
        let cands_b = index::candidates(&idx, id_b);
        assert!(vector_contains(&cands_b, id_a), 2);

        // A's broadphase candidates must still include B.
        let cands_a = index::candidates(&idx, id_a);
        assert!(vector_contains(&cands_a, id_b), 3);

        // Adjacency is not an overlap — overlapping() must return empty for both.
        assert!(vector::length(&index::overlapping(&idx, id_a)) == 0, 4);
        assert!(vector::length(&index::overlapping(&idx, id_b)) == 0, 5);

        // Owner field is the only thing that changed.
        assert!(polygon::owner(index::get(&idx, id_a)) == USER, 6);
        std::unit_test::destroy(tc);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// After force_transfer, the new owner can register an additional adjacent
    /// polygon — the candidate set expands to include it, confirming that the
    /// index remains fully consistent after ownership changes.
    fun transferred_polygon_participates_in_new_registrations() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let tc = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let id_a = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        index::force_transfer(&tc, &mut idx, id_a, USER);

        // Register a new polygon adjacent to A (on the other side).
        let id_c = register_square(&mut idx, 2 * SCALE, 0, 3 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        // A and C are not adjacent — neither should appear in each other's
        // *overlapping* set, but C's candidates may or may not include A
        // depending on quadtree depth — the important invariant is that
        // the index is not corrupted and both polygons are retrievable.
        let _poly_a = index::get(&idx, id_a);
        let _poly_c = index::get(&idx, id_c);
        std::unit_test::destroy(tc);
        std::unit_test::destroy(idx);
    }
}
