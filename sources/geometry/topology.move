/// Multipart polygon topology validation: shared-edge connectivity,
/// hole-free boundary, interior disjointness, and compactness checks.
module mercator::topology {
    use mercator::{aabb::{Self, AABB}, sat, signed::{Self, Signed}};
    use std::u128;

    const EPartOverlap: u64 = 2006;
    const EInvalidMultipartContact: u64 = 2007;
    const EDisconnectedMultipart: u64 = 2008;
    const EInvalidBoundary: u64 = 2009;
    const ECompactnessTooLow: u64 = 2011;

    const MIN_COMPACTNESS_PPM: u128 = 150_000;
    const REL_DISJOINT: u8 = 0;
    const REL_SHARED_EDGE: u8 = 1;
    const REL_VERTEX_CONTACT: u8 = 2;

    /// Topology-local copy of `polygon::Part` to avoid cyclic module dependencies.
    public struct Part has copy, drop, store {
        xs: vector<u64>,
        ys: vector<u64>,
        aabb: AABB,
    }

    /// Normalized undirected edge key.
    public struct EdgeKey has copy, drop, store {
        start_x: u64,
        start_y: u64,
        end_x: u64,
        end_y: u64,
    }

    /// Multiplicity for one normalized edge in a multipart polygon.
    public struct EdgeCount has copy, drop, store {
        key: EdgeKey,
        count: u64,
    }

    /// Normalized boundary vertex.
    public struct VertexKey has copy, drop, store {
        x: u64,
        y: u64,
    }

    public(package) fun part(xs: vector<u64>, ys: vector<u64>, aabb: AABB): Part {
        Part { xs, ys, aabb }
    }

    /// Compactness is a property of the polygon boundary, not of individual parts.
    /// When count == 1, the single part IS the boundary, so `validate_compactness`
    /// is called on its (twice_area, L1 perimeter). When count >= 2, compactness is
    /// evaluated on the outer boundary produced by `validate_boundary_graph`
    /// (edges with count == 1) against the SUM of per-part twice_areas.
    ///
    /// Per-part checks in Move are: `is_convex_vertices`, `validate_part_edges`,
    /// and vertex-count bounds (MAX_VERTICES_PER_PART, enforced by `part()`).
    /// No per-part compactness check exists, and the Rust companion library
    /// (exact-poly) mirrors this invariant — do NOT add per-part compactness
    /// without a matching change there.
    public(package) fun validate_multipart_topology(parts: &vector<Part>): u64 {
        let count = vector::length(parts);

        if (count == 1) {
            let p = vector::borrow(parts, 0);
            let (twice_area_fp2, perimeter) = part_area_and_perimeter(p);

            return validate_compactness(
                    twice_area_fp2,
                    perimeter,
                )
        };

        let mut relations = empty_relation_matrix(count);
        let mut i = 0;

        while (i < count) {
            let current = vector::borrow(parts, i);
            let mut j = i + 1;

            while (j < count) {
                let other = vector::borrow(parts, j);
                let (rel, code) = part_topology_relation(
                    current,
                    other,
                );
                if (code != 0) {
                    return code
                };
                if (rel != REL_DISJOINT) {
                    set_relation(
                        &mut relations,
                        count,
                        i,
                        j,
                        rel,
                    );
                    set_relation(
                        &mut relations,
                        count,
                        j,
                        i,
                        rel,
                    );
                };
                j = j + 1;
            };

            i = i + 1;
        };

        let components = compute_shared_edge_components(
            &relations,
            count,
        );

        i = 0;
        while (i < count) {
            let mut j = i + 1;
            while (j < count) {
                if (
                    relation_at(
                    &relations,
                    count,
                    i,
                    j,
                ) == REL_VERTEX_CONTACT
                ) {
                    if (
                        *vector::borrow(&components, i)
                        != *vector::borrow(
                            &components,
                            j,
                        )
                    ) {
                        return EInvalidMultipartContact
                    };
                };
                j = j + 1;
            };
            i = i + 1;
        };

        i = 0;
        while (i < count) {
            if (*vector::borrow(&components, i) != 0) {
                return EDisconnectedMultipart
            };
            i = i + 1;
        };

        let (edge_counts, code) = collect_edge_counts(parts);
        if (code != 0) {
            return code
        };
        let (boundary_perimeter_l1_fp, code) = validate_boundary_graph(
            &edge_counts,
        );
        if (code != 0) {
            return code
        };
        let twice_area_fp2 = polygon_twice_area_fp2(parts);
        validate_compactness(
            twice_area_fp2,
            boundary_perimeter_l1_fp,
        )
    }

