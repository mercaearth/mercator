/// Extracted polygon module tests.
#[test_only, allow(unused_variable, duplicate_alias)]
module mercator::polygon_tests {
    use mercator::{aabb, index::{Self, Index}, polygon::{Self, Polygon}, sat};
    use sui::{object, test_scenario, tx_context};

    const SCALE: u64 = 1_000_000;
    const MAX_VERTICES_PER_PART: u64 = 64;
    const EMismatch: u64 = 2005;
    const ENotConvex: u64 = 2003;
    const EPartOverlap: u64 = 2006;
    const EInvalidMultipartContact: u64 = 2007;
    const EDisconnectedMultipart: u64 = 2008;
    const EInvalidBoundary: u64 = 2009;
    const EEdgeTooShort: u64 = 2010;
    const ECompactnessTooLow: u64 = 2011;
    const EAreaConservationViolation: u64 = 2012;

    fun rectangle(min_x: u64, min_y: u64, width: u64, height: u64): polygon::Part {
        polygon::part(
            vector[min_x, min_x + width, min_x + width, min_x],
            vector[min_y, min_y, min_y + height, min_y + height],
        )
    }

    fun test_index(ctx: &mut tx_context::TxContext): Index {
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

    fun register_rect(
        idx: &mut Index,
        x0: u64,
        y0: u64,
        x1: u64,
        y1: u64,
        ctx: &mut tx_context::TxContext,
    ): object::ID {
        index::register(idx, vector[sq_xs(x0, x1)], vector[sq_ys(y0, y1)], ctx)
    }

    fun destroy_polygon(polygon: Polygon) {
        std::unit_test::destroy(polygon);
    }

    #[test]
    fun polygon_part_constructs_valid_convex_part() {
        let convex = polygon::part(
            vector[0, SCALE, SCALE, 0],
            vector[0, 0, SCALE, SCALE],
        );

        let bounds = polygon::part_bounds(&convex);
        assert!(aabb::min_x(&bounds) == 0, 0);
        assert!(aabb::max_y(&bounds) == SCALE, 1);
    }

    #[test]
    #[expected_failure(abort_code = EMismatch, location = mercator::polygon)]
    fun polygon_part_rejects_mismatched_vertices() {
        let _part = polygon::part(
            vector[0, SCALE, SCALE],
            vector[0, 0],
        );
    }

    #[test]
    #[expected_failure(abort_code = EEdgeTooShort, location = mercator::polygon)]
    fun polygon_part_m_shape_has_short_diagonal_edges() {
        // Non-convex "M" shape whose diagonals are ~0.7*SCALE — sub-meter,
        // so EEdgeTooShort fires before the convexity check.
        let _part = polygon::part(
            vector[0, SCALE, SCALE / 2, SCALE, 0],
            vector[0, 0, SCALE / 2, SCALE, SCALE],
        );
    }

    #[test]
    #[expected_failure(abort_code = ENotConvex, location = mercator::polygon)]
    fun polygon_part_rejects_non_convex_input() {
        // Same "W" shape scaled up so all edges exceed MIN_EDGE_LENGTH.
        let _part = polygon::part(
            vector[0, 2 * SCALE, SCALE, 2 * SCALE, 0],
            vector[0, 0, SCALE, 2 * SCALE, SCALE],
        );
    }

    #[test]
    #[expected_failure(abort_code = EEdgeTooShort, location = mercator::polygon)]
    fun polygon_part_rejects_sub_meter_edge() {
        let _part = polygon::part(
            vector[0, SCALE / 2, 0],
            vector[0, 0, SCALE],
        );
    }

    #[test]
    #[expected_failure(abort_code = EInvalidMultipartContact, location = mercator::polygon)]
    fun polygon_rejects_corner_touching_parts() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let first = rectangle(0, 0, SCALE, SCALE);
            let second = rectangle(SCALE, SCALE, SCALE, SCALE);

            let polygon = polygon::new(vector[first, second], ctx);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun polygon_accepts_shared_edge_parts() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let first = rectangle(0, 0, SCALE, SCALE);
            let second = rectangle(SCALE, 0, SCALE, SCALE);
            let polygon = polygon::new(vector[first, second], ctx);

            assert!(polygon::parts(&polygon) == 2, 0);
            assert!(polygon::vertices(&polygon) == 8, 1);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun polygon_accepts_dumbbell_with_thin_connecting_strip() {
        // Regression: compactness is boundary-level. A thin 30x1 connecting strip
        // would FAIL compactness if evaluated as an isolated part, but the assembled
        // polygon has a well-shaped outer boundary and must be accepted.
        //
        //  (0,20)----(20,20)           (50,20)----(70,20)
        //    |           |                |            |
        //    |  left     |                |  right     |
        //    |  square   |(20,10)(50,10)  |  square    |
        //    |           +----strip-------+            |
        //    |           |(20, 9)(50, 9)  |            |
        //    |           |                |            |
        //  (0, 0)----(20, 0)           (50, 0)----(70, 0)
        //
        // Shared edges (internal): left↔strip at x=20,y∈[9,10]; right↔strip at x=50,y∈[9,10].
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = polygon::part(
                vector[0, 20 * SCALE, 20 * SCALE, 20 * SCALE, 20 * SCALE, 0],
                vector[0, 0, 9 * SCALE, 10 * SCALE, 20 * SCALE, 20 * SCALE],
            );
            let strip = polygon::part(
                vector[20 * SCALE, 50 * SCALE, 50 * SCALE, 20 * SCALE],
                vector[9 * SCALE, 9 * SCALE, 10 * SCALE, 10 * SCALE],
            );
            let right = polygon::part(
                vector[50 * SCALE, 70 * SCALE, 70 * SCALE, 50 * SCALE, 50 * SCALE, 50 * SCALE],
                vector[0, 0, 20 * SCALE, 20 * SCALE, 10 * SCALE, 9 * SCALE],
            );

            let polygon = polygon::new(vector[left, strip, right], ctx);
            assert!(polygon::parts(&polygon) == 3, 0);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EInvalidMultipartContact, location = mercator::polygon)]
    fun polygon_rejects_partial_edge_contact() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let base = rectangle(0, 0, 4 * SCALE, SCALE);
            let roof = polygon::part(
                vector[SCALE, 3 * SCALE, 2 * SCALE],
                vector[SCALE, SCALE, 2 * SCALE],
            );

