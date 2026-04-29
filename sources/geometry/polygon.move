/// Multi-part polygon representation for spatial region geometry.
/// A Polygon is a union of convex Parts with strict topology checks.
module mercator::polygon {
    use mercator::{aabb::{Self, AABB}, sat, signed, topology};
    use std::u128;

    // === Imports ===

    // === Errors ===

    const EEmpty: u64 = 2001;
    const ETooManyParts: u64 = 2002;
    const ENotConvex: u64 = 2003;
    const EBadVertices: u64 = 2004;
    const EMismatch: u64 = 2005;
    const EEdgeTooShort: u64 = 2010;
    const EAreaConservationViolation: u64 = 2012;
    const ECoordinateOutOfWorld: u64 = 2013;
    const EArithmeticOverflow: u64 = 2014;

    // === Constants ===

    /// Maximum coordinate value in the world grid. Default sized for Web Mercator Earth
    /// (≈40.075 trillion µm), but can be reinterpreted for any 2D domain.
    /// The library only requires `x, y ∈ [0, MAX_WORLD]` and a consistent unit scale.
    /// Fork and adjust for game boards, virtual worlds, or different coordinate systems.
    const MAX_WORLD: u64 = 40_075_017_000_000;

    const MAX_PARTS: u64 = 10;
    const MAX_VERTICES_PER_PART: u64 = 64;
    const EDGE_SAMPLE_DIVISOR: u64 = 3;
    const MIN_VERTICES: u64 = 3;
    /// Minimum edge length squared (= SCALE²). Prevents degenerate micro-polygons.
    const MIN_EDGE_LENGTH_SQUARED: u128 = 1_000_000_000_000;
    const AREA_DIVISOR: u128 = 2_000_000_000_000;

    // === Structs ===

    /// A single convex sub-polygon with precomputed bounding box.
    public struct Part has copy, drop, store {
        xs: vector<u64>,
        ys: vector<u64>,
        aabb: AABB,
    }

    /// A spatial region — union of convex Parts.
    public struct Polygon has key, store {
        id: object::UID,
        parts: vector<Part>,
        global_aabb: AABB,
        cells: vector<u64>,
        owner: address,
        created_epoch: u64,
        total_vertices: u64,
        part_count: u64,
    }

    // === Public Functions ===

    /// Construct a Part from vertex arrays.
    public fun part(xs: vector<u64>, ys: vector<u64>): Part {
        let xs_len = vector::length(&xs);
        let mut i = 0;
        while (i < xs_len) {
            assert!(*vector::borrow(&xs, i) <= MAX_WORLD, ECoordinateOutOfWorld);
            i = i + 1;
        };

        let ys_len = vector::length(&ys);
        i = 0;
        while (i < ys_len) {
            assert!(*vector::borrow(&ys, i) <= MAX_WORLD, ECoordinateOutOfWorld);
            i = i + 1;
        };

        validate_part_arrays(&xs, &ys);
        validate_part_edges(&xs, &ys);
        assert!(is_convex_vertices(&xs, &ys), ENotConvex);

        let aabb = aabb::from_vertices(&xs, &ys);
        Part { xs, ys, aabb }
    }

    /// Construct a Polygon from its convex parts.
    public fun new(parts: vector<Part>, ctx: &mut tx_context::TxContext): Polygon {
        let part_count = vector::length(&parts);
        assert!(part_count > 0, EEmpty);
        assert!(part_count <= MAX_PARTS, ETooManyParts);

        validate_multipart_topology(&parts);

        Polygon {
            id: object::new(ctx),
            global_aabb: compute_global_aabb(&parts),
            total_vertices: total_vertices(&parts),
            part_count,
            cells: vector::empty<u64>(),
            owner: tx_context::sender(ctx),
            created_epoch: tx_context::epoch(ctx),
            parts,
        }
    }

    public fun max_vertices_per_part(): u64 {
        MAX_VERTICES_PER_PART
    }

    public fun max_parts(): u64 {
        MAX_PARTS
    }

