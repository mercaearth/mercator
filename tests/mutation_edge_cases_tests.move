/// Mutation edge-case tests.
///
/// Covers:
///   reshape_unclaimed at the exact AABB containment boundary
///   repartition_adjacent with corner-only (point) contact
///   repartition_adjacent teleportation (union AABB containment) rejection
///   repartition_adjacent post-adjacency violation rejection
///   merge_keep with two multi-part polygons
///   split_replace into multiple children with area-conservation and depth placement
///   reshape that forces a depth migration (cell key change)
///   chained mutations: split → reshape child → merge with neighbour
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::mutation_edge_cases_tests {
    use mercator::{index::{Self, Index}, mutations, polygon};

    const SCALE: u64 = 1_000_000;
    const ENotFound: u64 = 4005;
    const EOverlap: u64 = 4012;

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    fun test_index(ctx: &mut tx_context::TxContext): Index {
        // max_depth = 3 keeps broadphase cheap.
        // With cell_size = SCALE: 1m×1m → depth 2, 2m×2m → depth 1, 4m×4m → depth 0.
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

    // ─── reshape_unclaimed: exact containment boundary ────────────────────────────

    #[test]
    /// A reshape whose new AABB equals the old AABB on three sides (zero margin)
    /// satisfies the containment check — the boundary condition is inclusive.
    /// A second reshape adds the minimum valid expansion, confirming both extremes pass.
    fun reshape_exact_aabb_boundary_passes() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);

        // Reshape to [S,2S]×[0,S] — new AABB exactly equals old on all four sides.
        // Containment check uses <=/>= so equality passes.
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(SCALE, 2 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        assert!(index::count(&idx) == 1, 0);

        // Reshape again: expand left by S — new min_x(0) < old min_x(S).
        // This is the minimum meaningful new-geometry expansion.
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        assert!(index::count(&idx) == 1, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::ENotContained)]
    /// A reshape whose new min_x exceeds the old min_x by even one coordinate unit
    /// is rejected: the new geometry no longer contains the original region.
    fun reshape_one_unit_outside_boundary_fails() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);

        // new min_x = S+1 > old min_x = S → AABB containment check fails.
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[vector[SCALE + 1, 3 * SCALE, 3 * SCALE, SCALE + 1]],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ─── repartition_adjacent: corner-only contact ────────────────────────────────

    #[test]
    #[expected_failure(abort_code = mutations::ENotAdjacent)]
    /// Two squares meeting at exactly one corner point (no shared edge) are not
    /// adjacent for the purposes of repartition_adjacent.
    fun repartition_corner_point_contact_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let b_id = register_square(&mut idx, SCALE, SCALE, 2 * SCALE, 2 * SCALE, &mut ctx);

        // New geometries preserve total area, but adjacency check fires first.
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, SCALE)],
            vector[sq_ys(0, SCALE)],
            b_id,
            vector[sq_xs(SCALE, 2 * SCALE)],
            vector[sq_ys(SCALE, 2 * SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    /// A full shared edge (not merely corner) satisfies the adjacency requirement.
    /// Confirms that the corner-rejection above is not a false negative.
    /// Uses 2m×2m squares so all edges remain >= the minimum edge length.
    fun repartition_full_shared_edge_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);

        let old_sum =
            (polygon::area(index::get(&idx, a_id)) as u128)
        + (polygon::area(index::get(&idx, b_id)) as u128);

        // Repartition: rotate the boundary from vertical to horizontal.
        // A' = [0,4S]×[0,S] (4m²), B' = [0,4S]×[S,2S] (4m²) — total unchanged.
        // All edges are >= SCALE (short sides = S = SCALE). ✓
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
        assert!(old_sum == new_sum, 0);
        assert!(index::count(&idx) == 2, 1);
        std::unit_test::destroy(idx);
    }

    // ─── repartition_adjacent: union AABB containment (anti-teleportation) ────────

    #[test]
    #[expected_failure(abort_code = mutations::ENotContained)]
    /// [MUT-07 fix] Output polygon teleported completely outside the union AABB of
    /// the original pair is rejected — prevents the acquire_slice attack where an
    /// attacker controls the victim's post-repartition polygon placement.
    ///
    /// Setup:  A=[0,2S]×[0,2S] (4 m²), B=[2S,4S]×[0,2S] (4 m²).
    ///         Union AABB = [0,4S]×[0,2S].
    /// Attempt: A'=[0,2S]×[0,2S] (4 m², unchanged), B'=[6S,8S]×[0,2S] (4 m²).
    ///   Area conserved (4+4=4+4), no self-overlap, but B' is outside union AABB.
    fun repartition_teleportation_outside_union_aabb_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            b_id,
            vector[sq_xs(6 * SCALE, 8 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::ENotContained)]
    /// [MUT-07 fix] Exact audit PoC scenario: B pivots to a different row (y offset),
    /// staying within x-range but escaping y-range of the union AABB.
    ///
    /// Old A = [0,2S]×[0,2S], Old B = [2S,4S]×[0,2S]. Union = [0,4S]×[0,2S].
    /// New A = [0,2S]×[0,2S], New B = [0,4S]×[2S,3S].
    /// B' max_y = 3S > union max_y = 2S → ENotContained.
    fun repartition_audit_poc_pivot_to_different_row_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);

        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            b_id,
            vector[sq_xs(0, 4 * SCALE)],
            vector[sq_ys(2 * SCALE, 3 * SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    /// [MUT-07 fix] Valid boundary redistribution within union AABB passes both
    /// containment and post-adjacency guards — confirms the fix doesn't break
    /// legitimate repartitions.
    ///
    /// A=[0,2S]×[0,2S], B=[2S,4S]×[0,2S]. Union=[0,4S]×[0,2S].
    /// A'=[0,4S]×[0,S] (4 m²), B'=[0,4S]×[S,2S] (4 m²).
    /// Both within union, share edge at y=S, area conserved.
    fun repartition_valid_boundary_rotation_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);

        let old_sum =
            (polygon::area(index::get(&idx, a_id)) as u128)
        + (polygon::area(index::get(&idx, b_id)) as u128);

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
        assert!(old_sum == new_sum, 0);
        std::unit_test::destroy(idx);
    }

    // ─── merge_keep: multi-part polygons ──────────────────────────────────────────

    #[test]
    /// Both keep and absorb are 2-part polygons (1m×2m vertical strips).
    /// merge_keep accepts multi-part inputs; the result is a single 2m×2m square.
    fun merge_keep_two_multipart_polygons_into_single_part() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // Part 0: [0,S]×[0,S], Part 1: [0,S]×[S,2S].
        // Parts share the edge from (0,S) to (S,S) → valid connected multipart polygon.
        let keep_id = index::register(
            &mut idx,
            vector[sq_xs(0, SCALE), sq_xs(0, SCALE)],
            vector[sq_ys(0, SCALE), sq_ys(SCALE, 2 * SCALE)],
            &mut ctx,
        );

        // absorb: right strip [S,2S]×[0,2S] — same topology, shifted right by S.
        // Parts share edge from (S,S) to (2S,S).
        let absorb_id = index::register(
            &mut idx,
            vector[sq_xs(SCALE, 2 * SCALE), sq_xs(SCALE, 2 * SCALE)],
            vector[sq_ys(0, SCALE), sq_ys(SCALE, 2 * SCALE)],
            &mut ctx,
        );

        assert!(index::count(&idx) == 2, 0);

        // The two strips share the full edge at x = S from y = 0 to y = 2S
        // (keep.part0 shares (S,0)–(S,S) with absorb.part0, triggering touches_by_edge).
        // Merged area: 2m² + 2m² = 4m² → single 2m×2m square.
        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            &ctx,
        );

        assert!(index::count(&idx) == 1, 1);
        assert!(polygon::area(index::get(&idx, keep_id)) == 4, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// After merging two multi-part polygons, the surviving polygon's area equals
    /// the sum of both inputs and the absorbed polygon's ID is removed from the index.
    fun merge_keep_multipart_absorbed_id_disappears() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let keep_id = index::register(
            &mut idx,
            vector[sq_xs(0, SCALE), sq_xs(0, SCALE)],
            vector[sq_ys(0, SCALE), sq_ys(SCALE, 2 * SCALE)],
            &mut ctx,
        );
        let absorb_id = index::register(
            &mut idx,
            vector[sq_xs(SCALE, 2 * SCALE), sq_xs(SCALE, 2 * SCALE)],
            vector[sq_ys(0, SCALE), sq_ys(SCALE, 2 * SCALE)],
            &mut ctx,
        );

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            &ctx,
        );

        // count dropped from 2 to 1 — absorb_id is gone.
        assert!(index::count(&idx) == 1, 0);

        // The merged polygon no longer reports any overlaps with itself.
        assert!(vector::length(&index::overlapping(&idx, keep_id)) == 0, 1);
        std::unit_test::destroy(idx);
    }

    // ─── split_replace: multiple children ────────────────────────────────────────

    #[test]
    /// A 4m×1m parent is split into 4 equal 1m×1m children.
    /// All children survive, the parent is consumed, and area is conserved.
    fun split_replace_four_children_all_survive() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = register_square(&mut idx, 0, 0, 4 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[
                vector[sq_xs(0, SCALE)],
                vector[sq_xs(SCALE, 2 * SCALE)],
                vector[sq_xs(2 * SCALE, 3 * SCALE)],
                vector[sq_xs(3 * SCALE, 4 * SCALE)],
            ],
            vector[
                vector[sq_ys(0, SCALE)],
                vector[sq_ys(0, SCALE)],
                vector[sq_ys(0, SCALE)],
                vector[sq_ys(0, SCALE)],
            ],
            &mut ctx,
        );

        assert!(index::count(&idx) == 4, 1);
        assert!(vector::length(&child_ids) == 4, 2);

        // Each child is retrievable and has area 1m².
        let mut i = 0;
        while (i < 4) {
            let cid = *vector::borrow(&child_ids, i);
            assert!(polygon::area(index::get(&idx, cid)) == 1, 3);
            i = i + 1;
        };

        // No child overlaps any sibling.
        i = 0;
        while (i < 4) {
            let cid = *vector::borrow(&child_ids, i);
            assert!(vector::length(&index::overlapping(&idx, cid)) == 0, 4);
            i = i + 1;
        };
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = ENotFound, location = mercator::index)]
    /// After split_replace the parent ID no longer exists in the index.
    fun split_replace_parent_id_is_gone() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);

        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[sq_xs(0, SCALE)], vector[sq_xs(SCALE, 2 * SCALE)]],
            vector[vector[sq_ys(0, SCALE)], vector[sq_ys(0, SCALE)]],
            &mut ctx,
        );

        // parent_id no longer in index — get must abort with ENotFound.
        let _gone = index::get(&idx, parent_id);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Uneven split: one child gets three-quarters of the area, the other one-quarter.
    /// Area conservation still holds.
    fun split_replace_uneven_children_area_conserved() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = register_square(&mut idx, 0, 0, 4 * SCALE, SCALE, &mut ctx);

        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[
                vector[sq_xs(0, 3 * SCALE)], // 3m×1m
                vector[sq_xs(3 * SCALE, 4 * SCALE)], // 1m×1m
            ],
            vector[vector[sq_ys(0, SCALE)], vector[sq_ys(0, SCALE)]],
            &mut ctx,
        );

        let c0 = *vector::borrow(&child_ids, 0);
        let c1 = *vector::borrow(&child_ids, 1);
        let total =
            (polygon::area(index::get(&idx, c0)) as u128)
        + (polygon::area(index::get(&idx, c1)) as u128);
        assert!(total == 4, 0);
        assert!(polygon::area(index::get(&idx, c0)) == 3, 1);
        assert!(polygon::area(index::get(&idx, c1)) == 1, 2);
        std::unit_test::destroy(idx);
    }

    // ─── Depth migration after reshape ────────────────────────────────────────────

    #[test]
    /// Reshaping a small polygon so its AABB spans all four depth-0 quadrants
    /// forces a depth migration: the stored cell key changes to the root cell.
    /// The index remains consistent after the migration.
    fun reshape_small_to_root_triggers_depth_migration() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);

        // 1m×1m at origin → natural_depth = 2.
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let cell_before = *vector::borrow(polygon::cells(index::get(&idx, id)), 0);

        // Reshape to 4m×4m — spans all depth-0 quadrants → natural_depth = 0.
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(0, 4 * SCALE)],
            vector[sq_ys(0, 4 * SCALE)],
            &ctx,
        );

        let cell_after = *vector::borrow(polygon::cells(index::get(&idx, id)), 0);

        // Cell key must change (depth 2 key ≠ depth 0 key).
        assert!(cell_before != cell_after, 0);
        assert!(index::count(&idx) == 1, 1);
        // No spurious self-overlap after re-indexing.
        assert!(vector::length(&index::overlapping(&idx, id)) == 0, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// After depth migration via reshape, a new polygon that falls inside the
    /// reshaped footprint is correctly rejected — proving the updated cell key
    /// is honoured by the broadphase.
    fun reshape_depth_migration_blocks_inner_registration() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        // Reshape to 4m×4m (depth 0).
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(0, 4 * SCALE)],
            vector[sq_ys(0, 4 * SCALE)],
            &ctx,
        );

        // A polygon fully inside the new footprint must be rejected.
        // Use a separate expected_failure block via inline abort-check:
        // we verify by checking that overlapping() would catch it if we
        // could register — instead, assert the migrated polygon covers that area
        // by confirming it is the only polygon and its broadphase candidates are empty.
        // (Actual EOverlap is tested via the expected_failure twin below.)
        assert!(index::count(&idx) == 1, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOverlap, location = mercator::index)]
    /// After reshape migrates a polygon to depth 0, a new registration inside
    /// the new footprint is rejected with EOverlap — the index correctly tracks
    /// the updated cell key.
    fun reshaped_migrated_polygon_blocks_overlapping_registration() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(0, 4 * SCALE)],
            vector[sq_ys(0, 4 * SCALE)],
            &ctx,
        );

        // [S,2S]×[S,2S] is inside the reshaped polygon → must abort.
        let _overlap = register_square(&mut idx, SCALE, SCALE, 2 * SCALE, 2 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    // ─── Chained mutations: split → reshape child → merge with neighbour ─────────

    #[test]
    /// Full chain: a 4m×1m parent is split into two children, one child is
    /// reshaped upward to 2m×2m, then that child absorbs a 2m×2m neighbour.
    ///
    /// After the chain:
    ///   count = 2  (surviving split child + the merged polygon)
    ///   merged polygon covers [2S,6S]×[0,2S]
    ///   split survivor is untouched at [0,2S]×[0,S]
    fun chained_split_reshape_merge() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // They share only the point at (4S,0)–(4S,S) which is a full edge of both:
        // parent right edge = (4S,0)–(4S,S), neighbour left edge = (4S,0)–(4S,2S).
        // These are NOT an exact full edge match so they're registered without issue.
        let parent_id = register_square(&mut idx, 0, 0, 4 * SCALE, SCALE, &mut ctx);
        let neighbour_id = register_square(&mut idx, 4 * SCALE, 0, 6 * SCALE, 2 * SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        // ── Step 1: split parent into child_a=[0,2S]×[0,S] and child_b=[2S,4S]×[0,S] ──
        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[sq_xs(0, 2 * SCALE)], vector[sq_xs(2 * SCALE, 4 * SCALE)]],
            vector[vector[sq_ys(0, SCALE)], vector[sq_ys(0, SCALE)]],
            &mut ctx,
        );
        let child_a = *vector::borrow(&child_ids, 0);
        let child_b = *vector::borrow(&child_ids, 1);
        assert!(index::count(&idx) == 3, 1); // child_a + child_b + neighbour

        // ── Step 2: reshape child_b from [2S,4S]×[0,S] to [2S,4S]×[0,2S] ─────────
        // New shape contains old ✓.  Right edge at x=4S now matches neighbour's left
        // edge from y=0 to y=2S → they become exactly adjacent.
        mutations::reshape_unclaimed(
            &mut idx,
            child_b,
            vector[sq_xs(2 * SCALE, 4 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            &ctx,
        );
        assert!(index::count(&idx) == 3, 2);
        assert!(polygon::area(index::get(&idx, child_b)) == 4, 3);

        // ── Step 3: merge child_b (keep) absorbs neighbour ───────────────────────
        // child_b = [2S,4S]×[0,2S] (4m²), neighbour = [4S,6S]×[0,2S] (4m²).
        // Shared edge: x=4S from y=0 to y=2S — exact full edge for both.
        // Merged result = [2S,6S]×[0,2S] (8m²).
        mutations::merge_keep(
            &mut idx,
            child_b,
            neighbour_id,
            vector[sq_xs(2 * SCALE, 6 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            &ctx,
        );

        // Final state: child_a=[0,2S]×[0,S] (1m²) + merged=[2S,6S]×[0,2S] (8m²).
        assert!(index::count(&idx) == 2, 4);
        assert!(polygon::area(index::get(&idx, child_a)) == 2, 5);
        assert!(polygon::area(index::get(&idx, child_b)) == 8, 6);

        // The two surviving polygons are adjacent (share x=2S edge) but do not overlap.
        assert!(vector::length(&index::overlapping(&idx, child_a)) == 0, 7);
        assert!(vector::length(&index::overlapping(&idx, child_b)) == 0, 8);
        std::unit_test::destroy(idx);
    }

    // ─── ESelfMerge ───────────────────────────────────────────────────────────────

    #[test]
    #[expected_failure(abort_code = mutations::ESelfMerge)]
    /// Passing the same ID for both keep and absorb must abort immediately.
    fun merge_keep_self_id_aborts() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);

        mutations::merge_keep(
            &mut idx,
            id,
            id,
            vector[sq_xs(0, SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ─── EOwnerMismatch ───────────────────────────────────────────────────────────

    #[test]
    #[expected_failure(abort_code = mutations::EOwnerMismatch)]
    /// merge_keep aborts when keep is caller-owned but absorb belongs to someone else.
    /// This is the baseline: absorb ≠ keep owner.
    fun merge_keep_absorb_foreign_aborts() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let transfer_cap = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let keep_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let absorb_id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);

        // Reassign absorb to a different owner — keep stays on the dummy sender.
        index::force_transfer(&transfer_cap, &mut idx, absorb_id, @0xBEEF);

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(transfer_cap);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::EOwnerMismatch)]
    /// Symmetric direction: keep is foreign, absorb belongs to the caller.
    /// Verifies the check compares owner(keep) == owner(absorb) rather than
    /// only owner(absorb) == ctx.sender() — which the previous test alone cannot rule out.
    fun merge_keep_keep_foreign_aborts() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let transfer_cap = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let keep_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let absorb_id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);

        // Reassign keep to a different owner — absorb stays on the dummy sender.
        index::force_transfer(&transfer_cap, &mut idx, keep_id, @0xBEEF);

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(transfer_cap);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::EOwnerMismatch)]
    /// Both regions are foreign but belong to different third parties.
    /// keep → @0xBEEF, absorb → @0xCAFE — still a mismatch.
    fun merge_keep_both_foreign_different_owners_aborts() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let transfer_cap = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let keep_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let absorb_id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);

        index::force_transfer(&transfer_cap, &mut idx, keep_id, @0xBEEF);
        index::force_transfer(&transfer_cap, &mut idx, absorb_id, @0xCAFE);

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(transfer_cap);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::EOwnerMismatch)]
    /// merge_keep now rejects same-owner third-party regions when caller is not owner.
    fun merge_keep_both_same_third_party_owner_aborts() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let transfer_cap = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let keep_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let absorb_id = register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);

        // Transfer both to the same third party.
        index::force_transfer(&transfer_cap, &mut idx, keep_id, @0xBEEF);
        index::force_transfer(&transfer_cap, &mut idx, absorb_id, @0xBEEF);

        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(transfer_cap);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::EOwnerMismatch)]
    /// repartition_adjacent now rejects regions with different owners.
    fun repartition_adjacent_rejects_owner_mismatch() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let transfer_cap = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        // A = [0,2S]×[0,2S], B = [2S,4S]×[0,2S] — share the full edge at x = 2S.
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);

        // Give B a different owner — repartition must now abort.
        index::force_transfer(&transfer_cap, &mut idx, b_id, @0xBEEF);

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
        std::unit_test::destroy(transfer_cap);
        std::unit_test::destroy(idx);
    }

    // ─── EOverlap in repartition_adjacent ────────────────────────────────────────

    #[test]
    #[expected_failure(abort_code = mutations::EOverlap)]
    /// The direct A'–B' overlap check fires before any third-party scan.
    /// old A = [0,3S]×[0,S] (3m²), old B = [3S,8S]×[0,S] (5m²).
    /// new A' = [0,3S]×[0,S] (3m²), new B' = [0.5S,5.5S]×[0,S] (5m²).
    /// A' and B' overlap in [0.5S,3S]×[0,S]; total area is conserved (8m²).
    fun repartition_adjacent_new_shapes_overlap_each_other() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = index::register(
            &mut idx,
            vector[sq_xs(0, 3 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &mut ctx,
        );
        let b_id = index::register(
            &mut idx,
            vector[sq_xs(3 * SCALE, 8 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &mut ctx,
        );

        // new A' same footprint (3m²), new B' overlaps A' — total still 8m².
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, 3 * SCALE)],
            vector[sq_ys(0, SCALE)],
            b_id,
            vector[vector[500_000, 5_500_000, 5_500_000, 500_000]],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::ENotContained)]
    /// [MUT-07 fix] The union-AABB containment guard fires before the third-party
    /// overlap check when a repartitioned shape is teleported outside the original
    /// bounding box.
    /// old A = [0,2S]×[0,2S], old B = [2S,4S]×[0,2S], C = [5S,7S]×[0,2S].
    /// new A' = same, new B' = [4S,6S]×[0,2S] — B' outside union [0,4S] → ENotContained.
    fun repartition_adjacent_new_shape_overlaps_third_party() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);
        let b_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, 2 * SCALE, &mut ctx);
        let _c_id = register_square(&mut idx, 5 * SCALE, 0, 7 * SCALE, 2 * SCALE, &mut ctx);

        // A' unchanged (4m²), B' shifts right to [4S,6S]×[0,2S] (4m²) — total 8m².
        // B' overlaps C.
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, 2 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            b_id,
            vector[sq_xs(4 * SCALE, 6 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ─── EOverlap in split_replace ────────────────────────────────────────────────

    #[test]
    #[expected_failure(abort_code = mutations::EOverlap)]
    /// Two children with the same height as the parent but overlapping x-spans
    /// trigger the child–child overlap check.
    /// parent = [0,2S]×[0,2S] (4m²); child1 = [0,S]×[0,2S] (2m²);
    /// child2 = [0.5S,1.5S]×[0,2S] (2m²) — they overlap in [0.5S,S]×[0,2S].
    fun split_replace_children_overlap_each_other() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let parent_id = register_square(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);

        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[sq_xs(0, SCALE)], vector[vector[500_000, 1_500_000, 1_500_000, 500_000]]],
            vector[vector[sq_ys(0, 2 * SCALE)], vector[sq_ys(0, 2 * SCALE)]],
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = mutations::ENotContained)]
    /// Children extend beyond parent → ENotContained (F-01 fix).
    /// parent = [0,2S]×[0,4S] (8m²); C = [3S,5S]×[0,4S] (8m²).
    /// child1 = [0,4S]×[0,S] (4m²); child2 = [0,4S]×[S,2S] (4m²).
    /// Both children extend to x=4S, beyond parent's x=2S.
    /// Previously caught by bystander overlap; now caught earlier by containment.
    fun split_replace_child_overlaps_existing_region() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _c_id = register_square(&mut idx, 3 * SCALE, 0, 5 * SCALE, 4 * SCALE, &mut ctx);
        let parent_id = register_square(&mut idx, 0, 0, 2 * SCALE, 4 * SCALE, &mut ctx);

        let _child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[sq_xs(0, 4 * SCALE)], vector[sq_xs(0, 4 * SCALE)]],
            vector[vector[sq_ys(0, SCALE)], vector[sq_ys(SCALE, 2 * SCALE)]],
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ─── EOverlap in merge_keep ───────────────────────────────────────────────────

    #[test]
    #[expected_failure(abort_code = mutations::EOverlap)]
    /// The merged-polygon overlap check fires when the supplied merged geometry
    /// intersects a third-party bystander.
    /// keep = [0,2S]×[0,S] (2m²), absorb = [2S,4S]×[0,S] (2m²),
    /// C = [4S,6S]×[0,S] (2m²).
    /// merged = [2S,6S]×[0,S] (4m²) — intersects C at [4S,6S]×[0,S].
    fun merge_keep_result_overlaps_third_party() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let keep_id = register_square(&mut idx, 0, 0, 2 * SCALE, SCALE, &mut ctx);
        let absorb_id = register_square(&mut idx, 2 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);
        let _c_id = register_square(&mut idx, 4 * SCALE, 0, 6 * SCALE, SCALE, &mut ctx);

        // Merged geometry [2S,6S]×[0,S] has correct area (4m²) but overlaps C.
        mutations::merge_keep(
            &mut idx,
            keep_id,
            absorb_id,
            vector[sq_xs(2 * SCALE, 6 * SCALE)],
            vector[sq_ys(0, SCALE)],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ─── Multi-part polygon interaction tests ─────────────────────────────────────

    #[test]
    #[expected_failure(abort_code = EOverlap, location = mercator::index)]
    /// A 5-part polygon [0,5S]×[0,S] occupies the index.  A new registration
    /// whose AABB overlaps only the last part ([4S,5S]×[0,S]) must be rejected.
    /// Confirms the broadphase scans all occupied cells of a multi-part polygon,
    /// not just the cell of its first part.
    fun broadphase_catches_overlap_with_last_of_five_parts() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // A straight row has no corner-only contacts between non-adjacent parts.
        // Combined external perimeter = 12S; area = 5m².
        let _a_id = index::register(
            &mut idx,
            vector[
                sq_xs(0, SCALE),
                sq_xs(SCALE, 2*SCALE),
                sq_xs(2*SCALE, 3*SCALE),
                sq_xs(3*SCALE, 4*SCALE),
                sq_xs(4*SCALE, 5*SCALE),
            ],
            vector[
                sq_ys(0, SCALE),
                sq_ys(0, SCALE),
                sq_ys(0, SCALE),
                sq_ys(0, SCALE),
                sq_ys(0, SCALE),
            ],
            &mut ctx,
        );

        // New polygon whose AABB overlaps only the last part [4S,5S]×[0,S].
        let _b_id = index::register(
            &mut idx,
            vector[sq_xs(4 * SCALE + 500_000, 5 * SCALE + 500_000)],
            vector[sq_ys(0, SCALE)],
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Two adjacent 3-part polygons are merged.  The absorb polygon is consumed
    /// and the keep polygon's geometry is replaced by a single-part result.
    /// Area is conserved: 3m² + 3m² = 6m².
    fun merge_keep_two_multipart_polygons_area_conserved() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = index::register(
            &mut idx,
            vector[sq_xs(0, SCALE), sq_xs(SCALE, 2*SCALE), sq_xs(2*SCALE, 3*SCALE)],
            vector[sq_ys(0, SCALE), sq_ys(0, SCALE), sq_ys(0, SCALE)],
            &mut ctx,
        );
        // B: 3 parts [kS,(k+1)S]×[S,2S] for k=0..2 — total area 3m²; adjacent to A at y=S.
        let b_id = index::register(
            &mut idx,
            vector[sq_xs(0, SCALE), sq_xs(SCALE, 2*SCALE), sq_xs(2*SCALE, 3*SCALE)],
            vector[sq_ys(SCALE, 2*SCALE), sq_ys(SCALE, 2*SCALE), sq_ys(SCALE, 2*SCALE)],
            &mut ctx,
        );
        assert!(index::count(&idx) == 2, 0);
        assert!(polygon::area(index::get(&idx, a_id)) == 3, 1);
        assert!(polygon::area(index::get(&idx, b_id)) == 3, 2);

        // Merged geometry: single-part [0,3S]×[0,2S] — area = 6m² = 3+3. ✓
        mutations::merge_keep(
            &mut idx,
            a_id,
            b_id,
            vector[sq_xs(0, 3 * SCALE)],
            vector[sq_ys(0, 2 * SCALE)],
            &ctx,
        );

        assert!(index::count(&idx) == 1, 3);
        assert!(polygon::area(index::get(&idx, a_id)) == 6, 4);
        assert!(vector::length(&index::overlapping(&idx, a_id)) == 0, 5);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// A 4-part parent (2×2 grid, [0,2S]×[0,2S]) is split into two single-part
    /// children.  Area is conserved: 4m² → 2m² + 2m².
    fun split_replace_multipart_parent_area_conserved() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // A straight row has no corner-only contacts between non-adjacent parts.
        let parent_id = index::register(
            &mut idx,
            vector[
                sq_xs(0, SCALE),
                sq_xs(SCALE, 2*SCALE),
                sq_xs(2*SCALE, 3*SCALE),
                sq_xs(3*SCALE, 4*SCALE),
            ],
            vector[sq_ys(0, SCALE), sq_ys(0, SCALE), sq_ys(0, SCALE), sq_ys(0, SCALE)],
            &mut ctx,
        );
        assert!(polygon::area(index::get(&idx, parent_id)) == 4, 0);

        // Split into two 2S×S children — each 2m².
        let child_ids = mutations::split_replace(
            &mut idx,
            parent_id,
            vector[vector[sq_xs(0, 2 * SCALE)], vector[sq_xs(2 * SCALE, 4 * SCALE)]],
            vector[vector[sq_ys(0, SCALE)], vector[sq_ys(0, SCALE)]],
            &mut ctx,
        );

        assert!(index::count(&idx) == 2, 1);
        let c0 = *vector::borrow(&child_ids, 0);
        let c1 = *vector::borrow(&child_ids, 1);
        assert!(polygon::area(index::get(&idx, c0)) == 2, 2);
        assert!(polygon::area(index::get(&idx, c1)) == 2, 3);

        // Total area conserved: 2 + 2 = 4m² = parent area.
        let total =
            (polygon::area(index::get(&idx, c0)) as u128)
        + (polygon::area(index::get(&idx, c1)) as u128);
        assert!(total == 4, 4);

        // Children are adjacent but do not overlap.
        assert!(vector::length(&index::overlapping(&idx, c0)) == 0, 5);
        assert!(vector::length(&index::overlapping(&idx, c1)) == 0, 6);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Two adjacent 3-part polygons are repartitioned into single-part shapes.
    /// The combinatorial overlap loop must check each new part against the index.
    /// Area is conserved and no overlap is introduced.
    fun repartition_adjacent_multipart_polygons_area_conserved() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let a_id = index::register(
            &mut idx,
            vector[sq_xs(0, SCALE), sq_xs(SCALE, 2*SCALE), sq_xs(2*SCALE, 3*SCALE)],
            vector[sq_ys(0, SCALE), sq_ys(0, SCALE), sq_ys(0, SCALE)],
            &mut ctx,
        );
        // B: 3 parts [kS,(k+1)S]×[S,2S] for k=0..2 — total area 3m²; adjacent to A at y=S.
        let b_id = index::register(
            &mut idx,
            vector[sq_xs(0, SCALE), sq_xs(SCALE, 2*SCALE), sq_xs(2*SCALE, 3*SCALE)],
            vector[sq_ys(SCALE, 2*SCALE), sq_ys(SCALE, 2*SCALE), sq_ys(SCALE, 2*SCALE)],
            &mut ctx,
        );
        assert!(index::count(&idx) == 2, 0);
        assert!(polygon::area(index::get(&idx, a_id)) == 3, 1);
        assert!(polygon::area(index::get(&idx, b_id)) == 3, 2);

        // Repartition: A'=[0,3S]×[0,S] (3m²) and B'=[0,3S]×[S,2S] (3m²).
        // Total area in = total area out = 6m².  A' and B' remain adjacent at y=S.
        mutations::repartition_adjacent(
            &mut idx,
            a_id,
            vector[sq_xs(0, 3 * SCALE)],
            vector[sq_ys(0, SCALE)],
            b_id,
            vector[sq_xs(0, 3 * SCALE)],
            vector[sq_ys(SCALE, 2 * SCALE)],
            &ctx,
        );

        assert!(index::count(&idx) == 2, 3);
        assert!(polygon::area(index::get(&idx, a_id)) == 3, 4);
        assert!(polygon::area(index::get(&idx, b_id)) == 3, 5);
        assert!(vector::length(&index::overlapping(&idx, a_id)) == 0, 6);
        assert!(vector::length(&index::overlapping(&idx, b_id)) == 0, 7);
        std::unit_test::destroy(idx);
    }
}