    fun empty_relation_matrix(count: u64): vector<u8> {
        let mut relations = vector::empty<u8>();
        let mut i = 0;
        let total = count * count;

        while (i < total) {
            vector::push_back(&mut relations, REL_DISJOINT);
            i = i + 1;
        };

        relations
    }

    fun set_relation(relations: &mut vector<u8>, count: u64, row: u64, col: u64, value: u8) {
        let index = row * count + col;
        *vector::borrow_mut(relations, index) = value;
    }

    fun relation_at(relations: &vector<u8>, count: u64, row: u64, col: u64): u8 {
        *vector::borrow(relations, row * count + col)
    }

    fun compute_shared_edge_components(relations: &vector<u8>, count: u64): vector<u64> {
        let sentinel = count;
        let mut components = vector::empty<u64>();
        let mut i = 0;
        while (i < count) {
            vector::push_back(&mut components, sentinel);
            i = i + 1;
        };

        let mut component_id: u64 = 0;
        let mut start: u64 = 0;
        while (start < count) {
            if (*vector::borrow(&components, start) < sentinel) {
                start = start + 1;
                continue
            };

            *vector::borrow_mut(&mut components, start) = component_id;
            let mut queue = vector::empty<u64>();
            vector::push_back(&mut queue, start);

            let mut cursor: u64 = 0;
            while (cursor < vector::length(&queue)) {
                let current = *vector::borrow(&queue, cursor);
                let mut neighbor: u64 = 0;

                while (neighbor < count) {
                    if (
                        relation_at(
                        relations,
                        count,
                        current,
                        neighbor,
                    ) == REL_SHARED_EDGE
                        && *vector::borrow(
                            &components,
                            neighbor,
                        ) == sentinel
                    ) {
                        *vector::borrow_mut(
                            &mut components,
                            neighbor,
                        ) = component_id;
                        vector::push_back(
                            &mut queue,
                            neighbor,
                        );
                    };
                    neighbor = neighbor + 1;
                };

                cursor = cursor + 1;
            };

            component_id = component_id + 1;
            start = start + 1;
        };

        components
    }

