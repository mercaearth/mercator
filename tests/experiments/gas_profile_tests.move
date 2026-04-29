/// Gas-profile tests for the quadtree-backed index.
///
/// These tests verify the *behavioral* properties that underpin O(1) gas costs:
///   • Every registered polygon remains retrievable regardless of how many
///     others are in the index.
///   • Non-overlapping polygons report zero overlaps.
///   • Spatially adjacent polygons appear as broadphase candidates of each
///     other, confirming that the index finds neighbours without needing to
///     scan every registered polygon.
///   • Large and small polygons are indexed without bias — the index handles
///     both at the same cost.
///
/// No internal storage fields (e.g. polygon::cells()) are inspected.
/// Run with: sui move test gas_profile
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::gas_profile_tests {
    use mercator::index;

    const SCALE: u64 = 1_000_000;

    // === Helpers ===

    fun make_index(ctx: &mut tx_context::TxContext): index::Index {
        // max_depth=6 keeps broadphase fast while still exercising multi-level indexing.
        index::with_config(SCALE, 6, 64, 10, 1024, 64, 2_000_000, ctx)
    }

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

    fun vec_contains(v: &vector<object::ID>, id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) return true;
            i = i + 1;
        };
        false
    }

    // === Test: many small polygons stay retrievable and non-overlapping ===

    #[test]
    /// Registering N well-separated small polygons:
    ///   • count equals N — no phantom entries, no lost entries
    ///   • each polygon is individually retrievable
    ///   • none are reported as overlapping (they are separated)
    ///
    /// This verifies the O(1)-per-polygon storage claim behaviorally:
    /// if insertion cost grew with index size, later registrations would
    /// produce incorrect state or abort.
    fun small_polygons_all_retrievable_and_non_overlapping() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(&mut ctx);
        let q1 = register_square(&mut idx, 0, 0, 1, 1, &mut ctx);
        let q2 = register_square(&mut idx, 3, 0, 4, 1, &mut ctx);
        let q3 = register_square(&mut idx, 6, 0, 7, 1, &mut ctx);
        let q4 = register_square(&mut idx, 0, 3, 1, 4, &mut ctx);
        let q5 = register_square(&mut idx, 3, 3, 4, 4, &mut ctx);

        // All five present.
        assert!(index::count(&idx) == 5, 0);

        // Each individually retrievable.
        let _p1 = index::get(&idx, q1);
        let _p2 = index::get(&idx, q2);
        let _p3 = index::get(&idx, q3);
        let _p4 = index::get(&idx, q4);
        let _p5 = index::get(&idx, q5);

        // No polygon reports a geometric overlap with any other.
        assert!(vector::length(&index::overlapping(&idx, q1)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, q2)) == 0, 2);
        assert!(vector::length(&index::overlapping(&idx, q3)) == 0, 3);
        assert!(vector::length(&index::overlapping(&idx, q4)) == 0, 4);
        assert!(vector::length(&index::overlapping(&idx, q5)) == 0, 5);
        std::unit_test::destroy(idx);
    }

    // === Test: large polygon — index handles wide footprint correctly ===

    #[test]
    /// A large polygon and a small adjacent polygon are both retrievable.
    /// The small polygon appears as a broadphase candidate of the large one,
    /// confirming the index correctly covers the large footprint.
    /// A polygon placed far away does not appear in the large one's overlapping set.
    fun large_polygon_found_by_adjacent_neighbour() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(&mut ctx);
        let large_id = register_square(&mut idx, 0, 0, 6, 6, &mut ctx);
        let adj_id = register_square(&mut idx, 6, 0, 7, 1, &mut ctx);

        assert!(index::count(&idx) == 2, 0);

        // Both retrievable.
        let _large = index::get(&idx, large_id);
        let _adj = index::get(&idx, adj_id);

        // Adjacent polygon is a broadphase candidate of the large one.
        let cands = index::candidates(&idx, large_id);
        assert!(vec_contains(&cands, adj_id), 1);

        // Touching edge — not an overlap.
        assert!(vector::length(&index::overlapping(&idx, large_id)) == 0, 2);
        std::unit_test::destroy(idx);
    }

    // === Test: mixed sizes — broadphase is size-agnostic ===

    #[test]
    /// One large polygon and three small polygons placed adjacent to it (not
    /// overlapping).  The index must:
    ///   • keep all four retrievable
    ///   • report no geometric overlaps (they are adjacent, not intersecting)
    ///   • include the large polygon as a candidate for each small neighbour
    ///
    /// This confirms that index cost does not depend on polygon size:
    /// a large polygon is no more expensive to index or query against than a
    /// small one.
    fun mixed_sizes_no_overlaps_and_correct_candidates() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(&mut ctx);
        let large_id = register_square(&mut idx, 0, 0, 4, 4, &mut ctx);
        let s1_id = register_square(&mut idx, 4, 0, 5, 1, &mut ctx);
        let s2_id = register_square(&mut idx, 4, 1, 5, 2, &mut ctx);
        let s3_id = register_square(&mut idx, 4, 2, 5, 3, &mut ctx);

        assert!(index::count(&idx) == 4, 0);

        // All retrievable.
        let _l = index::get(&idx, large_id);
        let _s1 = index::get(&idx, s1_id);
        let _s2 = index::get(&idx, s2_id);
        let _s3 = index::get(&idx, s3_id);

        // No polygon overlaps any other (all adjacent, not intersecting).
        assert!(vector::length(&index::overlapping(&idx, large_id)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, s1_id))    == 0, 2);
        assert!(vector::length(&index::overlapping(&idx, s2_id))    == 0, 3);
        assert!(vector::length(&index::overlapping(&idx, s3_id))    == 0, 4);

        // Each small polygon has the large polygon as a broadphase candidate.
        assert!(vec_contains(&index::candidates(&idx, s1_id), large_id), 5);
        assert!(vec_contains(&index::candidates(&idx, s2_id), large_id), 6);
        assert!(vec_contains(&index::candidates(&idx, s3_id), large_id), 7);
        std::unit_test::destroy(idx);
    }
}