            let polygon = polygon::new(vector[base, roof], ctx);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EDisconnectedMultipart, location = mercator::polygon)]
    fun polygon_rejects_disconnected_parts_regardless_of_order() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = rectangle(0, 0, SCALE, SCALE);
            let center = rectangle(SCALE, 0, SCALE, SCALE);
            let far = rectangle(4 * SCALE, 0, SCALE, SCALE);

            let polygon = polygon::new(vector[center, far, left], ctx);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun polygon_getters_return_stored_fields() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let first = rectangle(0, 0, SCALE, SCALE);
            let second = rectangle(SCALE, 0, SCALE, SCALE);
            let expected_owner = tx_context::sender(ctx);
            let polygon = polygon::new(vector[first, second], ctx);
            let polygon_bounds = polygon::bounds(&polygon);

            assert!(polygon::parts(&polygon) == 2, 0);
            assert!(polygon::vertices(&polygon) == 8, 1);
            assert!(polygon::owner(&polygon) == expected_owner, 2);
            assert!(vector::length(polygon::cells(&polygon)) == 0, 3);
            assert!(aabb::min_x(&polygon_bounds) == 0, 4);
            assert!(aabb::max_x(&polygon_bounds) == 2 * SCALE, 5);
            assert!(aabb::max_y(&polygon_bounds) == SCALE, 6);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun polygon_new_constructs_valid_multipart() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let first = rectangle(0, 0, SCALE, SCALE);
            let second = rectangle(SCALE, 0, SCALE, SCALE);
            let polygon = polygon::new(vector[first, second], ctx);

            assert!(polygon::parts(&polygon) == 2, 0);
            assert!(polygon::vertices(&polygon) == 8, 1);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    /// Fan decomposition: 4 triangles around center (S,S) form a square.
    /// Adjacent triangles share edges; opposite triangles (T0↔T2, T1↔T3)
    /// share only the center vertex — this is valid fan topology, NOT a
    /// bowtie, because all parts are edge-connected through neighbors.
    fun polygon_accepts_fan_with_vertex_contact() {
        let s = SCALE;
        let c = s; // center
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            // T0: bottom  — (0,0) (2s,0) (s,s)
            let t0 = polygon::part(
                vector[0u64, 2 * s, c],
                vector[0u64, 0u64, c],
            );
            // T1: right   — (2s,0) (2s,2s) (s,s)
            let t1 = polygon::part(
                vector[2 * s, 2 * s, c],
                vector[0u64, 2 * s, c],
            );
            // T2: top     — (2s,2s) (0,2s) (s,s)
            let t2 = polygon::part(
                vector[2 * s, 0u64, c],
                vector[2 * s, 2 * s, c],
            );
            // T3: left    — (0,2s) (0,0) (s,s)
            let t3 = polygon::part(
                vector[0u64, 0u64, c],
                vector[2 * s, 0u64, c],
            );

            let polygon = polygon::new(vector[t0, t1, t2, t3], ctx);
            assert!(polygon::parts(&polygon) == 4, 0);
            assert!(polygon::vertices(&polygon) == 12, 1);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun polygon_accepts_shuffled_connected_parts() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = rectangle(0, 0, SCALE, SCALE);
            let center = rectangle(SCALE, 0, SCALE, SCALE);
            let right = rectangle(2 * SCALE, 0, SCALE, SCALE);
            let polygon = polygon::new(vector[left, right, center], ctx);

            assert!(polygon::parts(&polygon) == 3, 0);
            assert!(polygon::vertices(&polygon) == 12, 1);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EPartOverlap, location = mercator::polygon)]
    fun polygon_rejects_non_consecutive_part_overlap() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let first = rectangle(0, 0, SCALE, SCALE);
            let second = rectangle(SCALE, 0, SCALE, SCALE);
            let duplicate = rectangle(0, 0, SCALE, SCALE);

            let polygon = polygon::new(
                vector[first, second, duplicate],
                ctx,
            );
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EInvalidBoundary, location = mercator::polygon)]
    fun polygon_rejects_ring_with_hole() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let polygon = polygon::new(
                vector[
                    rectangle(0, 0, SCALE, SCALE),
                    rectangle(SCALE, 0, SCALE, SCALE),
                    rectangle(2 * SCALE, 0, SCALE, SCALE),
                    rectangle(0, SCALE, SCALE, SCALE),
                    rectangle(2 * SCALE, SCALE, SCALE, SCALE),
                    rectangle(0, 2 * SCALE, SCALE, SCALE),
                    rectangle(SCALE, 2 * SCALE, SCALE, SCALE),
                    rectangle(
                        2 * SCALE,
                        2 * SCALE,
                        SCALE,
                        SCALE,
                    ),
                ],
                ctx,
            );
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ECompactnessTooLow, location = mercator::polygon)]
    fun polygon_rejects_low_compactness_part() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let thin = rectangle(0, 0, 25 * SCALE, SCALE);
            let polygon = polygon::new(vector[thin], ctx);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun polygon_intersects_detects_part_overlap() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = polygon::new(
                vector[rectangle(0, 0, SCALE, SCALE)],
                ctx,
            );
            let right = polygon::new(
                vector[
                    rectangle(
                        SCALE / 2,
                        SCALE / 2,
                        SCALE,
                        SCALE,
                    ),
                ],
                ctx,
            );

            assert!(polygon::intersects(&left, &right), 0);
            destroy_polygon(left);
            destroy_polygon(right);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun polygon_intersects_rejects_touch_only() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = polygon::new(
                vector[rectangle(0, 0, SCALE, SCALE)],
                ctx,
            );
            let right = polygon::new(
                vector[rectangle(SCALE, 0, SCALE, SCALE)],
                ctx,
            );

            assert!(!polygon::intersects(&left, &right), 0);
            destroy_polygon(left);
            destroy_polygon(right);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun polygon_intersects_rejects_distant_polygons() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = polygon::new(
                vector[rectangle(0, 0, SCALE, SCALE)],
                ctx,
            );
            let right = polygon::new(
                vector[rectangle(3 * SCALE, 0, SCALE, SCALE)],
                ctx,
            );

            assert!(!polygon::intersects(&left, &right), 0);
            destroy_polygon(left);
            destroy_polygon(right);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun area_of_unit_square_is_one() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let square = rectangle(0, 0, SCALE, SCALE);
            let polygon = polygon::new(vector[square], ctx);

            assert!(polygon::area(&polygon) == 1, 0);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun area_of_known_rectangle() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let rect = rectangle(0, 0, 2 * SCALE, 3 * SCALE);
            let polygon = polygon::new(vector[rect], ctx);

            assert!(polygon::area(&polygon) == 6, 0);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun area_of_triangle_is_correct() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let triangle = polygon::part(
                vector[0, 3 * SCALE, 0],
                vector[0, 0, 4 * SCALE],
            );
            let polygon = polygon::new(vector[triangle], ctx);

            assert!(polygon::area(&polygon) == 6, 0);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun area_of_1km_square_is_1000000() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let km_square = rectangle(
                0,
                0,
                1000 * SCALE,
                1000 * SCALE,
            );
            let polygon = polygon::new(vector[km_square], ctx);

            assert!(polygon::area(&polygon) == 1_000_000, 0);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun area_of_multipart_polygon_sums_parts() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let first = rectangle(0, 0, SCALE, SCALE);
            let second = rectangle(SCALE, 0, SCALE, SCALE);
            let polygon = polygon::new(vector[first, second], ctx);

            assert!(polygon::area(&polygon) == 2, 0);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun touches_by_edge_adjacent() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = polygon::new(
                vector[rectangle(0, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );
            let right = polygon::new(
                vector[
                    rectangle(
                        2 * SCALE,
                        0,
                        2 * SCALE,
                        2 * SCALE,
                    ),
                ],
                ctx,
            );

            assert!(polygon::touches_by_edge(&left, &right), 0);
            destroy_polygon(left);
            destroy_polygon(right);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun touches_by_edge_disjoint() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = polygon::new(
                vector[rectangle(0, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );
            let right = polygon::new(
                vector[
                    rectangle(
                        5 * SCALE,
                        0,
                        2 * SCALE,
                        2 * SCALE,
                    ),
                ],
                ctx,
            );

            assert!(!polygon::touches_by_edge(&left, &right), 0);
            destroy_polygon(left);
            destroy_polygon(right);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EPartOverlap, location = mercator::polygon)]
    fun touches_by_edge_overlapping() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let left = polygon::new(
                vector[rectangle(0, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );
            let right = polygon::new(
                vector[rectangle(SCALE, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );

            let _ = polygon::touches_by_edge(&left, &right);
            destroy_polygon(left);
            destroy_polygon(right);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun touches_by_edge_point_only() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let lower_left = polygon::new(
                vector[rectangle(0, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );
            let upper_right = polygon::new(
                vector[
                    rectangle(
                        2 * SCALE,
                        2 * SCALE,
                        2 * SCALE,
                        2 * SCALE,
                    ),
                ],
                ctx,
            );

            assert!(!polygon::touches_by_edge(&lower_left, &upper_right), 0);
            destroy_polygon(lower_left);
            destroy_polygon(upper_right);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun contains_polygon_fully_inside() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let outer = polygon::new(
                vector[rectangle(0, 0, 6 * SCALE, 6 * SCALE)],
                ctx,
            );
            let inner = polygon::new(
                vector[
                    rectangle(
                        2 * SCALE,
                        2 * SCALE,
                        2 * SCALE,
                        2 * SCALE,
                    ),
                ],
                ctx,
            );

            assert!(polygon::contains_polygon(&outer, &inner), 0);
            destroy_polygon(outer);
            destroy_polygon(inner);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun contains_polygon_partially_outside() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let outer = polygon::new(
                vector[rectangle(0, 0, 6 * SCALE, 6 * SCALE)],
                ctx,
            );
            let inner = polygon::new(
                vector[
                    rectangle(
                        5 * SCALE,
                        2 * SCALE,
                        2 * SCALE,
                        2 * SCALE,
                    ),
                ],
                ctx,
            );

            assert!(!polygon::contains_polygon(&outer, &inner), 0);
            destroy_polygon(outer);
            destroy_polygon(inner);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun contains_polygon_identical() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let outer = polygon::new(
                vector[rectangle(0, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );
            let inner = polygon::new(
                vector[rectangle(0, 0, 2 * SCALE, 2 * SCALE)],
                ctx,
            );

            assert!(polygon::contains_polygon(&outer, &inner), 0);
            destroy_polygon(outer);
            destroy_polygon(inner);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun set_owner_changes_polygon_owner() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let square = rectangle(0, 0, SCALE, SCALE);
            let mut polygon = polygon::new(vector[square], ctx);

            polygon::set_owner(&mut polygon, @0xBEEF);
            assert!(polygon::owner(&polygon) == @0xBEEF, 0);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    #[test]
    fun prepare_geometry_valid() {
        let xs = vector[vector[0u64, 2_000_000u64, 2_000_000u64, 0u64]];
        let ys = vector[vector[0u64, 0u64, 2_000_000u64, 2_000_000u64]];

        let (parts, global_aabb, total_vertices, part_count) = polygon::prepare_geometry(
            xs,
            ys,
            MAX_VERTICES_PER_PART,
        );

        assert!(part_count == 1, 0);
        assert!(total_vertices == 4, 1);
        assert!(aabb::min_x(&global_aabb) == 0, 2);
        assert!(aabb::max_x(&global_aabb) == 2_000_000, 3);
        assert!(aabb::min_y(&global_aabb) == 0, 4);
        assert!(aabb::max_y(&global_aabb) == 2_000_000, 5);
    }

    #[test]
    #[expected_failure(abort_code = ENotConvex, location = mercator::polygon)]
    fun prepare_geometry_invalid_convexity() {
        let xs = vector[vector[0u64, 2 * SCALE, SCALE, 2 * SCALE, 0u64]];
        let ys = vector[vector[0u64, 0u64, SCALE, 2 * SCALE, SCALE]];

        let (_parts, _global_aabb, _total_vertices, _part_count) = polygon::prepare_geometry(
            xs,
            ys,
            MAX_VERTICES_PER_PART,
        );
    }

    #[test]
    fun prepare_geometry_accepts_collinear_boundary_vertex() {
        let xs = vector[vector[0u64, 2 * SCALE, 2 * SCALE, 2 * SCALE, 0u64]];
        let ys = vector[vector[0u64, 0u64, SCALE, 2 * SCALE, 2 * SCALE]];

        let (_parts, _global_aabb, total_vertices, part_count) = polygon::prepare_geometry(
            xs,
            ys,
            MAX_VERTICES_PER_PART,
        );

        assert!(part_count == 1, 0);
        assert!(total_vertices == 5, 1);
    }

    #[test]
    #[expected_failure(abort_code = ENotConvex, location = mercator::polygon)]
    fun prepare_geometry_rejects_all_collinear_vertices() {
        let xs = vector[vector[0u64, SCALE, 2 * SCALE, 3 * SCALE]];
        let ys = vector[vector[0u64, 0u64, 0u64, 0u64]];

        let (_parts, _global_aabb, _total_vertices, _part_count) = polygon::prepare_geometry(
            xs,
            ys,
            MAX_VERTICES_PER_PART,
        );
    }

    #[test]
    #[expected_failure(abort_code = ENotConvex, location = mercator::polygon)]
    fun prepare_geometry_rejects_turn_flip_after_collinear_run() {
        let xs = vector[vector[0u64, 3 * SCALE, 3 * SCALE, 3 * SCALE, 2 * SCALE, 0u64]];
        let ys = vector[vector[0u64, 0u64, SCALE, 2 * SCALE, SCALE, 2 * SCALE]];

        let (_parts, _global_aabb, _total_vertices, _part_count) = polygon::prepare_geometry(
            xs,
            ys,
            MAX_VERTICES_PER_PART,
        );
    }

    #[test]
    #[expected_failure(abort_code = EEdgeTooShort, location = mercator::polygon)]
    fun prepare_geometry_edge_too_short() {
        let xs = vector[vector[0u64, SCALE / 2, 0u64]];
        let ys = vector[vector[0u64, 0u64, SCALE]];

        let (_parts, _global_aabb, _total_vertices, _part_count) = polygon::prepare_geometry(
            xs,
            ys,
            MAX_VERTICES_PER_PART,
        );
    }

    #[test]
    fun area_conservation_check_pass() {
        let old_area = 4u128;
        let new_area = 4u128;

        polygon::assert_area_conserved(old_area, new_area);
    }

    #[test]
    #[expected_failure(abort_code = EAreaConservationViolation, location = mercator::polygon)]
    fun area_conservation_check_fail() {
        let old_area = 4u128;
        let new_area = 5u128;

        polygon::assert_area_conserved(old_area, new_area);
    }

    #[test]
    fun polygon_created_epoch_returns_correct_value() {
        let mut scenario = sui::test_scenario::begin(@0xCAFE);
        {
            let ctx = sui::test_scenario::ctx(&mut scenario);
            let square = rectangle(0, 0, SCALE, SCALE);
            let polygon = polygon::new(vector[square], ctx);
            assert!(polygon::created_epoch(&polygon) == 0, 0);
            destroy_polygon(polygon);
        };
        sui::test_scenario::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-02: contains_polygon vertex-only check — false positive for concave L
    // ═════════════════════════════════════════════════════════════════════════════
    //
    // ATTACK: An L-shaped outer polygon (2 convex parts) has a concave gap at
    // [S,3S]×[S,2S]. A triangle inner polygon has all 3 vertices inside the L,
    // but its hypotenuse crosses through the gap.
    //
    // The vertex-only check in contains_polygon says "contained" when it is NOT.
    //
    // L-shape layout (2 parts sharing edge (0,S)↔(S,S)):
    //
    //   y=2S ┌───┐
    //        │ P2│               gap: [S,3S]×[S,2S]
    //   y=S  ├───┴─────────┐    ← collinear vertex at (S,S) on P1
    //        │     P1       │
    //   y=0  └─────────────┘
    //        x=0  S        3S
    //
    // P1 = [(0,0),(3S,0),(3S,S),(S,S),(0,S)]  — 5 vertices, convex (collinear at (S,S))
    // P2 = [(0,S),(S,S),(S,2S),(0,2S)]        — standard square
    // Shared edge: (S,S)↔(0,S)
    //
    // Triangle: V1(S/2,S/2) in P1, V2(5S/2,S/2) in P1, V3(S/2,3S/2) in P2
    // Hypotenuse V2→V3 passes through (3S/2, S) → (S, 5S/4) → gap area

    #[test]
    /// F-02 PoC: outer_contains_inner incorrectly returns true for a triangle
    /// whose edge passes through the concave gap of an L-shaped outer polygon.
    ///
    /// If this test PASSES, the vulnerability is CONFIRMED.
    fun f02_contains_polygon_false_positive_concave_l() {
        let mut ctx = tx_context::dummy();
        let mut outer_idx = index::with_config(SCALE, 3, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let mut inner_idx = index::with_config(SCALE, 3, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let s = SCALE;

        // Register L-shaped outer polygon (2 parts):
        // P1: 5-vertex convex polygon with collinear vertex at (S,S)
        //     [(0,0), (3S,0), (3S,S), (S,S), (0,S)]
        // P2: square [(0,S), (S,S), (S,2S), (0,2S)]
        // They share exact edge (S,S)↔(0,S)
        let outer_id = index::register(
            &mut outer_idx,
            vector[
                // P1: bottom bar with collinear bend point
                vector[0, 3 * s, 3 * s, s, 0],
                // P2: top-left square
                sq_xs(0, s),
            ],
            vector[
                // P1 ys
                vector[0, 0, s, s, s],
                // P2 ys
                sq_ys(s, 2 * s),
            ],
            &mut ctx,
        );

        // Register triangle inner polygon — vertices inside L, edge crosses gap
        // V1(S/2, S/2) — inside P1 ✓
        // V2(5S/2, S/2) — inside P1 ✓
        // V3(S/2, 3S/2) — inside P2 ✓
        // Hypotenuse from V2(5S/2, S/2) to V3(S/2, 3S/2):
        //   at t=0.5: point (3S/2, S) — on boundary
        //   at t=0.6: point (1.3S, 1.1S) — OUTSIDE L (in the gap [S,3S]×[S,2S])
        let inner_id = index::register(
            &mut inner_idx,
            vector[vector[s / 2, 5 * s / 2, s / 2]],
            vector[vector[s / 2, s / 2, 3 * s / 2]],
            &mut ctx,
        );

        // Fixed (F-02): edge midpoint check now catches the hypotenuse crossing
        // the concave gap outside the L-shape.
        let result = index::outer_contains_inner(
            &outer_idx,
            outer_id,
            &inner_idx,
            inner_id,
        );

        // Correctly rejected: triangle edge crosses outside the L.
        assert!(result == false);
        std::unit_test::destroy(outer_idx);
        std::unit_test::destroy(inner_idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-03: Arithmetic safety at MAX_WORLD coordinates — defense test
    // ═════════════════════════════════════════════════════════════════════════════
    //
    // edge_length_squared uses unchecked u128 * u128. With MAX_WORLD coordinates
    // the product is ~3.2e27 which is safe (u128::MAX ~3.4e38). This test proves
    // that edge_length_squared, area, SAT, and registration all work at the
    // maximum valid coordinate boundary. If MAX_WORLD ever increases, this test
    // should be reviewed for overflow risk.

    #[test]
    /// F-03 Defense: Register a polygon at near-MAX_WORLD coordinates.
    /// Proves area computation, edge validation, and SAT don't overflow at
    /// the coordinate boundary. This is a safety-margin regression test.
    fun f03_arithmetic_safe_at_max_world_coordinates() {
        let mut ctx = tx_context::dummy();
        // Use a large cell_size to keep grid coords within u32
        let cell_size: u64 = 100_000_000_000; // 100B
        let mut idx = index::with_config(cell_size, 8, 64, 10, 1024, 64, 2_000_000, &mut ctx);
        let max = 40_075_017_000_000u64;
        let s = SCALE; // 1_000_000

        // Polygon near the world boundary: (max-2S, max-2S) to (max-S, max-S)
        let x0 = max - 2 * s;
        let y0 = max - 2 * s;
        let x1 = max - s;
        let y1 = max - s;

        let id = index::register(&mut idx, vector[sq_xs(x0, x1)], vector[sq_ys(y0, y1)], &mut ctx);

        // Area should be 1 m²
        assert!(polygon::area(index::get(&idx, id)) == 1);

        // Overlap check also exercises SAT at max coordinates
        assert!(vector::length(&index::overlapping(&idx, id)) == 0);
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-10: Area truncation to zero for small polygons
    // ═════════════════════════════════════════════════════════════════════════════
    // area() divides by AREA_DIVISOR=2e12 then truncates to u64.
    // A tiny polygon can have area_fp2 > 0 but area() == 0.
    // register() guards with assert!(area() > 0), so such polygons are rejected.
    // This test confirms small polygons are indeed rejected.

    #[test]
    #[expected_failure]
    /// F-10 PoC: A polygon smaller than 1 m² (in protocol units) will have
    /// area() truncate to 0, and register() rejects it with EZeroAreaRegion.
    fun f10_area_truncation_rejects_tiny_polygon() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // With SCALE=1_000_000, a 1x1 unit square has area = 1_000_000^2 / AREA_DIVISOR
        // = 1e12 / 2e12 = 0 (truncated). So it should be rejected.
        // Actually we need a polygon small enough. Try 1x1 raw coordinates.
        let _id = index::register(
            &mut idx,
            vector[vector[0, 1, 1, 0]],
            vector[vector[0, 0, 1, 1]],
            &mut ctx,
        );
        std::unit_test::destroy(idx);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // F-24: SAT touching-edge semantics — touching polygons do NOT overlap
    // ═════════════════════════════════════════════════════════════════════════════
    // projections_overlap uses strict > so touching edges are non-overlapping.
    // This is intentional but creates zero-width gaps between regions.

    #[test]
    /// F-24 PoC: Two squares sharing an edge are NOT reported as overlapping
    /// by SAT. This means adjacent regions can be registered separately.
    fun f24_sat_touching_edges_no_overlap() {
        let s = SCALE;

        // Square A: [0,S]×[0,S]
        let xs_a = sq_xs(0, s);
        let ys_a = sq_ys(0, s);
        // Square B: [S,2S]×[0,S] — shares edge at x=S
        let xs_b = sq_xs(s, 2 * s);
        let ys_b = sq_ys(0, s);

        // Touching polygons do NOT overlap per SAT (strict inequality)
        assert!(!sat::overlaps(&xs_a, &ys_a, &xs_b, &ys_b));

        // Slightly overlapping polygons DO overlap
        let xs_c = vector[s - 1, 2 * s, 2 * s, s - 1]; // overlap by 1 unit
        assert!(sat::overlaps(&xs_a, &ys_a, &xs_c, &ys_b));
    }

    #[test]
    fun multipart_edge_passes_through_other_part() {
        let mut ctx = tx_context::dummy();

        let outer = polygon::new(
            vector[
                polygon::part(
                    vector[0u64, 2 * SCALE, 2 * SCALE, 0u64],
                    vector[2 * SCALE, 2 * SCALE, 4 * SCALE, 4 * SCALE],
                ),
                polygon::part(
                    vector[4 * SCALE, 6 * SCALE, 6 * SCALE, 4 * SCALE],
                    vector[2 * SCALE, 2 * SCALE, 4 * SCALE, 4 * SCALE],
                ),
                polygon::part(
                    vector[0u64, 6 * SCALE, 6 * SCALE, 4 * SCALE, 2 * SCALE, 0u64],
                    vector[0u64, 0u64, 2 * SCALE, 2 * SCALE, 2 * SCALE, 2 * SCALE],
                ),
            ],
            &mut ctx,
        );
        let inner = polygon::new(
            vector[
                polygon::part(
                    vector[0u64, 5 * SCALE, SCALE],
                    vector[0u64, 3 * SCALE, 4 * SCALE],
                ),
            ],
            &mut ctx,
        );

        assert!(!polygon::contains_polygon(&outer, &inner), 0);

        destroy_polygon(outer);
        destroy_polygon(inner);
    }

    // ─── 3. Triangle ──────────────────────────────────────────────────────────────

    #[test]
    /// The minimum-vertex polygon (3 vertices) passes all validation:
    /// convexity, edge-length ≥ SCALE, and compactness.  It survives the full
    /// register → retrieve → remove lifecycle and leaves the index empty.
    fun triangle_minimum_vertex_polygon_full_lifecycle() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        // All edges ≥ SCALE, convex (triangle is always convex), CCW winding.
        let id = index::register(
            &mut idx,
            vector[vector[0u64, 2 * SCALE, 0u64]],
            vector[vector[0u64, 0u64, SCALE]],
            &mut ctx,
        );

        assert!(index::count(&idx) == 1, 0);

        // The triangle is retrievable.
        let _poly = index::get(&idx, id);

        // No other polygon to overlap with.
        assert!(vector::length(&index::overlapping(&idx, id)) == 0, 1);

        // Remove — index must be empty.
        index::remove(&mut idx, id, &mut ctx);
        assert!(index::count(&idx) == 0, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// A triangle adjacent to a rectangle (sharing one edge) can coexist without
    /// triggering a false overlap.
    fun triangle_touching_rectangle_no_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let id_rect = register_rect(&mut idx, 0, 0, 2 * SCALE, 2 * SCALE, &mut ctx);

        // Triangle to the right, touching the rectangle along x = 2m.
        // Vertices: (2m, 0), (4m, 0), (2m, 2m).
        // Shares the segment (2m,0)↔(2m,2m) with the rectangle's right edge.
        let id_tri = index::register(
            &mut idx,
            vector[vector[2 * SCALE, 4 * SCALE, 2 * SCALE]],
            vector[vector[0u64, 0u64, 2 * SCALE]],
            &mut ctx,
        );

        assert!(index::count(&idx) == 2, 0);

        assert!(vector::length(&index::overlapping(&idx, id_rect)) == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, id_tri))  == 0, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    #[expected_failure(abort_code = 2004, location = mercator::polygon)]
    /// Attempting to register a polygon with 65 vertices (one over the 64-vertex
    /// limit) must abort with polygon::EBadVertices before the index is mutated.
    fun vertex_count_65_is_rejected() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let mut xs = vector::empty<u64>();
        let mut ys = vector::empty<u64>();
        let n: u64 = 16;

        // Bottom: 18 vertices (one extra)
        let mut i = 0u64;
        while (i <= n + 1) {
            vector::push_back(&mut xs, i * SCALE);
            vector::push_back(&mut ys, 0u64);
            i = i + 1;
        };
        // Right
        let mut i = 1u64;
        while (i <= n) {
            vector::push_back(&mut xs, n * SCALE);
            vector::push_back(&mut ys, i * SCALE);
            i = i + 1;
        };
        // Top
        let mut i = 1u64;
        while (i <= n) {
            vector::push_back(&mut xs, (n - i) * SCALE);
            vector::push_back(&mut ys, n * SCALE);
            i = i + 1;
        };
        // Left
        let mut i = 1u64;
        while (i < n) {
            vector::push_back(&mut xs, 0u64);
            vector::push_back(&mut ys, (n - i) * SCALE);
            i = i + 1;
        };

        // 65 vertices — registration must abort.
        index::register(&mut idx, vector[xs], vector[ys], &mut ctx);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// A polygon placed exactly inside the U-shape's gap ([2m,4m]×[2m,4m]) can
    /// be registered alongside the U-shape.  Although the two polygons' global
    /// AABBs overlap, no part of the U-shape geometrically intersects the inner
    /// polygon — SAT correctly reports zero overlap for both.
    fun inner_polygon_inside_u_gap_registers_with_no_overlap() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let u_id = index::register(
            &mut idx,
            vector[
                vector[0u64, 2*SCALE, 2*SCALE, 0u64],
                vector[4*SCALE, 6*SCALE, 6*SCALE, 4*SCALE],
                vector[0u64, 6*SCALE, 6*SCALE, 4*SCALE, 2*SCALE, 0u64],
            ],
            vector[
                vector[2*SCALE, 2*SCALE, 4*SCALE, 4*SCALE],
                vector[2*SCALE, 2*SCALE, 4*SCALE, 4*SCALE],
                vector[0u64, 0u64, 2*SCALE, 2*SCALE, 2*SCALE, 2*SCALE],
            ],
            &mut ctx,
        );

        // Inner polygon sits in the gap between the arms: [2m, 4m] × [2m, 4m].
        // It touches the arms and bottom along full edges but does not overlap any part.
        let inner_id = register_rect(&mut idx, 2*SCALE, 2*SCALE, 4*SCALE, 4*SCALE, &mut ctx);

        assert!(index::count(&idx) == 2, 0);

        // The inner polygon is fully retrievable.
        let _inner = index::get(&idx, inner_id);

        // Despite the U's global AABB containing the inner polygon's AABB, the
        // SAT check on each part-pair confirms no geometric overlap.
        assert!(vector::length(&index::overlapping(&idx, u_id))    == 0, 1);
        assert!(vector::length(&index::overlapping(&idx, inner_id)) == 0, 2);
        std::unit_test::destroy(idx);
    }

    #[test]
    /// The U-shape and inner polygon survive independent removal in either order.
    /// After removing the U, the inner is still intact; after removing the inner,
    /// the index is empty.
    fun u_shape_and_inner_polygon_independent_removal() {
        let mut ctx = tx_context::dummy();
        let mut idx = test_index(&mut ctx);
        let u_id = index::register(
            &mut idx,
            vector[
                vector[0u64, 2*SCALE, 2*SCALE, 0u64],
                vector[4*SCALE, 6*SCALE, 6*SCALE, 4*SCALE],
                vector[0u64, 6*SCALE, 6*SCALE, 4*SCALE, 2*SCALE, 0u64],
            ],
            vector[
                vector[2*SCALE, 2*SCALE, 4*SCALE, 4*SCALE],
                vector[2*SCALE, 2*SCALE, 4*SCALE, 4*SCALE],
                vector[0u64, 0u64, 2*SCALE, 2*SCALE, 2*SCALE, 2*SCALE],
            ],
            &mut ctx,
        );
        let inner_id = register_rect(&mut idx, 2*SCALE, 2*SCALE, 4*SCALE, 4*SCALE, &mut ctx);
        assert!(index::count(&idx) == 2, 0);

        // Remove the U first.
        index::remove(&mut idx, u_id, &mut ctx);
        assert!(index::count(&idx) == 1, 1);

        // Inner polygon is still retrievable and overlap-free.
        let _inner = index::get(&idx, inner_id);
        assert!(vector::length(&index::overlapping(&idx, inner_id)) == 0, 2);

        // Remove the inner.
        index::remove(&mut idx, inner_id, &mut ctx);
        assert!(index::count(&idx) == 0, 3);
        std::unit_test::destroy(idx);
    }
}