    /// Construct Parts from coordinate arrays and validate them.
    /// Returns (parts, global_aabb, total_vertices, part_count).
    /// Validates convexity, edge length, and multipart topology.
    /// `max_vertices_per_part` is the admin-configurable per-part vertex limit (F-28).
    public(package) fun prepare_geometry(
        parts_xs: vector<vector<u64>>,
        parts_ys: vector<vector<u64>>,
        max_vertices_per_part: u64,
    ): (vector<Part>, AABB, u64, u64) {
        let mut parts_xs = parts_xs;
        let mut parts_ys = parts_ys;
        let part_count = vector::length(&parts_xs);
        assert!(part_count > 0, EEmpty);
        assert!(part_count <= MAX_PARTS, ETooManyParts);
        assert!(part_count == vector::length(&parts_ys), EMismatch);

        let mut parts = vector::empty<Part>();
        let mut i = 0;

        while (i < part_count) {
            let xs = vector::remove(&mut parts_xs, 0);
            let ys = vector::remove(&mut parts_ys, 0);
            // Enforce admin-configured vertex limit before constructing part (F-28).
            assert!(vector::length(&xs) <= max_vertices_per_part, EBadVertices);
            let p = part(xs, ys);
            vector::push_back(&mut parts, p);
            i = i + 1;
        };

        validate_multipart_topology(&parts);

        let global_aabb = compute_global_aabb(&parts);
        let total_verts = total_vertices(&parts);

        (parts, global_aabb, total_verts, part_count)
    }

    /// Assert that two exact area sums in fixed-point squared units are equal.
    /// Aborts with EAreaConservationViolation if not.
    public(package) fun assert_area_conserved(old_area_sum: u128, new_area_sum: u128) {
        assert!(old_area_sum == new_area_sum, EAreaConservationViolation);
    }

    /// Checked u128 addition for area accumulators.
    /// Aborts with EAreaConservationViolation on overflow instead of a generic
    /// arithmetic abort — any overflow means conservation cannot hold.
    public(package) fun checked_area_sum(a: u128, b: u128): u128 {
        let sum = u128::checked_add(a, b);
        assert!(option::is_some(&sum), EAreaConservationViolation);
        option::destroy_some(sum)
    }

    /// True iff the two polygons overlap (SAT per part-pair).
    public fun intersects(a: &Polygon, b: &Polygon): bool {
        if (!aabb::intersects(&a.global_aabb, &b.global_aabb)) {
            return false
        };

        let count_a = a.part_count;
        let count_b = b.part_count;

        if (count_a == 1 && count_b == 1) {
            let part_a = vector::borrow(&a.parts, 0);
            let part_b = vector::borrow(&b.parts, 0);
            return sat::overlaps(
                    &part_a.xs,
                    &part_a.ys,
                    &part_b.xs,
                    &part_b.ys,
                )
        };

        let mut i = 0;
        while (i < count_a) {
            let part_a = vector::borrow(&a.parts, i);
            let mut j = 0;

            while (j < count_b) {
                let part_b = vector::borrow(&b.parts, j);

                if (
                    aabb::intersects(
                    &part_a.aabb,
                    &part_b.aabb,
                ) && sat::overlaps(
                    &part_a.xs,
                    &part_a.ys,
                    &part_b.xs,
                    &part_b.ys,
                )
                ) {
                    return true
                };

                j = j + 1;
            };

            i = i + 1;
        };

        false
    }

    /// Global AABB enclosing all parts.
    public fun bounds(polygon: &Polygon): AABB {
        polygon.global_aabb
    }

    /// Number of convex parts.
    public fun parts(polygon: &Polygon): u64 {
        polygon.part_count
    }

    /// Total vertex count across all parts.
    public fun vertices(polygon: &Polygon): u64 {
        polygon.total_vertices
    }

    /// Owner address of this region.
    public fun owner(polygon: &Polygon): address {
        polygon.owner
    }

    /// Epoch when this polygon was created.
    public fun created_epoch(polygon: &Polygon): u64 {
        polygon.created_epoch
    }

    /// Grid cell IDs this polygon covers.
    public fun cells(polygon: &Polygon): &vector<u64> {
        &polygon.cells
    }

    /// Compute the area of this polygon in whole base-unit² (lossy truncation from fixed-point).
    /// With default SCALE, 1 base unit = 1 meter, so the result is in square meters.
    /// Polygons with true area < 1 m² truncate to 0. This function is intended for
    /// display, events, and the `register()` zero-area guard only.
    /// **All internal conservation arithmetic MUST use `area_fp2()` instead** — it
    /// returns the exact twice-area in fixed-point squared units with no truncation.
    /// See F-10 in the security audit for details.
    public fun area(polygon: &Polygon): u64 {
        ((polygon_twice_area_fp2(&polygon.parts) / AREA_DIVISOR) as u64)
    }

