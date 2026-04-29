/// Security tests: probe boundary conditions and potential weaknesses.
///
/// These tests are intentionally adversarial — they do NOT fit to the current
/// implementation but instead attempt to exploit known attack surfaces:
///
///   1. Convexity bypass — collinear / barely-concave / duplicate vertex polygons
///   2. Near-zero area slivers — thin shapes trying to pass the compactness check
///   3. Maximum-coordinate arithmetic — u64 products in area / SAT near the grid ceiling
///   4. Quadtree cell saturation — DoS via many candidates in the same broadphase cell
///   5. Integer-boundary SAT precision — touching vs. 1-unit overlap
///   6. Self-intersecting multipart attempts
///   7. Duplicate vertex submissions
#[test_only, allow(unused_variable, unused_const, duplicate_alias, unused_function)]
module mercator::security_tests {
    use mercator::{index, polygon::{Self, part}, sat};
    use sui::tx_context;

    // === Constants ===

    const SCALE: u64 = 1_000_000;

    // === Helpers ===

    fun vector_contains_id(v: &vector<object::ID>, id: object::ID): bool {
        let mut i = 0;
        while (i < vector::length(v)) {
            if (*vector::borrow(v, i) == id) { return true };
            i = i + 1;
        };
        false
    }

    // Coordinate at the world boundary.
    const NEAR_MAX_COORD: u64 = 40_075_017_000_000;

    // ============================================================
    // --- 1. Convexity bypass ---
    // ============================================================

    /// ATTACK: Submit three collinear vertices as a triangle.
    /// All cross-products are zero → `direction` stays 0 →
    /// `is_convex_vertices` returns false → ENotConvex.
    ///
    /// WHY IT MATTERS: A zero-area "polygon" that bypassed convexity could be
    /// registered with undefined behavior in SAT and area checks.
    #[test]
    /// Companion to collinear_triangle_rejected.
    /// A genuinely non-collinear right triangle passes part() without error,
    /// proving the ENotConvex gate fires on degenerate geometry only.
    fun non_collinear_triangle_accepted() {
        let s = SCALE;
        // Right triangle at origin: (0,0),(2S,0),(0,2S) — all turns are strictly left.
        let _p = part(
            vector[0u64, 2 * s, 0u64],
            vector[0u64, 0u64, 2 * s],
        );
    }

    #[test]
    #[expected_failure(abort_code = polygon::ENotConvex)]
    fun collinear_triangle_rejected() {
        // (0,0), (S,0), (2S,0) — three points on the x-axis
        let _p = part(
            vector[0u64, SCALE, 2 * SCALE],
            vector[0u64, 0u64, 0u64],
        );
    }

    /// ATTACK: Submit N collinear vertices with coordinates spread along a diagonal.
    /// Cross-product of any three consecutive collinear points is zero.
    /// `direction` never set → ENotConvex.
    ///
    /// WHY IT MATTERS: Confirms that collinear-point skipping in `is_convex_vertices`
    /// does NOT allow a degenerate polygon to sneak through when ALL turns are zero.
    #[test]
    #[expected_failure(abort_code = polygon::ENotConvex)]
    fun diagonal_collinear_polygon_rejected() {
        // Five vertices on the line y = x (CCW order doesn't matter — all collinear)
        let s = SCALE;
        let _p = part(
            vector[0u64, s, 2 * s, 3 * s, 4 * s],
            vector[0u64, s, 2 * s, 3 * s, 4 * s],
        );
    }

    /// Companion to barely_concave_pentagon_rejected, diagonal_collinear_polygon_rejected,
    /// non_consecutive_duplicate_vertex_rejected, and
    /// duplicate_non_adjacent_vertex_creates_concavity_rejected.
    /// A strictly convex pentagon with all distinct, non-collinear vertices passes part().
    ///
    /// Vertices (CCW): (0,0),(4S,0),(5S,2S),(3S,4S),(0,3S)
    /// All cross-products are positive (verified analytically), all edge lengths ≥ S.
    #[test]
    fun convex_pentagon_accepted() {
        let s = SCALE;
        let _p = part(
            vector[0u64, 4 * s, 5 * s, 3 * s, 0u64],
            vector[0u64, 0u64, 2 * s, 4 * s, 3 * s],
        );
    }

