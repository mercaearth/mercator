/// Quadtree Stress Tests.
///
/// Exercises the spatial index at scale across four scenarios:
///   1. Deep tree — many small polygons at the deepest achievable natural depth.
///   2. Wide tree — polygons stored at the root (depth 0) due to large span.
///   3. Bulk-removal rebalancing — verifies no ghost candidates remain after
///      large-scale deletions.
///   4. Large-scale — 30 polygons across mixed depths; count, retrieval, and
///      zero-overlap invariants all hold.
///
/// Configuration note: all tests use max_depth = 3, cell_size = SCALE.
///   • 1m×1m squares  → natural_depth 2  (deepest achievable = max_depth − 1)
///   • 2m×2m squares  → natural_depth 1
///   • 4m×4m squares  → natural_depth 0  (root; "wide" placement)
///
/// This depth setting keeps each broadphase scan to ≤ 39 table lookups,
/// well within the Move test-runner's wall-clock budget even for many polygons.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::quadtree_stress_tests {
    use mercator::index::{Self, Index};

    const SCALE: u64 = 1_000_000;

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    /// Three-level tree (depths 0–2).  With cell_size = SCALE:
    ///   depth 2 — deepest achievable for any valid 1m×1m polygon
    ///   depth 1 — 2m×2m polygons
    ///   depth 0 — 4m×4m polygons (root-level / "wide")
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

    fun contains_id(v: &vector<object::ID>, id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) return true;
            i = i + 1;
        };
        false
    }

    // ─── Deep tree ────────────────────────────────────────────────────────────────

    #[test]
    /// 16 non-adjacent 1m×1m squares placed at even-aligned x positions each reach
    /// natural_depth = 2 (the deepest achievable with max_depth = 3).
    /// Count, individual retrieval, and zero-overlap invariants must all hold.
    fun deep_tree_small_polygons_all_retrievable() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let mut ids = vector::empty<object::ID>();
        let mut i = 0u64;
        while (i < 16) {
            let x0 = i * 2 * SCALE;
            let id = register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            vector::push_back(&mut ids, id);
            i = i + 1;
        };

        assert!(index::count(&idx) == 16, 0);

        // All polygons must be directly retrievable.
        let mut j = 0u64;
        while (j < 16) {
            let _p = index::get(&idx, *vector::borrow(&ids, j));
            j = j + 1;
        };

        // No polygon overlaps any other (all separated by 1m gaps).
        let mut k = 0u64;
        while (k < 16) {
            assert!(vector::length(&index::overlapping(&idx, *vector::borrow(&ids, k))) == 0, 1);
            k = k + 1;
        };
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Each insertion into a deep tree increments the count by exactly 1.
    /// Verifies that cell bookkeeping is monotone and does not skip or double-count.
    fun deep_tree_count_increments_by_one_per_registration() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let mut i = 0u64;
        while (i < 20) {
            let x0 = i * 2 * SCALE;
            register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            assert!(index::count(&idx) == i + 1, 0);
            i = i + 1;
        };
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Removing all polygons one-by-one returns the count to zero and frees every
    /// cell entry.  A subsequent registration succeeds on the clean slate.
    fun deep_tree_full_removal_restores_empty_index() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let n = 16u64;
        let mut ids = vector::empty<object::ID>();
        let mut i = 0u64;
        while (i < n) {
            let x0 = i * 2 * SCALE;
            let id = register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            vector::push_back(&mut ids, id);
            i = i + 1;
        };
        assert!(index::count(&idx) == n, 0);

        let mut j = 0u64;
        while (j < n) {
            index::remove(&mut idx, *vector::borrow(&ids, j), &mut ctx);
            j = j + 1;
        };
        assert!(index::count(&idx) == 0, 1);

        // Fresh registration on the now-empty index must succeed.
        let new_id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 2);
        let _p = index::get(&idx, new_id);
        std::unit_test::destroy(idx);
    }

    // ─── Wide tree ────────────────────────────────────────────────────────────────

    #[test]
    /// Four 4m×4m quadrants cover an 8m×8m world.  Each polygon spans every
    /// cell-boundary at depths 1–3 and is therefore stored at the root (depth 0).
    /// Touching edges are not overlaps (aabb::intersects uses strict inequality).
    fun wide_tree_four_quadrants_all_stored_at_root() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let half: u64 = 4 * SCALE; // 4 m
        let full: u64 = 8 * SCALE; // 8 m

        let id_a = register_square(&mut idx, 0, 0, half, half, &mut ctx);
        let id_b = register_square(&mut idx, half, 0, full, half, &mut ctx);
        let id_c = register_square(&mut idx, 0, half, half, full, &mut ctx);
        let id_d = register_square(&mut idx, half, half, full, full, &mut ctx);

        assert!(index::count(&idx) == 4, 0);

        let _pa = index::get(&idx, id_a);
        let _pb = index::get(&idx, id_b);
        let _pc = index::get(&idx, id_c);
        let _pd = index::get(&idx, id_d);

        assert!(vector::length(&index::overlapping(&idx, id_a)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, id_b)) == 0, 2);
        assert!(vector::length(&index::overlapping(&idx, id_c)) == 0, 3);
        assert!(vector::length(&index::overlapping(&idx, id_d)) == 0, 4);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// A root-level (depth 0) polygon and multiple deep-level (depth 2) polygons
    /// placed outside its bounds coexist without overlap.  Verifies that mixed-depth
    /// storage does not corrupt count or retrieval.
    fun wide_and_deep_polygons_coexist_without_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let big_id = register_square(&mut idx, 0, 0, 4 * SCALE, 4 * SCALE, &mut ctx);

        // 1m×1m squares placed outside the big polygon (to the right).
        // These land at depth 2 (deepest achievable with max_depth = 3).
        let id1 = register_square(&mut idx, 4 * SCALE, 0, 5 * SCALE, SCALE, &mut ctx);
        let id2 = register_square(&mut idx, 6 * SCALE, 0, 7 * SCALE, SCALE, &mut ctx);
        let id3 = register_square(&mut idx, 8 * SCALE, 0, 9 * SCALE, SCALE, &mut ctx);
        let id4 = register_square(&mut idx, 10 * SCALE, 0, 11 * SCALE, SCALE, &mut ctx);

        assert!(index::count(&idx) == 5, 0);

        assert!(vector::length(&index::overlapping(&idx, big_id)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, id1))    == 0, 2);
        assert!(vector::length(&index::overlapping(&idx, id2))    == 0, 3);
        assert!(vector::length(&index::overlapping(&idx, id3))    == 0, 4);
        assert!(vector::length(&index::overlapping(&idx, id4))    == 0, 5);
        std::unit_test::destroy(idx);
    }

    // ─── Bulk-removal rebalancing ─────────────────────────────────────────────────

    #[test]
    /// After removing 15 of 16 polygons, the survivor's broadphase candidate set
    /// must not contain any of the removed polygons (no ghost entries in the tree).
    fun bulk_removal_leaves_no_ghost_candidates() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let n = 16u64;
        let mut ids = vector::empty<object::ID>();
        let mut i = 0u64;
        while (i < n) {
            let x0 = i * 2 * SCALE;
            let id = register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            vector::push_back(&mut ids, id);
            i = i + 1;
        };

        let survivor = *vector::borrow(&ids, n - 1);

        // Remove all but the last polygon.
        let mut j = 0u64;
        while (j < n - 1) {
            index::remove(&mut idx, *vector::borrow(&ids, j), &mut ctx);
            j = j + 1;
        };
        assert!(index::count(&idx) == 1, 0);

        // Survivor's broadphase must contain no removed IDs.
        let cands = index::candidates(&idx, survivor);
        let mut k = 0u64;
        while (k < n - 1) {
            assert!(!contains_id(&cands, *vector::borrow(&ids, k)), 1);
            k = k + 1;
        };
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Interleaved register / remove cycles keep the count consistent at every
    /// step.  Freed cells are reusable without error.
    fun interleaved_register_remove_count_stays_consistent() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let mut ids = vector::empty<object::ID>();
        let mut i = 0u64;
        while (i < 8) {
            let x0 = i * 2 * SCALE;
            let id = register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            vector::push_back(&mut ids, id);
            i = i + 1;
        };
        assert!(index::count(&idx) == 8, 0);

        // Phase 2: remove the first 4, halving the population.
        let mut j = 0u64;
        while (j < 4) {
            index::remove(&mut idx, *vector::borrow(&ids, j), &mut ctx);
            j = j + 1;
        };
        assert!(index::count(&idx) == 4, 1);

        // Phase 3: re-register into the now-freed positions.
        let mut k = 0u64;
        while (k < 4) {
            let x0 = k * 2 * SCALE;
            register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            k = k + 1;
        };
        assert!(index::count(&idx) == 8, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// A removed polygon no longer occupies its spatial cell; a subsequent
    /// registration in the identical footprint must succeed without overlap error.
    fun removed_polygon_no_longer_blocks_its_cell() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_a = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        index::remove(&mut idx, id_a, &mut ctx);
        assert!(index::count(&idx) == 0, 0);

        let id_b = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 1);
        let _pb = index::get(&idx, id_b);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Count decrements by exactly 1 after each removal even under a dense
    /// population where polygons share broadphase candidate sets.
    fun bulk_removal_decrements_count_each_step() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let n = 12u64;
        let mut ids = vector::empty<object::ID>();
        let mut i = 0u64;
        while (i < n) {
            let x0 = i * 2 * SCALE;
            let id = register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            vector::push_back(&mut ids, id);
            i = i + 1;
        };
        assert!(index::count(&idx) == n, 0);

        let mut j = 0u64;
        while (j < n) {
            index::remove(&mut idx, *vector::borrow(&ids, j), &mut ctx);
            assert!(index::count(&idx) == n - j - 1, 1);
            j = j + 1;
        };
        std::unit_test::destroy(idx);
    }

    // ─── Large-scale and mixed-depth ─────────────────────────────────────────────

    #[test]
    /// 30 non-overlapping 1m×1m squares in a 5-column × 6-row grid (1m gaps)
    /// must all be registered, reach the correct total count, and remain
    /// individually retrievable.
    fun large_scale_polygons_count_and_retrieval() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let cols = 5u64;
        let rows = 6u64;
        let total = cols * rows; // 30

        let mut ids = vector::empty<object::ID>();
        let mut row = 0u64;
        while (row < rows) {
            let mut col = 0u64;
            while (col < cols) {
                let x0 = col * 2 * SCALE;
                let y0 = row * 2 * SCALE;
                let id = register_square(&mut idx, x0, y0, x0 + SCALE, y0 + SCALE, &mut ctx);
                vector::push_back(&mut ids, id);
                col = col + 1;
            };
            row = row + 1;
        };

        assert!(index::count(&idx) == total, 0);

        let mut i = 0u64;
        while (i < total) {
            let _p = index::get(&idx, *vector::borrow(&ids, i));
            i = i + 1;
        };
        std::unit_test::destroy(idx);
    }

    #[test]
    /// With 30 non-overlapping polygons in the index, no polygon may report a
    /// geometric overlap against any other.
    fun large_scale_polygons_no_spurious_overlaps() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let cols = 5u64;
        let rows = 6u64;
        let total = cols * rows;

        let mut ids = vector::empty<object::ID>();
        let mut row = 0u64;
        while (row < rows) {
            let mut col = 0u64;
            while (col < cols) {
                let x0 = col * 2 * SCALE;
                let y0 = row * 2 * SCALE;
                let id = register_square(&mut idx, x0, y0, x0 + SCALE, y0 + SCALE, &mut ctx);
                vector::push_back(&mut ids, id);
                col = col + 1;
            };
            row = row + 1;
        };

        let mut i = 0u64;
        while (i < total) {
            assert!(vector::length(&index::overlapping(&idx, *vector::borrow(&ids, i))) == 0, 0);
            i = i + 1;
        };
        std::unit_test::destroy(idx);
    }

    #[test]
    /// Mixed depths: small (1m×1m → depth 2), medium (2m×2m → depth 1), and
    /// large (4m×4m → depth 0) non-overlapping polygons coexist in the same index.
    /// Count, retrieval, and zero-overlap invariants hold regardless of depth.
    fun mixed_depth_polygons_coexist_without_corruption() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let mut small_ids = vector::empty<object::ID>();
        let mut i = 0u64;
        while (i < 8) {
            let x0 = i * 2 * SCALE;
            let id = register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            vector::push_back(&mut small_ids, id);
            i = i + 1;
        };

        // Medium 2m×2m at depth 1 — spaced 4m apart at y = 6 m.
        // [0,2]×[6,8], [4,6]×[6,8], [8,10]×[6,8], [12,14]×[6,8]
        let mut med_ids = vector::empty<object::ID>();
        let mut j = 0u64;
        while (j < 4) {
            let x0 = j * 4 * SCALE;
            let id = register_square(&mut idx, x0, 6 * SCALE, x0 + 2 * SCALE, 8 * SCALE, &mut ctx);
            vector::push_back(&mut med_ids, id);
            j = j + 1;
        };

        // Large 4m×4m at depth 0 (root) — far corner to avoid any overlap.
        let big_id = register_square(
            &mut idx,
            20 * SCALE,
            20 * SCALE,
            24 * SCALE,
            24 * SCALE,
            &mut ctx,
        );

        let total: u64 = 8 + 4 + 1; // 13
        assert!(index::count(&idx) == total, 0);

        let mut k = 0u64;
        while (k < 8) {
            assert!(
                vector::length(&index::overlapping(&idx, *vector::borrow(&small_ids, k))) == 0,
                1,
            );
            k = k + 1;
        };
        let mut l = 0u64;
        while (l < 4) {
            assert!(
                vector::length(&index::overlapping(&idx, *vector::borrow(&med_ids, l))) == 0,
                2,
            );
            l = l + 1;
        };
        assert!(vector::length(&index::overlapping(&idx, big_id)) == 0, 3);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// After removing half of a 30-polygon index, the remaining 15 polygons are
    /// still retrievable and report no spurious overlaps.
    fun large_scale_partial_bulk_removal_preserves_survivors() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let cols = 5u64;
        let rows = 6u64;
        let total = cols * rows; // 30

        let mut ids = vector::empty<object::ID>();
        let mut row = 0u64;
        while (row < rows) {
            let mut col = 0u64;
            while (col < cols) {
                let x0 = col * 2 * SCALE;
                let y0 = row * 2 * SCALE;
                let id = register_square(&mut idx, x0, y0, x0 + SCALE, y0 + SCALE, &mut ctx);
                vector::push_back(&mut ids, id);
                col = col + 1;
            };
            row = row + 1;
        };
        assert!(index::count(&idx) == total, 0);

        // Remove the first 15 polygons (the first 3 rows).
        let half = total / 2; // 15
        let mut i = 0u64;
        while (i < half) {
            index::remove(&mut idx, *vector::borrow(&ids, i), &mut ctx);
            i = i + 1;
        };
        assert!(index::count(&idx) == total - half, 1);

        // The remaining 15 polygons are retrievable and overlap-free.
        let mut j = half;
        while (j < total) {
            let id = *vector::borrow(&ids, j);
            let _p = index::get(&idx, id);
            assert!(vector::length(&index::overlapping(&idx, id)) == 0, 2);
            j = j + 1;
        };
        std::unit_test::destroy(idx);
    }
}