    /// Compute the exact polygon twice-area in fixed-point squared units.
    public(package) fun area_fp2(polygon: &Polygon): u128 {
        polygon_twice_area_fp2(&polygon.parts)
    }

    /// Compute area from prepared parts without constructing a Polygon object.
    public(package) fun area_from_parts(parts: &vector<Part>): u64 {
        ((polygon_twice_area_fp2(parts) / AREA_DIVISOR) as u64)
    }

    /// Compute the exact prepared-parts twice-area in fixed-point squared units.
    public(package) fun area_fp2_from_parts(parts: &vector<Part>): u128 {
        polygon_twice_area_fp2(parts)
    }

    // === Package Functions ===

    public(package) fun touches_by_edge(a: &Polygon, b: &Polygon): bool {
        if (
            !topology::aabbs_may_contact(
                &a.global_aabb,
                &b.global_aabb,
            )
        ) {
            return false
        };

        let count_a = a.part_count;
        let count_b = b.part_count;

        if (count_a == 1 && count_b == 1) {
            let part_a = vector::borrow(&a.parts, 0);
            let part_b = vector::borrow(&b.parts, 0);
            let topo_a = to_topology_part(part_a);
            let topo_b = to_topology_part(part_b);
            if (
                topology::has_exact_shared_edge(
                    &topo_a,
                    &topo_b,
                )
            ) {
                let (shared, code) = topology::shared_edge_relation(
                    &topo_a,
                    &topo_b,
                );
                assert!(code == 0, code);
                return shared
            };

            if (aabb::intersects(&part_a.aabb, &part_b.aabb)) {
                let (_, code) = topology::shared_edge_relation(
                    &topo_a,
                    &topo_b,
                );
                assert!(code == 0, code);
            };

            return false
        };

        let mut i = 0;
        while (i < count_a) {
            let part_a = vector::borrow(&a.parts, i);
            let mut j = 0;

            while (j < count_b) {
                let part_b = vector::borrow(&b.parts, j);
                if (
                    topology::aabbs_may_contact(
                        &part_a.aabb,
                        &part_b.aabb,
                    )
                ) {
                    let topo_a = to_topology_part(part_a);
                    let topo_b = to_topology_part(part_b);
                    if (
                        topology::has_exact_shared_edge(
                            &topo_a,
                            &topo_b,
                        )
                    ) {
                        let (shared, code) = topology::shared_edge_relation(
                            &topo_a,
                            &topo_b,
                        );
                        assert!(code == 0, code);
                        if (shared) {
                            return true
                        };
                    };
                };
                j = j + 1;
            };

            i = i + 1;
        };

        false
    }

    /// Check whether two sets of prepared parts share at least one edge.
    /// Mirrors `touches_by_edge` but accepts raw `vector<Part>` + AABB instead of
    /// full Polygon objects — used by `repartition_adjacent` to validate that the
    /// two output geometries remain adjacent after the boundary redistribution.
    public(package) fun touches_by_edge_by_parts(
        parts_a: &vector<Part>,
        aabb_a: &AABB,
        parts_b: &vector<Part>,
        aabb_b: &AABB,
    ): bool {
        if (!topology::aabbs_may_contact(aabb_a, aabb_b)) {
            return false
        };

        let count_a = vector::length(parts_a);
        let count_b = vector::length(parts_b);

        if (count_a == 1 && count_b == 1) {
            let part_a = vector::borrow(parts_a, 0);
            let part_b = vector::borrow(parts_b, 0);
            let topo_a = to_topology_part(part_a);
            let topo_b = to_topology_part(part_b);
            if (
                topology::has_exact_shared_edge(
                    &topo_a,
                    &topo_b,
                )
            ) {
                let (shared, code) = topology::shared_edge_relation(
                    &topo_a,
                    &topo_b,
                );
                assert!(code == 0, code);
                return shared
            };

            if (aabb::intersects(&part_a.aabb, &part_b.aabb)) {
                let (_, code) = topology::shared_edge_relation(
                    &topo_a,
                    &topo_b,
                );
                assert!(code == 0, code);
            };

            return false
        };

        let mut i = 0;
        while (i < count_a) {
            let part_a = vector::borrow(parts_a, i);
            let mut j = 0;

            while (j < count_b) {
                let part_b = vector::borrow(parts_b, j);
                if (
                    topology::aabbs_may_contact(
                        &part_a.aabb,
                        &part_b.aabb,
                    )
                ) {
                    let topo_a = to_topology_part(part_a);
                    let topo_b = to_topology_part(part_b);
                    if (
                        topology::has_exact_shared_edge(
                            &topo_a,
                            &topo_b,
                        )
                    ) {
                        let (shared, code) = topology::shared_edge_relation(
                            &topo_a,
                            &topo_b,
                        );
                        assert!(code == 0, code);
                        if (shared) {
                            return true
                        };
                    };
                };
                j = j + 1;
            };

            i = i + 1;
        };

        false
    }

