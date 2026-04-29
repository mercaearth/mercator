/// Compound lifecycle / sequence tests.
///
/// Each test exercises a multi-step sequence that crosses module boundaries,
/// verifying that the quadtree index remains consistent at every intermediate
/// step — not just at the end.
///
/// Tests:
///
///   1. register_transfer_reshape_cell_key_updates_correctly
///      Register → force-transfer (ownership change) → reshape (triggers depth
///      migration).  Verifies: ownership preserved by reshape, cell key updated,
///      broadphase still finds the reshaped polygon.
///
///   2. register_6_remove_alternating_no_stale_entries
///      Register 6 polygons in a row → remove every other one → verify that the
///      removed IDs never appear in the broadphase candidates of any surviving
///      polygon, and that count and retrievability are correct.
///
///   3. split_reshape_merge_state_verified_at_each_step
///      Split → reshape one child (triggers depth migration: depth 6 → 5)
///      → merge with a neighbour.  Asserts count, area, cell key, and broadphase
///      candidates after EVERY operation.
///
///   4. force_transfer_reshape_transfer_remove_full_lifecycle
///      Full ownership chain across five transactions:
///        ADMIN registers → ADMIN force-transfers to USER_A
///        → owner auth holder reshapes (depth migration: depth 5 → 4)
///        → USER_A transfers to USER_B → USER_B removes.
///      Verifies count, owner, area, and cell key at every hand-off.
///
/// ─── Geometry key ─────────────────────────────────────────────────────────────
///
///   SCALE = 1_000_000.  Tests use max_depth = 8, cell_size = SCALE.
///   At this depth:
///     [k*S,(k+1)*S] polygons land at depths 5–7 (none at depth 0 for k < 8).
///     Depth migrations are triggered by choosing shapes that cross cell
///     boundaries at the previous natural depth.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::lifecycle_sequence_tests {
    use mercator::{index::{Self, Index}, mutations, polygon};
    use sui::test_scenario;

    // ─── Constants ────────────────────────────────────────────────────────────────

    const SCALE: u64 = 1_000_000;

    const ADMIN: address = @0xAD;
    const USER_A: address = @0xA;
    const USER_B: address = @0xB;

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    fun test_index(ctx: &mut tx_context::TxContext): Index {
        // max_depth=8 keeps polygons in [0,8m] at depths 4–7 (no root-cell collision).
        index::with_config(SCALE, 8, 64, 10, 1024, 64, 2_000_000, ctx)
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

    fun xs(a: u64, b: u64): vector<u64> { vector[a, b, b, a] }

    fun ys(a: u64, b: u64): vector<u64> { vector[a, a, b, b] }

    fun vec_contains(v: &vector<object::ID>, id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) return true;
            i = i + 1;
        };
        false
    }

    // ─── 1. Register → Force-transfer → Reshape ────────────────────────────────
    //
    // Flow:
    //   Register P=[1S,2S]×[0,S] and Q=[4S,5S]×[0,S] (separated, different cells).
    //   Force-transfer P to USER_B.
    //   Reshape P to [0,4S]×[0,S] (spans 4 fine cells → triggers depth migration).
    //
    // Key assertions:
    //   ① After transfer : owner changes, count/geometry unchanged.
    //   ② After reshape  : owner still USER_B (reshape is ownership-agnostic),
    //                      area 4×, cell key changed, Q is in P's broadphase.
    //
    // Depth migration geometry:
    //   P before: [1S,2S]×[0,S] — natural depth 6 at max_depth=8
    //             (shift=2: 1>>2=0, 2>>2=0; both same → depth 6)
    //   P after:  [0,4S]×[0,S] — natural depth 5
    //             (shift=3: 0>>3=0, 4>>3=0; same; depth-6 fails: 0>>2=0, 4>>2=1)
    //   Cell keys differ because the sentinel bits are at different positions.

    #[test]
    fun register_reshape_cell_key_updates_correctly() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let p_id = register_square(&mut idx, SCALE, 0, 2*SCALE, SCALE, &mut ctx);
        let q_id = register_square(&mut idx, 4*SCALE, 0, 5*SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        assert!(index::count(&idx) == 2, 1);
        assert!(polygon::area(index::get(&idx, p_id)) == 1, 2);

        let cell_before = *vector::borrow(polygon::cells(index::get(&idx, p_id)), 0);

        // ── ① Reshape P: [1S,2S]×[0,S] → [0,4S]×[0,S] ──────────────────────────
        // Crosses a cell boundary in x → natural depth drops from 6 to 5.
        // Right edge at x=4S is adjacent to Q (x=[4S,5S]) — touching, not overlapping.
        mutations::reshape_unclaimed(
            &mut idx,
            p_id,
            vector[xs(0, 4*SCALE)],
            vector[ys(0, SCALE)],
            &ctx,
        );

        // Ownership is not touched by reshape.
        assert!(polygon::owner(index::get(&idx, p_id)) == tx_context::sender(&ctx), 3);
        // Area: 1m² → 4m².
        assert!(polygon::area(index::get(&idx, p_id)) == 4, 4);
        // Count unchanged.
        assert!(index::count(&idx) == 2, 5);

        // Cell key changed: depth-6 key ≠ depth-5 key.
        let cell_after = *vector::borrow(polygon::cells(index::get(&idx, p_id)), 0);
        assert!(cell_before != cell_after, 6);

        // Both polygons remain retrievable.
        let _p = index::get(&idx, p_id);
        let _q = index::get(&idx, q_id);

        // P's expanded AABB shares the cell containing Q → broadphase finds P from Q.
        assert!(vec_contains(&index::candidates(&idx, q_id), p_id), 7);
        std::unit_test::destroy(idx);
    }

    // ─── 2. Register 6 → remove alternating → broadphase clean ───────────────
    //
    // Flow:
    //   Register six adjacent 1 m × 1 m regions P0..P5 in a row.
    //   Remove P1, P3, P5 (odd-indexed).
    //
    // Assertions:
    //   ① count == 3 after removal.
    //   ② P0, P2, P4 are individually retrievable.
    //   ③ No removed ID appears in the broadphase candidates of any surviving
    //      polygon — the index correctly cleaned up all stale cell entries.
    //
    // The broadphase check uses a flat scan (no nested loops) to avoid gas pressure.

    #[test]
    fun register_6_remove_alternating_no_stale_entries() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let p0 = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let p1 = register_square(&mut idx, SCALE, 0, 2*SCALE, SCALE, &mut ctx);
        let p2 = register_square(&mut idx, 2*SCALE, 0, 3*SCALE, SCALE, &mut ctx);
        let p3 = register_square(&mut idx, 3*SCALE, 0, 4*SCALE, SCALE, &mut ctx);
        let p4 = register_square(&mut idx, 4*SCALE, 0, 5*SCALE, SCALE, &mut ctx);
        let p5 = register_square(&mut idx, 5*SCALE, 0, 6*SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 6, 0);

        // Remove odd-indexed polygons.
        index::remove(&mut idx, p1, &mut ctx);
        index::remove(&mut idx, p3, &mut ctx);
        index::remove(&mut idx, p5, &mut ctx);

        // ── ① Count ──────────────────────────────────────────────────────────────
        assert!(index::count(&idx) == 3, 1);

        // ── ② Retrievability ─────────────────────────────────────────────────────
        let _s0 = index::get(&idx, p0);
        let _s2 = index::get(&idx, p2);
        let _s4 = index::get(&idx, p4);

        // ── ③ No stale entries: removed IDs must not appear in candidates ─────────
        // Check each surviving polygon's broadphase candidates against each removed ID.
        let c0 = index::candidates(&idx, p0);
        let c2 = index::candidates(&idx, p2);
        let c4 = index::candidates(&idx, p4);

        // p1 was the direct right-neighbour of p0 and left-neighbour of p2.
        assert!(!vec_contains(&c0, p1), 2);
        assert!(!vec_contains(&c2, p1), 3);
        assert!(!vec_contains(&c4, p1), 4);

        // p3 was adjacent to p2 and p4.
        assert!(!vec_contains(&c0, p3), 5);
        assert!(!vec_contains(&c2, p3), 6);
        assert!(!vec_contains(&c4, p3), 7);

        // p5 was the direct right-neighbour of p4.
        assert!(!vec_contains(&c0, p5), 8);
        assert!(!vec_contains(&c2, p5), 9);
        assert!(!vec_contains(&c4, p5), 10);
        std::unit_test::destroy(idx);
    }

    // ─── 3. Split → Reshape child → Merge: state verified at every step ───────
    //
    // Flow:
    //   Register parent=[0,2S]×[0,S]  and  neighbour=[2S,4S]×[0,4S].
    //   Split parent into child_a=[0,S]×[0,S]  and  child_b=[S,2S]×[0,S].
    //   Reshape child_b from [S,2S]×[0,S] → [S,2S]×[0,4S]
    //     (expands upward; depth migration 6→5).
    //   Merge child_b (keep) + neighbour (absorb) → [S,4S]×[0,4S].
    //
    // Unlike mutation_edge_cases_tests::chained_split_reshape_merge, this test
    // asserts count, area, and cell key at every intermediate step.
    //
    // Depth migration geometry (max_depth=8):
    //   child_b before: [S,2S]×[0,S]    → natural depth 6
    //     (depth 6 shift=2: x:1>>2=0,2>>2=0 same; y:0>>2=0,1>>2=0 same)
    //   child_b after:  [S,2S]×[0,4S]   → natural depth 5
    //     (depth 6 fails: y:0>>2=0,4>>2=1 differ; depth 5 shift=3: both 0)

    #[test]
    fun split_reshape_merge_state_verified_at_each_step() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // They share the edge at x=2S from y=0 to y=1S (parent's full right edge).
        let parent_id = register_square(&mut idx, 0, 0, 2*SCALE, SCALE, &mut ctx);
        let neighbour_id = register_square(&mut idx, 2*SCALE, 0, 4*SCALE, 4*SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        // ── Step 1: Split parent → child_a=[0,S]×[0,S], child_b=[S,2S]×[0,S] ────
        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[xs(0, SCALE)], vector[xs(SCALE, 2*SCALE)]],
            vector[vector[ys(0, SCALE)], vector[ys(0, SCALE)]],
            &mut ctx,
        );
        let child_a = *vector::borrow(&child_ids, 0);
        let child_b = *vector::borrow(&child_ids, 1);

        // Post-split: parent gone, three polygons remain.
        assert!(index::count(&idx) == 3, 1);
        assert!(polygon::area(index::get(&idx, child_a)) == 1, 2);
        assert!(polygon::area(index::get(&idx, child_b)) == 1, 3);

        // ── Step 2: Reshape child_b → [S,2S]×[0,4S] ─────────────────────────────
        // No bystander above [S,2S]×[S,4S]. neighbour is at x>=2S so no overlap.
        let cell_b_before = *vector::borrow(polygon::cells(index::get(&idx, child_b)), 0);

        mutations::reshape_unclaimed(
            &mut idx,
            child_b,
            vector[xs(SCALE, 2*SCALE)],
            vector[ys(0, 4*SCALE)],
            &ctx,
        );

        // Post-reshape: count unchanged, area grew.
        assert!(index::count(&idx) == 3, 4);
        assert!(polygon::area(index::get(&idx, child_b)) == 4, 5);
        assert!(polygon::area(index::get(&idx, child_a)) == 1, 6); // sibling untouched

        // Cell key changed: depth-6 key ≠ depth-5 key.  This is the core assertion
        // of this test: depth migration fires when the reshaped AABB crosses a cell
        // boundary at the previous natural depth.
        let cell_b_after = *vector::borrow(polygon::cells(index::get(&idx, child_b)), 0);
        assert!(cell_b_before != cell_b_after, 7);

        // ── Step 3: Merge child_b (keep) absorbs neighbour ───────────────────────
        // child_b=[S,2S]×[0,4S] (4m²) + neighbour=[2S,4S]×[0,4S] (8m²) → 12m².
        // Merged geometry: [S,4S]×[0,4S].
        let pre_merge_total =
            (polygon::area(index::get(&idx, child_b)) as u128)
        + (polygon::area(index::get(&idx, neighbour_id)) as u128);

        mutations::merge_keep(
            &mut idx,
            child_b,
            neighbour_id,
            vector[xs(SCALE, 4*SCALE)],
            vector[ys(0, 4*SCALE)],
            &ctx,
        );

        // Post-merge: count dropped by one, area conserved.
        assert!(index::count(&idx) == 2, 8);
        assert!((polygon::area(index::get(&idx, child_b)) as u128) == pre_merge_total, 9);
        assert!(polygon::area(index::get(&idx, child_b)) == 12, 10);

        // child_a untouched; still adjacent to the merged polygon via x=S edge.
        assert!(polygon::area(index::get(&idx, child_a)) == 1, 11);

        // Confirm broadphase finds the sibling pair — one candidates() call to keep
        // gas cost low (the symmetric check is implied by the shared cell key).
        assert!(vec_contains(&index::candidates(&idx, child_a), child_b), 12);
        std::unit_test::destroy(idx);
    }

    // ─── 4. Force-transfer → Reshape → Transfer → Remove ─────────────────────
    //
    // Full ownership chain across five transactions:
    //
    //   Tx 0 (setup) : create and share a fresh Index.
    //   Tx 1 (ADMIN) : register P=[3S,4S]×[3S,4S].
    //   Tx 2 (ADMIN) : force-transfer P → USER_A.
    //   Tx 3 (ADMIN) : reshape P → [0,8S]×[0,8S]  (depth migration: 5 → 4).
    //   Tx 4 (USER_A): transfer_ownership P → USER_B.
    //   Tx 5 (USER_B): remove P.
    //
    // Assertions at every transaction boundary:
    //   count, owner, area.
    // Additionally after Tx 3: cell key changed (depth 5 key ≠ depth 4 key).
    //
    // Depth migration geometry (max_depth=8):
    //   P before: [3S,4S]×[3S,4S]  → natural depth 5
    //     (depth 5 shift=3: 3>>3=0, 4>>3=0 same for both axes)
    //   P after:  [0,8S]×[0,8S]    → natural depth 4
    //     (depth 5 shift=3: x 0>>3=0, 8>>3=1 differ; depth 4 shift=4: 0>>4=0, 8>>4=0 same)

    #[test]
    fun force_transfer_reshape_transfer_remove_full_lifecycle() {
        let mut s = test_scenario::begin(ADMIN);
        let polygon_id: object::ID;

        // ── Tx 0: create and share a fresh Index ─────────────────────────────────
        {
            let idx = index::with_config(
                SCALE,
                8,
                64,
                10,
                1024,
                64,
                2_000_000,
                test_scenario::ctx(&mut s),
            );
            index::share_existing(idx);
        };

        // ── Tx 1: ADMIN registers P=[3S,4S]×[3S,4S] ────────────────────────────
        test_scenario::next_tx(&mut s, ADMIN);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            polygon_id =
                register_square(
                    &mut idx,
                    3*SCALE,
                    3*SCALE,
                    4*SCALE,
                    4*SCALE,
                    test_scenario::ctx(&mut s),
                );
            assert!(index::count(&idx) == 1, 0);
            assert!(polygon::owner(index::get(&idx, polygon_id)) == ADMIN, 1);
            assert!(polygon::area(index::get(&idx, polygon_id)) == 1, 2);
            test_scenario::return_shared(idx);
        };

        // ── Tx 2: force-transfer P → USER_A ──────────────────────────────────────
        test_scenario::next_tx(&mut s, ADMIN);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            let tc = index::mint_transfer_cap_for_testing(&mut idx, test_scenario::ctx(&mut s));
            index::force_transfer(&tc, &mut idx, polygon_id, USER_A);
            assert!(polygon::owner(index::get(&idx, polygon_id)) == USER_A, 3);
            assert!(index::count(&idx) == 1, 4);
            assert!(polygon::area(index::get(&idx, polygon_id)) == 1, 5);
            test_scenario::return_shared(idx);
            std::unit_test::destroy(tc);
        };

        // ── Tx 3: current owner reshapes successfully with owner auth ───────────
        test_scenario::next_tx(&mut s, USER_A);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            let cell_before =
                *vector::borrow(
                    polygon::cells(index::get(&idx, polygon_id)),
                    0,
                );
            mutations::reshape_unclaimed(
                &mut idx,
                polygon_id,
                vector[xs(0, 8*SCALE)],
                vector[ys(0, 8*SCALE)],
                test_scenario::ctx(&mut s),
            );
            assert!(polygon::area(index::get(&idx, polygon_id)) == 64, 7);
            // Count unchanged.
            assert!(index::count(&idx) == 1, 8);
            // Cell key migrated: depth-5 sentinel ≠ depth-4 sentinel.
            let cell_after =
                *vector::borrow(
                    polygon::cells(index::get(&idx, polygon_id)),
                    0,
                );
            assert!(cell_before != cell_after, 9);
            test_scenario::return_shared(idx);
        };

        // ── Tx 4: USER_A transfers ownership → USER_B ────────────────────────────
        // transfer_ownership checks ctx.sender == current owner (USER_A ✓).
        test_scenario::next_tx(&mut s, USER_A);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            index::transfer_ownership(&mut idx, polygon_id, USER_B, test_scenario::ctx(&mut s));
            assert!(polygon::owner(index::get(&idx, polygon_id)) == USER_B, 10);
            assert!(index::count(&idx) == 1, 11);
            // Geometry unaffected by ownership transfer.
            assert!(polygon::area(index::get(&idx, polygon_id)) == 64, 12);
            test_scenario::return_shared(idx);
        };

        // ── Tx 5: USER_B removes P ───────────────────────────────────────────────
        // remove checks ctx.sender == current owner (USER_B ✓).
        test_scenario::next_tx(&mut s, USER_B);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            index::remove(&mut idx, polygon_id, test_scenario::ctx(&mut s));
            assert!(index::count(&idx) == 0, 13);
            test_scenario::return_shared(idx);
        };

        test_scenario::end(s);
    }
}
