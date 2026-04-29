/// Tests for Index sharing entry points: share(), share_existing(), share_with_config().
///
/// These are the real-deployment entry points that publish an Index as a
/// Sui shared object.  The tests verify that each path:
///   - produces a shared object visible to subsequent transactions,
///   - stores the expected configuration parameters, and
///   - yields a fully functional index (registration, removal, etc.).
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::index_sharing_tests {
    use mercator::{aabb, index::{Self, EBadCellSize, EBadMaxDepth, ETooManyParts, Index}, polygon};
    use sui::test_scenario;

    const ADMIN: address = @0xCAFE;
    const USER: address = @0xBEEF;
    const SCALE: u64 = 1_000_000;
    const DEPTH: u8 = 20;

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    fun register_unit_square(idx: &mut Index, s: &mut sui::test_scenario::Scenario): object::ID {
        index::register(
            idx,
            vector[vector[0u64, SCALE, SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            test_scenario::ctx(s),
        )
    }

    // ─── share() ─────────────────────────────────────────────────────────────────

    #[test]
    /// share() publishes a shared Index with the protocol default configuration.
    fun share_produces_shared_object_with_default_config() {
        let mut s = test_scenario::begin(ADMIN);
        {
            index::share(test_scenario::ctx(&mut s));
        };
        test_scenario::next_tx(&mut s, ADMIN);
        {
            let idx = test_scenario::take_shared<Index>(&s);
            assert!(index::cell_size(&idx) == SCALE, 0);
            assert!(index::max_depth(&idx) == DEPTH, 1);
            assert!(index::count(&idx)     == 0, 2);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    #[test]
    /// The Index produced by share() accepts polygon registration from any caller.
    fun share_index_accepts_registration() {
        let mut s = test_scenario::begin(ADMIN);
        { index::share(test_scenario::ctx(&mut s)); };

        test_scenario::next_tx(&mut s, USER);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            register_unit_square(&mut idx, &mut s);
            assert!(index::count(&idx) == 1, 0);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    #[test]
    /// Multiple callers can use the same shared index in separate transactions.
    fun share_index_is_accessible_across_transactions() {
        let mut s = test_scenario::begin(ADMIN);
        { index::share(test_scenario::ctx(&mut s)); };

        test_scenario::next_tx(&mut s, ADMIN);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            register_unit_square(&mut idx, &mut s);
            test_scenario::return_shared(idx);
        };

        // A different address accesses the same shared object in the next tx.
        test_scenario::next_tx(&mut s, USER);
        {
            let idx = test_scenario::take_shared<Index>(&s);
            assert!(index::count(&idx) == 1, 0);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    // ─── share_existing() ────────────────────────────────────────────────────────

    #[test]
    /// share_existing() converts an owned Index into a shared object;
    /// it is then visible to subsequent transactions.
    fun share_existing_makes_index_accessible_as_shared() {
        let mut s = test_scenario::begin(ADMIN);
        {
            let idx = index::new(test_scenario::ctx(&mut s));
            index::share_existing(idx);
        };
        test_scenario::next_tx(&mut s, ADMIN);
        {
            let idx = test_scenario::take_shared<Index>(&s);
            assert!(index::count(&idx) == 0, 0);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    #[test]
    /// share_existing() preserves all configuration of the owned Index,
    /// including a custom cell_size and max_depth.
    fun share_existing_preserves_custom_config() {
        let custom_cell: u64 = 500_000;
        let custom_depth: u8 = 12;

        let mut s = test_scenario::begin(ADMIN);
        {
            let idx = index::with_config(
                custom_cell,
                custom_depth,
                64,
                10,
                1024,
                64,
                2_000_000,
                test_scenario::ctx(&mut s),
            );
            index::share_existing(idx);
        };
        test_scenario::next_tx(&mut s, ADMIN);
        {
            let idx = test_scenario::take_shared<Index>(&s);
            assert!(index::cell_size(&idx) == custom_cell, 0);
            assert!(index::max_depth(&idx) == custom_depth, 1);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    #[test]
    /// An Index that already holds regions can be shared via share_existing();
    /// the region count survives the conversion to a shared object.
    fun share_existing_retains_pre_existing_regions() {
        let mut s = test_scenario::begin(ADMIN);
        {
            let ctx = test_scenario::ctx(&mut s);
            let mut idx = index::new(ctx);
            index::register(
                &mut idx,
                vector[vector[0u64, SCALE, SCALE, 0u64]],
                vector[vector[0u64, 0u64, SCALE, SCALE]],
                ctx,
            );
            index::share_existing(idx);
        };
        test_scenario::next_tx(&mut s, USER);
        {
            let idx = test_scenario::take_shared<Index>(&s);
            // Count must still be 1 — the polygon was not lost during sharing.
            assert!(index::count(&idx) == 1, 0);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    // ─── share_with_config() ─────────────────────────────────────────────────────

    #[test]
    /// share_with_config() stores the supplied cell_size and max_depth verbatim.
    fun share_with_config_stores_custom_cell_size_and_depth() {
        let custom_cell: u64 = 2_000_000;
        let custom_depth: u8 = 15;

        let mut s = test_scenario::begin(ADMIN);
        {
            index::share_with_config(
                custom_cell,
                custom_depth,
                64,
                10,
                1024,
                64,
                2_000_000,
                test_scenario::ctx(&mut s),
            );
        };
        test_scenario::next_tx(&mut s, ADMIN);
        {
            let idx = test_scenario::take_shared<Index>(&s);
            assert!(index::cell_size(&idx) == custom_cell, 0);
            assert!(index::max_depth(&idx) == custom_depth, 1);
            assert!(index::count(&idx)     == 0, 2);
            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    #[test]
    /// share_with_config() produces a functional index: registration and removal
    /// both work on the resulting shared object.
    fun share_with_config_index_is_functional() {
        let mut s = test_scenario::begin(ADMIN);
        {
            index::share_with_config(
                SCALE,
                DEPTH,
                64,
                10,
                1024,
                64,
                2_000_000,
                test_scenario::ctx(&mut s),
            );
        };
        test_scenario::next_tx(&mut s, ADMIN);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            let id = register_unit_square(&mut idx, &mut s);
            assert!(index::count(&idx) == 1, 0);

            index::remove(&mut idx, id, test_scenario::ctx(&mut s));
            assert!(index::count(&idx) == 0, 1);

            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    #[test]
    #[expected_failure(abort_code = ETooManyParts)]
    /// share_with_config() bakes the max_parts limit into the shared index;
    /// registrations that exceed it are rejected.
    fun share_with_config_enforces_max_parts() {
        let mut s = test_scenario::begin(ADMIN);
        // max_parts = 1
        {
            index::share_with_config(
                SCALE,
                DEPTH,
                64,
                1,
                1024,
                64,
                2_000_000,
                test_scenario::ctx(&mut s),
            );
        };

        test_scenario::next_tx(&mut s, ADMIN);
        {
            let mut idx = test_scenario::take_shared<Index>(&s);
            index::register(
                &mut idx,
                vector[
                    vector[0u64, SCALE, SCALE, 0u64],
                    vector[SCALE, 2 * SCALE, 2 * SCALE, SCALE],
                ],
                vector[vector[0u64, 0u64, SCALE, SCALE], vector[0u64, 0u64, SCALE, SCALE]],
                test_scenario::ctx(&mut s),
            );
            test_scenario::return_shared(idx);
        };
        test_scenario::end(s);
    }

    #[test]
    #[expected_failure(abort_code = EBadCellSize)]
    /// share_with_config() rejects a zero cell_size before creating the object.
    fun share_with_config_rejects_zero_cell_size() {
        let mut s = test_scenario::begin(ADMIN);
        {
            index::share_with_config(
                0,
                DEPTH,
                64,
                10,
                1024,
                64,
                2_000_000,
                test_scenario::ctx(&mut s),
            );
        };
        test_scenario::end(s);
    }

    #[test]
    #[expected_failure(abort_code = EBadMaxDepth)]
    /// share_with_config() rejects a zero max_depth before creating the object.
    fun share_with_config_rejects_zero_max_depth() {
        let mut s = test_scenario::begin(ADMIN);
        {
            index::share_with_config(
                SCALE,
                0,
                64,
                10,
                1024,
                64,
                2_000_000,
                test_scenario::ctx(&mut s),
            );
        };
        test_scenario::end(s);
    }

    // ─── Config behavior ─────────────────────────────────────────────────────────

    #[test]
    /// cell_size controls how polygon coordinates are projected onto the quadtree grid.
    /// A larger cell_size shrinks the polygon in grid space (it spans fewer cells),
    /// allowing it to be stored at a deeper quadtree level.
    /// A smaller cell_size expands the polygon in grid space, forcing it shallower.
    ///
    /// Concrete example with a SCALE×SCALE polygon and DEPTH=20:
    ///   cell_size = 2×SCALE → grid coords [0..0] (point) → stored at depth 20
    ///   cell_size =   SCALE → grid coords [0..1]          → stored at depth 19
    ///   cell_size = SCALE/2 → grid coords [0..2]          → stored at depth 18
    fun cell_size_determines_quadtree_depth() {
        let mut s = test_scenario::begin(ADMIN);
        {
            let ctx = test_scenario::ctx(&mut s);
            let bounds = aabb::new(0, 0, SCALE, SCALE);

            // Coarse: 2×SCALE → grid [0..0] → deepest placement (depth == DEPTH)
            let idx = index::with_config(2 * SCALE, DEPTH, 64, 10, 1024, 64, 2_000_000, ctx);
            let (lo_x, lo_y, hi_x, hi_y) = index::grid_bounds_for_aabb(&idx, &bounds);
            let depth_coarse = index::natural_depth(lo_x, lo_y, hi_x, hi_y, DEPTH);
            std::unit_test::destroy(idx);

            // Default: SCALE → grid [0..1] → one level shallower (depth == DEPTH − 1)
            let idx = index::with_config(SCALE, DEPTH, 64, 10, 1024, 64, 2_000_000, ctx);
            let (lo_x, lo_y, hi_x, hi_y) = index::grid_bounds_for_aabb(&idx, &bounds);
            let depth_default = index::natural_depth(lo_x, lo_y, hi_x, hi_y, DEPTH);
            std::unit_test::destroy(idx);

            // Fine: SCALE/2 → grid [0..2] → two levels shallower (depth == DEPTH − 2)
            let idx = index::with_config(SCALE / 2, DEPTH, 64, 10, 1024, 64, 2_000_000, ctx);
            let (lo_x, lo_y, hi_x, hi_y) = index::grid_bounds_for_aabb(&idx, &bounds);
            let depth_fine = index::natural_depth(lo_x, lo_y, hi_x, hi_y, DEPTH);
            std::unit_test::destroy(idx);

            assert!(depth_coarse == DEPTH, 0); // 20: point in grid space → max depth
            assert!(depth_default == DEPTH - 1, 1); // 19
            assert!(depth_fine    == DEPTH - 2, 2); // 18
            // The three cell sizes produce three strictly different placements.
            assert!(depth_coarse > depth_default, 3);
            assert!(depth_default > depth_fine, 4);
        };
        test_scenario::end(s);
    }

    #[test]
    /// max_depth caps the finest resolution level in the quadtree.
    /// The same polygon at the same cell_size lands at different absolute depths
    /// depending on max_depth: grid coords are the same ([0..1]), but the depth
    /// assigned is relative to max_depth, so a shallower tree produces a lower number.
    fun max_depth_caps_polygon_placement_depth() {
        let mut s = test_scenario::begin(ADMIN);
        {
            let ctx = test_scenario::ctx(&mut s);
            let bounds = aabb::new(0, 0, SCALE, SCALE);

            // Deep tree: max_depth=20 → polygon placed at depth 19
            let idx = index::with_config(SCALE, 20, 64, 10, 1024, 64, 2_000_000, ctx);
            let (lo_x, lo_y, hi_x, hi_y) = index::grid_bounds_for_aabb(&idx, &bounds);
            let depth_deep = index::natural_depth(lo_x, lo_y, hi_x, hi_y, 20);
            std::unit_test::destroy(idx);

            // Shallow tree: max_depth=10 → same grid coords, but placed at depth 9
            let idx = index::with_config(SCALE, 10, 64, 10, 1024, 64, 2_000_000, ctx);
            let (lo_x, lo_y, hi_x, hi_y) = index::grid_bounds_for_aabb(&idx, &bounds);
            let depth_shallow = index::natural_depth(lo_x, lo_y, hi_x, hi_y, 10);
            std::unit_test::destroy(idx);

            assert!(depth_deep    == 19, 0);
            assert!(depth_shallow == 9, 1);
            // max_depth is not just metadata — it changes where polygons are stored.
            assert!(depth_deep != depth_shallow, 2);
        };
        test_scenario::end(s);
    }

    #[test]
    /// End-to-end: two indexes with different cell sizes store the same polygon under
    /// different cell keys.  The config actively routes data, not merely labels it.
    fun cell_size_changes_cell_key_of_registered_polygon() {
        let mut s = test_scenario::begin(ADMIN);
        {
            let ctx = test_scenario::ctx(&mut s);
            let mut idx_coarse = index::with_config(
                2 * SCALE,
                DEPTH,
                64,
                10,
                1024,
                64,
                2_000_000,
                ctx,
            );
            let xs = vector[vector[0u64, SCALE, SCALE, 0u64]];
            let ys = vector[vector[0u64, 0u64, SCALE, SCALE]];

            // Register in a coarse index (2×SCALE).
            let id_coarse = index::register(&mut idx_coarse, xs, ys, ctx);
            let cell_coarse =
                *vector::borrow(polygon::cells(index::get(&idx_coarse, id_coarse)), 0);

            // Register the identical polygon in a fine index (SCALE/2).
            let mut idx_fine = index::with_config(
                SCALE / 2,
                DEPTH,
                64,
                10,
                1024,
                64,
                2_000_000,
                ctx,
            );
            let id_fine = index::register(&mut idx_fine, xs, ys, ctx);
            let cell_fine = *vector::borrow(polygon::cells(index::get(&idx_fine, id_fine)), 0);

            // Different cell_size → different cell key (depth encoded in sentinel bit differs).
            assert!(cell_coarse != cell_fine, 0);

            std::unit_test::destroy(idx_coarse);
            std::unit_test::destroy(idx_fine);
        };
        test_scenario::end(s);
    }
}