    public fun contains_polygon(outer: &Polygon, inner: &Polygon): bool {
        if (
            !aabb_contains_or_touches(
                &outer.global_aabb,
                &inner.global_aabb,
            )
        ) {
            return false
        };

        let inner_count = vector::length(&inner.parts);
        let mut i = 0;
        while (i < inner_count) {
            if (
                !part_is_inside_polygon(
                    outer,
                    vector::borrow(&inner.parts, i),
                )
            ) {
                return false
            };
            i = i + 1;
        };

        true
    }

    public(package) fun contains_polygon_by_parts(
        outer_parts: &vector<Part>,
        outer_aabb: &AABB,
        inner: &Polygon,
    ): bool {
        if (
            !aabb_contains_or_touches(
                outer_aabb,
                &inner.global_aabb,
            )
        ) {
            return false
        };

        let inner_count = vector::length(&inner.parts);
        let mut i = 0;
        while (i < inner_count) {
            if (
                !part_is_inside_parts(
                    outer_parts,
                    vector::borrow(&inner.parts, i),
                )
            ) {
                return false
            };
            i = i + 1;
        };

        true
    }

    public(package) fun intersects_polygon_by_parts(
        parts: &vector<Part>,
        parts_aabb: &AABB,
        other: &Polygon,
    ): bool {
        if (!aabb::intersects(parts_aabb, &other.global_aabb)) {
            return false
        };

        let count_a = vector::length(parts);
        let count_b = vector::length(&other.parts);

        let mut i = 0;
        while (i < count_a) {
            let part_a = vector::borrow(parts, i);
            let mut j = 0;
            while (j < count_b) {
                let part_b = vector::borrow(&other.parts, j);
                if (
                    aabb::intersects(&part_a.aabb, &part_b.aabb)
                    && sat::overlaps(
                        &part_a.xs,
                        &part_a.ys,
                        &part_b.xs,
                        &part_b.ys,
                    )
                ) {
                    return true
                };
                j = j + 1;
            };
            i = i + 1;
        };

        false
    }

    public(package) fun intersects_parts_by_parts(
        parts_a: &vector<Part>,
        aabb_a: &AABB,
        parts_b: &vector<Part>,
        aabb_b: &AABB,
    ): bool {
        if (!aabb::intersects(aabb_a, aabb_b)) {
            return false
        };

        let count_a = vector::length(parts_a);
        let count_b = vector::length(parts_b);
        let mut i = 0;
        while (i < count_a) {
            let part_a = vector::borrow(parts_a, i);
            let mut j = 0;
            while (j < count_b) {
                let part_b = vector::borrow(parts_b, j);
                if (
                    aabb::intersects(&part_a.aabb, &part_b.aabb)
                    && sat::overlaps(
                        &part_a.xs,
                        &part_a.ys,
                        &part_b.xs,
                        &part_b.ys,
                    )
                ) {
                    return true
                };
                j = j + 1;
            };
            i = i + 1;
        };

        false
    }

    /// Set grid cell IDs on this polygon. Called by index::register() after computing coverage.
    public(package) fun set_cells(polygon: &mut Polygon, cells: vector<u64>) {
        polygon.cells = cells;
    }

    /// Set the owner of this polygon. Package-internal function.
    public(package) fun set_owner(polygon: &mut Polygon, new_owner: address) {
        polygon.owner = new_owner;
    }

    /// Set the parts of this polygon and auto-recompute global_aabb, total_vertices, and part_count.
    public(package) fun set_parts(polygon: &mut Polygon, new_parts: vector<Part>) {
        polygon.global_aabb = compute_global_aabb(&new_parts);
        polygon.total_vertices = total_vertices(&new_parts);
        polygon.part_count = vector::length(&new_parts);
        polygon.parts = new_parts;
    }

