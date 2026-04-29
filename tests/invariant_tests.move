/// Invariant tests: properties that must hold across any valid sequence of
/// index operations and region mutations.
///
/// Four invariants are verified here:
///
///   1. Count — index::count() equals the number of registered polygons minus
///      the number removed at every step, including through reshape,
///      repartition, split, and merge.
///
///   2. Area conservation — structure-preserving mutations (repartition, split,
///      merge) leave the total area of all polygons in the index unchanged.
///      reshape_unclaimed expands area by design; its count and retrievability
///      invariants are verified instead.
///
///   3. No-teleportation and no-overlap enforcement — repartition_adjacent
///      enforces union-AABB containment (outputs stay within original
///      bounding box) and post-adjacency (outputs share an edge).
///      split_replace does not yet enforce containment, so a child can
///      still be placed at an arbitrary position — the bystander overlap
///      check is the backstop there.
///
///      (A-B self-overlap for repartition and reshape vs. neighbour are
///       already covered by inline tests in mutations.move.)
///
///   4. Retrievability — after any valid mutation sequence, every surviving
///      polygon ID remains accessible via index::get().
///
/// ─── Relationships to other test files ───────────────────────────────────────
///
///   mutations.move         — single-operation correctness, error paths
///   quadtree_stress_tests  — large-scale register/remove cycles
///   integration_tests      — cross-module multi-user workflows
///   invariant_tests (here) — cross-operation sequences and compound invariants
///
/// ─── Geometry key ─────────────────────────────────────────────────────────────
///
///   All coordinates use SCALE = 1_000_000 as the unit (1 m in world space).
///   1m×1m = 1 m², 2m×1m = 2 m², etc.  All measurements are exact.
///   All tests use a shallow index (max_depth=3, cell_size=SCALE) to keep
///   broadphase traversal O(1) even with many polygons.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::invariant_tests {
    use mercator::{index::{Self, Index}, mutations, polygon};

    const SCALE: u64 = 1_000_000;

    /// Mirrors mutations.move ENotContained (module-private there).
    const ENotContained: u64 = 5001;
    /// Mirrors mutations.move EOverlap (module-private there).
    const EOverlap: u64 = 5002;

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    /// Shallow index that keeps broadphase traversal fast.
    fun test_index(ctx: &mut tx_context::TxContext): Index {
        index::with_config(SCALE, 3, 64, 10, 1024, 64, 2_000_000, ctx)
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

    /// Sum polygon::area() for every ID in the vector.
    fun total_area(ids: &vector<object::ID>, idx: &Index): u64 {
        let mut sum = 0u64;
        let mut i = 0;
        while (i < vector::length(ids)) {
            sum = sum + polygon::area(index::get(idx, *vector::borrow(ids, i)));
            i = i + 1;
        };
        sum
    }

    /// Abort-on-missing read for every ID — proves all are still in the index.
    fun assert_all_retrievable(ids: &vector<object::ID>, idx: &Index) {
        let mut i = 0;
        while (i < vector::length(ids)) {
            let _p = index::get(idx, *vector::borrow(ids, i));
            i = i + 1;
        };
    }

    // ─── Invariant 1 (focused): count per mutation type ──────────────────────────
    //
    // Each test isolates exactly one mutation and confirms the count rule:
    //   reshape          → unchanged
    //   repartition      → unchanged
    //   split (N parts)  → +N−1
    //   merge            → −1
    //
    // The compound test below verifies all four in sequence.

    #[test]
    /// reshape_unclaimed does not alter the polygon count.
    fun count_reshape_leaves_count_unchanged() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);

        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[vector[0u64, 2 * SCALE, 2 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 1, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// repartition_adjacent does not alter the count.
    /// A [0,2]×[0,1] | B [2,4]×[0,1] → A' [0,3]×[0,1] | B' [3,4]×[0,1].
    fun count_repartition_leaves_count_unchanged() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[vector[0u64, 3 * SCALE, 3 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            b_id,
            vector[vector[3 * SCALE, 4 * SCALE, 4 * SCALE, 3 * SCALE]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 2, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// split_replace(2 children) increments count by exactly 1: 1 parent removed,
    /// 2 children added → net +1.
    fun count_split_increments_by_children_minus_one() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[
                vector[vector[0u64, SCALE, SCALE, 0u64]],
                vector[vector[SCALE, 2 * SCALE, 2 * SCALE, SCALE]],
            ],
            vector[
                vector[vector[0u64, 0u64, SCALE, SCALE]],
                vector[vector[0u64, 0u64, SCALE, SCALE]],
            ],
            &mut ctx,
        );
        assert!(vector::length(&child_ids) == 2, 1);
        assert!(index::count(&idx) == 2, 2); // 1 − 1 + 2 = 2
        std::unit_test::destroy(idx);
    }

    #[test]
    /// merge_keep removes the absorbed polygon: count decrements by exactly 1.
    fun count_merge_decrements_by_one() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let keep_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let absorb_id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[vector[0u64, 2 * SCALE, 2 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 1, 1);
        std::unit_test::destroy(idx);
    }

    // ─── Invariants 1 + 2 + 4 (compound): full mutation sequence ─────────────────

    #[test]
    /// Compound sequence exercising all four mutation types.  Count and total area
    /// must be correct at every step; all surviving polygon IDs must be retrievable
    /// at the end.
    ///
    /// Geometry (all polygons at y = [0,1] unless noted):
    ///
    ///   A  [0,2]×[0,1]    2 m²   ─── registered
    ///   B  [2,4]×[0,1]    2 m²   ─── registered
    ///   C  [4,6]×[0,1]    2 m²   ─── registered, then reshaped
    ///
    /// Operation sequence and expected state:
    ///
    ///   register A                 count=1, total=2
    ///   register B                 count=2, total=4
    ///   register C                 count=3, total=6
    ///   reshape C → [4,6]×[0,2]   count=3, total=8   (area grew: C is now 4 m²)
    ///   repartition A+B            count=3, total=8   (A'=[0,3]×[0,1], B'=[3,4]×[0,1])
    ///   split C' → C1+C2           count=4, total=8   (C1=[4,5]×[0,2], C2=[5,6]×[0,2])
    ///   merge A'+B' → M            count=3, total=8   (M=[0,4]×[0,1])
    ///   remove M                   count=2, total=4   (C1, C2 survive)
    fun compound_sequence_count_and_area_consistent() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);

        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 1);

        let c_id = register_square(&mut idx, 4 * SCALE, 0, 6 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 3, 2);
        let abc = vector[a_id, b_id, c_id];
        assert!(total_area(&abc, &idx) == 6, 3);

        // ── reshape C: [4,6]×[0,1] → [4,6]×[0,2]  (area grows) ─────────────────
        mutations::reshape_unclaimed(
            &mut idx,
            c_id,
            vector[vector[4 * SCALE, 6 * SCALE, 6 * SCALE, 4 * SCALE]],
            vector[vector[0u64, 0u64, 2 * SCALE, 2 * SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 3, 4);
        // A=2, B=2, C'=4 → total = 8
        let area_after_reshape = total_area(&abc, &idx);
        assert!(area_after_reshape == 8, 5);

        // ── repartition A+B: A'=[0,3]×[0,1] (3 m²), B'=[3,4]×[0,1] (1 m²) ─────
        // Area conserved: A+B=4, A'+B'=3+1=4.  Touching C' at x=4 — not an overlap.
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[vector[0u64, 3 * SCALE, 3 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            b_id,
            vector[vector[3 * SCALE, 4 * SCALE, 4 * SCALE, 3 * SCALE]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 3, 6);
        // total unchanged: A'=3, B'=1, C'=4 = 8
        assert!(total_area(&abc, &idx) == area_after_reshape, 7);

        // ── split C'=[4,6]×[0,2] → C1=[4,5]×[0,2] + C2=[5,6]×[0,2] ─────────────
        let child_ids = mutations::split_replace(
            &mut idx,
            c_id,
            vector[
                vector[vector[4 * SCALE, 5 * SCALE, 5 * SCALE, 4 * SCALE]],
                vector[vector[5 * SCALE, 6 * SCALE, 6 * SCALE, 5 * SCALE]],
            ],
            vector[
                vector[vector[0u64, 0u64, 2 * SCALE, 2 * SCALE]],
                vector[vector[0u64, 0u64, 2 * SCALE, 2 * SCALE]],
            ],
            &mut ctx,
        );
        assert!(index::count(&idx) == 4, 8); // 3 − 1 + 2 = 4
        let c1_id = *vector::borrow(&child_ids, 0);
        let c2_id = *vector::borrow(&child_ids, 1);
        // total unchanged: A'=3, B'=1, C1=2, C2=2 = 8
        let ab_cc = vector[a_id, b_id, c1_id, c2_id];
        let area_after_split = total_area(&ab_cc, &idx);
        assert!(area_after_split == area_after_reshape, 9);

        // ── merge A'+B' → M=[0,4]×[0,1] (4 m²), keeping a_id ────────────────────
        // A'=[0,3] and B'=[3,4] share edge at x=3.  M touches C1 at x=4 — not overlap.
        mutations::merge_keep(
            &mut idx,
            a_id,
            b_id,
            vector[vector[0u64, 4 * SCALE, 4 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        assert!(index::count(&idx) == 3, 10); // 4 − 1 = 3
        // total unchanged: M=4, C1=2, C2=2 = 8  (a_id is now M)
        let m_cc = vector[a_id, c1_id, c2_id];
        assert!(total_area(&m_cc, &idx) == area_after_split, 11);

        // ── remove M ─────────────────────────────────────────────────────────────
        index::remove(&mut idx, a_id, &mut ctx);
        assert!(index::count(&idx) == 2, 12);

        // ── Invariant 4: all surviving polygons still retrievable ─────────────────
        let survivors = vector[c1_id, c2_id];
        assert_all_retrievable(&survivors, &idx);
        std::unit_test::destroy(idx);
    }

    // ─── Invariant 3: No-overlap enforcement — bystander cases ───────────────────
    //
    // The following three tests expose the bystander boundary for each mutable
    // operation.  In each case the geometry is carefully constructed so that:
    //
    //   (a) area is exactly conserved — the area conservation check passes first;
    //   (b) the mutated polygon(s) do not overlap each other;
    //   (c) exactly one mutated polygon overlaps a pre-existing bystander polygon,
    //       triggering EOverlap from the broadphase + SAT bystander check.
    //
    // This confirms that the no-overlap invariant is actively maintained by the
    // protocol, not merely a consequence of the initial registration barrier.

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    /// repartition that teleports B' outside the union AABB is rejected.
    ///
    /// Setup:  A=[0,2]×[0,1] (2 m²), B=[2,4]×[0,1] (2 m²), X=[6,8]×[0,1] (2 m²).
    /// Attempt: A'=[0,2]×[0,1] (2 m²), B'=[5,7]×[0,1] (2 m²).
    ///   • Area conserved:   A'+B' = 2+2 = 4 = A+B ✓
    ///   • A' vs B' no self-overlap:  [0,2] ∩ [5,7] = ∅ ✓
    ///   • Union AABB = [0,4]×[0,1]; B' AABB = [5,7]×[0,1] → ENotContained
    fun repartition_teleportation_outside_union_aabb_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);
        let _x_id = register_square(&mut idx, 6 * SCALE, 0, 8 * SCALE, SCALE, &mut ctx);
        // count = 3 — activates the bystander broadphase check

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[vector[0u64, 2 * SCALE, 2 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            b_id,
            vector[vector[5 * SCALE, 7 * SCALE, 7 * SCALE, 5 * SCALE]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );

        // unreachable — satisfies Move linearity
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = ENotContained, location = mercator::mutations)]
    /// split_replace that teleports a child onto a bystander is rejected.
    ///
    /// Setup:  X=[0,1]×[0,1] (1 m²),  P=[2,4]×[0,1] (2 m²).
    /// Attempt: C1=[2,3]×[0,1] (1 m²), C2=[0,1]×[0,1] (1 m²).
    ///   • C2 is outside parent P → ENotContained (F-01 fix).
    ///   • Previously caught by bystander overlap; now caught earlier by
    ///     the containment check.
    fun split_child_teleportation_overlap_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _x_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let p_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);

        mutations::split_replace(
            &mut idx,
            p_id,
            vector[
                vector[vector[2 * SCALE, 3 * SCALE, 3 * SCALE, 2 * SCALE]],
                vector[vector[0u64, SCALE, SCALE, 0u64]], // teleported onto X
            ],
            vector[
                vector[vector[0u64, 0u64, SCALE, SCALE]],
                vector[vector[0u64, 0u64, SCALE, SCALE]],
            ],
            &mut ctx,
        );

        // unreachable
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOverlap, location = mercator::mutations)]
    /// merge_keep where the merged geometry overlaps a bystander is rejected.
    ///
    /// Setup:  A=[0,1]×[0,1] (1 m²), B=[1,2]×[0,1] (1 m²), X=[3,4]×[0,1] (1 m²).
    /// Attempt: M=[2,4]×[0,1] (2 m²).
    ///   • Area conserved:   M = 2 = A+B ✓
    ///   • M vs X overlap:  [2,4] ∩ [3,4] = [3,4] ≠ ∅ → EOverlap
    ///
    /// Note: the merged geometry is deliberately placed OUTSIDE the original A+B
    /// footprint to demonstrate that the bystander check catches this case even
    /// when the merged polygon has been "relocated".
    fun merge_overlap_with_bystander_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let b_id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);
        let _x_id = register_square(&mut idx, 3 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);
        // count = 3 — activates the bystander broadphase check

        mutations::merge_keep(
            &mut idx,
            a_id,
            b_id,
            vector[vector[2 * SCALE, 4 * SCALE, 4 * SCALE, 2 * SCALE]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );

        // unreachable
        std::unit_test::destroy(idx);
    }

    // ─── Invariant 4 (focused): retrievability per mutation type ─────────────────
    //
    // These tests verify individually that each mutation preserves access to
    // surviving polygons and correctly reflects geometry changes.  The compound
    // test above provides the end-to-end sequence check.

    #[test]
    /// After reshape, the polygon is still retrievable and reflects the larger area.
    fun retrievability_reshape_polygon_accessible_with_new_area() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let old_area = polygon::area(index::get(&idx, id));

        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[vector[0u64, 2 * SCALE, 2 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );

        let new_area = polygon::area(index::get(&idx, id)); // must not abort
        assert!(new_area > old_area, 0); // 2 m² > 1 m²
        assert!(index::count(&idx) == 1, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// After repartition, both polygon IDs remain accessible with updated areas
    /// that sum to the original total.
    fun retrievability_repartitioned_polygons_accessible_with_new_areas() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);
        let ab = vector[a_id, b_id];
        let area_before = total_area(&ab, &idx);

        // Repartition to A' = 3 m², B' = 1 m².
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[vector[0u64, 3 * SCALE, 3 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            b_id,
            vector[vector[3 * SCALE, 4 * SCALE, 4 * SCALE, 3 * SCALE]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );

        // Both IDs still valid; areas reflect new geometry.
        assert!(polygon::area(index::get(&idx, a_id)) == 3, 0);
        assert!(polygon::area(index::get(&idx, b_id)) == 1, 1);
        // Area conserved.
        assert!(total_area(&ab, &idx) == area_before, 2);
        assert!(index::count(&idx) == 2, 3);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// After split, all child IDs are retrievable; child areas sum to parent area.
    fun retrievability_all_children_accessible_after_split() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        let parent_area = polygon::area(index::get(&idx, parent_id));

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[
                vector[vector[0u64, SCALE, SCALE, 0u64]],
                vector[vector[SCALE, 2 * SCALE, 2 * SCALE, SCALE]],
            ],
            vector[
                vector[vector[0u64, 0u64, SCALE, SCALE]],
                vector[vector[0u64, 0u64, SCALE, SCALE]],
            ],
            &mut ctx,
        );

        assert_all_retrievable(&child_ids, &idx);
        // Child areas sum to parent area.
        assert!(total_area(&child_ids, &idx) == parent_area, 0);
        assert!(index::count(&idx) == 2, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// After merge, the kept polygon is retrievable with the combined area;
    /// count falls by 1, confirming the absorbed polygon was removed.
    fun retrievability_keep_accessible_absorbed_counted_out_after_merge() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let keep_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let absorb_id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);
        let area_sum =
            polygon::area(index::get(&idx, keep_id))
        + polygon::area(index::get(&idx, absorb_id));

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[vector[0u64, 2 * SCALE, 2 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );

        // kept polygon retrievable; area equals old sum (1+1=2 m²).
        assert!(polygon::area(index::get(&idx, keep_id)) == area_sum, 0);
        // count fell by 1; absorb_id is no longer in the index.
        assert!(index::count(&idx) == 1, 1);
        std::unit_test::destroy(idx);
    }
}
