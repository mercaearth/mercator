/// Correctness tests for the quadtree spatial index.
/// Validates hierarchical insertion, ancestor/descendant broadphase queries,
/// overlap detection, and multi-polygon scenarios.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::quadtree_tests {
    use mercator::{index, polygon};

    // === Constants ===

    const SCALE: u64 = 1_000_000;

    // === Helpers ===

    /// Create a quadtree index with max_depth=6 for fast test execution.
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

    // === Hierarchical Query Tests ===

    #[test]
    fun hierarchical_query_finds_both_ancestor_and_leaf() {
        // Core test: insert a massive polygon at a shallow ancestor node
        // and a tiny polygon at a deep leaf node. Query a region overlapping
        // both and verify BOTH IDs are returned by candidates().
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // Grid: (0,0)-(8,1). natural_depth with max_depth=6:
        //   depth=6 shift=0: 0!=8 fail; depth=5 shift=1: 0!=4 fail;
        //   depth=4 shift=2: 0!=2 fail; depth=3 shift=3: 0!=1 fail;
        //   depth=2 shift=4: 0>>4=0, 8>>4=0, 0>>4=0, 1>>4=0. Return 2.
        let id_large = register_square(&mut idx, 0, 0, 8, 1, &mut ctx);

        // Tiny polygon: 1-2m x, 3-4m y (non-overlapping, above id_large)
        // Grid: (1,3)-(2,4). natural_depth:
        //   depth=6 shift=0: 1!=2 fail; depth=5 shift=1: 0!=1 fail;
        //   depth=4 shift=2: 0==0, 0==1? 3>>2=0, 4>>2=1 fail;
        //   depth=3 shift=3: 0==0, 0==0. Return 3.
        let id_small = register_square(&mut idx, 1, 3, 2, 4, &mut ctx);

        // Both stored at exactly 1 cell each
        assert!(vector::length(polygon::cells(index::get(&idx, id_large))) == 1, 0);
        assert!(vector::length(polygon::cells(index::get(&idx, id_small))) == 1, 1);

        // Candidates for small polygon should include large (ancestor cell overlap)
        let cands_small = index::candidates(&idx, id_small);
        assert!(vector_contains(&cands_small, id_large), 2);

        // Candidates for large polygon should include small (descendant cell)
        let cands_large = index::candidates(&idx, id_large);
        assert!(vector_contains(&cands_large, id_small), 3);

        // overlapping() should return empty (they don't geometrically overlap)
        let overlaps = index::overlapping(&idx, id_small);
        assert!(vector::length(&overlaps) == 0, 4);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun three_depth_levels_all_found() {
        // Three polygons at three different depths in the same quadtree branch.
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_huge = register_square(&mut idx, 0, 0, 8, 1, &mut ctx);

        // Level 2 (mid): 0-2m × 3-4m → depth 3
        let id_mid = register_square(&mut idx, 0, 3, 2, 4, &mut ctx);

        // Level 3 (deepest): 10-11m × 5-6m → depth 4
        let id_tiny = register_square(&mut idx, 10, 5, 11, 6, &mut ctx);

        // id_mid at depth 3 shares ancestor cell (0,0) at depth 2 with id_huge.
        // So candidates for id_mid should include id_huge.
        let cands_mid = index::candidates(&idx, id_mid);
        assert!(vector_contains(&cands_mid, id_huge), 0);

        // id_huge's broadphase covers id_mid's cell at depth 3 (descendant).
        let cands_huge = index::candidates(&idx, id_huge);
        assert!(vector_contains(&cands_huge, id_mid), 1);

        // id_tiny queries should find id_huge as ancestor candidate
        // (at depth 2, id_tiny maps to cell (0,0) where id_huge is stored).
        let cands_tiny = index::candidates(&idx, id_tiny);
        assert!(vector_contains(&cands_tiny, id_huge), 2);
        std::unit_test::destroy(idx);
    }

    // === Registration Tests ===

    #[test]
    fun register_multipart_polygon() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let xs = vector[vector[0, SCALE, SCALE, 0], vector[SCALE, 2 * SCALE, 2 * SCALE, SCALE]];
        let ys = vector[vector[0, 0, SCALE, SCALE], vector[0, 0, SCALE, SCALE]];
        let id = index::register(&mut idx, xs, ys, &mut ctx);
        assert!(index::count(&idx) == 1, 0);

        let poly = index::get(&idx, id);
        assert!(polygon::parts(poly) == 2, 1);
        assert!(vector::length(polygon::cells(poly)) == 1, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun register_and_remove_leaves_empty_index() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id1 = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);
        let id2 = register_square(&mut idx, 5, 5, 6, 6, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        index::remove(&mut idx, id1, &mut ctx);
        index::remove(&mut idx, id2, &mut ctx);
        assert!(index::count(&idx) == 0, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun delete_and_reinsert_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id1 = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);
        index::remove(&mut idx, id1, &mut ctx);

        let _id2 = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);
        assert!(index::count(&idx) == 1, 0);
        std::unit_test::destroy(idx);
    }

    // === Overlap Detection Tests ===

    #[test]
    /// Companion to register_rejects_contained_polygon.
    /// The same outer polygon (0-4m) registers successfully, and a polygon placed
    /// completely outside it also registers.  Proves the EOverlap gate fires only
    /// when there is genuine containment, not on every second registration.
    fun register_outer_polygon_and_disjoint_neighbour_both_succeed() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _id1 = register_square(&mut idx, 0, 0, 4, 4, &mut ctx);
        let _id2 = register_square(&mut idx, 5, 5, 6, 6, &mut ctx);
        assert!(index::count(&idx) == 2, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::EOverlap)]
    fun register_rejects_contained_polygon() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _id1 = register_square(&mut idx, 0, 0, 4, 4, &mut ctx);
        let _id2 = register_square(&mut idx, 1, 1, 2, 2, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Companion to register_rejects_partial_overlap.
    /// The same first polygon (0-3m) registers successfully, and a non-overlapping
    /// polygon to its right (4-6m) also registers.  Proves the gate fires only on
    /// genuine partial overlap, not on all second registrations.
    fun register_first_polygon_and_non_overlapping_second_both_succeed() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _id1 = register_square(&mut idx, 0, 0, 3, 3, &mut ctx);
        let _id2 = register_square(&mut idx, 4, 0, 6, 3, &mut ctx);
        assert!(index::count(&idx) == 2, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::EOverlap)]
    fun register_rejects_partial_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _id1 = register_square(&mut idx, 0, 0, 3, 3, &mut ctx);
        let _id2 = register_square(&mut idx, 2, 2, 5, 5, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun register_accepts_edge_touching_polygons() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _id1 = register_square(&mut idx, 0, 0, 2, 2, &mut ctx);
        let _id2 = register_square(&mut idx, 2, 0, 4, 2, &mut ctx);
        assert!(index::count(&idx) == 2, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun overlapping_returns_empty_for_non_overlapping() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id1 = register_square(&mut idx, 0, 0, 2, 2, &mut ctx);
        let _id2 = register_square(&mut idx, 5, 5, 7, 7, &mut ctx);

        let result = index::overlapping(&idx, id1);
        assert!(vector::length(&result) == 0, 0);
        std::unit_test::destroy(idx);
    }

    // === Broadphase Precision Tests ===

    /// Four 1m×1m squares placed 2m apart along the x-axis.
    ///
    /// Cell assignment (max_depth=6, shift=1 at depth=5):
    ///   A=[0,1]m → depth-5 cell (0,0)
    ///   B=[2,3]m → depth-5 cell (1,0)
    ///   C=[4,5]m → depth-5 cell (2,0)
    ///   D=[6,7]m → depth-5 cell (3,0)
    ///
    /// None of these cells is an ancestor or descendant of any other.
    /// Therefore candidates() for every polygon must be empty.
    ///
    /// FALSE-POSITIVE GUARD: a broadphase implementation that always returns all
    /// registered polygons (or uses no spatial filtering at all) would put 3 IDs
    /// in each result, causing the length==0 assertions to fail.
    #[test]
    fun isolated_polygons_have_no_broadphase_candidates() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);
        let id_b = register_square(&mut idx, 2, 0, 3, 1, &mut ctx);
        let id_c = register_square(&mut idx, 4, 0, 5, 1, &mut ctx);
        let id_d = register_square(&mut idx, 6, 0, 7, 1, &mut ctx);
        assert!(index::count(&idx) == 4, 0);

        // Each polygon's candidate set must be empty: no other polygon shares
        // an ancestor cell or descendant cell with it.
        assert!(vector::length(&index::candidates(&idx, id_a)) == 0, 1);
        assert!(vector::length(&index::candidates(&idx, id_b)) == 0, 2);
        assert!(vector::length(&index::candidates(&idx, id_c)) == 0, 3);
        assert!(vector::length(&index::candidates(&idx, id_d)) == 0, 4);
        std::unit_test::destroy(idx);
    }

    /// Broadphase candidates is based on the exact ancestor/descendant cell path,
    /// not a global scan.
    ///
    /// Three polygons at mixed depths in max_depth=6 tree:
    ///
    ///   P = [0,1]m × [0,1]m  → depth-5, cell (0,0)
    ///   Q = [0,2]m × [1,2]m  → depth-4, cell (0,0)  [ancestor of P's cell]
    ///   B = [4,5]m × [0,1]m  → depth-5, cell (2,0)  [different branch entirely]
    ///
    /// P and Q are edge-adjacent (share y=1m edge) so they don't overlap.
    ///
    /// Expected:
    ///   candidates(P) = {Q}   — Q is stored at P's depth-4 ancestor cell
    ///   candidates(Q) = {P}   — P is stored inside Q's depth-5 subtree
    ///   candidates(B) = {}    — B's ancestor chain and subtree share no cells with P or Q
    ///
    /// SELECTIVITY PROOF: if candidates returned all registered polygons,
    /// B would appear in candidates(P) and candidates(Q).
    /// If candidates missed the ancestor relationship,
    /// Q would be absent from candidates(P) and P absent from candidates(Q).
    #[test]
    fun broadphase_candidates_is_selective_not_global() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_p = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);

        // Q: 2m×1m strip above P → depth-4 cell (0,0)  [ancestor of P's cell]
        // Grid [0,2]×[1,2]: at depth-4, shift=2: x 0>>2==2>>2==0, y 1>>2==2>>2==0 ✓
        let id_q = register_square(&mut idx, 0, 1, 2, 2, &mut ctx);

        // B: 1m×1m far to the right → depth-5 cell (2,0)  [different branch]
        let id_b = register_square(&mut idx, 4, 0, 5, 1, &mut ctx);

        assert!(index::count(&idx) == 3, 0);

        // P sees Q (ancestor) but not B (unrelated branch).
        let cands_p = index::candidates(&idx, id_p);
        assert!(vector_contains(&cands_p, id_q), 1);
        assert!(!vector_contains(&cands_p, id_b), 2);

        // Q sees P (descendant) but not B (unrelated branch).
        let cands_q = index::candidates(&idx, id_q);
        assert!(vector_contains(&cands_q, id_p), 3);
        assert!(!vector_contains(&cands_q, id_b), 4);

        // B's subtree shares no cells with P or Q.
        let cands_b = index::candidates(&idx, id_b);
        assert!(vector::length(&cands_b) == 0, 5);
        std::unit_test::destroy(idx);
    }

    // === Ownership Tests ===

    #[test]
    fun transfer_ownership_changes_owner() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);
        index::transfer_ownership(&mut idx, id, @0xBEEF, &ctx);

        let poly = index::get(&idx, id);
        assert!(polygon::owner(poly) == @0xBEEF, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun force_transfer_bypasses_ownership() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let cap = index::mint_transfer_cap_for_testing(&mut idx, &mut ctx);

        let id = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);
        index::force_transfer(&cap, &mut idx, id, @0xBEEF);

        let poly = index::get(&idx, id);
        assert!(polygon::owner(poly) == @0xBEEF, 0);
        std::unit_test::destroy(cap);
        std::unit_test::destroy(idx);
    }

    #[test]
    fun fresh_owner_auth_allows_registration() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let _id = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);
        assert!(index::count(&idx) == 1, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = index::ENotOwner)]
    fun non_owner_cannot_remove() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            let id = register_square(&mut idx, 0, 0, 1, 1, ctx);

            index::transfer_ownership(&mut idx, id, @0xBEEF, ctx);
            // Caller is @0xCAFE but owner is now @0xBEEF → should fail
            index::remove(&mut idx, id, ctx);
            std::unit_test::destroy(idx);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = index::ENotOwner)]
    fun non_owner_cannot_transfer_ownership_even_with_cap() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let mut idx = test_index(ctx);
            let id = register_square(&mut idx, 0, 0, 1, 1, ctx);
            index::transfer_ownership(&mut idx, id, @0xBEEF, ctx);
            index::transfer_ownership(&mut idx, id, @0xC0FFEE, ctx);
            std::unit_test::destroy(idx);
        };

        sui::test_scenario::end(scenario);
    }
}