    /// Set the global AABB of this polygon. Package-internal function.
    public(package) fun set_global_aabb(polygon: &mut Polygon, new_aabb: AABB) {
        polygon.global_aabb = new_aabb;
    }

    /// Set the total vertex count of this polygon. Package-internal function.
    public(package) fun set_total_vertices(polygon: &mut Polygon, count: u64) {
        polygon.total_vertices = count;
    }

    /// Set the part count of this polygon. Package-internal function.
    public(package) fun set_part_count(polygon: &mut Polygon, count: u64) {
        polygon.part_count = count;
    }

    /// Destroy this polygon, freeing its UID. Called by index::remove_unchecked().
    public(package) fun destroy(polygon: Polygon) {
        let Polygon {
            id,
            parts: _,
            global_aabb: _,
            cells: _,
            owner: _,
            created_epoch: _,
            total_vertices: _,
            part_count: _,
        } = polygon;
        object::delete(id);
    }

    // === Private Functions ===

    fun validate_part_arrays(xs: &vector<u64>, ys: &vector<u64>) {
        let count = vector::length(xs);
        assert!(count >= MIN_VERTICES, EBadVertices);
        assert!(count <= MAX_VERTICES_PER_PART, EBadVertices);
        assert!(count == vector::length(ys), EMismatch);
    }

    fun part_is_inside_polygon(outer: &Polygon, inner_part: &Part): bool {
        let vertex_count = vector::length(&inner_part.xs);
        let mut i = 0;

        while (i < vertex_count) {
            let px = *vector::borrow(&inner_part.xs, i);
            let py = *vector::borrow(&inner_part.ys, i);
            if (
                !point_inside_any_part_or_on_boundary(
                    outer,
                    px,
                    py,
                )
            ) {
                return false
            };
            i = i + 1;
        };

        // For multi-part concave outers, vertex check alone is insufficient —
        // an inner edge can bridge two outer parts through the concave gap.
        // Sample two asymmetric points per edge (t=1/3, t=2/3) to avoid
        // degenerate cases where a midpoint lands exactly on a part boundary.
        // Skipped for single-part outers where convex ⊂ convex is proven by vertices.
        if (vector::length(&outer.parts) > 1) {
            let mut j = 0;
            while (j < vertex_count) {
                let next = if (j + 1 < vertex_count) { j + 1 } else { 0 };
                let xj = *vector::borrow(&inner_part.xs, j);
                let yj = *vector::borrow(&inner_part.ys, j);
                let xn = *vector::borrow(&inner_part.xs, next);
                let yn = *vector::borrow(&inner_part.ys, next);
                // t=1/3 sample — 3× scaled, no integer division
                let t1x_scaled = 2 * xj + xn;
                let t1y_scaled = 2 * yj + yn;
                if (
                    !point_inside_any_part_or_on_boundary_parts_scaled(
                        &outer.parts,
                        t1x_scaled,
                        t1y_scaled,
                    )
                ) {
                    return false
                };
                // t=2/3 sample — 3× scaled, no integer division
                let t2x_scaled = xj + 2 * xn;
                let t2y_scaled = yj + 2 * yn;
                if (
                    !point_inside_any_part_or_on_boundary_parts_scaled(
                        &outer.parts,
                        t2x_scaled,
                        t2y_scaled,
                    )
                ) {
                    return false
                };
                j = j + 1;
            };
        };

        true
    }

