/// Split broadphase correctness tests for repartition_adjacent.
///
/// Verifies that the per-output-polygon AABB broadphase in
/// assert_no_overlap_with_others_pair has zero false negatives.
///
/// Test E: valid repartition with distant bystander — no false rejection
/// Test F: bystander overlaps output A — detected by A's individual scan
/// Test G: bystander overlaps output B (not A) — detected by B's individual scan
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::broadphase_split_tests {
    use mercator::{index::{Self, Index}, mutations, polygon};

    const SCALE: u64 = 1_000_000;

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    fun test_index(ctx: &mut tx_context::TxContext): Index {
        index::with_config(SCALE, 3, 64, 10, 1024, 64, 2_000_000, ctx)
    }

    fun sq_xs(min: u64, max: u64): vector<u64> {
        vector[min, max, max, min]
    }

    fun sq_ys(min: u64, max: u64): vector<u64> {
        vector[min, min, max, max]
    }

    fun register_square(
        idx: &mut Index,
        x0: u64,
        y0: u64,
        x1: u64,
        y1: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[sq_xs(x0, x1)], vector[sq_ys(y0, y1)], ctx)
    }

    // ─── Test E: split broadphase allows valid repartition with distant bystander ─

    #[test]
    /// Two adjacent squares A and B are repartitioned in the presence of a
    /// distant bystander C.  The split broadphase must NOT false-reject this
    /// valid repartition.
    ///
    /// A = [0,2S]×[0,2S], B = [2S,4S]×[0,2S], C = [6S,8S]×[0,2S].
    /// A' = [0,4S]×[0,S], B' = [0,4S]×[S,2S].
    fun split_broadphase_repartition_succeeds_no_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);
        let _c_id = register_square(&mut idx, 6 * SCALE, 0, 8 * SCALE, 2 * SCALE, &mut ctx);

        assert!(index::count(&idx) == 3, 0);

        let old_sum =
            (polygon::area(index::get(&idx, a_id)) as u128)
        + (polygon::area(index::get(&idx, b_id)) as u128);

        // Repartition: rotate boundary from vertical to horizontal.
        // A' = [0,4S]×[0,S] (4m²), B' = [0,4S]×[S,2S] (4m²).
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, 4 * SCALE)],
            vector[sq_ys(0, SCALE)],
            b_id,
            vector[sq_xs(0, 4 * SCALE)],
            vector[sq_ys(SCALE, 2 * SCALE)],
            &ctx,
        );

        let new_sum =
            (polygon::area(index::get(&idx, a_id)) as u128)
        + (polygon::area(index::get(&idx, b_id)) as u128);
        assert!(old_sum == new_sum, 1);
        assert!(index::count(&idx) == 3, 2);
        assert!(vector::length(&index::overlapping(&idx, a_id)) == 0, 3);
        assert!(vector::length(&index::overlapping(&idx, b_id)) == 0, 4);
        std::unit_test::destroy(idx);
    }

    // ─── Tests F & G: triangle pair with gap ─────────────────────────────────────
    //
    // Two adjacent right triangles leave a triangular gap in the union AABB.
    // A bystander rectangle C sits in that gap.
    //
    //   A = ▷ (0,0)-(2S,0)-(2S,2S)   area 2m²   hypotenuse y = x
    //   B = ◁ (2S,0)-(4S,0)-(2S,2S)  area 2m²   shared edge at x = 2S
    //
    //   Union AABB = [0,4S]×[0,2S]
    //   Gap above A's hypotenuse: { (x,y) : y > x, x ∈ [0,2S] }
    //
    //   C = [0,S]×[S,2S] (1m²)  — in the gap, disjoint from A and B.
    //     SAT confirms: on A's hypotenuse normal (1,−1), projection of A is
    //     [0,2S] while C projects to [−2S,0]; max_b(0) > min_a(0) is false
    //     ⇒ separating axis ⇒ no overlap.

    #[test]
    #[expected_failure(abort_code = mutations::EOverlap)]
    /// New A' = [0,2S]×[S,2S] (2m²) covers C's footprint → EOverlap.
    /// New B' = [0,2S]×[0,S] (2m²) is far from C.
    /// Verifies: A's individual broadphase scan catches the overlap.
    fun split_broadphase_detects_overlap_with_output_a() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = index::register(
            &mut idx,
            vector[vector[0, 2 * SCALE, 2 * SCALE]],
            vector[vector[0, 0, 2 * SCALE]],
            &mut ctx,
        );
        // B: right triangle — right angle at (2S,0), mirror of A.
        let b_id = index::register(
            &mut idx,
            vector[vector[2 * SCALE, 4 * SCALE, 2 * SCALE]],
            vector[vector[0, 0, 2 * SCALE]],
            &mut ctx,
        );
        // C: in A's gap above hypotenuse.
        let _c_id = register_square(&mut idx, 0, SCALE, SCALE, 2 * SCALE, &mut ctx);

        assert!(index::count(&idx) == 3, 0);

        // A' = [0,2S]×[S,2S] (2m²) — overlaps C.
        // B' = [0,2S]×[0,S] (2m²) — disjoint from C.
        // Total = 4m² = 2+2.
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(SCALE, 2 * SCALE)],
            b_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::EOverlap)]
    /// New A' = [0,2S]×[0,S] (2m²) is disjoint from C.
    /// New B' = [0,2S]×[S,2S] (2m²) covers C's footprint → EOverlap.
    /// This is the critical correctness test: C falls inside B's AABB
    /// [0,2S]×[S,2S] but NOT A's AABB [0,2S]×[0,S].  The split broadphase
    /// catches C via B's individual scan — confirming zero false negatives
    /// even when A's scan alone would miss it.
    fun split_broadphase_detects_overlap_with_output_b() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = index::register(
            &mut idx,
            vector[vector[0, 2 * SCALE, 2 * SCALE]],
            vector[vector[0, 0, 2 * SCALE]],
            &mut ctx,
        );
        // B: right triangle — right angle at (2S,0), mirror of A.
        let b_id = index::register(
            &mut idx,
            vector[vector[2 * SCALE, 4 * SCALE, 2 * SCALE]],
            vector[vector[0, 0, 2 * SCALE]],
            &mut ctx,
        );
        // C: in A's gap above hypotenuse.
        let _c_id = register_square(&mut idx, 0, SCALE, SCALE, 2 * SCALE, &mut ctx);

        assert!(index::count(&idx) == 3, 0);

        // A' = [0,2S]×[0,S] (2m²) — disjoint from C (C.min_y=S = A'.max_y).
        // B' = [0,2S]×[S,2S] (2m²) — overlaps C at [0,S]×[S,2S].
        // Total = 4m² = 2+2.
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, SCALE)],
            b_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(SCALE, 2 * SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }
}