    public(package) fun has_exact_shared_edge(a: &Part, b: &Part): bool {
        let count_a = vector::length(&a.xs);
        let count_b = vector::length(&b.xs);
        let mut i = 0;

        while (i < count_a) {
            let next_a = if (i + 1 < count_a) { i + 1 } else {
                0
            };
            let ax = *vector::borrow(&a.xs, i);
            let ay = *vector::borrow(&a.ys, i);
            let bx = *vector::borrow(&a.xs, next_a);
            let by = *vector::borrow(&a.ys, next_a);

            let mut j = 0;
            while (j < count_b) {
                let next_b = if (j + 1 < count_b) { j + 1 } else { 0 };
                if (
                    edges_match_exactly(
                        ax,
                        ay,
                        bx,
                        by,
                        *vector::borrow(&b.xs, j),
                        *vector::borrow(&b.ys, j),
                        *vector::borrow(&b.xs, next_b),
                        *vector::borrow(&b.ys, next_b),
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

    public(package) fun shared_edge_relation(a: &Part, b: &Part): (bool, u64) {
        if (!aabbs_may_contact(&a.aabb, &b.aabb)) {
            return (false, 0)
        };

        if (
            sat::overlaps(
                &a.xs,
                &a.ys,
                &b.xs,
                &b.ys,
            )
        ) {
            return (false, EPartOverlap)
        };

        if (has_exact_shared_edge(a, b)) {
            return (true, 0)
        };

        let count_a = vector::length(&a.xs);
        let count_b = vector::length(&b.xs);
        let mut shared_edge_found = false;
        let mut boundary_contact_without_shared_edge = false;

        let mut i = 0;
        while (i < count_a) {
            let next_a = if (i + 1 < count_a) { i + 1 } else {
                0
            };
            let ax = *vector::borrow(&a.xs, i);
            let ay = *vector::borrow(&a.ys, i);
            let bx = *vector::borrow(&a.xs, next_a);
            let by = *vector::borrow(&a.ys, next_a);

            let mut j = 0;
            while (j < count_b) {
                let next_b = if (j + 1 < count_b) { j + 1 } else { 0 };
                let cx = *vector::borrow(&b.xs, j);
                let cy = *vector::borrow(&b.ys, j);
                let dx = *vector::borrow(&b.xs, next_b);
                let dy = *vector::borrow(&b.ys, next_b);

                if (
                    edges_match_exactly(
                        ax,
                        ay,
                        bx,
                        by,
                        cx,
                        cy,
                        dx,
                        dy,
                    )
                ) {
                    shared_edge_found = true;
                } else if (
                    segments_contact(
                        ax,
                        ay,
                        bx,
                        by,
                        cx,
                        cy,
                        dx,
                        dy,
                    )
                ) {
                    boundary_contact_without_shared_edge = true;
                };

                j = j + 1;
            };

            i = i + 1;
        };

        if (boundary_contact_without_shared_edge
            && !shared_edge_found) {
            return (false, EInvalidMultipartContact)
        };

        (shared_edge_found, 0)
    }

    fun part_topology_relation(a: &Part, b: &Part): (u8, u64) {
        if (!aabbs_may_contact(&a.aabb, &b.aabb)) {
            return (REL_DISJOINT, 0)
        };

        if (
            sat::overlaps(
                &a.xs,
                &a.ys,
                &b.xs,
                &b.ys,
            )
        ) {
            return (REL_DISJOINT, EPartOverlap)
        };

        if (has_exact_shared_edge(a, b)) {
            return (REL_SHARED_EDGE, 0)
        };

        let count_a = vector::length(&a.xs);
        let count_b = vector::length(&b.xs);
        let mut shared_edge_found = false;
        let mut boundary_contact = false;

        let mut i = 0;
        while (i < count_a) {
            let next_a = if (i + 1 < count_a) { i + 1 } else {
                0
            };
            let ax = *vector::borrow(&a.xs, i);
            let ay = *vector::borrow(&a.ys, i);
            let bx = *vector::borrow(&a.xs, next_a);
            let by = *vector::borrow(&a.ys, next_a);

            let mut j = 0;
            while (j < count_b) {
                let next_b = if (j + 1 < count_b) { j + 1 } else { 0 };
                let cx = *vector::borrow(&b.xs, j);
                let cy = *vector::borrow(&b.ys, j);
                let dx = *vector::borrow(&b.xs, next_b);
                let dy = *vector::borrow(&b.ys, next_b);

                if (
                    edges_match_exactly(
                        ax,
                        ay,
                        bx,
                        by,
                        cx,
                        cy,
                        dx,
                        dy,
                    )
                ) {
                    shared_edge_found = true;
                } else if (
                    segments_contact(
                        ax,
                        ay,
                        bx,
                        by,
                        cx,
                        cy,
                        dx,
                        dy,
                    )
                ) {
                    boundary_contact = true;
                };

                j = j + 1;
            };

            i = i + 1;
        };

        if (shared_edge_found) {
            (REL_SHARED_EDGE, 0)
        } else if (boundary_contact) {
            (REL_VERTEX_CONTACT, 0)
        } else {
            (REL_DISJOINT, 0)
        }
    }

    fun collect_edge_counts(parts: &vector<Part>): (vector<EdgeCount>, u64) {
        let mut edge_counts = vector::empty<EdgeCount>();
        let count = vector::length(parts);
        let mut i = 0;

        while (i < count) {
            let code = append_part_edges(
                vector::borrow(parts, i),
                &mut edge_counts,
            );
            if (code != 0) {
                return (edge_counts, code)
            };
            i = i + 1;
        };

        (edge_counts, 0)
    }

    fun append_part_edges(part: &Part, edge_counts: &mut vector<EdgeCount>): u64 {
        let edge_total = vector::length(&part.xs);
        let mut i = 0;

        while (i < edge_total) {
            let next = if (i + 1 < edge_total) { i + 1 } else {
                0
            };
            let key = normalize_edge(
                *vector::borrow(&part.xs, i),
                *vector::borrow(&part.ys, i),
                *vector::borrow(&part.xs, next),
                *vector::borrow(&part.ys, next),
            );

            let mut found = false;
            let mut j = 0;
            let count = vector::length(edge_counts);
            while (j < count) {
                let entry = vector::borrow_mut(edge_counts, j);
                if (edge_keys_equal(&entry.key, &key)) {
                    entry.count = entry.count + 1;
                    if (entry.count > 2) {
                        return EInvalidBoundary
                    };
                    found = true;
                    j = count;
                } else {
                    j = j + 1;
                };
            };

            if (!found) {
                vector::push_back(
                    edge_counts,
                    EdgeCount { key, count: 1 },
                );
            };

            i = i + 1;
        };

        0
    }

    fun normalize_edge(ax: u64, ay: u64, bx: u64, by: u64): EdgeKey {
        if (point_precedes(ax, ay, bx, by)) {
            EdgeKey {
                start_x: ax,
                start_y: ay,
                end_x: bx,
                end_y: by,
            }
        } else {
            EdgeKey {
                start_x: bx,
                start_y: by,
                end_x: ax,
                end_y: ay,
            }
        }
    }

    fun point_precedes(ax: u64, ay: u64, bx: u64, by: u64): bool {
        ax < bx || (ax == bx && ay <= by)
    }

    fun edge_keys_equal(a: &EdgeKey, b: &EdgeKey): bool {
        a.start_x == b.start_x
        && a.start_y == b.start_y
        && a.end_x == b.end_x
        && a.end_y == b.end_y
    }

    fun edge_l1_length(edge: &EdgeKey): u128 {
        let dx = signed::sub_u64(edge.end_x, edge.start_x);
        let dy = signed::sub_u64(edge.end_y, edge.start_y);
        signed::magnitude(&dx) + signed::magnitude(&dy)
    }

    fun validate_boundary_graph(edge_counts: &vector<EdgeCount>): (u128, u64) {
        let mut vertices = vector::empty<VertexKey>();
        let mut degrees = vector::empty<u64>();
        let mut edge_starts = vector::empty<u64>();
        let mut edge_ends = vector::empty<u64>();
        let mut perimeter_l1_fp: u128 = 0;

        let mut i = 0;
        let count = vector::length(edge_counts);
        while (i < count) {
            let edge_count = vector::borrow(edge_counts, i);
            if (edge_count.count != 1 && edge_count.count != 2) {
                return (0, EInvalidBoundary)
            };

            if (edge_count.count == 1) {
                let start_idx = find_or_push_vertex(
                    &mut vertices,
                    &mut degrees,
                    edge_count.key.start_x,
                    edge_count.key.start_y,
                );
                let end_idx = find_or_push_vertex(
                    &mut vertices,
                    &mut degrees,
                    edge_count.key.end_x,
                    edge_count.key.end_y,
                );

                let start_degree = vector::borrow_mut(
                    &mut degrees,
                    start_idx,
                );
                *start_degree = *start_degree + 1;
                let end_degree = vector::borrow_mut(
                    &mut degrees,
                    end_idx,
                );
                *end_degree = *end_degree + 1;

                vector::push_back(&mut edge_starts, start_idx);
                vector::push_back(&mut edge_ends, end_idx);
                perimeter_l1_fp = perimeter_l1_fp + edge_l1_length(&edge_count.key);
            };

            i = i + 1;
        };

        let boundary_edge_count = vector::length(&edge_starts);
        let vertex_count = vector::length(&vertices);
        if (boundary_edge_count == 0) {
            return (0, EInvalidBoundary)
        };
        if (boundary_edge_count != vertex_count) {
            return (0, EInvalidBoundary)
        };

        i = 0;
        while (i < vector::length(&degrees)) {
            if (*vector::borrow(&degrees, i) != 2) {
                return (0, EInvalidBoundary)
            };
            i = i + 1;
        };

        if (
            !boundary_graph_connected(
                &edge_starts,
                &edge_ends,
                vertex_count,
            )
        ) {
            return (0, EInvalidBoundary)
        };

        (perimeter_l1_fp, 0)
    }

    fun find_or_push_vertex(
        vertices: &mut vector<VertexKey>,
        degrees: &mut vector<u64>,
        x: u64,
        y: u64,
    ): u64 {
        let mut i = 0;
        let count = vector::length(vertices);

        while (i < count) {
            let vertex = vector::borrow(vertices, i);
            if (vertex.x == x && vertex.y == y) {
                return i
            };
            i = i + 1;
        };

        vector::push_back(vertices, VertexKey { x, y });
        vector::push_back(degrees, 0);
        vector::length(vertices) - 1
    }

    fun boundary_graph_connected(
        edge_starts: &vector<u64>,
        edge_ends: &vector<u64>,
        vertex_count: u64,
    ): bool {
        let mut visited = vector::empty<bool>();
        let mut i = 0;
        while (i < vertex_count) {
            vector::push_back(&mut visited, false);
            i = i + 1;
        };

        let mut queue = vector::empty<u64>();
        vector::push_back(&mut queue, 0);
        *vector::borrow_mut(&mut visited, 0) = true;

        let mut cursor = 0;
        let mut visited_count = 1;
        let edge_count = vector::length(edge_starts);

        while (cursor < vector::length(&queue)) {
            let current = *vector::borrow(&queue, cursor);
            let mut edge_idx = 0;

            while (edge_idx < edge_count) {
                let start = *vector::borrow(edge_starts, edge_idx);
                let end = *vector::borrow(edge_ends, edge_idx);
                let neighbor = if (start == current) { end } else if (end == current) { start }
                else {
                    vertex_count
                };

                if (
                    neighbor < vertex_count
                    && !*vector::borrow(&visited, neighbor)
                ) {
                    *vector::borrow_mut(
                        &mut visited,
                        neighbor,
                    ) = true;
                    vector::push_back(&mut queue, neighbor);
                    visited_count = visited_count + 1;
                };

                edge_idx = edge_idx + 1;
            };

            cursor = cursor + 1;
        };

        visited_count == vertex_count
    }

    fun validate_compactness(twice_area_fp2: u128, boundary_perimeter_l1_fp: u128): u64 {
        let perimeter_sq_opt = u128::checked_mul(
            boundary_perimeter_l1_fp,
            boundary_perimeter_l1_fp,
        );
        if (!option::is_some(&perimeter_sq_opt)) {
            return ECompactnessTooLow
        };
        let perimeter_squared = option::destroy_some(
            perimeter_sq_opt,
        );

        let rhs_opt = u128::checked_mul(
            MIN_COMPACTNESS_PPM,
            perimeter_squared,
        );
        if (!option::is_some(&rhs_opt)) {
            return ECompactnessTooLow
        };
        let rhs = option::destroy_some(rhs_opt);

        let lhs_opt = u128::checked_mul(
            8_000_000u128,
            twice_area_fp2,
        );
        if (option::is_some(&lhs_opt)) {
            if (option::destroy_some(lhs_opt) < rhs) {
                return ECompactnessTooLow
            };
        };

        0
    }

    public(package) fun aabbs_may_contact(a: &AABB, b: &AABB): bool {
        aabb::min_x(a) <= aabb::max_x(b)
        && aabb::max_x(a) >= aabb::min_x(b)
        && aabb::min_y(a) <= aabb::max_y(b)
        && aabb::max_y(a) >= aabb::min_y(b)
    }

    fun edges_match_exactly(
        ax: u64,
        ay: u64,
        bx: u64,
        by: u64,
        cx: u64,
        cy: u64,
        dx: u64,
        dy: u64,
    ): bool {
        let edge_a = normalize_edge(ax, ay, bx, by);
        let edge_b = normalize_edge(cx, cy, dx, dy);
        edge_keys_equal(&edge_a, &edge_b)
    }

    fun segments_contact(
        ax: u64,
        ay: u64,
        bx: u64,
        by: u64,
        cx: u64,
        cy: u64,
        dx: u64,
        dy: u64,
    ): bool {
        let ab_c = signed::cross_sign(ax, ay, bx, by, cx, cy);
        let ab_d = signed::cross_sign(ax, ay, bx, by, dx, dy);
        let cd_a = signed::cross_sign(cx, cy, dx, dy, ax, ay);
        let cd_b = signed::cross_sign(cx, cy, dx, dy, bx, by);

        if (is_zero(&ab_c) && point_on_segment(ax, ay, bx, by, cx, cy)) {
            return true
        };
        if (is_zero(&ab_d) && point_on_segment(ax, ay, bx, by, dx, dy)) {
            return true
        };
        if (is_zero(&cd_a) && point_on_segment(cx, cy, dx, dy, ax, ay)) {
            return true
        };
        if (is_zero(&cd_b) && point_on_segment(cx, cy, dx, dy, bx, by)) {
            return true
        };

        opposite_signs(&ab_c, &ab_d) && opposite_signs(&cd_a, &cd_b)
    }

    fun point_on_segment(ax: u64, ay: u64, bx: u64, by: u64, px: u64, py: u64): bool {
        let cross = signed::cross_sign(ax, ay, bx, by, px, py);
        is_zero(&cross)
        && within(ax, bx, px)
        && within(ay, by, py)
    }

    fun within(a: u64, b: u64, value: u64): bool {
        let min_value = if (a < b) { a } else { b };
        let max_value = if (a > b) { a } else { b };
        value >= min_value && value <= max_value
    }

    public(package) fun is_zero(value: &Signed): bool {
        signed::magnitude(value) == 0
    }

    fun opposite_signs(a: &Signed, b: &Signed): bool {
        !is_zero(a)
        && !is_zero(b)
        && signed::is_negative(a) != signed::is_negative(b)
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

    fun part_area_and_perimeter(part: &Part): (u128, u128) {
        let vertex_count = vector::length(&part.xs);
        let mut sum_positive: u128 = 0;
        let mut sum_negative: u128 = 0;
        let mut perimeter: u128 = 0;

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

            let dx = if (x_next >= x_i) {
                (x_next - x_i) as u128
            } else {
                (x_i - x_next) as u128
            };
            let dy = if (y_next >= y_i) {
                (y_next - y_i) as u128
            } else {
                (y_i - y_next) as u128
            };
            perimeter = perimeter + dx + dy;

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
        let dx = if (first_x >= x_i) {
            (first_x - x_i) as u128
        } else {
            (x_i - first_x) as u128
        };
        let dy = if (first_y >= y_i) {
            (first_y - y_i) as u128
        } else {
            (y_i - first_y) as u128
        };
        perimeter = perimeter + dx + dy;

        let twice_area = if (sum_positive >= sum_negative) {
            sum_positive - sum_negative
        } else {
            sum_negative - sum_positive
        };

        (twice_area, perimeter)
    }
}