    fun part_is_inside_parts(outer_parts: &vector<Part>, inner_part: &Part): bool {
        let vertex_count = vector::length(&inner_part.xs);
        let mut i = 0;

        while (i < vertex_count) {
            let px = *vector::borrow(&inner_part.xs, i);
            let py = *vector::borrow(&inner_part.ys, i);
            if (
                !point_inside_any_part_or_on_boundary_parts(
                    outer_parts,
                    px,
                    py,
                )
            ) {
                return false
            };
            i = i + 1;
        };

        // Edge sample check for multi-part concave outers (F-02 fix).
        // Two asymmetric samples per edge (t=1/3, t=2/3) avoid boundary degeneracy.
        if (vector::length(outer_parts) > 1) {
            let mut j = 0;
            while (j < vertex_count) {
                let next = if (j + 1 < vertex_count) { j + 1 } else { 0 };
                let xj = *vector::borrow(&inner_part.xs, j);
                let yj = *vector::borrow(&inner_part.ys, j);
                let xn = *vector::borrow(&inner_part.xs, next);
                let yn = *vector::borrow(&inner_part.ys, next);
                // t=1/3 sample — 3× scaled, no integer division
                let t1x_scaled = 2 * xj + xn;
                let t1y_scaled = 2 * yj + yn;
                if (
                    !point_inside_any_part_or_on_boundary_parts_scaled(
                        outer_parts,
                        t1x_scaled,
                        t1y_scaled,
                    )
                ) {
                    return false
                };
                // t=2/3 sample — 3× scaled, no integer division
                let t2x_scaled = xj + 2 * xn;
                let t2y_scaled = yj + 2 * yn;
                if (
                    !point_inside_any_part_or_on_boundary_parts_scaled(
                        outer_parts,
                        t2x_scaled,
                        t2y_scaled,
                    )
                ) {
                    return false
                };
                j = j + 1;
            };
        };

        true
    }

    fun point_inside_any_part_or_on_boundary(polygon: &Polygon, px: u64, py: u64): bool {
        let part_count = vector::length(&polygon.parts);
        let mut i = 0;

        while (i < part_count) {
            let part_ref = vector::borrow(&polygon.parts, i);
            if (
                point_in_aabb_or_on_boundary(&part_ref.aabb, px, py)
                && point_inside_convex_part_or_on_boundary(
                    part_ref,
                    px,
                    py,
                )
            ) {
                return true
            };
            i = i + 1;
        };

        false
    }

    fun point_inside_any_part_or_on_boundary_parts(parts: &vector<Part>, px: u64, py: u64): bool {
        let part_count = vector::length(parts);
        let mut i = 0;

        while (i < part_count) {
            let part_ref = vector::borrow(parts, i);
            if (
                point_in_aabb_or_on_boundary(&part_ref.aabb, px, py)
                && point_inside_convex_part_or_on_boundary(
                    part_ref,
                    px,
                    py,
                )
            ) {
                return true
            };
            i = i + 1;
        };

        false
    }

    fun point_inside_convex_part_or_on_boundary(part: &Part, px: u64, py: u64): bool {
        let vertex_count = vector::length(&part.xs);
        let mut saw_positive = false;
        let mut saw_negative = false;
        let mut i = 0;

        while (i < vertex_count) {
            let next = if (i + 1 < vertex_count) { i + 1 } else {
                0
            };
            let cross = signed::cross_sign(
                *vector::borrow(&part.xs, i),
                *vector::borrow(&part.ys, i),
                *vector::borrow(&part.xs, next),
                *vector::borrow(&part.ys, next),
                px,
                py,
            );

            if (!topology::is_zero(&cross)) {
                if (signed::is_negative(&cross)) {
                    saw_negative = true;
                } else {
                    saw_positive = true;
                };

                if (saw_positive && saw_negative) {
                    return false
                };
            };

            i = i + 1;
        };

        true
    }

    fun point_in_aabb_or_on_boundary(box: &AABB, px: u64, py: u64): bool {
        px >= aabb::min_x(box)
        && px <= aabb::max_x(box)
        && py >= aabb::min_y(box)
        && py <= aabb::max_y(box)
    }

    fun point_in_aabb_or_on_boundary_scaled(box: &AABB, px_scaled: u64, py_scaled: u64): bool {
        px_scaled >= EDGE_SAMPLE_DIVISOR * aabb::min_x(box)
        && px_scaled <= EDGE_SAMPLE_DIVISOR * aabb::max_x(box)
        && py_scaled >= EDGE_SAMPLE_DIVISOR * aabb::min_y(box)
        && py_scaled <= EDGE_SAMPLE_DIVISOR * aabb::max_y(box)
    }

    fun point_inside_convex_part_or_on_boundary_scaled(
        part: &Part,
        px_scaled: u64,
        py_scaled: u64,
    ): bool {
        let vertex_count = vector::length(&part.xs);
        let mut saw_positive = false;
        let mut saw_negative = false;
        let mut i = 0;

        while (i < vertex_count) {
            let next = if (i + 1 < vertex_count) { i + 1 } else {
                0
            };
            let cross = signed::cross_sign(
                EDGE_SAMPLE_DIVISOR * *vector::borrow(&part.xs, i),
                EDGE_SAMPLE_DIVISOR * *vector::borrow(&part.ys, i),
                EDGE_SAMPLE_DIVISOR * *vector::borrow(&part.xs, next),
                EDGE_SAMPLE_DIVISOR * *vector::borrow(&part.ys, next),
                px_scaled,
                py_scaled,
            );

            if (!topology::is_zero(&cross)) {
                if (signed::is_negative(&cross)) {
                    saw_negative = true;
                } else {
                    saw_positive = true;
                };

                if (saw_positive && saw_negative) {
                    return false
                };
            };

            i = i + 1;
        };

        true
    }

