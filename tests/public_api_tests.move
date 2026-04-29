/// Tests for public functions that had zero or near-zero direct coverage:
///
///   • polygon::contains_polygon()  — used internally by mutations but never
///     tested directly; a bug here silently corrupts reshape/repartition.
///   • index::outer_contains_inner() — wraps contains_polygon via the index;
///     completely untested.
///   • index::candidates() edge cases — isolated polygon (empty result) and
///     many neighbours (large candidate set).
///   • index::overlapping() returning non-empty — tests were only vacuous
///     (asserting empty).  Here we inject an overlapping polygon directly
///     via the package-private bypass API to exercise the full path.
///   • index::overlaps() — direct pair SAT check; also untested.
///
/// ─── Injection technique ─────────────────────────────────────────────────────
///
///   index::register enforces EOverlap, so overlapping polygons cannot be
///   added through the public API.  To test overlapping() returning non-empty
///   we bypass the overlap check using package-private functions:
///     index::put_polygon  + register_in_cell + increment_count
///   These are accessible from any mercator::* module (same package).
///
/// ─── Geometry key ─────────────────────────────────────────────────────────────
///
///   SCALE = 1_000_000.  Coordinates are expressed as multiples of SCALE
///   so that "1 unit" = 1 m in world space.
///   All tests use max_depth=3, cell_size=SCALE to keep broadphase fast.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::public_api_tests {
    use mercator::{index::{Self, Index}, morton, polygon};

    const SCALE: u64 = 1_000_000;

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    fun test_index(ctx: &mut tx_context::TxContext): Index {
        index::with_config(SCALE, 3, 64, 10, 1024, 64, 2_000_000, ctx)
    }

    /// Register an axis-aligned rectangle.
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

    /// Build a standalone Polygon (not registered in any index) for use in
    /// direct polygon::contains_polygon() tests.
    fun make_square_polygon(
        x0: u64,
        y0: u64,
        x1: u64,
        y1: u64,
        ctx: &mut tx_context::TxContext,
    ): polygon::Polygon {
        let part = polygon::part(
            vector[x0, x1, x1, x0],
            vector[y0, y0, y1, y1],
        );
        polygon::new(vector[part], ctx)
    }

    /// Inject `b_poly` into `idx` bypassing the overlap check.
    /// Computes the natural quadtree cell for b_poly's AABB and stores it there.
    fun inject_polygon(idx: &mut Index, b_poly: polygon::Polygon): object::ID {
        let b_bounds = polygon::bounds(&b_poly);
        let (min_gx, min_gy, max_gx, max_gy) = index::grid_bounds_for_aabb(idx, &b_bounds);
        let md = index::max_depth(idx);
        let depth = index::natural_depth(
            min_gx,
            min_gy,
            max_gx,
            max_gy,
            md,
        );
        let shift = md - depth;
        let cx = min_gx >> shift;
        let cy = min_gy >> shift;
        let cell_key = morton::depth_prefix(
            morton::interleave_n(cx, cy, depth),
            depth,
        );
        let mut b_poly = b_poly;
        polygon::set_cells(&mut b_poly, vector[cell_key]);
        let b_id = index::put_polygon(idx, b_poly);
        index::register_in_cell(idx, b_id, cell_key, depth);
        index::increment_count(idx);
        b_id
    }

    // ─── polygon::contains_polygon ────────────────────────────────────────────────

    #[test]
    /// A small inner square placed well inside a larger outer square → true.
    fun contains_polygon_inner_well_inside_outer() {
        let mut ctx = tx_context::dummy();
        let outer = make_square_polygon(0, 0, 6 * SCALE, 6 * SCALE, &mut ctx);
        let inner = make_square_polygon(
            2 * SCALE,
            2 * SCALE,
            4 * SCALE,
            4 * SCALE,
            &mut ctx,
        );
        assert!(polygon::contains_polygon(&outer, &inner), 0);
        polygon::destroy(outer);
        polygon::destroy(inner);
    }

    #[test]
    /// Inner touching the outer boundary (sharing the bottom edge) → true.
    /// contains_polygon uses ≤ for the boundary check.
    fun contains_polygon_inner_touching_outer_boundary() {
        let mut ctx = tx_context::dummy();
        // Outer: [0,4]×[0,4]
        let outer = make_square_polygon(0, 0, 4 * SCALE, 4 * SCALE, &mut ctx);
        // Inner: [1,2]×[0,1] — bottom edge sits on y=0 boundary of outer
        let inner = make_square_polygon(
            SCALE,
            0,
            2 * SCALE,
            SCALE,
            &mut ctx,
        );
        assert!(polygon::contains_polygon(&outer, &inner), 0);
        polygon::destroy(outer);
        polygon::destroy(inner);
    }

    #[test]
    /// Identical polygons: outer == inner → true (boundary vertices are inside-or-on).
    fun contains_polygon_identical_polygons() {
        let mut ctx = tx_context::dummy();
        let outer = make_square_polygon(0, 0, 3 * SCALE, 3 * SCALE, &mut ctx);
        let inner = make_square_polygon(0, 0, 3 * SCALE, 3 * SCALE, &mut ctx);
        assert!(polygon::contains_polygon(&outer, &inner), 0);
        polygon::destroy(outer);
        polygon::destroy(inner);
    }

    #[test]
    /// Inner extends beyond outer's right edge → false.
    fun contains_polygon_inner_partially_outside() {
        let mut ctx = tx_context::dummy();
        // Outer: [0,4]×[0,4]
        let outer = make_square_polygon(0, 0, 4 * SCALE, 4 * SCALE, &mut ctx);
        // Inner: [3,6]×[1,2] — right side sticks out past x=4
        let inner = make_square_polygon(
            3 * SCALE,
            SCALE,
            6 * SCALE,
            2 * SCALE,
            &mut ctx,
        );
        assert!(!polygon::contains_polygon(&outer, &inner), 0);
        polygon::destroy(outer);
        polygon::destroy(inner);
    }

    #[test]
    /// Inner lies completely disjoint from outer → false.
    fun contains_polygon_inner_completely_outside() {
        let mut ctx = tx_context::dummy();
        // Outer: [0,2]×[0,2]
        let outer = make_square_polygon(0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        // Inner: [5,7]×[5,7] — no intersection
        let inner = make_square_polygon(
            5 * SCALE,
            5 * SCALE,
            7 * SCALE,
            7 * SCALE,
            &mut ctx,
        );
        assert!(!polygon::contains_polygon(&outer, &inner), 0);
        polygon::destroy(outer);
        polygon::destroy(inner);
    }

    #[test]
    /// contains_polygon is not symmetric: B⊂A does not imply A⊂B.
    fun contains_polygon_asymmetric() {
        let mut ctx = tx_context::dummy();
        let big = make_square_polygon(0, 0, 6 * SCALE, 6 * SCALE, &mut ctx);
        let small = make_square_polygon(
            SCALE,
            SCALE,
            3 * SCALE,
            3 * SCALE,
            &mut ctx,
        );
        // big contains small
        assert!(polygon::contains_polygon(&big, &small), 0);
        // small does NOT contain big
        assert!(!polygon::contains_polygon(&small, &big), 1);
        polygon::destroy(big);
        polygon::destroy(small);
    }

    // ─── index::outer_contains_inner ─────────────────────────────────────────────

    #[test]
    /// Inner registered in a separate index from outer: outer_contains_inner → true.
    /// Two-index variant: the function accepts separate &Index for outer and inner,
    /// which is required whenever the two polygons would geometrically overlap
    /// (a nested polygon cannot be registered in the same index).
    fun outer_contains_inner_true_cross_index() {
        let mut ctx = tx_context::dummy();
        // Outer lives in idx_outer; inner lives in idx_inner to avoid EOverlap.
        let mut idx_outer = test_index(&mut ctx);
        let mut idx_inner = test_index(&mut ctx);
        let outer_id = register_square(&mut idx_outer, 0, 0, 6 * SCALE, 6 * SCALE, &mut ctx);
        let inner_id = register_square(
            &mut idx_inner,
            SCALE,
            SCALE,
            3 * SCALE,
            3 * SCALE,
            &mut ctx,
        );

        assert!(index::outer_contains_inner(&idx_outer, outer_id, &idx_inner, inner_id), 0);
        std::unit_test::destroy(idx_outer);
        std::unit_test::destroy(idx_inner);
    }

    #[test]
    /// Two non-nested adjacent polygons in the same index: outer_contains_inner → false
    /// in both directions.
    fun outer_contains_inner_false_when_adjacent() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);

        assert!(!index::outer_contains_inner(&idx, a_id, &idx, b_id), 0);
        assert!(!index::outer_contains_inner(&idx, b_id, &idx, a_id), 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Same-index references passed for both outer and inner parameters.
    /// The inner polygon is injected (bypassing EOverlap) so that both polygons
    /// live in the same index, exercising the same-ref code path.
    fun outer_contains_inner_same_index_both_sides() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let outer_id = register_square(&mut idx, 0, 0, 10 * SCALE, 10 * SCALE, &mut ctx);
        let inner_part = polygon::part(
            vector[3 * SCALE, 5 * SCALE, 5 * SCALE, 3 * SCALE],
            vector[3 * SCALE, 3 * SCALE, 5 * SCALE, 5 * SCALE],
        );
        let inner_poly = polygon::new(vector[inner_part], &mut ctx);
        let inner_id = inject_polygon(&mut idx, inner_poly);

        // Same &idx passed for both — outer contains inner.
        assert!(index::outer_contains_inner(&idx, outer_id, &idx, inner_id), 0);
        // Inner does not contain outer.
        assert!(!index::outer_contains_inner(&idx, inner_id, &idx, outer_id), 1);
        std::unit_test::destroy(idx);
    }

    // ─── index::candidates ────────────────────────────────────────────────────────

    #[test]
    /// A single polygon in the index has no neighbours → candidates is empty.
    fun candidates_empty_for_isolated_polygon() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        assert!(vector::length(&index::candidates(&idx, id)) == 0, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Adding a second, spatially distant polygon does not affect candidates of
    /// the first — the index must not return false positives.
    fun candidates_empty_when_all_polygons_are_far_apart() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let b_id = register_square(
            &mut idx,
            20 * SCALE,
            20 * SCALE,
            21 * SCALE,
            21 * SCALE,
            &mut ctx,
        );

        assert!(vector::length(&index::candidates(&idx, a_id)) == 0, 0);
        assert!(vector::length(&index::candidates(&idx, b_id)) == 0, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Three polygons placed adjacent to a central polygon are all returned as
    /// broadphase candidates of that central polygon.
    fun candidates_returns_all_adjacent_neighbours() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let center_id = register_square(&mut idx, SCALE, SCALE, 2 * SCALE, 2 * SCALE, &mut ctx);
        // Right:   [2,3]×[1,2]
        let right_id = register_square(&mut idx, 2 * SCALE, SCALE, 3 * SCALE, 2 * SCALE, &mut ctx);
        // Above:   [1,2]×[2,3]
        let above_id = register_square(&mut idx, SCALE, 2 * SCALE, 2 * SCALE, 3 * SCALE, &mut ctx);
        // Right-above: [2,3]×[2,3]
        let diag_id = register_square(
            &mut idx,
            2 * SCALE,
            2 * SCALE,
            3 * SCALE,
            3 * SCALE,
            &mut ctx,
        );

        let cands = index::candidates(&idx, center_id);

        // All three neighbours must appear (order irrelevant).
        let mut found_right = false;
        let mut found_above = false;
        let mut found_diag = false;
        let mut i = 0;
        while (i < vector::length(&cands)) {
            let pid = *vector::borrow(&cands, i);
            if (pid == right_id) { found_right = true };
            if (pid == above_id) { found_above = true };
            if (pid == diag_id) { found_diag = true };
            i = i + 1;
        };
        assert!(found_right, 0);
        assert!(found_above, 1);
        assert!(found_diag, 2);
        std::unit_test::destroy(idx);
    }

    // ─── index::overlapping (non-empty) and index::overlaps ──────────────────────

    #[test]
    /// Injecting an overlapping polygon exposes it through overlapping().
    /// Also verifies that overlapping() is symmetric: A sees B and B sees A.
    fun overlapping_returns_non_empty_for_injected_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);

        // B: [1,3]×[0,1] overlaps A by [1,2]×[0,1].
        // Injected directly to bypass the EOverlap guard.
        let b_part = polygon::part(
            vector[SCALE, 3 * SCALE, 3 * SCALE, SCALE],
            vector[0, 0, SCALE, SCALE],
        );
        let b_poly = polygon::new(vector[b_part], &mut ctx);
        let b_id = inject_polygon(&mut idx, b_poly);

        assert!(index::count(&idx) == 2, 0);

        // A's overlapping set contains B.
        let a_overlaps = index::overlapping(&idx, a_id);
        assert!(vector::length(&a_overlaps) == 1, 1);
        assert!(*vector::borrow(&a_overlaps, 0) == b_id, 2);

        // B's overlapping set contains A (symmetry).
        let b_overlaps = index::overlapping(&idx, b_id);
        assert!(vector::length(&b_overlaps) == 1, 3);
        assert!(*vector::borrow(&b_overlaps, 0) == a_id, 4);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Polygons that are adjacent (touching edges) are NOT reported as overlapping.
    /// This is a geometric boundary property: shared edge ≠ intersection.
    fun overlapping_empty_for_edge_touching_polygons() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);

        assert!(vector::length(&index::overlapping(&idx, a_id)) == 0, 0);
        assert!(vector::length(&index::overlapping(&idx, b_id)) == 0, 1);
        std::unit_test::destroy(idx);
    }

    // ─── index::overlaps (pair check) ────────────────────────────────────────────

    #[test]
    /// Two non-overlapping adjacent polygons → overlaps returns false.
    fun overlaps_false_for_adjacent_polygons() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);

        assert!(!index::overlaps(&idx, a_id, b_id), 0);
        assert!(!index::overlaps(&idx, b_id, a_id), 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Two disjoint polygons → overlaps returns false.
    fun overlaps_false_for_disjoint_polygons() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 5 * SCALE, 5 * SCALE, 6 * SCALE, 6 * SCALE, &mut ctx);

        assert!(!index::overlaps(&idx, a_id, b_id), 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Injected overlapping pair → overlaps returns true, symmetrically.
    fun overlaps_true_for_injected_overlapping_pair() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);

        // B: [1,3]×[0,1] — overlaps A in [1,2]×[0,1]
        let b_part = polygon::part(
            vector[SCALE, 3 * SCALE, 3 * SCALE, SCALE],
            vector[0, 0, SCALE, SCALE],
        );
        let b_poly = polygon::new(vector[b_part], &mut ctx);
        let b_id = inject_polygon(&mut idx, b_poly);

        assert!(index::overlaps(&idx, a_id, b_id), 0);
        assert!(index::overlaps(&idx, b_id, a_id), 1); // symmetric
        std::unit_test::destroy(idx);
    }

    #[test]
    /// overlaps(id, id) — a polygon overlaps itself.
    /// Verifies that the self-overlap case is handled correctly by the SAT check.
    fun overlaps_self_is_true() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);

        assert!(index::overlaps(&idx, id, id), 0);
        std::unit_test::destroy(idx);
    }
}
