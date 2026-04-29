/// Separating Axis Theorem (SAT) for convex polygon overlap.
module mercator::sat {
    use mercator::{aabb::{Self, AABB}, signed::{Self, Signed}};

    #[test_only]
    const TEST_SCALE: u64 = 1_000_000;

    // === Imports ===

    // === Errors ===
    const EBadVertices: u64 = 1001;
    const EMismatch: u64 = 1002;
    const EZeroAxis: u64 = 1004;

    // === Constants ===

    // === Structs ===

    /// A perpendicular projection axis for the SAT algorithm.
    /// Temporary computation value — `store` removed per F-22.
    public struct Axis has copy, drop {
        dx: u64,
        dy: u64,
        negative_dx: bool,
        negative_dy: bool,
    }

    // === Public Functions ===

    public fun overlaps(
        xs_a: &vector<u64>,
        ys_a: &vector<u64>,
        xs_b: &vector<u64>,
        ys_b: &vector<u64>,
    ): bool {
        sat_intersect_parts(xs_a, ys_a, xs_b, ys_b)
    }

    /// SAT overlap check with a fast AABB pre-filter.
    public fun overlaps_with_aabb(
        xs_a: &vector<u64>,
        ys_a: &vector<u64>,
        xs_b: &vector<u64>,
        ys_b: &vector<u64>,
    ): bool {
        let aabb_a: AABB = aabb::from_vertices(xs_a, ys_a);
        let aabb_b: AABB = aabb::from_vertices(xs_b, ys_b);

        if (!aabb::intersects(&aabb_a, &aabb_b)) {
            return false
        };

        sat_intersect_parts(xs_a, ys_a, xs_b, ys_b)
    }

    /// SAT overlap test for two convex parts represented by vertex arrays.
    public fun sat_intersect_parts(
        xs_a: &vector<u64>,
        ys_a: &vector<u64>,
        xs_b: &vector<u64>,
        ys_b: &vector<u64>,
    ): bool {
        validate_polygon(xs_a, ys_a);
        validate_polygon(xs_b, ys_b);

        if (
            has_separating_axis(
                xs_a,
                ys_a,
                xs_a,
                ys_a,
                xs_b,
                ys_b,
            )
        ) {
            return false
        };

        if (
            has_separating_axis(
                xs_b,
                ys_b,
                xs_a,
                ys_a,
                xs_b,
                ys_b,
            )
        ) {
            return false
        };

        true
    }

    // === Private Functions ===

    fun perp_axis(x1: u64, y1: u64, x2: u64, y2: u64): Axis {
        let edge_dx = signed::sub_u64(x2, x1);
        let edge_dy = signed::sub_u64(y2, y1);

        Axis {
            dx: (signed::magnitude(&edge_dy) as u64),
            dy: (signed::magnitude(&edge_dx) as u64),
            negative_dx: negated_sign(&edge_dy),
            negative_dy: signed::is_negative(&edge_dx),
        }
    }

    fun dot_signed(x: u64, y: u64, axis: &Axis): Signed {
        let term_x = signed::new(
            (x as u128) * (axis.dx as u128),
            axis.negative_dx,
        );
        let term_y = signed::new(
            (y as u128) * (axis.dy as u128),
            axis.negative_dy,
        );

        signed::add(&term_x, &term_y)
    }

    fun project(xs: &vector<u64>, ys: &vector<u64>, axis: &Axis): (Signed, Signed) {
        let n = vector::length(xs);
        let first_proj = dot_signed(
            *vector::borrow(xs, 0),
            *vector::borrow(ys, 0),
            axis,
        );

        let mut min_proj = first_proj;
        let mut max_proj = first_proj;

        let mut i = 1;
        while (i < n) {
            let proj = dot_signed(
                *vector::borrow(xs, i),
                *vector::borrow(ys, i),
                axis,
            );

            if (signed::lt(&proj, &min_proj)) {
                min_proj = proj;
            };
            if (signed::gt(&proj, &max_proj)) {
                max_proj = proj;
            };

            i = i + 1;
        };

        (min_proj, max_proj)
    }

    fun validate_polygon(xs: &vector<u64>, ys: &vector<u64>) {
        let n = vector::length(xs);
        assert!(n >= 3, EBadVertices);
        assert!(n == vector::length(ys), EMismatch);
    }

