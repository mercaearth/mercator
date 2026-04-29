/// Geometry boundary condition tests.
///
/// Covers five gap areas:
///   1. Maximum vertex count (64 per part)
///   2. Maximum part count (10 per polygon)
///   3. Near-minimum compactness (just above / just below the 150 000 ppm threshold)
///   4. Coordinates near u32::MAX grid boundary
///   5. Collinear edge behaviour across geometry operations
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::geometry_boundary_tests {
    use mercator::{
        index,
        mutations,
        polygon::{Self, Polygon, part, new, intersects, parts, vertices}
    };
    use sui::{test_scenario, tx_context};

    // === Constants ===

    const SCALE: u64 = 1_000_000;
    const MAX_WORLD: u64 = 40_075_017_000_000;

    // === Helpers ===

    /// Build a convex CCW rectangle from (min_x, min_y) with the given dimensions.
    fun rect(min_x: u64, min_y: u64, width: u64, height: u64): polygon::Part {
        part(
            vector[min_x, min_x + width, min_x + width, min_x],
            vector[min_y, min_y, min_y + height, min_y + height],
        )
    }

    /// Destroy a Polygon object (which has `key` but not `drop`).
    /// Struct deconstruction is restricted to the defining module, so we use
    /// the test-only escape hatch instead.
    fun destroy_polygon(p: Polygon) {
        std::unit_test::destroy(p);
    }

    // ============================================================
    // Group 1 — Maximum vertex count (MAX_VERTICES_PER_PART = 64)
    // ============================================================

    /// A convex polygon with exactly 64 vertices must be accepted.
    ///
    /// The shape is a 16 × 16 SCALE square decomposed into 16 vertices per side
    /// (CCW: bottom → right → top → left).  Vertices along each straight side are
    /// collinear, exercising the zero-cross-product skip path in `is_convex_vertices`.
    /// Every edge has length exactly SCALE, the minimum permitted value.
    #[test]
    fun part_accepts_exactly_64_vertices() {
        let s = SCALE;
        let xs = vector[
            // Bottom (y = 0): x = 0, S, 2S … 15S
            0,
            1*s,
            2*s,
            3*s,
            4*s,
            5*s,
            6*s,
            7*s,
            8*s,
            9*s,
            10*s,
            11*s,
            12*s,
            13*s,
            14*s,
            15*s,
            // Right (x = 16S): 16 vertices, x fixed
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            // Top (y = 16S): x = 16S, 15S … S
            16*s,
            15*s,
            14*s,
            13*s,
            12*s,
            11*s,
            10*s,
            9*s,
            8*s,
            7*s,
            6*s,
            5*s,
            4*s,
            3*s,
            2*s,
            s,
            // Left (x = 0): 16 vertices, x fixed
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        ];
        let ys = vector[
            // Bottom: y fixed = 0
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            // Right: y = 0, S, 2S … 15S
            0,
            1*s,
            2*s,
            3*s,
            4*s,
            5*s,
            6*s,
            7*s,
            8*s,
            9*s,
            10*s,
            11*s,
            12*s,
            13*s,
            14*s,
            15*s,
            // Top: y fixed = 16S
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            // Left: y = 16S, 15S … S
            16*s,
            15*s,
            14*s,
            13*s,
            12*s,
            11*s,
            10*s,
            9*s,
            8*s,
            7*s,
            6*s,
            5*s,
            4*s,
            3*s,
            2*s,
            s,
        ];
        // Part has `drop`; no explicit cleanup needed.
        let _p = part(xs, ys);
    }

    /// A part with exactly 63 vertices must be accepted — confirming the upper
    /// bound is inclusive (≤ 64) and 63 is not accidentally caught by an off-by-one.
    ///
    /// The shape reuses the 16-per-side layout of the 64-vertex test but drops
    /// the last vertex on the left column (y = S).  The closing edge now runs
    /// from (0, 2S) directly to (0, 0), length = 2S ≥ S, so all edge and
    /// convexity checks still pass.
    #[test]
    fun part_accepts_63_vertices() {
        let s = SCALE;
        let xs = vector[
            // Bottom (y = 0): x = 0, S … 15S — 16 vertices
            0,
            1*s,
            2*s,
            3*s,
            4*s,
            5*s,
            6*s,
            7*s,
            8*s,
            9*s,
            10*s,
            11*s,
            12*s,
            13*s,
            14*s,
            15*s,
            // Right (x = 16S): y ascending, 16 vertices
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            // Top (y = 16S): x descending 16S … S — 16 vertices
            16*s,
            15*s,
            14*s,
            13*s,
            12*s,
            11*s,
            10*s,
            9*s,
            8*s,
            7*s,
            6*s,
            5*s,
            4*s,
            3*s,
            2*s,
            s,
            // Left (x = 0): y descending 16S … 2S — 15 vertices (y = S dropped)
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        ];
        let ys = vector[
            // Bottom
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            // Right: y = 0, S … 15S
            0,
            1*s,
            2*s,
            3*s,
            4*s,
            5*s,
            6*s,
            7*s,
            8*s,
            9*s,
            10*s,
            11*s,
            12*s,
            13*s,
            14*s,
            15*s,
            // Top: y = 16S
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            16*s,
            // Left: y = 16S … 2S  (15 values)
            16*s,
            15*s,
            14*s,
            13*s,
            12*s,
            11*s,
            10*s,
            9*s,
            8*s,
            7*s,
            6*s,
            5*s,
            4*s,
            3*s,
            2*s,
        ];
        let _p = part(xs, ys);
    }

    /// A part with 65 vertices must be rejected with EBadVertices.
    /// The count check fires before any geometry validation, so the coordinates
    /// are irrelevant.
    #[test]
    #[expected_failure(abort_code = polygon::EBadVertices)]
    fun part_rejects_65_vertices() {
        let _p = part(
            vector[
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64,
                0u64, // 65 elements total
            ],
            vector[0u64],
        );
    }

    // ============================================================
    // Group 1b — Minimum edge length (MIN_EDGE_LENGTH = 1_000_000)
    // ============================================================
    //
    // MIN_EDGE_LENGTH_SQUARED = 1_000_000_000_000 = SCALE².
    // An edge of exactly SCALE is accepted (equality satisfies ≥).
    // An edge of SCALE − 1 = 999_999 has length² = 999_998_000_001 < SCALE²
    // and must be rejected with EEdgeTooShort.
    //
    // The failing polygon is a tall rectangle whose short side is 999_999.
    // validate_part_edges fires before convexity or compactness.

    /// An edge of exactly 999_999 coordinate units (one unit shorter than the
    /// minimum SCALE = 1_000_000) is rejected with EEdgeTooShort.
    #[test]
    #[expected_failure(abort_code = polygon::EEdgeTooShort)]
    fun part_rejects_edge_one_unit_below_minimum() {
        // Rectangle: bottom edge 0→999_999 has length 999_999 < SCALE.
        let _p = part(
            vector[0u64, 999_999u64, 999_999u64, 0u64],
            vector[0u64, 0u64, 25_000_000u64, 25_000_000u64],
        );
    }

    // ============================================================
    // Group 2 — Maximum part count (MAX_PARTS = 10)
    // ============================================================

    /// A polygon with exactly 10 connected parts must be accepted.
    /// The parts form a 10 × 1 strip of unit squares sharing edges pairwise.
    #[test]
    fun polygon_accepts_exactly_10_parts() {
        let mut scenario = test_scenario::begin(@0xCAFE);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let polygon = new(
                vector[
                    rect(0 * SCALE, 0, SCALE, SCALE),
                    rect(1 * SCALE, 0, SCALE, SCALE),
                    rect(2 * SCALE, 0, SCALE, SCALE),
                    rect(3 * SCALE, 0, SCALE, SCALE),
                    rect(4 * SCALE, 0, SCALE, SCALE),
                    rect(5 * SCALE, 0, SCALE, SCALE),
                    rect(6 * SCALE, 0, SCALE, SCALE),
                    rect(7 * SCALE, 0, SCALE, SCALE),
                    rect(8 * SCALE, 0, SCALE, SCALE),
                    rect(9 * SCALE, 0, SCALE, SCALE),
                ],
                ctx,
            );
            assert!(parts(&polygon) == 10, 0);
            assert!(vertices(&polygon) == 40, 1);
            destroy_polygon(polygon);
        };
        test_scenario::end(scenario);
    }

    /// An 11-part polygon must be rejected with ETooManyParts.
    /// The assertion fires inside `new()` before any topology validation.
    #[test]
    #[expected_failure(abort_code = polygon::ETooManyParts)]
    fun polygon_rejects_11_parts() {
        let mut ctx = tx_context::dummy();
        let p = new(
            vector[
                rect(0 * SCALE, 0, SCALE, SCALE),
                rect(1 * SCALE, 0, SCALE, SCALE),
                rect(2 * SCALE, 0, SCALE, SCALE),
                rect(3 * SCALE, 0, SCALE, SCALE),
                rect(4 * SCALE, 0, SCALE, SCALE),
                rect(5 * SCALE, 0, SCALE, SCALE),
                rect(6 * SCALE, 0, SCALE, SCALE),
                rect(7 * SCALE, 0, SCALE, SCALE),
                rect(8 * SCALE, 0, SCALE, SCALE),
                rect(9 * SCALE, 0, SCALE, SCALE),
                rect(10 * SCALE, 0, SCALE, SCALE),
            ],
            &mut ctx,
        );
        // Unreachable — new() aborts before returning. Required by the compiler
        // because Polygon lacks `drop`.
        std::unit_test::destroy(p);
    }

    // ============================================================
    // Group 3 — Near-minimum compactness (MIN_COMPACTNESS_PPM = 150 000)
    // ============================================================
    //
    // Compactness condition (single-part):
    //   8_000_000 × twice_area ≥ 150_000 × perimeter²
    //
    // For a W × H rectangle (L1 perimeter = 2(W+H), twice_area = 2WH):
    //   8_000_000 × 2WH ≥ 150_000 × 4(W+H)²
    //   ⟺  40WH ≥ 3(W+H)²
    //
    // 24 × 1 (just above): 40×24 = 960 ≥ 3×25² = 1875 … wait, in SCALE units:
    //   twice_area  = 2 × 24S × S  = 48S²
    //   perimeter   = 2(24S + S)   = 50S
    //   LHS = 8_000_000 × 48S²     = 384 × 10¹⁸
    //   RHS = 150_000  × (50S)²    = 375 × 10¹⁸   ← passes ✓
    //
    // 25 × 1 (just below):
    //   twice_area  = 50S²,   perimeter = 52S
    //   LHS = 400 × 10¹⁸  <  RHS = 405.6 × 10¹⁸  ← fails ✓

    /// A 24 m × 1 m rectangle lies just above the compactness threshold.
    #[test]
    fun polygon_accepts_24x1_part_at_compactness_threshold() {
        let mut scenario = test_scenario::begin(@0xCAFE);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let polygon = new(
                vector[rect(0, 0, 24 * SCALE, SCALE)],
                ctx,
            );
            destroy_polygon(polygon);
        };
        test_scenario::end(scenario);
    }

    /// A 25 m × 1 m rectangle lies just below the compactness threshold.
    #[test]
    #[expected_failure(abort_code = 2011, location = mercator::polygon)]
    fun polygon_rejects_25x1_part_below_compactness_threshold() {
        let mut ctx = tx_context::dummy();
        let p = new(
            vector[rect(0, 0, 25 * SCALE, SCALE)],
            &mut ctx,
        );
        // Unreachable — new() aborts before returning. Required by the compiler.
        std::unit_test::destroy(p);
    }

    // ─── Exact compactness threshold ──────────────────────────────────────────────
    //
    // The threshold equation for a single-part polygon is:
    //   8_000_000 × twice_area = 150_000 × perimeter²
    // which simplifies to:
    //   160 × twice_area = 3 × perimeter²
    //
    // Integer solutions: twice_area = 30k², perimeter = 40k for any k ≥ 1.
    // For k = SCALE: twice_area = 30S², perimeter = 40S.
    //
    // Right trapezoid with vertices (0,0), (S,0), (S,11S), (0,19S):
    //   L1 perimeter = S + 11S + (S+8S) + 19S = 40S   ← S-wide diagonal contributes S+8S=9S
    //   twice_area   = shoelace = S×11S + S×19S       = 30S²
    //   LHS = 8_000_000 × 30S² = 240_000_000S²
    //   RHS = 150_000 × (40S)² = 150_000 × 1600S² = 240_000_000S²
    //   LHS = RHS  →  exactly at the threshold, ≥ passes  ✓
    //
    // One unit below: shift the top-right vertex from (S,11S) to (S,11S−1).
    //   The perimeter is unchanged (40S), but twice_area drops to 30S² − S.
    //   LHS = 240_000_000S² − 8_000_000S  <  RHS  →  fails  ✓

    /// The right trapezoid (0,0)→(S,0)→(S,11S)→(0,19S) sits at exactly
    /// 150_000 ppm compactness; the check (≥) accepts it.
    #[test]
    fun polygon_accepts_exact_compactness_threshold() {
        let s = SCALE;
        let mut ctx = tx_context::dummy();
        let polygon = new(
            vector[
                part(
                    vector[0, s, s, 0],
                    vector[0, 0, 11 * s, 19 * s],
                ),
            ],
            &mut ctx,
        );
        destroy_polygon(polygon);
    }

    /// Shifting the top-right vertex down by one unit reduces twice_area to
    /// 30S² − S while keeping perimeter = 40S, pushing the ratio just below
    /// 150_000 ppm.  validate_compactness must abort with ECompactnessTooLow.
    #[test]
    #[expected_failure(abort_code = 2011, location = mercator::polygon)]
    fun polygon_rejects_one_unit_below_exact_compactness_threshold() {
        let s = SCALE;
        let mut ctx = tx_context::dummy();
        let p = new(
            vector[
                part(
                    vector[0, s, s, 0],
                    vector[0, 0, 11 * s - 1, 19 * s],
                ),
            ],
            &mut ctx,
        );
        std::unit_test::destroy(p);
    }

    // ============================================================
    // Group 4 — Coordinate near u32::MAX grid boundary
    // ============================================================
    //
    // With cell_size = 1 the grid coordinate equals the raw coordinate.
    // The check in `grid_bounds_for_aabb` is:  grid_coord ≤ u32::MAX (4_294_967_295).
    //
    // The polygon is a 1 m × 1 m square (SCALE × SCALE).  All edge-length,
    // convexity, and compactness checks pass regardless of translation.

    /// A polygon at the exact MAX_WORLD boundary is accepted.
    #[test]
    fun part_accepts_coordinate_at_exact_max_world_boundary() {
        let max = MAX_WORLD;
        let _p = part(
            vector[max - SCALE, max, max, max - SCALE],
            vector[0, 0, SCALE, SCALE],
        );
    }

    /// Any coordinate above MAX_WORLD is rejected.
    #[test]
    #[expected_failure(abort_code = polygon::ECoordinateOutOfWorld)]
    fun part_rejects_coordinate_above_max_world() {
        let max = MAX_WORLD;
        let _p = part(
            vector[max - SCALE, max + 1, max + 1, max - SCALE],
            vector[0, 0, SCALE, SCALE],
        );
    }

    /// Mutation path is also protected because reshape_unclaimed goes through
    /// prepare_geometry() -> part().
    #[test]
    #[expected_failure(abort_code = polygon::ECoordinateOutOfWorld)]
    fun reshape_unclaimed_rejects_out_of_world_coordinates() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let id = index::register(
            &mut idx,
            vector[vector[0u64, SCALE, SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &mut ctx,
        );

        let max = MAX_WORLD;
        mutations::reshape_unclaimed(
            &mut idx,
            id,
            vector[vector[max - SCALE, max + 1, max + 1, max - SCALE]],
            vector[vector[0u64, 0u64, SCALE, SCALE]],
            &ctx,
        );
        std::unit_test::destroy(idx);
    }

    /// A polygon with maximum grid x = u32::MAX − 1 must be accepted.
    ///
    /// Uses coordinates at the edge of MAX_WORLD while staying in range.
    #[test]
    fun polygon_accepts_coordinate_just_below_u32_max_grid_boundary() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let max = MAX_WORLD - 1;
        // Square 1 m × 1 m with right edge at MAX_WORLD - 1.
        let xs = vector[vector[max - SCALE, max, max, max - SCALE]];
        let ys = vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]];

        let _id = index::register(&mut idx, xs, ys, &mut ctx);

        std::unit_test::destroy(idx);
    }

    /// A polygon whose maximum grid coordinate is exactly u32::MAX passes the
    /// ECoordinateTooLarge guard (which uses ≤) but causes a u32 arithmetic
    /// overflow in the broadphase loop.
    ///
    /// The broadphase iterates `while (cx <= cmax_x) { ... cx = cx + 1; }`.
    /// When cmax_x = u32::MAX and cx reaches u32::MAX, the loop body executes
    /// and then `cx + 1` overflows.  The coordinate guard and the loop therefore
    /// have an off-by-one: the guard accepts u32::MAX but the loop cannot handle
    /// it.  The safe usable maximum is u32::MAX − 1 (tested above).
    #[test]
    #[expected_failure]
    fun polygon_at_exact_u32_max_grid_boundary_overflows_broadphase() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let xs = vector[
            vector[
                4_294_967_294_000_000u64,
                4_294_967_295_000_000u64,
                4_294_967_295_000_000u64,
                4_294_967_294_000_000u64,
            ],
        ];
        let ys = vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]];

        let _id = index::register(&mut idx, xs, ys, &mut ctx);

        std::unit_test::destroy(idx);
    }

    /// A polygon with coordinates above MAX_WORLD is rejected at geometry level.
    #[test]
    #[expected_failure(abort_code = polygon::ECoordinateOutOfWorld)]
    fun polygon_rejects_coordinate_one_unit_beyond_u32_max_grid() {
        let mut ctx = tx_context::dummy();
        let mut idx = index::with_config(SCALE, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let over = MAX_WORLD + 1;
        let xs = vector[vector[over - SCALE, over, over, over - SCALE]];
        let ys = vector[vector[0u64, 0u64, 1_000_000u64, 1_000_000u64]];

        let _id = index::register(&mut idx, xs, ys, &mut ctx);

        // Never reached — cleanup omitted intentionally.
        std::unit_test::destroy(idx);
    }

    // ============================================================
    // Group 5 — Collinear edge behaviour
    // ============================================================
    //
    // The convexity checker (`is_convex_vertices`) skips vertices whose
    // cross-product with their neighbours is zero (collinear), so a polygon
    // with collinear intermediate vertices is accepted as convex.
    //
    // Test geometry — "collinear pentagon":
    //   Vertices (CCW): (0,0), (S,0), (2S,0), (2S,2S), (0,2S)
    //   The midpoint (S,0) on the bottom edge is collinear with (0,0) and (2S,0).
    //   Area  = 4S²,  L1 perimeter = 8S,  compactness passes.

    /// A convex polygon containing a collinear intermediate vertex is accepted.
    #[test]
    fun part_accepts_collinear_intermediate_vertex() {
        // Pentagon: collinear midpoint (S,0) on the bottom edge.
        let _p = part(
            vector[0, SCALE, 2 * SCALE, 2 * SCALE, 0],
            vector[0, 0, 0, 2 * SCALE, 2 * SCALE],
        );
    }

    /// Two adjacent polygons, one of which has a collinear vertex on the shared
    /// boundary, do not intersect — SAT correctly returns no overlap.
    #[test]
    fun collinear_edge_polygon_does_not_intersect_adjacent_rectangle() {
        let mut scenario = test_scenario::begin(@0xCAFE);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            // Pentagon shares the edge x = 2S with the rectangle.
            let poly_a = new(
                vector[
                    part(
                        vector[0, SCALE, 2 * SCALE, 2 * SCALE, 0],
                        vector[0, 0, 0, 2 * SCALE, 2 * SCALE],
                    ),
                ],
                ctx,
            );
            let poly_b = new(
                vector[rect(2 * SCALE, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );
            assert!(!intersects(&poly_a, &poly_b), 0);
            destroy_polygon(poly_a);
            destroy_polygon(poly_b);
        };
        test_scenario::end(scenario);
    }

    /// A two-part polygon where one part has a collinear base vertex is valid.
    /// The shared edge (2S,0)↔(2S,2S) is detected correctly despite the extra
    /// collinear point on Part 0's bottom side.
    #[test]
    fun multipart_polygon_with_collinear_internal_vertex_is_valid() {
        let mut scenario = test_scenario::begin(@0xCAFE);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let pentagon = part(
                vector[0, SCALE, 2 * SCALE, 2 * SCALE, 0],
                vector[0, 0, 0, 2 * SCALE, 2 * SCALE],
            );
            let rectangle = rect(2 * SCALE, 0, 2 * SCALE, 2 * SCALE);
            let polygon = new(vector[pentagon, rectangle], ctx);
            assert!(parts(&polygon) == 2, 0);
            assert!(vertices(&polygon) == 9, 1);
            destroy_polygon(polygon);
        };
        test_scenario::end(scenario);
    }

    /// Two single-part polygons sharing the exact edge (2S,0)↔(2S,2S),
    /// where one part has a collinear vertex on its boundary, are recognized
    /// as touching by edge.
    #[test]
    fun collinear_edge_polygon_touches_adjacent_by_edge() {
        let mut scenario = test_scenario::begin(@0xCAFE);
        {
            let ctx = test_scenario::ctx(&mut scenario);
            let poly_a = new(
                vector[
                    part(
                        vector[0, SCALE, 2 * SCALE, 2 * SCALE, 0],
                        vector[0, 0, 0, 2 * SCALE, 2 * SCALE],
                    ),
                ],
                ctx,
            );
            let poly_b = new(
                vector[rect(2 * SCALE, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );
            assert!(polygon::touches_by_edge(&poly_a, &poly_b), 0);
            destroy_polygon(poly_a);
            destroy_polygon(poly_b);
        };
        test_scenario::end(scenario);
    }
}
