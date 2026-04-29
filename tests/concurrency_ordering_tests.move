/// Tests for Concurrency / Ordering Edge Cases.
///
/// Sui shared objects are serialised by consensus — there is no true
/// parallel execution — but transaction ordering still creates edge cases:
///
///   1. Register → remove → re-register the identical geometry
///   2. Two callers attempting conflicting registrations (first writer wins)
///   3. Reshape / repartition blocked by a polygon registered after the
///      source polygon, then unblocked once that polygon is removed
///   4. Split → immediately merge the resulting children back together,
///      and split → merge one child with an external neighbour instead
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::concurrency_ordering_tests {
    use mercator::{index::{Self, ENotFound, EOverlap, Index}, mutations, polygon};
    use sui::test_scenario;

    const ADMIN: address = @0xCAFE;
    const USER: address = @0xBEEF;
    const SCALE: u64 = 1_000_000;

    // mutations error codes are private; mirror the values here and pin them to
    // the correct module via the `location` qualifier on expected_failure.
    const MUT_ENOTCONTAINED: u64 = 5001;
    const MUT_EOVERLAP: u64 = 5002;

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    fun test_index(ctx: &mut tx_context::TxContext): Index {
        index::with_config(SCALE, 6, 64, 10, 1024, 64, 2_000_000, ctx)
    }

    fun sq(
        idx: &mut Index,
        x0: u64,
        y0: u64,
        x1: u64,
        y1: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[vector[x0, x1, x1, x0]], vector[vector[y0, y0, y1, y1]], ctx)
    }

    /// Split `parent_id` (a 2 m × 2 m square at [0,2]×[0,2]) vertically at x = 1 m.
    /// Returns [left_id, right_id].
    fun split_two(
        idx: &mut Index,
        parent_id: object::ID,
        ctx: &mut tx_context::TxContext,
    ): vector<object::ID> {
        mutations::split_replace(
            idx,
            parent_id,
            vector[
                vector[vector[0u64, SCALE, SCALE, 0u64]], // left xs
                vector[vector[SCALE, 2*SCALE, 2*SCALE, SCALE]], // right xs
            ],
            vector[
                vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]], // left ys
                vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]], // right ys
            ],
            ctx,
        )
    }

    // ─── 1. Register → remove → re-register same geometry ────────────────────────

    #[test]
    /// After a polygon is removed the same coordinates can be registered again.
    fun reregister_same_geometry_succeeds_after_remove() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_first = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);

        index::remove(&mut idx, id_first, &mut ctx);
        assert!(index::count(&idx) == 0, 1);

        // The slot is now free — re-registration must succeed.
        let id_second = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 2);
        let _poly = index::get(&idx, id_second);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Re-registering identical geometry produces a fresh object ID — the index
    /// treats the two regions as independent objects, not an idempotent upsert.
    fun reregister_produces_distinct_id() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_first = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        index::remove(&mut idx, id_first, &mut ctx);
        let id_second = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        assert!(id_first != id_second, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = ENotFound)]
    /// The original ID is permanently invalid after remove; re-registration at
    /// the same coordinates does not resurrect the old object.
    fun original_id_invalid_after_remove_and_reregister() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_first = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        index::remove(&mut idx, id_first, &mut ctx);
        let _id_second = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        // id_first was deleted — looking it up must abort.
        index::get(&idx, id_first);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Multiple remove-and-reregister cycles remain consistent: each cycle yields
    /// a new polygon and leaves count == 1.
    fun repeated_remove_reregister_cycles_remain_consistent() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let mut prev_id = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let mut round = 0u64;
        while (round < 3) {
            index::remove(&mut idx, prev_id, &mut ctx);
            let next_id = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
            assert!(next_id != prev_id, round);
            assert!(index::count(&idx) == 1, round);
            prev_id = next_id;
            round = round + 1;
        };
        std::unit_test::destroy(idx);
    }

    // ─── 2. Two callers racing to register overlapping regions ────────────────────

    #[test]
    #[expected_failure(abort_code = EOverlap)]
    /// When two registrations for overlapping geometry are ordered by consensus,
    /// the first writer prevails and the second transaction is rejected.
    fun second_overlapping_registration_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _id_a = sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, &mut ctx);

        // Second writer tries [1,3]×[0,2] — partially overlaps A.  Must abort.
        let _id_b = sq(&mut idx, SCALE, 0, 3*SCALE, 2*SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOverlap)]
    /// The overlap check applies regardless of which address submits the
    /// conflicting registration — there is no "same user" exemption.
    fun different_user_overlapping_registration_is_rejected() {
        let mut scenario = test_scenario::begin(ADMIN);

        // ADMIN registers [0,2]×[0,2].
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, ctx);
            index::share_existing(idx);
        };

        // USER tries [1,3]×[0,2] in a later transaction — must abort.
        test_scenario::next_tx(&mut scenario, USER);
        {
            let mut idx = test_scenario::take_shared<Index>(&scenario);
            sq(&mut idx, SCALE, 0, 3*SCALE, 2*SCALE, test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(idx);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EOverlap)]
    /// Registering the exact same coordinates twice is treated as overlap.
    /// There is no idempotent "upsert" path — the caller must remove first.
    fun duplicate_registration_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx); // must abort
        std::unit_test::destroy(idx);
    }

    // ─── 3. Mutation during overlap check window ─────────────────────────────────

    // --- 3a. reshape_unclaimed ---

    #[test]
    #[expected_failure(abort_code = MUT_EOVERLAP, location = mercator::mutations)]
    /// reshape_unclaimed is blocked when a polygon registered *after* the source
    /// polygon occupies the expansion area.
    /// Ordering: A registers first, B registers later into adjacent space.
    /// A then tries to expand over B → rejected.
    fun reshape_blocked_by_later_registered_neighbour() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        // B arrives later and claims [2,3]×[0,1].
        let _id_b = sq(&mut idx, 2*SCALE, 0, 3*SCALE, SCALE, &mut ctx);

        // A tries to expand to [0,3]×[0,1] — now blocked by B.
        mutations::reshape_unclaimed(
            &mut idx,
            id_a,
            vector[vector[0u64, 3*SCALE, 3*SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    /// The same reshape succeeds once the blocking polygon is removed.
    /// A failed mutation leaves no residual state — the index is unchanged.
    fun reshape_succeeds_after_blocker_removed() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = sq(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let id_b = sq(&mut idx, 2*SCALE, 0, 3*SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        index::remove(&mut idx, id_b, &mut ctx);
        assert!(index::count(&idx) == 1, 1);

        // Expansion into now-free territory must succeed.
        mutations::reshape_unclaimed(
            &mut idx,
            id_a,
            vector[vector[0u64, 3*SCALE, 3*SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 1, 2);
        std::unit_test::destroy(idx);
    }

    // --- 3b. repartition_adjacent ---
    //
    // Geometry setup
    // ─────────────────────────────────────────────────────────────────────────────
    //  Old A = [0,2]×[0,2] (4 m²)    Old B = [2,4]×[0,2] (4 m²)
    //  Adjacent at edge x = 2 m, y ∈ [0,2].
    //
    //  C = [0,2]×[2,4] (4 m²) — adjacent to A at edge y = 2, registered first.
    //
    //  Repartition attempt (area-conserving: 4 + 4 = 4 + 4):
    //    New A = [0,2]×[0,2] (4 m², unchanged)
    //    New B = [0,4]×[2,3] (4 m²) — pivots up into C's territory
    //
    //  New A and new B share edge y=2 at x∈[0,2] (edge contact, not overlap).
    //  New B overlaps C at [0,2]×[2,3] → EOverlap (5002, from mutations).
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    #[expected_failure(abort_code = MUT_ENOTCONTAINED, location = mercator::mutations)]
    /// repartition_adjacent is blocked when the new geometry escapes the union
    /// AABB of the original pair — the containment guard fires before the
    /// third-party overlap check.
    fun repartition_blocked_by_third_polygon_in_target_area() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, &mut ctx);
        let id_b = sq(&mut idx, 2*SCALE, 0, 4*SCALE, 2*SCALE, &mut ctx);
        let _id_c = sq(&mut idx, 0, 2*SCALE, 2*SCALE, 4*SCALE, &mut ctx);
        assert!(index::count(&idx) == 3, 0); // ensures third-party check runs

        // New A stays put; new B pivots into the top strip — into C's territory.
        mutations::repartition_adjacent(
            &mut idx,
            id_a,
            vector[vector[0u64, 2*SCALE, 2*SCALE, 0u64]], // new A xs
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]], // new A ys
            id_b,
            vector[vector[0u64, 4*SCALE, 4*SCALE, 0u64]], // new B xs
            vector[vector[2*SCALE, 2*SCALE, 3*SCALE, 3*SCALE]], // new B ys
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = MUT_ENOTCONTAINED, location = mercator::mutations)]
    /// After removing C, the same teleportation is STILL blocked.
    /// The union-AABB containment guard prevents output geometry from escaping
    /// the original bounding box regardless of how many polygons exist.
    /// (Before the [MUT-07] fix, this would have succeeded with count == 2.)
    fun repartition_teleportation_blocked_even_after_blocker_removed() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, &mut ctx);
        let id_b = sq(&mut idx, 2*SCALE, 0, 4*SCALE, 2*SCALE, &mut ctx);
        let id_c = sq(&mut idx, 0, 2*SCALE, 2*SCALE, 4*SCALE, &mut ctx);

        // Remove the blocker — but containment guard still fires.
        index::remove(&mut idx, id_c, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        // New B = [0,4]×[2,3] extends beyond union AABB [0,4]×[0,2] → ENotContained
        mutations::repartition_adjacent(
            &mut idx,
            id_a,
            vector[vector[0u64, 2*SCALE, 2*SCALE, 0u64]],
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]],
            id_b,
            vector[vector[0u64, 4*SCALE, 4*SCALE, 0u64]],
            vector[vector[2*SCALE, 2*SCALE, 3*SCALE, 3*SCALE]],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    /// With three polygons, repartition that stays within the existing union
    /// area is still accepted — the third-party check only blocks actual overlap.
    fun repartition_with_third_polygon_present_but_not_overlapping() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, &mut ctx);
        let id_b = sq(&mut idx, 2*SCALE, 0, 4*SCALE, 2*SCALE, &mut ctx);
        // C is well away from the repartitioned area.
        let _id_c = sq(&mut idx, 5*SCALE, 0, 6*SCALE, 2*SCALE, &mut ctx);
        assert!(index::count(&idx) == 3, 0);

        // Move the shared boundary from x=2 to x=3, staying inside [0,4]×[0,2].
        mutations::repartition_adjacent(
            &mut idx,
            id_a,
            vector[vector[0u64, 3*SCALE, 3*SCALE, 0u64]],
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]],
            id_b,
            vector[vector[3*SCALE, 4*SCALE, 4*SCALE, 3*SCALE]],
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]],
            &ctx,
        );

        assert!(index::count(&idx) == 3, 1);
        std::unit_test::destroy(idx);
    }

    // ─── 4. Split → immediately merge the resulting children ─────────────────────

    #[test]
    /// Splitting a polygon and immediately merging the two halves back together
    /// restores the original area; the net count is unchanged.
    fun split_then_merge_siblings_restores_parent_area() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, &mut ctx);
        let parent_area = polygon::area(index::get(&idx, parent_id));
        assert!(index::count(&idx) == 1, 0);

        // Split into left [0,1]×[0,2] and right [1,2]×[0,2].
        let child_ids = split_two(&mut idx, parent_id, &mut ctx);
        assert!(index::count(&idx) == 2, 1);
        let left_id = *vector::borrow(&child_ids, 0);
        let right_id = *vector::borrow(&child_ids, 1);

        // Merge them back immediately.
        mutations::merge_keep(
            &mut idx,
            left_id,
            right_id,
            vector[vector[0u64, 2*SCALE, 2*SCALE, 0u64]],
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]],
            &ctx,
        );

        // One polygon survives with area equal to the original parent.
        assert!(index::count(&idx) == 1, 2);
        assert!(polygon::area(index::get(&idx, left_id)) == parent_area, 3);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = ENotFound)]
    /// After split + merge the absorbed sibling's ID is gone from the index.
    fun merged_sibling_id_is_invalid_after_merge() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, &mut ctx);
        let child_ids = split_two(&mut idx, parent_id, &mut ctx);
        let left_id = *vector::borrow(&child_ids, 0);
        let right_id = *vector::borrow(&child_ids, 1);

        mutations::merge_keep(
            &mut idx,
            left_id,
            right_id,
            vector[vector[0u64, 2*SCALE, 2*SCALE, 0u64]],
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]],
            &ctx,
        );

        // right_id was absorbed — looking it up must abort.
        index::get(&idx, right_id);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Split a polygon, then merge one child with an *external* neighbour rather
    /// than its sibling.  The untouched sibling is unaffected.
    fun split_then_merge_one_child_with_external_neighbour() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let neighbour_id = sq(&mut idx, 2*SCALE, 0, 3*SCALE, 2*SCALE, &mut ctx);

        // Parent: [0,2]×[0,2].
        let parent_id = sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, &mut ctx);

        // Split parent → left [0,1]×[0,2] and right [1,2]×[0,2].
        let child_ids = split_two(&mut idx, parent_id, &mut ctx);
        assert!(index::count(&idx) == 3, 0);
        let left_id = *vector::borrow(&child_ids, 0);
        let right_id = *vector::borrow(&child_ids, 1);

        // right [1,2]×[0,2] is adjacent to neighbour [2,3]×[0,2].
        // Merge right + neighbour → [1,3]×[0,2].
        mutations::merge_keep(
            &mut idx,
            right_id,
            neighbour_id,
            vector[vector[SCALE, 3*SCALE, 3*SCALE, SCALE]],
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]],
            &ctx,
        );

        // Two polygons remain: left (untouched) and the merged right.
        assert!(index::count(&idx) == 2, 1);

        // Untouched sibling retains its original 1 m × 2 m shape.
        assert!(polygon::area(index::get(&idx, left_id)) == 2, 2);

        // Merged polygon spans [1,3]×[0,2] → area == 4.
        assert!(polygon::area(index::get(&idx, right_id)) == 4, 3);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Two sequential split→merge roundtrips leave the index in the same state
    /// as the original single polygon.
    fun split_then_two_sequential_merge_roundtrips() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = sq(&mut idx, 0, 0, 2*SCALE, 2*SCALE, &mut ctx);
        let original_area = polygon::area(index::get(&idx, parent_id));

        // First split → merge cycle.
        let ids1 = split_two(&mut idx, parent_id, &mut ctx);
        let (l1, r1) = (*vector::borrow(&ids1, 0), *vector::borrow(&ids1, 1));
        mutations::merge_keep(
            &mut idx,
            l1,
            r1,
            vector[vector[0u64, 2*SCALE, 2*SCALE, 0u64]],
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 1, 0);
        assert!(polygon::area(index::get(&idx, l1)) == original_area, 1);

        // Second split → merge cycle on the merged result.
        let ids2 = split_two(&mut idx, l1, &mut ctx);
        let (l2, r2) = (*vector::borrow(&ids2, 0), *vector::borrow(&ids2, 1));
        mutations::merge_keep(
            &mut idx,
            l2,
            r2,
            vector[vector[0u64, 2*SCALE, 2*SCALE, 0u64]],
            vector[vector[0u64, 0u64, 2*SCALE, 2*SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 1, 2);
        assert!(polygon::area(index::get(&idx, l2)) == original_area, 3);
        std::unit_test::destroy(idx);
    }
}
