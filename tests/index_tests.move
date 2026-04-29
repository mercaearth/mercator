/// Extracted index module tests.
#[test_only, allow(unused_variable)]
module mercator::index_tests {
    use mercator::{aabb, index, polygon};
    use sui::test_scenario;

    const SCALE: u64 = 1_000_000;
    const DEFAULT_CELL_SIZE: u64 = 1_000_000;
    const DEFAULT_MAX_DEPTH: u8 = 20;
    const MAX_GRID_COORD: u64 = 4_294_967_295;
    const EQueryTooLarge: u64 = 4021;
    const EBroadphaseBudgetExceeded: u64 = 4023;
    const ECellOccupancyExceeded: u64 = 4024;

    fun test_index(ctx: &mut tx_context::TxContext): index::Index {
        index::with_config(SCALE, 3, 64, 10, 1024, 64, 2_000_000, ctx)
    }

    fun sq_xs(min: u64, max: u64): vector<u64> {
        vector[min, max, max, min]
    }

    fun sq_ys(min: u64, max: u64): vector<u64> {
        vector[min, min, max, max]
    }

    fun register_square(
        idx: &mut index::Index,
        x0: u64,
        y0: u64,
        x1: u64,
        y1: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[sq_xs(x0, x1)], vector[sq_ys(y0, y1)], ctx)
    }

    fun contains_id(v: &vector<object::ID>, id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) {
                return true
            };
            i = i + 1;
        };
        false
    }

    fun rect_xs(min_x: u64, max_x: u64): vector<u64> {
        vector[min_x, max_x, max_x, min_x]
    }

    fun rect_ys(min_y: u64, max_y: u64): vector<u64> {
        vector[min_y, min_y, max_y, max_y]
    }

    fun register_rect(
        idx: &mut index::Index,
        min_x: u64,
        min_y: u64,
        max_x: u64,
        max_y: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[rect_xs(min_x, max_x)], vector[rect_ys(min_y, max_y)], ctx)
    }

    #[test]
    fun quadtree_new_has_correct_defaults() {
        let mut ctx = tx_context::dummy();
        let idx = index::new(&mut ctx);
        assert!(index::count(&idx) == 0, 0);
        assert!(index::cell_size(&idx) == DEFAULT_CELL_SIZE, 1);
        assert!(index::max_depth(&idx) == DEFAULT_MAX_DEPTH, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadCellSize)]
    fun quadtree_rejects_zero_cell_size() {
        let mut ctx = tx_context::dummy();
        let idx = index::with_config(0, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadMaxDepth)]
    fun quadtree_rejects_zero_max_depth() {
        let mut ctx = tx_context::dummy();
        let idx = index::with_config(1_000_000, 0, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun natural_depth_point_is_max() {
        assert!(index::natural_depth(5, 5, 5, 5, 8) == 8, 0);
    }

    #[test]
    fun natural_depth_small_aabb() {
        assert!(index::natural_depth(1, 1, 1, 1, 8) == 8, 0);
        assert!(index::natural_depth(1, 1, 2, 2, 8) == 6, 1);
    }

    #[test]
    fun natural_depth_large_aabb_is_shallow() {
        assert!(index::natural_depth(0, 0, 100, 100, 8) == 1, 0);
    }

    #[test]
    fun natural_depth_world_is_root() {
        let big = (1u32 << 8) - 1;
        assert!(index::natural_depth(0, 0, big, big, 8) == 0, 0);
    }

    #[test]
    fun grid_bounds_for_aabb_converts_within_range() {
        let mut ctx = tx_context::dummy();
        let idx = index::with_config(1, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let bounds = aabb::new(1, 2, 3, 4);
        let (min_gx, min_gy, max_gx, max_gy) = index::grid_bounds_for_aabb(&idx, &bounds);
        assert!(min_gx == 1, 0);
        assert!(min_gy == 2, 1);
        assert!(max_gx == 3, 2);
        assert!(max_gy == 4, 3);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::ECoordinateTooLarge)]
    fun grid_bounds_for_aabb_rejects_out_of_range_coordinate() {
        let mut ctx = tx_context::dummy();
        let idx = index::with_config(1, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let bounds = aabb::new(0, 0, MAX_GRID_COORD + 1, 1);
        let (_min_gx, _min_gy, _max_gx, _max_gy) = index::grid_bounds_for_aabb(&idx, &bounds);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun register_inserts_single_polygon() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(1_000_000, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let xs = vector[vector[0, 1_000_000, 1_000_000, 0]];
        let ys = vector[vector[0, 0, 1_000_000, 1_000_000]];
        let _id = index::register(&mut idx, xs, ys, &mut ctx);
        assert!(index::count(&idx) == 1, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun register_stores_at_one_cell() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(1_000_000, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let xs = vector[vector[0, 1_000_000, 1_000_000, 0]];
        let ys = vector[vector[0, 0, 1_000_000, 1_000_000]];
        let id = index::register(&mut idx, xs, ys, &mut ctx);
        let polygon = index::get(&idx, id);
        assert!(vector::length(polygon::cells(polygon)) == 1, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::EOverlap)]
    fun register_rejects_overlapping_polygon() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(1_000_000, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let xs1 = vector[vector[0, 2_000_000, 2_000_000, 0]];
        let ys1 = vector[vector[0, 0, 2_000_000, 2_000_000]];
        let _id1 = index::register(&mut idx, xs1, ys1, &mut ctx);
        let xs2 = vector[vector[1_000_000, 3_000_000, 3_000_000, 1_000_000]];
        let ys2 = vector[vector[1_000_000, 1_000_000, 3_000_000, 3_000_000]];
        let _id2 = index::register(&mut idx, xs2, ys2, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun register_accepts_non_overlapping_polygons() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(1_000_000, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let xs1 = vector[vector[0, 1_000_000, 1_000_000, 0]];
        let ys1 = vector[vector[0, 0, 1_000_000, 1_000_000]];
        let _id1 = index::register(&mut idx, xs1, ys1, &mut ctx);
        let xs2 = vector[vector[3_000_000, 4_000_000, 4_000_000, 3_000_000]];
        let ys2 = vector[vector[3_000_000, 3_000_000, 4_000_000, 4_000_000]];
        let _id2 = index::register(&mut idx, xs2, ys2, &mut ctx);
        assert!(index::count(&idx) == 2, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun candidates_finds_ancestor_polygon() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(1_000_000, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let xs1 = vector[vector[0, 8_000_000, 8_000_000, 0]];
        let ys1 = vector[vector[0, 0, 1_000_000, 1_000_000]];
        let id1 = index::register(&mut idx, xs1, ys1, &mut ctx);
        let xs2 = vector[vector[1_000_000, 2_000_000, 2_000_000, 1_000_000]];
        let ys2 = vector[vector[3_000_000, 3_000_000, 4_000_000, 4_000_000]];
        let id2 = index::register(&mut idx, xs2, ys2, &mut ctx);
        let cands = index::candidates(&idx, id2);
        let mut found_id1 = false;
        let mut i = 0;
        while (i < vector::length(&cands)) {
            if (*vector::borrow(&cands, i) == id1) {
                found_id1 = true;
            };
            i = i + 1;
        };
        assert!(found_id1, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun candidates_finds_descendant_polygon() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(1_000_000, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let xs1 = vector[vector[0, 8_000_000, 8_000_000, 0]];
        let ys1 = vector[vector[0, 0, 1_000_000, 1_000_000]];
        let id1 = index::register(&mut idx, xs1, ys1, &mut ctx);
        let xs2 = vector[vector[1_000_000, 2_000_000, 2_000_000, 1_000_000]];
        let ys2 = vector[vector[3_000_000, 3_000_000, 4_000_000, 4_000_000]];
        let id2 = index::register(&mut idx, xs2, ys2, &mut ctx);
        let cands = index::candidates(&idx, id1);
        let mut found_id2 = false;
        let mut i = 0;
        while (i < vector::length(&cands)) {
            if (*vector::borrow(&cands, i) == id2) {
                found_id2 = true;
            };
            i = i + 1;
        };
        assert!(found_id2, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun remove_decrements_count() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(1_000_000, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let xs = vector[vector[0, 1_000_000, 1_000_000, 0]];
        let ys = vector[vector[0, 0, 1_000_000, 1_000_000]];
        let id = index::register(&mut idx, xs, ys, &mut ctx);
        assert!(index::count(&idx) == 1, 0);
        index::remove(&mut idx, id, &mut ctx);
        assert!(index::count(&idx) == 0, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun outer_contains_inner_returns_true_when_contained() {
        let mut scenario = test_scenario::begin(@0xCAFE);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut outer_idx = index::new(ctx);
            let mut inner_idx = index::new(ctx);
            let outer_id = index::register(
                &mut outer_idx,
                vector[vector[0u64, 3_000_000u64, 3_000_000u64, 0u64]],
                vector[vector[0u64, 0u64, 3_000_000u64, 3_000_000u64]],
                ctx,
            );
            let inner_id = index::register(
                &mut inner_idx,
                vector[vector[1_000_000u64, 2_000_000u64, 2_000_000u64, 1_000_000u64]],
                vector[vector[1_000_000u64, 1_000_000u64, 2_000_000u64, 2_000_000u64]],
                ctx,
            );
            assert!(
                index::outer_contains_inner(
                    &outer_idx,
                    outer_id,
                    &inner_idx,
                    inner_id,
                ),
                0,
            );
            std::unit_test::destroy(outer_idx);
            std::unit_test::destroy(inner_idx);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun new_config_accepts_valid_params() {
        let cfg = index::new_config(64, 10, 1_000_000, 1024, 64, 2_000_000);
        let mut ctx = tx_context::dummy();
        let mut idx = index::new(&mut ctx);
        index::set_config(&mut idx, cfg);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadConfig)]
    fun new_config_rejects_zero_max_vertices() {
        let _cfg = index::new_config(0, 10, 1_000_000, 1024, 64, 2_000_000);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadConfig)]
    fun new_config_rejects_zero_max_parts() {
        let _cfg = index::new_config(64, 0, 1_000_000, 1024, 64, 2_000_000);
    }

    #[test]
    #[expected_failure(abort_code = index::EBadConfig)]
    fun new_config_rejects_zero_scaling_factor() {
        let _cfg = index::new_config(64, 10, 0, 1024, 64, 2_000_000);
    }

    #[test]
    fun outer_contains_inner_returns_false_when_not_contained() {
        let mut scenario = test_scenario::begin(@0xCAFE);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let mut idx_a = index::new(ctx);
            let mut idx_b = index::new(ctx);
            let id_a = index::register(
                &mut idx_a,
                vector[vector[0u64, 1_000_000u64, 1_000_000u64, 0u64]],
                vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]],
                ctx,
            );
            let id_b = index::register(
                &mut idx_b,
                vector[vector[2_000_000u64, 3_000_000u64, 3_000_000u64, 2_000_000u64]],
                vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]],
                ctx,
            );
            assert!(!index::outer_contains_inner(&idx_a, id_a, &idx_b, id_b), 0);
            std::unit_test::destroy(idx_a);
            std::unit_test::destroy(idx_b);
        };
        test_scenario::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-13: config.max_depth diverges from index.max_depth after update
    // ═════════════════════════════════════════════════════════════════════════════
    //
    // set_config updates index.config but NOT index.max_depth. The quadtree uses
    // index.max_depth for all spatial operations. Changing config.max_depth via
    // update_config has no effect on the actual tree depth.

    #[test]
    /// Fixed (F-13): max_depth removed from Config entirely.
    /// Config updates can no longer cause divergence — max_depth lives only on Index
    /// and is immutable after creation.
    fun f13_config_max_depth_has_no_effect() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 3, 64, 10, 1024, 64, 2_000_000, &mut ctx);

        assert!(index::max_depth(&idx) == 3);

        // Config update changes vertices/parts/scaling but cannot touch max_depth.
        let new_config = index::new_config(32, 5, SCALE, 8, 64, 64);
        index::set_config(&mut idx, new_config);

        // max_depth unchanged — it is not part of Config.
        assert!(index::max_depth(&idx) == 3);

        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-25: query_viewport — zero test coverage, adding basic coverage
    // ═════════════════════════════════════════════════════════════════════════════

    #[test]
    /// F-25a: query_viewport returns polygons within the viewport.
    fun f25a_query_viewport_basic() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let s = SCALE;
        let id = register_square(&mut idx, 0, 0, s, s, &mut ctx);

        // Query viewport that fully contains the polygon
        let results = index::query_viewport(&idx, 0, 0, 2 * s, 2 * s);
        assert!(vector::length(&results) >= 1);

        // Query viewport far from the polygon — should return empty
        let results_far = index::query_viewport(&idx, 10 * s, 10 * s, 11 * s, 11 * s);
        assert!(vector::length(&results_far) == 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EQueryTooLarge, location = mercator::index)]
    /// F-25b: query_viewport with too-large span triggers EQueryTooLarge.
    fun f25b_query_viewport_too_large_rejected() {
        let mut ctx = tx_context::dummy();
        let idx = test_index(&mut ctx);

        // This fixture configures a 1024-cell broadphase span cap. With
        // cell_size = SCALE, a viewport spanning 1025*SCALE should be rejected.
        let s = SCALE;
        let _results = index::query_viewport(&idx, 0, 0, 1025 * s, s);

        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-14: World-spanning polygon registers at depth 0 (root cell)
    // ═════════════════════════════════════════════════════════════════════════════
    // A polygon covering most of the world fits in cell key = 1 (root).
    // Multiple such polygons degrade all broadphase queries.

    #[test]
    /// F-14 PoC: A large polygon registers at depth 0, creating a DoS vector.
    /// The polygon covers a large area and lands in the root cell.
    /// If this test PASSES, the issue is CONFIRMED — no size upper bound.
    fun f14_world_spanning_polygon_at_root_depth() {
        let mut ctx = tx_context::dummy();
        // Use max_depth=2, cell_size = SCALE → only 4×4 = 16 cells at finest level
        let mut idx = index::with_config(SCALE, 2, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let s = SCALE;
        // A polygon spanning 5×5 cells: at depth 2 (shift=0), 0≠4 → doesn't fit
        // at depth 1 (shift=1), 0>>1=0, 4>>1=2 → doesn't fit
        // at depth 0: returns 0 (root) → sits in root cell
        let id = index::register(
            &mut idx,
            vector[vector[0, 5 * s, 5 * s, 0]],
            vector[vector[0, 0, 5 * s, 5 * s]],
            &mut ctx,
        );

        // This polygon registers successfully with no size limit check
        assert!(index::count(&idx) == 1);

        // Polygon lands at depth 0 (root cell) — no upper bound prevents this
        let poly = index::get(&idx, id);
        let cells = polygon::cells(poly);
        assert!(vector::length(cells) == 1);
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-15: decrement_count aborts with generic arithmetic error
    // ═════════════════════════════════════════════════════════════════════════════
    // decrement_count doesn't check count > 0. On underflow, aborts with a
    // generic arithmetic error instead of a descriptive error code.

    #[test]
    #[expected_failure(abort_code = index::EIndexEmpty)]
    /// Fixed (F-15): decrement_count now aborts with EIndexEmpty instead
    /// of a generic arithmetic underflow.
    fun f15_decrement_count_generic_abort() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);

        // Index has count=0. Decrementing should abort.
        index::decrement_count(&mut idx);

        std::unit_test::destroy(idx);
    }

    #[test]
    /// DOS-01 PoC: registering a region at the maximum allowed broadphase span
    /// still succeeds, proving the protocol accepts the broadphase-bomb shape.
    fun dos01_broadphase_bomb_max_span_registration_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            31,
            64,
            10,
            1024,
            64,
            2_000_000,
            &mut ctx,
        );
        let max_span = 1024 * SCALE;
        let id = register_square(&mut idx, 0, 0, max_span, max_span, &mut ctx);

        assert!(index::count(&idx) == 1, 0);
        assert!(polygon::area(index::get(&idx, id)) == 1024 * 1024, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// DOS-02 PoC: many non-overlapping root-cell regions accumulate in one cell
    /// vector, and candidates() returns the entire accumulated set.
    fun dos02_hot_cell_vector_growth_returns_all_candidates() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            3,
            64,
            10,
            1024,
            64,
            2_000_000,
            &mut ctx,
        );
        let root_crossing_width = 4 * SCALE;
        let n = 8u64;
        let mut ids = vector::empty<object::ID>();
        let mut i = 0u64;
        while (i < n) {
            let y0 = i * SCALE;
            let y1 = y0 + SCALE;
            let id = register_square(&mut idx, 0, y0, root_crossing_width, y1, &mut ctx);
            vector::push_back(&mut ids, id);
            i = i + 1;
        };

        let query_id = register_square(
            &mut idx,
            0,
            n * SCALE,
            root_crossing_width,
            (n + 1) * SCALE,
            &mut ctx,
        );

        let cands = index::candidates(&idx, query_id);
        assert!(vector::length(&cands) == n, 0);

        let mut j = 0u64;
        while (j < n) {
            assert!(contains_id(&cands, *vector::borrow(&ids, j)), 1);
            j = j + 1;
        };
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EBroadphaseBudgetExceeded, location = mercator::index)]
    /// DOS-01 regression: once the index has regions at ≥2 distinct natural depths,
    /// a max-span broadphase query is rejected by the probe budget before it can
    /// iterate. Budget = span_x * span_y * popcount(occupied_depths) must be
    /// ≤ the configured probe budget (2_000_000). Here
    /// 1025 * 1025 * 2 = 2_101_250 > 2M.
    fun dos01_max_span_on_populated_index_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            DEFAULT_MAX_DEPTH, // 20
            64,
            10,
            1024,
            64,
            2_000_000,
            &mut ctx,
        );
        let _id_a = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        // Region B: grid coords (10..14). Natural depth = max_depth - 3.
        // Disjoint from A in both x and y.
        let _id_b = register_square(
            &mut idx,
            10 * SCALE,
            10 * SCALE,
            14 * SCALE,
            14 * SCALE,
            &mut ctx,
        );
        // occupied_depths now has at least two bits set → popcount ≥ 2.

        // Attacker attempts a max-span registration in a disjoint region far from
        // both incumbents. Budget check fires *before* any overlap iteration.
        let max_span = 1024 * SCALE;
        let _victim = register_square(
            &mut idx,
            100 * SCALE,
            100 * SCALE,
            100 * SCALE + max_span,
            100 * SCALE + max_span,
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = ECellOccupancyExceeded, location = mercator::index)]
    /// DOS-02 regression: register_in_cell aborts once a single cell reaches the
    /// configured occupancy cap (64). Uses fabricated IDs + a direct call so we
    /// exercise the cap without having to arrange 64 non-overlapping polygons at
    /// the same natural depth.
    fun dos02_cell_occupancy_cap_rejects_over_cap() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(
            SCALE,
            DEFAULT_MAX_DEPTH,
            64,
            10,
            1024,
            64,
            2_000_000,
            &mut ctx,
        );

        // Arbitrary fixed cell key — we just need one slot that starts empty.
        let cell_key: u64 = 42;
        let depth: u8 = 0;

        // Fill the cell up to exactly the configured occupancy cap (64).
        let mut i: u64 = 0;
        while (i < 64) {
            let id = object::id_from_address(sui::address::from_u256((i as u256) + 1));
            index::register_in_cell(&mut idx, id, cell_key, depth);
            i = i + 1;
        };

        // The 65th insertion of a fresh ID must abort with ECellOccupancyExceeded.
        let over_id = object::id_from_address(sui::address::from_u256(1000));
        index::register_in_cell(&mut idx, over_id, cell_key, depth);

        std::unit_test::destroy(idx);
    }

    #[test]
    fun two_polygons_same_cell_remove_one() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(4 * SCALE, 1, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let removed_id = register_rect(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let survivor_id = register_rect(&mut idx, 2 * SCALE, 0, 3 * SCALE, SCALE, &mut ctx);

        let removed = index::get(&idx, removed_id);
        let survivor = index::get(&idx, survivor_id);
        assert!(vector::length(polygon::cells(removed)) == 1, 0);
        assert!(vector::length(polygon::cells(survivor)) == 1, 1);
        assert!(
            *vector::borrow(polygon::cells(removed), 0)
            == *vector::borrow(polygon::cells(survivor), 0),
            2,
        );

        index::remove(&mut idx, removed_id, &mut ctx);
        assert!(index::count(&idx) == 1, 3);

        let survivor = index::get(&idx, survivor_id);
        let bounds = polygon::bounds(survivor);
        assert!(aabb::min_x(&bounds) == 2 * SCALE, 4);
        assert!(aabb::max_x(&bounds) == 3 * SCALE, 5);
        assert!(aabb::min_y(&bounds) == 0, 6);
        assert!(aabb::max_y(&bounds) == SCALE, 7);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun remove_last_polygon_cleans_cell() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(4 * SCALE, 1, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let first_id = register_rect(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let first_cell =
            *vector::borrow(
                polygon::cells(index::get(&idx, first_id)),
                0,
            );

        index::remove(&mut idx, first_id, &mut ctx);
        assert!(index::count(&idx) == 0, 0);

        let second_id = register_rect(&mut idx, 2 * SCALE, 0, 3 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 1);

        let second = index::get(&idx, second_id);
        assert!(vector::length(polygon::cells(second)) == 1, 2);
        assert!(*vector::borrow(polygon::cells(second), 0) == first_cell, 3);
        std::unit_test::destroy(idx);
    }

    // ─── 1. Cell boundary ─────────────────────────────────────────────────────────

    #[test]
    /// A polygon whose AABB aligns exactly with a quadtree cell boundary (here
    /// [SCALE, 2·SCALE] × [0, SCALE]) spans two cells at the finest depth and is
    /// therefore stored one level coarser than an identically-sized but
    /// cell-aligned polygon.  Both polygons must register successfully, be
    /// individually retrievable, and report no geometric overlap with each other
    /// (they touch along x = SCALE but strict-inequality AABB check rejects that
    /// as an overlap).
    fun cell_boundary_polygon_registers_and_reports_no_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = register_rect(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        // B straddles the grid boundary at x = SCALE; it cannot fit at depth 2
        // and is promoted to depth 1 (one level coarser).
        let id_b = register_rect(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);

        assert!(index::count(&idx) == 2, 0);

        // Both must be directly retrievable.
        let _pa = index::get(&idx, id_a);
        let _pb = index::get(&idx, id_b);

        // They share an edge at x = SCALE but do not geometrically overlap.
        assert!(vector::length(&index::overlapping(&idx, id_a)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, id_b)) == 0, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// A third polygon can be registered after the cell-boundary polygon without
    /// conflict, confirming the index stays consistent across depth levels.
    fun cell_boundary_polygon_does_not_corrupt_subsequent_registrations() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_b = register_rect(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);

        // Polygon entirely to the right — no shared cells.
        let id_c = register_rect(&mut idx, 4 * SCALE, 0, 5 * SCALE, SCALE, &mut ctx);

        assert!(index::count(&idx) == 2, 0);

        // No overlap between B and C — different coordinate ranges.
        assert!(vector::length(&index::overlapping(&idx, id_b)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, id_c)) == 0, 2);
        std::unit_test::destroy(idx);
    }

    // ─── 2. Edge-touching neighbours ──────────────────────────────────────────────

    #[test]
    /// Two 2m×2m squares sharing the exact edge at x = 2·SCALE must both
    /// register without error.  aabb::intersects uses strict (<, >) inequality,
    /// so A.max_x == B.min_x is NOT an intersection; the overlap set must be
    /// empty for both regions.
    fun edge_touching_polygons_both_register_with_no_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = register_rect(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let id_b = register_rect(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);

        assert!(index::count(&idx) == 2, 0);

        let _pa = index::get(&idx, id_a);
        let _pb = index::get(&idx, id_b);

        assert!(vector::length(&index::overlapping(&idx, id_a)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, id_b)) == 0, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Four squares arranged in a 2×2 grid, each touching two neighbours along
    /// full edges, must all register and report zero overlaps.
    fun four_grid_squares_share_edges_with_no_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let s = 2 * SCALE; // 2 m side length

        let id_a = register_rect(&mut idx, 0, 0, s, s, &mut ctx);
        let id_b = register_rect(&mut idx, s, 0, 2 * s, s, &mut ctx);
        let id_c = register_rect(&mut idx, 0, s, s, 2 * s, &mut ctx);
        let id_d = register_rect(&mut idx, s, s, 2 * s, 2 * s, &mut ctx);

        assert!(index::count(&idx) == 4, 0);

        assert!(vector::length(&index::overlapping(&idx, id_a)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, id_b)) == 0, 2);
        assert!(vector::length(&index::overlapping(&idx, id_c)) == 0, 3);
        assert!(vector::length(&index::overlapping(&idx, id_d)) == 0, 4);
        std::unit_test::destroy(idx);
    }
}