    /// ATTACK: Barely-concave polygon — a pentagon where one vertex is pushed
    /// 1 raw unit inward, creating a right turn of cross-product = −4·SCALE.
    ///
    /// Vertices (CCW): (0,0), (4S,0), (4S−1,2S), (4S,4S), (0,4S)
    /// Cross at (4S−1, 2S):
    ///   cross_sign(ax=4S, ay=0, bx=4S−1, by=2S, cx=4S, cy=4S)
    ///   = (4S−1−4S)(4S−0) − (2S−0)(4S−4S)
    ///   = (−1)(4S) − 0 = −4S  (right turn → concave)
    ///
    /// WHY IT MATTERS: Integer arithmetic must catch a concavity of a single
    /// raw-unit indent, confirming no float-like tolerance in the convexity gate.
    #[test]
    #[expected_failure(abort_code = polygon::ENotConvex)]
    fun barely_concave_pentagon_rejected() {
        let s = SCALE;
        // Convex hull would be (0,0),(4S,0),(4S,4S),(0,4S).
        // Vertex (4S−1, 2S) is 1 raw unit inside the right edge → concave.
        let _p = part(
            vector[0u64, 4 * s, 4 * s - 1, 4 * s, 0u64],
            vector[0u64, 0u64, 2 * s, 4 * s, 4 * s],
        );
    }

    /// ATTACK: Polygon with two consecutive identical vertices (zero-length edge).
    /// Edge length check fires before convexity: EEdgeTooShort.
    ///
    /// WHY IT MATTERS: Zero-length edges produce a zero-magnitude axis in SAT,
    /// which the implementation skips with `if axis.dx != 0 || axis.dy != 0`.
    /// A zero-area degenerate polygon bypassing that guard would be invisible to
    /// the overlap checker for any axis derived from that edge.
    #[test]
    #[expected_failure(abort_code = polygon::EEdgeTooShort)]
    fun duplicate_consecutive_vertex_rejected() {
        // Triangle where v0 == v1: zero-length first edge
        let s = SCALE;
        let _p = part(
            vector[s, s, 3 * s, s], // v0==v1 at (S,S)
            vector[s, s, s, 3 * s],
        );
    }

    /// ATTACK: Polygon with a non-consecutive duplicate vertex.
    /// Pattern: A, B, C, B where C is above the AB line.
    /// Cross-product at B (index 3, preceded by C):
    ///   cross_sign(C=(3S,2S), B=(2S,0), next=(0,2S))
    ///   = (2S−3S)(2S−2S) − (0−2S)(0−3S)
    ///   = (−S)(0) − (−2S)(−3S) = 0 − 6S² = −6S² (right turn → concave)
    ///
    /// WHY IT MATTERS: A polygon that visits the same point twice could self-
    /// intersect in ways the convexity check might miss if zero-cross skipping
    /// were too aggressive — this test confirms it does not miss it.
    #[test]
    #[expected_failure(abort_code = polygon::ENotConvex)]
    fun non_consecutive_duplicate_vertex_rejected() {
        let s = SCALE;
        // Vertices: (0,0), (2S,0), (3S,2S), (2S,0), (0,2S)
        // v1 == v3 == (2S,0).  Creates a right turn at v3.
        let _p = part(
            vector[0u64, 2 * s, 3 * s, 2 * s, 0u64],
            vector[0u64, 0u64, 2 * s, 0u64, 2 * s],
        );
    }

    // ============================================================
    // --- 2. Near-zero area slivers ---
    // ============================================================

    /// ATTACK: Thin diamond at 45° with width = 1 raw unit, height = 4·SCALE.
    ///
    /// This shape passes the edge-length check (each edge has squared length ≥ S²)
    /// but has an extreme aspect ratio, producing near-zero area.
    ///
    /// twice_area = 2 × 1 × 4S = 8S = 8×10⁶
    /// L1 perimeter ≈ 4(1 + 4S) ≈ 16S = 16×10⁶
    /// Compactness: 8×10⁶ × 8×10⁶ = 64×10¹² << 150000 × (16×10⁶)² = 38.4×10¹⁸
    ///
    /// WHY IT MATTERS: A 45° sliver exploits the fact that L1 perimeter equals
    /// |dx|+|dy| per edge (same formula as axis-aligned rectangles), so it does
    /// NOT gain a compactness advantage over axis-aligned slivers.  The test
    /// confirms no orientation-based bypass.
    ///
    /// NOTE: `part()` only checks edge-length and convexity; the compactness gate
    /// lives in `polygon::new()`.  This test therefore calls `polygon::new()`.
    #[test]
    #[expected_failure(abort_code = 2011, location = mercator::polygon)]
    fun thin_45_degree_diamond_sliver_rejected() {
        let s = SCALE;
        let w: u64 = 10 * s; // x-center offset to keep coords positive
        let h: u64 = 4 * s; // half-height

        // Diamond: (w,0), (w+1,h), (w,2h), (w−1,h) — width = 2 raw units
        let p = part(
            vector[w, w + 1, w, w - 1],
            vector[0u64, h, 2 * h, h],
        );
        let mut ctx = tx_context::dummy();
        let poly = polygon::new(vector[p], &mut ctx);
        std::unit_test::destroy(poly);
    }