    fun point_inside_any_part_or_on_boundary_parts_scaled(
        parts: &vector<Part>,
        px_scaled: u64,
        py_scaled: u64,
    ): bool {
        let part_count = vector::length(parts);
        let mut i = 0;

        while (i < part_count) {
            let part_ref = vector::borrow(parts, i);
            if (
                point_in_aabb_or_on_boundary_scaled(&part_ref.aabb, px_scaled, py_scaled)
                && point_inside_convex_part_or_on_boundary_scaled(
                    part_ref,
                    px_scaled,
                    py_scaled,
                )
            ) {
                return true
            };
            i = i + 1;
        };

        false
    }

    fun aabb_contains_or_touches(outer: &AABB, inner: &AABB): bool {
        aabb::min_x(outer) <= aabb::min_x(inner)
        && aabb::max_x(outer) >= aabb::max_x(inner)
        && aabb::min_y(outer) <= aabb::min_y(inner)
        && aabb::max_y(outer) >= aabb::max_y(inner)
    }

    fun validate_part_edges(xs: &vector<u64>, ys: &vector<u64>) {
        let count = vector::length(xs);
        let mut i = 0;

        while (i < count) {
            let next = if (i + 1 < count) { i + 1 } else { 0 };
            let length_squared = edge_length_squared(
                *vector::borrow(xs, i),
                *vector::borrow(ys, i),
                *vector::borrow(xs, next),
                *vector::borrow(ys, next),
            );
            assert!(length_squared >= MIN_EDGE_LENGTH_SQUARED, EEdgeTooShort);
            i = i + 1;
        };
    }

    fun is_convex_vertices(xs: &vector<u64>, ys: &vector<u64>): bool {
        let count = vector::length(xs);
        if (count < MIN_VERTICES) return false;

        let mut direction = 0u8;

        let mut x0 = *vector::borrow(xs, count - 2);
        let mut y0 = *vector::borrow(ys, count - 2);
        let mut x1 = *vector::borrow(xs, count - 1);
        let mut y1 = *vector::borrow(ys, count - 1);

        let mut i = 0;
        while (i < count) {
            let x2 = *vector::borrow(xs, i);
            let y2 = *vector::borrow(ys, i);

            let cross = signed::cross_sign(
                x0,
                y0,
                x1,
                y1,
                x2,
                y2,
            );

            if (signed::magnitude(&cross) == 0) {
                x0 = x1;
                y0 = y1;
                x1 = x2;
                y1 = y2;
                i = i + 1;
                continue
            };

            let cross_direction = if (signed::is_negative(&cross)) {
                1u8
            } else {
                2u8
            };
            if (direction == 0) {
                direction = cross_direction;
            } else if (direction != cross_direction) {
                return false
            };

            x0 = x1;
            y0 = y1;
            x1 = x2;
            y1 = y2;
            i = i + 1;
        };

        direction != 0
    }

    fun compute_global_aabb(parts: &vector<Part>): AABB {
        let count = vector::length(parts);
        if (count == 1) {
            return vector::borrow(parts, 0).aabb
        };
        let first = vector::borrow(parts, 0);
        let mut min_x = aabb::min_x(&first.aabb);
        let mut min_y = aabb::min_y(&first.aabb);
        let mut max_x = aabb::max_x(&first.aabb);
        let mut max_y = aabb::max_y(&first.aabb);

        let mut i = 1;
        while (i < count) {
            let current = vector::borrow(parts, i);
            if (aabb::min_x(&current.aabb) < min_x) {
                min_x = aabb::min_x(&current.aabb)
            };
            if (aabb::min_y(&current.aabb) < min_y) {
                min_y = aabb::min_y(&current.aabb)
            };
            if (aabb::max_x(&current.aabb) > max_x) {
                max_x = aabb::max_x(&current.aabb)
            };
            if (aabb::max_y(&current.aabb) > max_y) {
                max_y = aabb::max_y(&current.aabb)
            };
            i = i + 1;
        };

        aabb::new(min_x, min_y, max_x, max_y)
    }

