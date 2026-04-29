/// Behavioral tests for the `occupied_depths` bitmask in broadphase queries.
/// Validates that the bitmask correctly tracks which quadtree depths contain
/// polygons, enabling the depth-skip optimization without breaking correctness.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::broadphase_bitmask_tests {
    use mercator::index;

    const SCALE: u64 = 1_000_000;

    // === Helpers ===

    /// Quadtree with max_depth=6, cell_size=SCALE.
    /// World = 64m × 64m with 1m finest-level cells.
    fun test_index(ctx: &mut tx_context::TxContext): index::Index {
        index::with_config(SCALE, 6, 64, 10, 1024, 64, 2_000_000, ctx)
    }

    /// Register a square polygon from (x1,y1) to (x2,y2) in meters.
    fun register_square(
        idx: &mut index::Index,
        x1: u64,
        y1: u64,
        x2: u64,
        y2: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        let xs = vector[vector[x1 * SCALE, x2 * SCALE, x2 * SCALE, x1 * SCALE]];
        let ys = vector[vector[y1 * SCALE, y1 * SCALE, y2 * SCALE, y2 * SCALE]];
        index::register(idx, xs, ys, ctx)
    }

    fun vector_contains(v: &vector<object::ID>, id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) {
                return true
            };
            i = i + 1;
        };
        false
    }

    // === Test A: bitmask bit set on registration ===

    #[test]
    /// Register a polygon and verify broadphase finds it via viewport query.
    /// Proves the occupied_depths bitmask bit was set for the polygon's natural
    /// depth, causing broadphase to scan that depth and discover the polygon.
    fun bitmask_registers_depth_on_polygon_add() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // (shift=1: 0>>1=0, 1>>1=0 for both axes)
        let id = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);

        // query_viewport over the polygon's location must find it.
        // If the bitmask bit for depth 5 were not set, broadphase would skip
        // that depth entirely and return empty.
        let results = index::query_viewport(&idx, 0, 0, SCALE, SCALE);
        assert!(vector_contains(&results, id), 0);
        std::unit_test::destroy(idx);
    }

    // === Test B: empty bitmask skips all depths ===

    #[test]
    /// An empty index has occupied_depths = 0. A broadphase query over the entire
    /// world must return an empty result because every depth is skipped by the
    /// bitmask — no iterations, no table lookups.
    fun bitmask_empty_index_finds_nothing() {
        let mut ctx = tx_context::dummy();
        let idx = test_index(&mut ctx);

        // World = 2^6 = 64 cells per axis = 64m × 64m.
        // The fixture's configured span cap is 1024, so the full-world query is valid.
        let world_max = 64 * SCALE;
        let results = index::query_viewport(&idx, 0, 0, world_max, world_max);
        assert!(vector::length(&results) == 0, 0);

        std::unit_test::destroy(idx);
    }

    // === Test C: overlap detection still works with bitmask ===

    #[test]
    #[expected_failure(abort_code = index::EOverlap)]
    /// Overlap detection must still work correctly with the bitmask optimization.
    /// Register polygon A, then attempt to register overlapping polygon B.
    /// The broadphase must find A as a candidate (bitmask bit set) and the
    /// narrowphase must detect the geometric overlap → abort with EOverlap.
    fun bitmask_overlap_detection_preserved() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _id_a = register_square(&mut idx, 0, 0, 4, 4, &mut ctx);
        // B: 1-2m × 1-2m (fully contained in A → geometric overlap)
        let _id_b = register_square(&mut idx, 1, 1, 2, 2, &mut ctx);
        std::unit_test::destroy(idx);
    }

    // === Test D: multiple depth bits tracked simultaneously ===

    #[test]
    /// Register 3 polygons at three different natural depths (via different sizes).
    /// Verify each polygon is discoverable and candidates() finds spatially nearby
    /// polygons stored at other depths. Proves the bitmask correctly tracks
    /// multiple occupied depth bits simultaneously.
    ///
    /// Layout (max_depth=6, cell_size=1m):
    ///   large:  0-8m × 0-1m  → depth 2 (shift=4: 0>>4=0, 8>>4=0)
    ///   medium: 0-2m × 3-4m  → depth 3 (shift=3: 0>>3=0, 2>>3=0)
    ///   small:  0-1m × 6-7m  → depth 5 (shift=1: 0>>1=0, 1>>1=0)
    ///
    /// All three share ancestor cell (0,0) at depths ≤2, so candidates()
    /// discovers cross-depth relationships via the ancestor/descendant scan.
    fun bitmask_finds_polygons_across_multiple_depths() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_large = register_square(&mut idx, 0, 0, 8, 1, &mut ctx);

        // Medium: 0-2m × 3-4m → depth 3 (non-overlapping, above large)
        let id_medium = register_square(&mut idx, 0, 3, 2, 4, &mut ctx);

        // Small: 0-1m × 6-7m → depth 5 (non-overlapping, above medium)
        let id_small = register_square(&mut idx, 0, 6, 1, 7, &mut ctx);

        assert!(index::count(&idx) == 3, 0);

        // Verify each polygon is findable at its own location via viewport query.
        // Each query exercises a different depth bit in the bitmask.
        let r_large = index::query_viewport(&idx, 0, 0, 8 * SCALE, SCALE);
        assert!(vector_contains(&r_large, id_large), 1);

        let r_medium = index::query_viewport(&idx, 0, 3 * SCALE, 2 * SCALE, 4 * SCALE);
        assert!(vector_contains(&r_medium, id_medium), 2);

        let r_small = index::query_viewport(&idx, 0, 6 * SCALE, SCALE, 7 * SCALE);
        assert!(vector_contains(&r_small, id_small), 3);

        // Cross-depth discovery via candidates():
        // Small (depth 5) finds large (depth 2) and medium (depth 3) as ancestors.
        let cands_small = index::candidates(&idx, id_small);
        assert!(vector_contains(&cands_small, id_large), 4);
        assert!(vector_contains(&cands_small, id_medium), 5);

        // Medium (depth 3) finds large (depth 2) as ancestor.
        let cands_medium = index::candidates(&idx, id_medium);
        assert!(vector_contains(&cands_medium, id_large), 6);

        // Large (depth 2) finds medium (depth 3) as descendant.
        let cands_large = index::candidates(&idx, id_large);
        assert!(vector_contains(&cands_large, id_medium), 7);
        std::unit_test::destroy(idx);
    }
}
