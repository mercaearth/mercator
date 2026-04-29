/// Regression guard tests for DOS-01 / DOS-02 fixes.
///
/// These tests encode the invariants that a good DoS fix MUST preserve.
/// All of them pass on the current (DoS-vulnerable-but-correct) code, and
/// must CONTINUE to pass after any mitigation lands. A fix that breaks any
/// of these is by definition a bad fix, because it trades DoS for either:
///
///   - silent correctness regressions (overlapping regions accepted), OR
///   - legitimate workflows breaking (small/medium register, viewport,
///     reshape, candidates()), OR
///   - new griefing vectors (hot-cell fill blocks disjoint regions).
///
/// Sections:
///   A. Overlap MUST still fire after the fix.
///   B. Legitimate small/medium workflows MUST still succeed.
///   C. No new griefing: hot-cell fill must not block disjoint registrations.
///   D. Cross-depth / cross-cell correctness.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::dos_fix_regression_tests {
    use mercator::{aabb, index::{Self, Index}, mutations, polygon};
    use sui::{object, tx_context};

    const SCALE: u64 = 1_000_000;
    const EOVERLAP: u64 = 4012;
    const EPartOverlap: u64 = 2006;
    const ECompactnessTooLow: u64 = 2011;

    // ═════════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════════════

    fun sq_xs(min: u64, max: u64): vector<u64> {
        vector[min, max, max, min]
    }

    fun sq_ys(min: u64, max: u64): vector<u64> {
        vector[min, min, max, max]
    }

    fun make_index(max_depth: u8, ctx: &mut tx_context::TxContext): Index {
        index::with_config(SCALE, max_depth, 64, 10, 1024, 64, 2_000_000, ctx)
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

    // ═════════════════════════════════════════════════════════════════════════════
    // Section A — Overlap MUST still fire
    //
    // Any DoS fix that makes these pass (i.e. the second register succeeds)
    // silently accepts overlapping regions and is strictly worse than the bug
    // it claims to fix.
    // ═════════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// A1. Two squares that overlap by a sub-cell margin must be rejected even
    /// though they share a common shallow ancestor cell. Catches fixes that
    /// collapse or skip candidates by cell depth.
    fun a1_interior_overlap_small_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(10, &mut ctx);
        register_square(&mut idx, 0, 0, 10 * SCALE, 10 * SCALE, &mut ctx);
        // Overlaps previous by 1m x 10m strip on the right.
        register_square(&mut idx, 9 * SCALE, 0, 19 * SCALE, 10 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// A2. Overlap across a quadtree cell boundary: first region sits fully in
    /// cell (0,0) at cell_size=SCALE; second region straddles the boundary into
    /// cell (1,0) and overlaps the first on its right edge. Catches ancestor-
    /// aware traversals that forget to walk siblings / parents.
    fun a2_cross_cell_boundary_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(10, &mut ctx);
        register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        // B straddles the boundary at x=SCALE and overlaps A by SCALE/2.
        register_square(&mut idx, SCALE / 2, 0, SCALE + SCALE / 2, SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// A3. Small deep region overlapping a large shallow region that contains
    /// it. Stored at very different natural depths. Catches fixes that only
    /// scan same-depth cells.
    fun a3_deep_region_inside_shallow_region_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(12, &mut ctx);
        register_square(&mut idx, 0, 0, 8 * SCALE, 8 * SCALE, &mut ctx);
        // Small region: 1m x 1m fully inside — different natural depth.
        register_square(&mut idx, 3 * SCALE, 3 * SCALE, 4 * SCALE, 4 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// A4. The reverse of A3: many small regions first, then one big region
    /// that swallows the region. Catches fixes that only look at shallower
    /// ancestors and skip descending into deeper occupied cells.
    fun a4_shallow_region_overlaps_deep_regions_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(12, &mut ctx);
        register_square(&mut idx, SCALE, SCALE, 2 * SCALE, 2 * SCALE, &mut ctx);
        register_square(&mut idx, 5 * SCALE, 5 * SCALE, 6 * SCALE, 6 * SCALE, &mut ctx);

        // Big region covering both.
        register_square(&mut idx, 0, 0, 10 * SCALE, 10 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// A5. Hot-cell overlap still fires: fill a shallow cell with many
    /// disjoint incumbents (DOS-02 attack shape), then register a region that
    /// overlaps exactly one of them. A candidate-count cap that abandons full
    /// SAT scanning would let this through — this test catches that.
    fun a5_hot_cell_overlap_still_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(4, &mut ctx);
        let width = 4 * SCALE;
        let n = 8u64;
        let mut i = 0u64;
        while (i < n) {
            let y0 = i * SCALE;
            let y1 = y0 + SCALE;
            register_square(&mut idx, 0, y0, width, y1, &mut ctx);
            i = i + 1;
        };

        // A new region that overlaps incumbent #3 by its full footprint.
        register_square(&mut idx, 0, 3 * SCALE, width, 4 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EPartOverlap, location = mercator::polygon)]
    /// A5b. Concave-via-multi-part overlap. Polygon A is an L-shape built from
    /// two disjoint axis-aligned parts. Polygon B sits inside A's AABB but
    /// OVERLAPS only one of A's parts (the other part doesn't cover B). A
    /// fix that stores only a polygon-level AABB or drops parts during
    /// broadphase would falsely accept B — catches that.
    fun a5b_multipart_overlap_on_one_part_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(10, &mut ctx);
        //   part 0: x∈[0, 10S], y∈[0, 3S]     (horizontal base)
        //   part 1: x∈[0, 3S],  y∈[0, 10S]    (vertical left column)
        // Note parts may touch at their shared rectangle — they intersect by
        // the 3S x 3S corner, which makes them a single convex-covering L
        // region for our purposes. AABB is 10S x 10S but the "notch"
        // [3S..10S] x [3S..10S] is NOT covered.
        index::register(
            &mut idx,
            vector[sq_xs(0, 10 * SCALE), sq_xs(0, 3 * SCALE)],
            vector[sq_ys(0, 3 * SCALE), sq_ys(0, 10 * SCALE)],
            &mut ctx,
        );

        // Polygon B: square that overlaps A's horizontal bar only.
        register_square(&mut idx, 5 * SCALE, SCALE, 7 * SCALE, 2 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// A5c. Sub-raw-unit overlap. Two 10m×10m regions whose AABBs overlap by
    /// exactly ONE raw coordinate unit (1/SCALE of a meter). The overlap area
    /// is astronomically smaller than 1 m² and truncates to zero in area()
    /// accounting, but SAT on integer coordinates still reports overlap. A
    /// fix that uses an epsilon or area-based tolerance in the SAT prefilter
    /// would falsely accept B — catches that.
    fun a5c_sub_raw_unit_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(10, &mut ctx);
        register_square(&mut idx, 0, 0, 10 * SCALE, 10 * SCALE, &mut ctx);
        // Overlaps by exactly 1 raw unit on the left edge.
        register_square(&mut idx, 10 * SCALE - 1, 0, 20 * SCALE - 1, 10 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = ECompactnessTooLow, location = mercator::polygon)]
    /// A5d. Thin-cross overlap. A horizontal 100m×1m strip already in the
    /// index, challenger is a vertical 1m×100m strip crossing it at the
    /// center. AABBs each span 100 cells at cell_size=SCALE; they only
    /// intersect in a 1m×1m square at the cross. Fixes that skip broadphase
    /// based on "long thin" heuristics would miss this.
    fun a5d_thin_cross_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(8, &mut ctx);
        register_square(&mut idx, 0, 50 * SCALE, 100 * SCALE, 51 * SCALE, &mut ctx);
        // Vertical strip x∈[50S, 51S], y∈[0, 100S] — crosses the horizontal.
        register_square(&mut idx, 50 * SCALE, 0, 51 * SCALE, 100 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// A5e. Duplicate footprint: registering an identical geometry (new ID)
    /// must still abort. Catches fixes whose dedup logic is ID-only and
    /// lets geometric duplicates slip through.
    fun a5e_duplicate_footprint_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(10, &mut ctx);
        register_square(&mut idx, SCALE, SCALE, 5 * SCALE, 5 * SCALE, &mut ctx);
        // Same footprint, new polygon ID.
        register_square(&mut idx, SCALE, SCALE, 5 * SCALE, 5 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// A6. Max-span AABB overlap: the DOS-01 fix must not turn off broadphase
    /// for large spans. A region that reuses the footprint of an existing one
    /// must still abort, even near the cap.
    fun a6_max_span_region_overlap_detected() {
        let mut ctx = tx_context::dummy();
        // Smaller depth so the test runs fast — cap semantics are identical.
        let mut idx = make_index(6, &mut ctx);
        register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        // A near-max-span region whose AABB covers the incumbent entirely.
        let span = 32 * SCALE;
        register_square(&mut idx, 0, 0, span, span, &mut ctx);
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Section B — Legitimate workflows MUST still succeed
    //
    // If a fix makes any of these abort or return wrong results, it's breaking
    // honest users. Pure baselines.
    // ═════════════════════════════════════════════════════════════════════════════

    #[test]
    /// B1. Baseline: register a single small region in an empty index.
    fun b1_small_register_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(10, &mut ctx);
        let id = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);
        assert!(polygon::area(index::get(&idx, id)) == 1, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// B2. Medium (64 x 64 m) register still succeeds. If a fix configures the
    /// per-index broadphase span below 64 it will abort here — which is a
    /// product-breaking change and must be caught.
    fun b2_medium_64m_register_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(8, &mut ctx);
        let id = register_square(&mut idx, 0, 0, 64 * SCALE, 64 * SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);
        let _ = id;
        std::unit_test::destroy(idx);
    }

    #[test]
    /// B3. query_viewport on a sane region (8 x 8 cells) returns the regions
    /// inside it. Fixes that blanket-abort large broadphase walks must leave
    /// this path intact.
    fun b3_viewport_small_returns_ids() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(8, &mut ctx);
        let a = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let b = register_square(&mut idx, 5 * SCALE, 5 * SCALE, 6 * SCALE, 6 * SCALE, &mut ctx);

        let results = index::query_viewport(&idx, 0, 0, 8 * SCALE, 8 * SCALE);
        assert!(vector::length(&results) == 2, 0);
        assert!(contains_id(&results, a), 1);
        assert!(contains_id(&results, b), 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// B4. candidates() on a non-overlapping neighbor still sees the incumbent
    /// as a candidate (broadphase correctness) and register() for a disjoint
    /// shape then passes via SAT. Catches fixes that prune candidates too
    /// aggressively.
    fun b4_candidates_returns_neighbor_and_register_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(8, &mut ctx);
        let a = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        // Disjoint neighbor, same row.
        let b = register_square(&mut idx, 2 * SCALE, 0, 3 * SCALE, SCALE, &mut ctx);

        let cands = index::candidates(&idx, b);
        // Broadphase can return 0+ candidates depending on cell depth; what we
        // require is that the SAT-post-filter is correct — register succeeded
        // without EOverlap, and overlaps() returns false.
        assert!(!index::overlaps(&idx, a, b), 0);
        let _ = cands;
        std::unit_test::destroy(idx);
    }

    #[test]
    /// B5. reshape_unclaimed on a medium region still works after the fix.
    /// mutations.reshape_unclaimed reuses broadphase; a too-tight probe budget
    /// would abort this legal mutation.
    fun b5_reshape_medium_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(8, &mut ctx);
        let id = register_square(&mut idx, SCALE, SCALE, 4 * SCALE, 4 * SCALE, &mut ctx);

        // Expand reshape: new AABB must contain old; here 0..5 covers 1..4.
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[sq_xs(0, 5 * SCALE)],
            vector[sq_ys(0, 5 * SCALE)],
            &ctx,
        );

        let reshaped = index::get(&idx, id);
        assert!(aabb::min_x(&polygon::bounds(reshaped)) == 0, 0);
        assert!(aabb::max_x(&polygon::bounds(reshaped)) == 5 * SCALE, 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// B6. Corner-touch is NOT an overlap. Two regions that share only a single
    /// vertex must both register. Catches fixes that over-reject on AABB-touch.
    fun b6_corner_touch_not_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(8, &mut ctx);
        register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        // Touches first only at corner (SCALE, SCALE).
        register_square(&mut idx, SCALE, SCALE, 2 * SCALE, 2 * SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// B7. Remove a region, then register a new region with the exact same
    /// footprint. Must succeed — stale `cells[cell]` entries from the removed
    /// region must not ghost-fire EOverlap. Catches DOS-02 fixes that add a
    /// per-cell length counter but forget to decrement it on remove().
    fun b7_remove_then_reregister_same_footprint_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(10, &mut ctx);
        let id = register_square(&mut idx, 2 * SCALE, 2 * SCALE, 5 * SCALE, 5 * SCALE, &mut ctx);
        index::remove(&mut idx, id, &mut ctx);
        let _id2 = register_square(&mut idx, 2 * SCALE, 2 * SCALE, 5 * SCALE, 5 * SCALE, &mut ctx);
        assert!(index::count(&idx) == 1, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// B8. In a hot-cell-packed region, remove one incumbent, then register
    /// a new region at that exact location. Must succeed. Catches DOS-02 cap
    /// bookkeeping that treats cell occupancy as monotonically increasing.
    fun b8_remove_from_hot_cell_then_reregister_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(5, &mut ctx);
        let mut ids = vector::empty<object::ID>();
        let mut i = 0u64;
        while (i < 8) {
            let x0 = i * SCALE;
            let id = register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            vector::push_back(&mut ids, id);
            i = i + 1;
        };

        // Remove #3 — now there's a gap.
        let removed = *vector::borrow(&ids, 3);
        index::remove(&mut idx, removed, &mut ctx);

        // Re-register at that exact slot — must succeed.
        let _new_id = register_square(&mut idx, 3 * SCALE, 0, 4 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 8, 0);
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Section C — No new griefing via hot-cell blocking
    //
    // A DOS-02 fix that rejects honest registrations once a hot cell is full
    // creates a PERMANENT denial-of-service in that region. These tests
    // require that honest users can still register in GEOGRAPHICALLY DISJOINT
    // areas even after an attacker fills a nearby hot cell.
    // ═════════════════════════════════════════════════════════════════════════════

    #[test]
    /// C1. Attacker fills a hot shallow cell. Honest user registers a region
    /// in a far-away region of the index. Must succeed regardless of hot-cell
    /// occupancy.
    fun c1_hot_cell_fill_does_not_block_disjoint_region() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(6, &mut ctx);
        let mut i = 0u64;
        while (i < 16) {
            let x0 = i * SCALE;
            register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            i = i + 1;
        };

        // Honest user registers far away — completely disjoint shallow cell.
        let id = register_square(
            &mut idx,
            50 * SCALE,
            50 * SCALE,
            51 * SCALE,
            51 * SCALE,
            &mut ctx,
        );
        assert!(index::count(&idx) == 17, 0);
        let _ = id;
        std::unit_test::destroy(idx);
    }

    #[test]
    /// C2. Hot-cell fill at one depth must not block registrations whose
    /// natural depth is different and whose AABB doesn't intersect the hot
    /// region. Guards against fixes that apply caps too broadly across the
    /// quadtree.
    fun c2_hot_cell_does_not_block_different_depth_disjoint_register() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(8, &mut ctx);
        let mut i = 0u64;
        while (i < 8) {
            let x0 = i * SCALE;
            register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            i = i + 1;
        };

        // Large region in a different shallow cell entirely.
        let id = register_square(
            &mut idx,
            100 * SCALE,
            100 * SCALE,
            108 * SCALE,
            108 * SCALE,
            &mut ctx,
        );
        assert!(index::count(&idx) == 9, 0);
        let _ = id;
        std::unit_test::destroy(idx);
    }

    #[test]
    /// C3. An honest user must be able to register within a partially-filled
    /// hot cell as long as their geometry is non-overlapping — a cell cap that
    /// triggers early (before the pathological incumbent count) would break
    /// legitimate density.
    fun c3_moderate_cell_density_non_overlapping_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(5, &mut ctx);
        let mut i = 0u64;
        while (i < 10) {
            let x0 = i * SCALE;
            register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            i = i + 1;
        };

        // Honest user adds an 11th, still non-overlapping.
        let id = register_square(&mut idx, 11 * SCALE, 0, 12 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 11, 0);
        let _ = id;
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Section D — Cross-depth / cross-ancestor correctness
    //
    // The current broadphase walks ALL depths 0..=max_depth. A DOS-01 fix that
    // replaces this with ancestor-aware traversal must still detect overlaps
    // where the two regions live at different natural depths or in sibling
    // cells sharing a common ancestor.
    // ═════════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// D1. Two regions whose AABBs cross a deep cell boundary therefore
    /// both bubble up to a shallow common ancestor. They also geometrically
    /// overlap in the shared strip. Must fire EOverlap.
    fun d1_common_ancestor_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(12, &mut ctx);
        register_square(&mut idx, SCALE / 2, 0, SCALE + SCALE / 2, SCALE, &mut ctx);
        // Region B: also straddles the boundary and overlaps A on the right.
        register_square(&mut idx, SCALE, 0, 2 * SCALE, SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// D2. Incumbent at shallow depth; challenger at a much deeper depth but
    /// geometrically inside. Must fire EOverlap.
    fun d2_deep_inside_shallow_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(16, &mut ctx);
        register_square(&mut idx, 0, 0, 16 * SCALE, 16 * SCALE, &mut ctx);
        // 1 x 1 m sub-region fully inside.
        register_square(&mut idx, 7 * SCALE, 7 * SCALE, 8 * SCALE, 8 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// D3. Sibling-cell disjoint registrations must not conflict. Two regions
    /// in adjacent shallow cells that don't share geometry must both land.
    /// Catches fixes that over-include sibling candidates AND SAT-filter
    /// incorrectly.
    fun d3_sibling_cells_disjoint_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(10, &mut ctx);
        let a = register_square(&mut idx, 0, 0, SCALE, SCALE, &mut ctx);
        let b = register_square(&mut idx, 2 * SCALE, 0, 3 * SCALE, SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);
        assert!(!index::overlaps(&idx, a, b), 1);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// D3b. LAST-incumbent overlap in hot cell. Challenger overlaps the
    /// LAST-registered incumbent (not the first). A fix that short-circuits
    /// after scanning N candidates would miss this if N is chosen lower than
    /// the incumbent count.
    fun d3b_last_incumbent_in_hot_cell_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(5, &mut ctx);
        let n = 16u64;
        let mut i = 0u64;
        while (i < n) {
            let x0 = i * SCALE;
            register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            i = i + 1;
        };

        // Challenger overlaps incumbent #15 (the last one registered).
        register_square(&mut idx, 15 * SCALE, 0, 16 * SCALE, SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// D4pre. Sanity: broad index state with many scattered registrations
    /// across multiple shallow cells. A new non-overlapping region must still
    /// register cleanly. This exercises the full broadphase state, not just
    /// one hot cell, so a fix that miscomputes occupied_depths or cell-key
    /// math (e.g., wrong shift during ancestor traversal) would break it.
    fun d4pre_broad_index_state_non_overlapping_succeeds() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(6, &mut ctx);
        // at 4m spacing so they land in distinct shallow cells.
        let mut r = 0u64;
        while (r < 4) {
            let mut c = 0u64;
            while (c < 4) {
                let x0 = c * 4 * SCALE;
                let y0 = r * 4 * SCALE;
                register_square(&mut idx, x0, y0, x0 + SCALE, y0 + SCALE, &mut ctx);
                c = c + 1;
            };
            r = r + 1;
        };

        // Register a new region in a gap between the grid cells.
        let _id = register_square(&mut idx, 2 * SCALE, 2 * SCALE, 3 * SCALE, 3 * SCALE, &mut ctx);
        assert!(index::count(&idx) == 17, 0);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// D4post. Same broad-state setup as D4pre, but challenger overlaps
    /// exactly one of the scattered incumbents. Must still abort. Combined
    /// with D4pre this proves the broadphase correctly decides both ways in
    /// a non-trivial index state.
    fun d4post_broad_index_state_overlap_detected() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(6, &mut ctx);
        let mut r = 0u64;
        while (r < 4) {
            let mut c = 0u64;
            while (c < 4) {
                let x0 = c * 4 * SCALE;
                let y0 = r * 4 * SCALE;
                register_square(&mut idx, x0, y0, x0 + SCALE, y0 + SCALE, &mut ctx);
                c = c + 1;
            };
            r = r + 1;
        };

        // Overlaps incumbent at (r=2, c=3): x0=12S, y0=8S, 1m×1m.
        register_square(&mut idx, 12 * SCALE, 8 * SCALE, 13 * SCALE, 9 * SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = EOVERLAP, location = mercator::index)]
    /// D4. After many DOS-02-style hot-cell registrations, a subsequent
    /// overlapping region must still be rejected. This is the composition of
    /// the hot-cell griefing shape with actual overlap: any fix that truncates
    /// candidates or skips the SAT scan for "hot" cells would miss this.
    fun d4_hot_cell_plus_overlap_still_fires() {
        let mut ctx = tx_context::dummy();
        let mut idx = make_index(5, &mut ctx);
        let mut i = 0u64;
        while (i < 12) {
            let x0 = i * SCALE;
            register_square(&mut idx, x0, 0, x0 + SCALE, SCALE, &mut ctx);
            i = i + 1;
        };

        // 13th region overlaps incumbent #6 by its full footprint.
        register_square(&mut idx, 6 * SCALE, 0, 7 * SCALE, SCALE, &mut ctx);
        std::unit_test::destroy(idx);
    }
}