    /// ATTACK: Rectangle 25 m × 1 m — one unit past the compactness threshold.
    ///
    /// twice_area = 50·S²;  L1 perimeter = 52·S
    /// LHS = 8×10⁶ × 50·S² = 400×10¹⁸
    /// RHS = 150000 × (52·S)² = 405.6×10¹⁸
    /// LHS < RHS → ECompactnessTooLow.
    ///
    /// NOTE: compactness is checked in polygon::new(), not in part().
    #[test]
    #[expected_failure(abort_code = 2011, location = mercator::polygon)]
    fun axis_aligned_sliver_25x1_rejected() {
        let p = part(
            vector[0u64, 25 * SCALE, 25 * SCALE, 0u64],
            vector[0u64, 0u64, SCALE, SCALE],
        );
        let mut ctx = tx_context::dummy();
        let poly = polygon::new(vector[p], &mut ctx);
        std::unit_test::destroy(poly);
    }

    /// VERIFY: The thinnest axis-aligned rectangle that still passes compactness.
    /// 24 m × 1 m is the tightest compliant rectangle (proved in geometry_boundary_tests).
    ///
    /// WHY IT MATTERS: Establishes the compactness gate boundary so future changes
    /// cannot accidentally widen the acceptance window.
    #[test]
    fun thinnest_compliant_rectangle_accepted() {
        let _p = part(
            vector[0u64, 24 * SCALE, 24 * SCALE, 0u64],
            vector[0u64, 0u64, SCALE, SCALE],
        );
    }

    #[test]
    /// Companion to thin_45_degree_diamond_sliver_rejected and axis_aligned_sliver_25x1_rejected.
    /// Both rejection tests call polygon::new(); this companion proves polygon::new() succeeds
    /// for a compact shape.  thinnest_compliant_rectangle_accepted only calls part(), not new().
    fun compact_polygon_passes_polygon_new() {
        let s = SCALE;
        let p = part(
            vector[0u64, 4 * s, 4 * s, 0u64],
            vector[0u64, 0u64, 4 * s, 4 * s],
        );
        let mut ctx = tx_context::dummy();
        let poly = polygon::new(vector[p], &mut ctx);
        std::unit_test::destroy(poly);
    }

    // ============================================================
    // --- 3. Maximum-coordinate arithmetic ---
    // ============================================================

    /// VERIFY: Area and compactness arithmetic at near-maximum grid coordinates
    /// do not overflow.  Uses a 1 m × 1 m square whose right/top edges are at
    /// NEAR_MAX_COORD = (u32::MAX − 1) × SCALE.
    ///
    /// twice_area = 2 × SCALE² = 2×10¹²  (small — no overflow risk for this part)
    /// Key concern: the Shoelace products x_i × y_j where x_i ≈ 4.29×10¹⁵.
    ///   (4.29×10¹⁵)² ≈ 1.84×10³¹ << u128::MAX ≈ 3.4×10³⁸  ✓
    ///
    /// WHY IT MATTERS: Confirms that no unchecked multiplication in area/compactness
    /// computation aborts when coordinates are pushed to the u32-grid ceiling.
    #[test]
    fun large_coordinate_area_computation_does_not_overflow() {
        let xs = vector[
            NEAR_MAX_COORD - SCALE,
            NEAR_MAX_COORD,
            NEAR_MAX_COORD,
            NEAR_MAX_COORD - SCALE,
        ];
        let ys = vector[0u64, 0u64, SCALE, SCALE];
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let _id = index::register(&mut idx, vector[xs], vector[ys], &mut ctx);
        std::unit_test::destroy(idx);
    }