    fun total_vertices(parts: &vector<Part>): u64 {
        let count = vector::length(parts);
        if (count == 1) {
            return vector::length(&vector::borrow(parts, 0).xs)
        };
        let mut total = 0;
        let mut i = 0;

        while (i < count) {
            total = total + vector::length(&vector::borrow(parts, i).xs);
            i = i + 1;
        };

        total
    }

    fun polygon_twice_area_fp2(parts: &vector<Part>): u128 {
        let count = vector::length(parts);
        if (count == 1) {
            return part_twice_area_fp2(vector::borrow(parts, 0))
        };
        let mut total_twice_area: u128 = 0;
        let mut i = 0;

        while (i < count) {
            total_twice_area = total_twice_area + part_twice_area_fp2(vector::borrow(parts, i));
            i = i + 1;
        };

        total_twice_area
    }

    /// Shoelace formula for 2× area in fixed-point squared units.
    /// Safety (F-03): each cross term is at most MAX_WORLD^2 ≈ 1.6e27.
    /// With MAX_VERTICES_PER_PART=64 terms, max accumulator ≈ 1.0e29 << u128::MAX ≈ 3.4e38.
    fun part_twice_area_fp2(part: &Part): u128 {
        let vertex_count = vector::length(&part.xs);
        let mut sum_positive: u128 = 0;
        let mut sum_negative: u128 = 0;

        let mut x_i = *vector::borrow(&part.xs, 0);
        let mut y_i = *vector::borrow(&part.ys, 0);
        let first_x = x_i;
        let first_y = y_i;

        let mut i = 1;
        while (i < vertex_count) {
            let x_next = *vector::borrow(&part.xs, i);
            let y_next = *vector::borrow(&part.ys, i);

            let term1 = (x_i as u128) * (y_next as u128);
            let term2 = (x_next as u128) * (y_i as u128);

            if (term1 >= term2) {
                sum_positive = sum_positive + (term1 - term2);
            } else {
                sum_negative = sum_negative + (term2 - term1);
            };

            x_i = x_next;
            y_i = y_next;
            i = i + 1;
        };

        let term1 = (x_i as u128) * (first_y as u128);
        let term2 = (first_x as u128) * (y_i as u128);

        if (term1 >= term2) {
            sum_positive = sum_positive + (term1 - term2);
        } else {
            sum_negative = sum_negative + (term2 - term1);
        };

        if (sum_positive >= sum_negative) {
            sum_positive - sum_negative
        } else {
            sum_negative - sum_positive
        }
    }

    fun edge_length_squared(ax: u64, ay: u64, bx: u64, by: u64): u128 {
        let dx = signed::sub_u64(bx, ax);
        let dy = signed::sub_u64(by, ay);
        let dx_mag = signed::magnitude(&dx);
        let dy_mag = signed::magnitude(&dy);
        // Safety (F-03): magnitudes bounded by MAX_WORLD (validated in part()).
        // MAX_WORLD^2 * 2 ≈ 3.2e27 << u128::MAX ≈ 3.4e38.
        assert!(dx_mag <= (MAX_WORLD as u128), EArithmeticOverflow);
        assert!(dy_mag <= (MAX_WORLD as u128), EArithmeticOverflow);
        dx_mag * dx_mag + dy_mag * dy_mag
    }

    fun validate_multipart_topology(parts: &vector<Part>) {
        let topology_parts = to_topology_parts(parts);
        let code = topology::validate_multipart_topology(
            &topology_parts,
        );
        assert!(code == 0, code);
    }

    fun to_topology_parts(parts: &vector<Part>): vector<topology::Part> {
        let mut topology_parts = vector::empty<topology::Part>();
        let count = vector::length(parts);
        let mut i = 0;

        while (i < count) {
            vector::push_back(
                &mut topology_parts,
                to_topology_part(vector::borrow(parts, i)),
            );
            i = i + 1;
        };

        topology_parts
    }

    fun to_topology_part(part: &Part): topology::Part {
        topology::part(part.xs, part.ys, part.aabb)
    }

    #[test_only]
    public(package) fun part_bounds(part: &Part): AABB {
        part.aabb
    }
}