    fun has_separating_axis(
        edge_xs: &vector<u64>,
        edge_ys: &vector<u64>,
        xs_a: &vector<u64>,
        ys_a: &vector<u64>,
        xs_b: &vector<u64>,
        ys_b: &vector<u64>,
    ): bool {
        let n = vector::length(edge_xs);
        let mut i = 0;

        while (i < n) {
            let next = if (i + 1 < n) { i + 1 } else { 0 };
            let axis = perp_axis(
                *vector::borrow(edge_xs, i),
                *vector::borrow(edge_ys, i),
                *vector::borrow(edge_xs, next),
                *vector::borrow(edge_ys, next),
            );

            // Fail-closed: a zero axis means degenerate geometry slipped past upstream
            // edge-length validation. Abort instead of silently skipping.
            assert!(axis.dx != 0 || axis.dy != 0, EZeroAxis);
            {
                let (min_a, max_a) = project(xs_a, ys_a, &axis);
                let (min_b, max_b) = project(xs_b, ys_b, &axis);

                if (
                    !projections_overlap(
                        &min_a,
                        &max_a,
                        &min_b,
                        &max_b,
                    )
                ) {
                    return true
                };
            };

            i = i + 1;
        };

        false
    }

    fun projections_overlap(min_a: &Signed, max_a: &Signed, min_b: &Signed, max_b: &Signed): bool {
        signed::gt(max_a, min_b) && signed::gt(max_b, min_a)
    }

    fun negated_sign(value: &Signed): bool {
        signed::magnitude(value) != 0 && !signed::is_negative(value)
    }

    #[test]
    fun sat_gap_detected() {
        let xs_a = vector[0, TEST_SCALE, TEST_SCALE, 0];
        let ys_a = vector[0, 0, TEST_SCALE, TEST_SCALE];

        let xs_b = vector[2 * TEST_SCALE, 3 * TEST_SCALE, 3 * TEST_SCALE, 2 * TEST_SCALE];
        let ys_b = vector[0, 0, TEST_SCALE, TEST_SCALE];

        assert!(!overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    #[test]
    fun sat_touching_edges_do_not_overlap() {
        let xs_a = vector[0, TEST_SCALE, TEST_SCALE, 0];
        let ys_a = vector[0, 0, TEST_SCALE, TEST_SCALE];

        let xs_b = vector[TEST_SCALE, 2 * TEST_SCALE, 2 * TEST_SCALE, TEST_SCALE];
        let ys_b = vector[0, 0, TEST_SCALE, TEST_SCALE];

        assert!(!overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    #[test]
    fun sat_overlap_detected() {
        let xs_a = vector[0, 2 * TEST_SCALE, 2 * TEST_SCALE, 0];
        let ys_a = vector[0, 0, 2 * TEST_SCALE, 2 * TEST_SCALE];

        let xs_b = vector[TEST_SCALE, 3 * TEST_SCALE, 3 * TEST_SCALE, TEST_SCALE];
        let ys_b = vector[TEST_SCALE, TEST_SCALE, 3 * TEST_SCALE, 3 * TEST_SCALE];

        assert!(overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    #[test]
    fun sat_micro_overlap_detected() {
        let xs_a = vector[0, TEST_SCALE, TEST_SCALE, 0];
        let ys_a = vector[0, 0, TEST_SCALE, TEST_SCALE];

        let xs_b = vector[TEST_SCALE - 1, 2 * TEST_SCALE - 1, 2 * TEST_SCALE - 1, TEST_SCALE - 1];
        let ys_b = vector[0, 0, TEST_SCALE, TEST_SCALE];

        assert!(overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    #[test]
    fun sat_corner_touching_does_not_overlap() {
        let xs_a = vector[0, TEST_SCALE, TEST_SCALE, 0];
        let ys_a = vector[0, 0, TEST_SCALE, TEST_SCALE];

        let xs_b = vector[TEST_SCALE, 2 * TEST_SCALE, 2 * TEST_SCALE, TEST_SCALE];
        let ys_b = vector[TEST_SCALE, TEST_SCALE, 2 * TEST_SCALE, 2 * TEST_SCALE];

        assert!(!overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    #[test]
    fun sat_triangle_touching_does_not_overlap() {
        let xs_a = vector[0, 2 * TEST_SCALE, TEST_SCALE];
        let ys_a = vector[0, 0, 2 * TEST_SCALE];

        let xs_b = vector[2 * TEST_SCALE, 3 * TEST_SCALE, 2 * TEST_SCALE + TEST_SCALE / 2];
        let ys_b = vector[0, 0, TEST_SCALE];

        assert!(!overlaps(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }

    #[test]
    fun aabb_pipeline_rejects_far_polygons() {
        let xs_a = vector[0, TEST_SCALE, TEST_SCALE, 0];
        let ys_a = vector[0, 0, TEST_SCALE, TEST_SCALE];

        let xs_b = vector[3 * TEST_SCALE, 4 * TEST_SCALE, 4 * TEST_SCALE, 3 * TEST_SCALE];
        let ys_b = vector[0, 0, TEST_SCALE, TEST_SCALE];

        assert!(!overlaps_with_aabb(&xs_a, &ys_a, &xs_b, &ys_b), 0);
    }
}