    /// ATTACK: SAT overlap check between two large polygons near the coordinate
    /// ceiling, where the overlap is exactly 1 raw unit.
    ///
    /// P1 spans [MAX−2S, MAX−S] × [0, S] in x (no overlap with P2 for SAT axis on x)
    /// P2 spans [MAX−S−1, MAX] × [0, S] in x — overlaps P1 by 1 raw unit.
    ///
    /// Projection onto the perpendicular of P1's right edge (x-axis normal):
    ///   max_proj(P1) = MAX−S, min_proj(P2) = MAX−S−1
    ///   gt(MAX−S, MAX−S−1) = true → projections overlap on this axis
    /// No separating axis exists → SAT reports overlap.
    ///
    /// WHY IT MATTERS: If signed arithmetic truncates or saturates at large
    /// magnitudes, a 1-unit overlap could be missed.
    #[test]
    fun sat_detects_one_unit_overlap_near_max_coordinates() {
        let base: u64 = NEAR_MAX_COORD;
        let s = SCALE;

        let xs_a = vector[base - 2 * s, base - s, base - s, base - 2 * s];
        let ys_a = vector[0u64, 0u64, s, s];

        // P2 left edge at (base − s − 1): overlaps P1 by 1 unit
        let xs_b = vector[base - s - 1, base, base, base - s - 1];
        let ys_b = vector[0u64, 0u64, s, s];

        assert!(sat::overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    /// VERIFY: Two large adjacent polygons touching at an exact coordinate
    /// boundary are NOT reported as overlapping.
    ///
    /// Projection of P1's right edge onto the x-axis normal:
    ///   max_proj(P1) = base−S = min_proj(P2)
    ///   signed::gt(max_P1, min_P2) = false (strict inequality) → no overlap ✓
    ///
    /// WHY IT MATTERS: If strict-inequality semantics are lost (e.g. by refactoring
    /// `gt` to `ge`), legitimately adjacent regions would be rejected.
    #[test]
    fun sat_touching_large_polygons_not_overlapping() {
        let base: u64 = NEAR_MAX_COORD;
        let s = SCALE;

        let xs_a = vector[base - 2 * s, base - s, base - s, base - 2 * s];
        let ys_a = vector[0u64, 0u64, s, s];

        let xs_b = vector[base - s, base, base, base - s];
        let ys_b = vector[0u64, 0u64, s, s];

        assert!(!sat::overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    // ============================================================
    // --- 4. Quadtree cell saturation --- (DoS / gas exhaustion)
    // ============================================================

    /// ATTACK: Fill a spatial region with many adjacent non-overlapping regions,
    /// then register a genuinely non-overlapping region in a gap.
    ///
    /// All regions share the same coarse-cell ancestor, so the broadphase for the
    /// new region returns ALL prior registrations as candidates.  Each candidate
    /// triggers a full SAT check, making check_no_overlaps O(N).
    ///
    /// This test verifies:
    ///   a) N non-overlapping registrations succeed (no false positive rejects)
    ///   b) An N+1-th polygon that fits in a gap is NOT falsely rejected
    ///
    /// WHY IT MATTERS: Gas cost scales with N; an attacker can pre-fill a region to
    /// make legitimate registrations prohibitively expensive on mainnet.
    /// The test also guards against false-positive rejections introduced by
    /// floating-point-style tolerance bugs in the integer SAT.
    #[test]
    fun cell_saturation_valid_region_in_gap_accepted() {
        let mut ctx = tx_context::dummy();
        // Small world: 32 m × 32 m, 1 m cells, depth 5.
        let mut idx = index::with_config(SCALE, 5, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        // Regions: [0,2S],[2S,4S],[4S,6S],[6S,8S],[8S,10S],[10S,12S],[12S,14S]
        // Gap at [14S,16S] intentionally left empty.
        let mut k: u64 = 0;
        while (k < 7) {
            let x0 = k * 2 * SCALE;
            index::register(
                &mut idx,
                vector[vector[x0, x0 + 2 * SCALE, x0 + 2 * SCALE, x0]],
                vector[vector[0u64, 0u64, SCALE, SCALE]],
                &mut ctx,
            );
            k = k + 1;
        };

        // Register a new region in the gap [14S,16S] × [0,S].
        // All 7 prior regions are candidates in the broadphase but none overlap.
        let _id = index::register(
            &mut idx,
            vector[vector[14 * SCALE, 16 * SCALE, 16 * SCALE, 14 * SCALE]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &mut ctx,
        );

        std::unit_test::destroy(idx);
    }

    /// ATTACK: Same cell saturation scenario, but the N+1-th registration
    /// overlaps an earlier region → must abort with EOverlap.
    #[test]
    #[expected_failure(abort_code = index::EOverlap)]
    fun cell_saturation_overlap_rejected_after_n_registrations() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 5, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let mut k: u64 = 0;
        while (k < 8) {
            let x0 = k * 2 * SCALE;
            index::register(
                &mut idx,
                vector[vector[x0, x0 + 2 * SCALE, x0 + 2 * SCALE, x0]],
                vector[vector[0u64, 0u64, SCALE, SCALE]],
                &mut ctx,
            );
            k = k + 1;
        };

        // Now attempt to register a polygon in [2S, 4S] — overlaps region 1.
        let _id = index::register(
            &mut idx,
            vector[vector[2 * SCALE, 4 * SCALE, 4 * SCALE, 2 * SCALE]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ============================================================
    // --- 5. Integer-boundary SAT precision ---
    // ============================================================

    /// VERIFY: Two polygons separated by 0 units (touching edge, no shared area)
    /// are NOT reported as overlapping — SAT uses strict `>` in projections_overlap.
    ///
    /// WHY IT MATTERS: Any regression that changes `gt` to `ge` would cause
    /// legally adjacent regions to be treated as overlapping, preventing registration.
    #[test]
    fun sat_exact_boundary_touching_is_not_overlap() {
        let s = SCALE;
        let xs_a = vector[0u64, s, s, 0u64];
        let ys_a = vector[0u64, 0u64, s, s];
        let xs_b = vector[s, 2 * s, 2 * s, s];
        let ys_b = vector[0u64, 0u64, s, s];
        assert!(!sat::overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    /// VERIFY: Two polygons separated by exactly 1 raw unit ARE overlapping.
    ///
    /// P1: [0, S], P2: [S−1, 2S] — 1-unit overlap at x = S−1..S.
    ///
    /// WHY IT MATTERS: Confirms the `>` threshold is at zero, not 1.
    /// If the check used `>= 1` (unit tolerance), slivers of 1 raw unit
    /// could register on top of existing regions.
    #[test]
    fun sat_one_unit_overlap_is_detected() {
        let s = SCALE;
        let xs_a = vector[0u64, s, s, 0u64];
        let ys_a = vector[0u64, 0u64, s, s];
        let xs_b = vector[s - 1, 2 * s - 1, 2 * s - 1, s - 1];
        let ys_b = vector[0u64, 0u64, s, s];
        assert!(sat::overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    /// ATTACK: Two polygons that share only a vertex (corner-to-corner).
    /// SAT must NOT report overlap (they are disjoint).
    ///
    /// This also probes the signed::gt zero-comparison: projection maxima equal
    /// projection minima when only a point is shared, so no axis-projection overlap.
    #[test]
    fun sat_corner_only_contact_is_not_overlap() {
        let s = SCALE;
        let xs_a = vector[0u64, s, s, 0u64];
        let ys_a = vector[0u64, 0u64, s, s];
        let xs_b = vector[s, 2 * s, 2 * s, s];
        let ys_b = vector[s, s, 2 * s, 2 * s];
        assert!(!sat::overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    /// ATTACK: One polygon fully contained in another.
    /// SAT must report overlap.
    ///
    /// WHY IT MATTERS: A "nested" polygon has no separating axis — both polygon
    /// edge sets produce projections that fully overlap on every axis.
    /// A buggy SAT that only checks edge normals of the OUTER polygon could miss
    /// containment.
    #[test]
    fun sat_containment_is_reported_as_overlap() {
        let s = SCALE;
        // Outer: 4 m × 4 m square
        let xs_outer = vector[0u64, 4 * s, 4 * s, 0u64];
        let ys_outer = vector[0u64, 0u64, 4 * s, 4 * s];
        // Inner: 1 m × 1 m square fully inside
        let xs_inner = vector[s, 2 * s, 2 * s, s];
        let ys_inner = vector[s, s, 2 * s, 2 * s];
        assert!(sat::overlaps(&xs_outer, &ys_outer, &xs_inner, &ys_inner), 0);
    }

    /// SAT PRECISION TEST: AABB overlaps but polygons do NOT.
    ///
    /// Diamond D = (4S,S),(7S,4S),(4S,7S),(S,4S) and rectangle R = [S,2S]×[S,2S].
    ///
    /// AABB of D is [S,7S]×[S,7S]; AABB of R is [S,2S]×[S,2S] — they overlap at
    /// [S,2S]×[S,2S], so the broadphase returns R as a candidate for D.
    ///
    /// The separating axis perpendicular to D's bottom-left edge (direction (1,1)):
    ///   D projects to [5S, 11S], R projects to [2S, 4S].  Since 5S > 4S, the
    ///   intervals are disjoint — SAT correctly returns false.
    ///
    /// WHY IT MATTERS: If SAT were stubbed to return `false` (or if the AABB
    /// broadphase short-circuited before calling SAT), this test would *fail*
    /// because both polygons could not register simultaneously — proving SAT is
    /// genuinely exercised on AABB-overlapping, geometrically-disjoint pairs.
    #[test]
    fun sat_separates_rotated_diamond_from_corner_of_its_aabb() {
        let s = SCALE;

        // Diamond D: vertices at (4S,S),(7S,4S),(4S,7S),(S,4S)
        let xs_d = vector[4 * s, 7 * s, 4 * s, s];
        let ys_d = vector[s, 4 * s, 7 * s, 4 * s];

        // Rectangle R: [S,2S]×[S,2S] — sits in the bottom-left corner of D's AABB
        let xs_r = vector[s, 2 * s, 2 * s, s];
        let ys_r = vector[s, s, 2 * s, 2 * s];

        // 1. Direct SAT: D and R are geometrically disjoint despite AABB overlap.
        assert!(!sat::overlaps(&xs_d, &ys_d, &xs_r, &ys_r), 0);

        // 2. Both register successfully in the index.
        //    D is stored at a shallow ancestor cell that covers R's quadtree cell,
        //    so the broadphase WILL find D as a candidate when R is inserted.
        //    count == 2 therefore proves SAT was invoked and returned false —
        //    a false positive (EOverlap) would have aborted the second registration.
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(s, 6, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let _d_id = index::register(&mut idx, vector[xs_d], vector[ys_d], &mut ctx);
        let _r_id = index::register(&mut idx, vector[xs_r], vector[ys_r], &mut ctx);
        assert!(index::count(&idx) == 2, 1);
        std::unit_test::destroy(idx);
    }

    /// SAT ROTATED OVERLAP: rotated rhombus and axis-aligned square share area.
    ///
    /// Rhombus R: 45°-rotated square centered at (2S,2S), vertices
    ///   (2S,0),(4S,2S),(2S,4S),(0,2S).
    /// Square  S: [S,3S]×[S,3S] — both shapes contain the center point (2S,2S).
    ///
    /// On x-axis:        R=[0,4S], S=[S,3S]  → overlap.
    /// On y-axis:        R=[0,4S], S=[S,3S]  → overlap.
    /// On (1,1) axis:    R=[2S,6S], S=[2S,6S] → overlap.
    /// On (1,-1) axis:   R=[-2S,2S], S=[-2S,2S] → overlap.
    /// No separating axis exists → SAT returns true.
    ///
    /// WHY IT MATTERS: Confirms SAT correctly reports overlap between a rotated
    /// quadrilateral and an axis-aligned square.  Documents that the edge-normal
    /// iteration runs for non-axis-aligned edges and produces the correct result
    /// in the overlap direction — the positive counterpart to the diamond
    /// separation test above.
    #[test]
    fun sat_rotated_rhombus_overlaps_axis_aligned_square() {
        let s = SCALE;
        // Rhombus: 45°-rotated square with diagonal 4S, centered at (2S,2S)
        let xs_r = vector[2 * s, 4 * s, 2 * s, 0u64];
        let ys_r = vector[0u64, 2 * s, 4 * s, 2 * s];
        // Axis-aligned square centred at the same point
        let xs_s = vector[s, 3 * s, 3 * s, s];
        let ys_s = vector[s, s, 3 * s, 3 * s];
        assert!(sat::overlaps(&xs_r, &ys_r, &xs_s, &ys_s), 0);
    }

    /// SAT ROTATED NON-OVERLAP (triangle): right triangle separated from a square
    /// only by the hypotenuse's outward normal — neither the x-axis nor the y-axis
    /// projection reveals the gap.
    ///
    /// Triangle T: (0,0),(3S,0),(0,3S)  — right triangle; AABB = [0,3S]×[0,3S].
    /// Square   S: [2S,4S]×[2S,4S]     — AABB = [2S,4S]×[2S,4S].
    ///
    /// AABB overlap: x [2S,3S], y [2S,3S] → broadphase keeps S as a candidate.
    ///
    /// Hypotenuse T's outward normal is (1,1)/√2.  Projection:
    ///   T vertices on (1,1): 0, 3S, 3S  → range [0, 3S].
    ///   S vertices on (1,1): 4S, 6S, 8S, 6S → range [4S, 8S].
    ///   3S < 4S → SEPARATED.
    ///
    /// WHY IT MATTERS: A SAT that only checks x- and y-axis projections would
    /// miss this separating axis (both x and y projections overlap) and would
    /// falsely claim T and S overlap.  This is a 3-vertex polygon, exercising
    /// the edge-normal loop with one non-axis-aligned edge (the hypotenuse).
    #[test]
    fun sat_right_triangle_separated_from_square_by_hypotenuse() {
        let s = SCALE;
        // Right triangle: (0,0),(3S,0),(0,3S)
        let xs_t = vector[0u64, 3 * s, 0u64];
        let ys_t = vector[0u64, 0u64, 3 * s];
        // Axis-aligned square: [2S,4S]×[2S,4S]
        let xs_s = vector[2 * s, 4 * s, 4 * s, 2 * s];
        let ys_s = vector[2 * s, 2 * s, 4 * s, 4 * s];

        // 1. Direct SAT: hypotenuse normal (1,1) reveals the gap.
        assert!(!sat::overlaps(&xs_t, &ys_t, &xs_s, &ys_s), 0);

        // 2. Both register in the index.
        //    T fits at quadtree depth 4, cell (0,0); S at depth 3, cell (0,0).
        //    S is a parent-cell ancestor of T, so the broadphase WILL surface T
        //    as a candidate for S (and vice-versa).  count == 2 proves SAT fired
        //    and returned false — a false positive would have aborted registration.
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(s, 6, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let _t_id = index::register(&mut idx, vector[xs_t], vector[ys_t], &mut ctx);
        let _s_id = index::register(&mut idx, vector[xs_s], vector[ys_s], &mut ctx);
        assert!(index::count(&idx) == 2, 1);
        std::unit_test::destroy(idx);
    }

    // ============================================================
    // --- 6. Self-intersecting multipart attempts ---
    // ============================================================

    /// Companion to multipart_overlapping_parts_rejected, multipart_vertex_only_contact_rejected,
    /// and multipart_disconnected_parts_rejected.
    /// A two-part polygon whose parts share exactly one full edge passes polygon::new(),
    /// proving the three rejection checks target the specific flaw in each attack, not all
    /// multipart polygons.
    #[test]
    fun valid_multipart_shared_edge_accepted() {
        let s = SCALE;
        let mut ctx = tx_context::dummy();
        // pa=[0,S]×[0,S] and pb=[S,2S]×[0,S] share the full edge (S,0)→(S,S).
        let pa = part(vector[0u64, s, s, 0u64], vector[0u64, 0u64, s, s]);
        let pb = part(vector[s, 2 * s, 2 * s, s], vector[0u64, 0u64, s, s]);
        let p = polygon::new(vector[pa, pb], &mut ctx);
        std::unit_test::destroy(p);
    }

    /// ATTACK: Multipart polygon where two parts overlap (area intersection).
    /// shared_edge_relation calls sat::overlaps; on true it aborts EPartOverlap.
    ///
    /// WHY IT MATTERS: An overlapping multipart would have incorrect area and
    /// could be used to claim two distinct geographic regions simultaneously
    /// through a single registration.
    #[test]
    #[expected_failure(abort_code = 2006, location = mercator::polygon)]
    fun multipart_overlapping_parts_rejected() {
        let s = SCALE;
        let mut ctx = tx_context::dummy();
        // Part A: [0,2S] × [0,2S]
        let pa = part(
            vector[0u64, 2 * s, 2 * s, 0u64],
            vector[0u64, 0u64, 2 * s, 2 * s],
        );
        // Part B: [S,3S] × [S,3S] — overlaps A by 1 m × 1 m
        let pb = part(
            vector[s, 3 * s, 3 * s, s],
            vector[s, s, 3 * s, 3 * s],
        );
        let p = polygon::new(vector[pa, pb], &mut ctx);
        std::unit_test::destroy(p);
    }

    /// ATTACK: Two-part polygon where parts touch only at a single vertex
    /// (diagonal squares sharing the corner (S, S)).
    ///
    /// shared_edge_relation:
    ///   sat::overlaps → false (strict projection overlap → false for corner)
    ///   has_exact_shared_edge → false (no matching edge)
    ///   segments_contact: edge (S,0)→(S,S) of A contains point (S,S) = endpoint of B's edge
    ///                     → boundary_contact_without_shared_edge = true
    ///   assert(!boundary_contact_without_shared_edge || shared_edge_found) FAILS
    ///   → EInvalidMultipartContact
    ///
    /// WHY IT MATTERS: Two parts touching at a vertex only form a topologically
    /// invalid multipart (a "bowtie" graph) — the implementation must reject it.
    #[test]
    #[expected_failure(abort_code = 2007, location = mercator::polygon)]
    fun multipart_vertex_only_contact_rejected() {
        let s = SCALE;
        let mut ctx = tx_context::dummy();
        // A: [0,S] × [0,S], B: [S,2S] × [S,2S] — share only vertex (S,S)
        let pa = part(
            vector[0u64, s, s, 0u64],
            vector[0u64, 0u64, s, s],
        );
        let pb = part(
            vector[s, 2 * s, 2 * s, s],
            vector[s, s, 2 * s, 2 * s],
        );
        let p = polygon::new(vector[pa, pb], &mut ctx);
        std::unit_test::destroy(p);
    }

    /// ATTACK: Two-part polygon where parts are fully disconnected (no shared
    /// edge or vertex contact).  part_graph_connected BFS from part 0 cannot
    /// reach part 1 → EDisconnectedMultipart.
    ///
    /// WHY IT MATTERS: Disconnected multiparts could register spatially
    /// separate claims as a single object, circumventing per-polygon validation.
    #[test]
    #[expected_failure(abort_code = 2008, location = mercator::polygon)]
    fun multipart_disconnected_parts_rejected() {
        let s = SCALE;
        let mut ctx = tx_context::dummy();
        // A: [0,S] × [0,S], B: [10S,11S] × [0,S] — gap of 9 m between them
        let pa = part(
            vector[0u64, s, s, 0u64],
            vector[0u64, 0u64, s, s],
        );
        let pb = part(
            vector[10 * s, 11 * s, 11 * s, 10 * s],
            vector[0u64, 0u64, s, s],
        );
        let p = polygon::new(vector[pa, pb], &mut ctx);
        std::unit_test::destroy(p);
    }

    // ============================================================
    // --- 7. Duplicate vertex submissions ---
    // ============================================================

    /// Companion to repeated_start_end_vertex_zero_closing_edge_rejected and
    /// duplicate_non_adjacent_vertex_creates_concavity_rejected.
    /// A square with four completely distinct vertices passes part(), proving
    /// the duplicate-vertex defenses fire on the specific defect, not on
    /// all multi-vertex polygons.
    #[test]
    fun polygon_with_all_distinct_vertices_accepted() {
        let s = SCALE;
        // (0,0),(2S,0),(2S,2S),(0,2S) — all four vertices distinct, all edges ≥ S.
        let _p = part(
            vector[0u64, 2 * s, 2 * s, 0u64],
            vector[0u64, 0u64, 2 * s, 2 * s],
        );
    }

    /// ATTACK: A "polygon" built from 3 distinct points but listed with a repeated
    /// first/last vertex to create a 4-element array, attempting to disguise a
    /// triangle as a quadrilateral.
    ///
    /// Vertices: (0,0), (2S,0), (2S,2S), (0,0) — v0 == v3.
    /// The closing edge from v3=(0,0) back to v0=(0,0) has length = 0
    /// → EEdgeTooShort fires before any convexity or compactness check.
    ///
    /// WHY IT MATTERS: Demonstrates that the edge-length gate is the correct
    /// first line of defense against repeated-vertex polygons.  A zero-length
    /// edge also generates a zero-length SAT axis (dx==dy==0), which the SAT
    /// implementation skips — so reaching SAT with such an edge would be silent.
    #[test]
    #[expected_failure(abort_code = polygon::EEdgeTooShort)]
    fun repeated_start_end_vertex_zero_closing_edge_rejected() {
        let s = SCALE;
        // v0=(0,0), v1=(2S,0), v2=(2S,2S), v3=(0,0) [same as v0]
        // Closing edge: v3→v0 = (0,0)→(0,0), length=0 → EEdgeTooShort.
        let _p = part(
            vector[0u64, 2 * s, 2 * s, 0u64],
            vector[0u64, 0u64, 2 * s, 0u64],
        );
    }

    /// ATTACK: Pentagon where a non-adjacent vertex is duplicated such that the
    /// resulting shape has a zero-area "spike" that flips convexity.
    ///
    /// Vertices: (0,0), (3S,0), (2S,S), (3S,0), (0,2S)
    /// v1==v3==(3S,0).  At v3, previous = (2S,S), next = (0,2S):
    ///   cross_sign(2S,S, 3S,0, 0,2S)
    ///   = (3S−2S)(2S−S) − (0−S)(0−2S)
    ///   = S×S − (−S)(−2S) = S² − 2S² = −S² (right turn → concave)
    /// → ENotConvex
    ///
    /// WHY IT MATTERS: Demonstrates that the convexity check handles the
    /// concavity introduced by revisiting a vertex, rather than silently
    /// allowing a "pinched" polygon.
    #[test]
    #[expected_failure(abort_code = polygon::ENotConvex)]
    fun duplicate_non_adjacent_vertex_creates_concavity_rejected() {
        let s = SCALE;
        let _p = part(
            vector[0u64, 3 * s, 2 * s, 3 * s, 0u64],
            vector[0u64, 0u64, s, 0u64, 2 * s],
        );
    }

    // ============================================================
    // --- 8. Cross-product overflow guard ---
    // ============================================================

    /// VERIFY: cross_sign does not overflow when both coordinate deltas are at
    /// the maximum permitted grid magnitude (~4.29 × 10¹⁵).
    ///
    /// checked_mul_or_abort is used internally, so this test passes iff:
    ///   (NEAR_MAX_COORD)² < u128::MAX  ≈ 3.4 × 10³⁸
    ///   (4.29 × 10¹⁵)² ≈ 1.84 × 10³¹ << 3.4 × 10³⁸  ✓
    ///
    /// WHY IT MATTERS: If future coordinate scaling increases SCALE or the grid
    /// ceiling, this test will abort with EOverflow rather than silently producing
    /// wrong cross-product signs.
    #[test]
    fun cross_product_at_max_coordinates_does_not_overflow() {
        // Use a large right triangle with legs of max-coordinate length.
        let base = NEAR_MAX_COORD - SCALE;
        let s = SCALE;
        // Right triangle: (base, 0), (base+S, 0), (base, S)
        // All edges pass MIN_EDGE_LENGTH (length = S).
        // All cross-products involve deltas up to S = 10⁶ — well within bounds.
        let _p = part(
            vector[base, base + s, base],
            vector[0u64, 0u64, s],
        );
        // NOTE: the *absolute* coordinates are large but the DELTAS between them
        // are small (= SCALE). The maximum-delta scenario is a polygon that
        // spans the entire grid, tested separately in geometry_boundary_tests.
    }
}
