/// Region mutation entrypoints for reshape operations.
module mercator::mutations {
    use mercator::{aabb, index::{Self, Index}, metadata, morton, polygon};
    use sui::event;

    // === Errors ===

    const ENotContained: u64 = 5001;
    const EOverlap: u64 = 5002;
    const ESelfRepartition: u64 = 5003;
    const ENotAdjacent: u64 = 5004;
    const EOwnerMismatch: u64 = 5005;
    const ESelfMerge: u64 = 5006;
    const EInvalidChildCount: u64 = 5007;
    const ETooManyChildren: u64 = 5008;
    const EAreaShrunk: u64 = 5009;
    const MIN_SPLIT_CHILDREN: u64 = 2;

    /// Maximum children per split_replace call.  Pairwise overlap is O(C²),
    /// so this caps worst-case SAT work.  10 children → 45 pair checks.
    const MAX_SPLIT_CHILDREN: u64 = 10;

    // === Events ===

    public struct RegionReshaped has copy, drop {
        polygon_id: ID,
        old_area: u64,
        new_area: u64,
        caller: address,
    }

    public struct RegionsRepartitioned has copy, drop {
        a_id: ID,
        b_id: ID,
        caller: address,
    }

    public struct RegionRetired has copy, drop {
        polygon_id: ID,
        caller: address,
    }

    public struct RegionSplit has copy, drop {
        parent_id: ID,
        child_ids: vector<ID>,
        caller: address,
    }

    public struct RegionsMerged has copy, drop {
        keep_id: ID,
        absorbed_id: ID,
        caller: address,
    }

    // === Public Functions ===
    //
    // SAFETY: All mutation functions below are low-level protocol operations.
    // Callers are responsible for enforcing any application-level invariants
    // (pricing, access control, pause checks) in their own modules.

    /// Reshape a region to a larger geometry. Area may grow but never shrink.
    /// SAFETY: Low-level protocol operation. Callers must enforce application-level invariants
    /// tax, and pause checks.
    #[allow(lint(prefer_mut_tx_context))]
    public fun reshape_unclaimed(
        index: &mut Index,
        polygon_id: ID,
        new_parts_xs: vector<vector<u64>>,
        new_parts_ys: vector<vector<u64>>,
        ctx: &tx_context::TxContext,
    ) {
        let old_polygon = index::get(index, polygon_id);
        assert!(polygon::owner(old_polygon) == tx_context::sender(ctx), EOwnerMismatch);
        let old_area = polygon::area(old_polygon);
        let old_bounds = polygon::bounds(old_polygon);
        let old_cells_ref = polygon::cells(old_polygon);
        let mut old_cells = vector::empty<u64>();
        let mut i = 0;
        let old_cell_count = vector::length(old_cells_ref);
        while (i < old_cell_count) {
            vector::push_back(
                &mut old_cells,
                *vector::borrow(old_cells_ref, i),
            );
            i = i + 1;
        };

        let (new_parts, new_aabb, new_total_vertices, new_part_count) = polygon::prepare_geometry(
            new_parts_xs,
            new_parts_ys,
            index::max_vertices_per_part(index),
        );
        index::assert_vertex_limit(
            index,
            new_total_vertices,
            new_part_count,
        );

        assert!(
            aabb::min_x(&new_aabb) <= aabb::min_x(&old_bounds)
            && aabb::min_y(&new_aabb) <= aabb::min_y(&old_bounds)
            && aabb::max_x(&new_aabb) >= aabb::max_x(&old_bounds)
            && aabb::max_y(&new_aabb) >= aabb::max_y(&old_bounds),
            ENotContained,
        );
        assert!(
            polygon::contains_polygon_by_parts(
                &new_parts,
                &new_aabb,
                old_polygon,
            ),
            ENotContained,
        );

        let (new_min_gx, new_min_gy, new_max_gx, new_max_gy) = index::grid_bounds_for_aabb(
            index,
            &new_aabb,
        );
        let candidate_ids = index::broadphase_from_aabb(
            index,
            new_min_gx,
            new_min_gy,
            new_max_gx,
            new_max_gy,
        );
        let mut c = 0;
        let candidate_count = vector::length(&candidate_ids);
        while (c < candidate_count) {
            let candidate_id = *vector::borrow(&candidate_ids, c);
            if (candidate_id != polygon_id) {
                let candidate_polygon = index::get(
                    index,
                    candidate_id,
                );
                if (
                    polygon::intersects_polygon_by_parts(
                        &new_parts,
                        &new_aabb,
                        candidate_polygon,
                    )
                ) {
                    abort EOverlap
                };
            };
            c = c + 1;
        };

        let new_depth = index::natural_depth(
            new_min_gx,
            new_min_gy,
            new_max_gx,
            new_max_gy,
            index::max_depth(index),
        );
        let shift = index::max_depth(index) - new_depth;
        let new_cell_key = morton::depth_prefix(
            morton::interleave_n(
                new_min_gx >> shift,
                new_min_gy >> shift,
                new_depth,
            ),
            new_depth,
        );

        index::unregister_from_cells(
            index,
            polygon_id,
            &old_cells,
        );
        let new_area = index::set_polygon_geometry(
            index,
            polygon_id,
            new_parts,
            new_cell_key,
        );
        // CORE-01 fix: area may grow but
        // must never shrink — shrinking would let an owner shed area while
        // keeping PriceState, effectively laundering premium.
        assert!(new_area >= old_area, EAreaShrunk);
        index::register_in_cell(
            index,
            polygon_id,
            new_cell_key,
            new_depth,
        );
        event::emit(RegionReshaped {
            polygon_id,
            old_area,
            new_area,
            caller: tx_context::sender(ctx),
        });
    }

    /// Repartition two adjacent same-owner regions. Total area conserved.
    /// SAFETY: Low-level protocol operation. Callers must enforce application-level invariants
    /// tax, and pause checks.
    #[allow(lint(prefer_mut_tx_context))]
    public fun repartition_adjacent(
        index: &mut Index,
        a_id: ID,
        a_parts_xs: vector<vector<u64>>,
        a_parts_ys: vector<vector<u64>>,
        b_id: ID,
        b_parts_xs: vector<vector<u64>>,
        b_parts_ys: vector<vector<u64>>,
        ctx: &tx_context::TxContext,
    ) {
        assert!(a_id != b_id, ESelfRepartition);

        let mut old_cells_a = vector::empty<u64>();
        let mut old_cells_b = vector::empty<u64>();
        let old_area_sum: u128;
        let old_bounds_a: aabb::AABB;
        let old_bounds_b: aabb::AABB;
        {
            let polygon_a = index::get(index, a_id);
            let polygon_b = index::get(index, b_id);
            assert!(polygon::owner(polygon_a) == tx_context::sender(ctx), EOwnerMismatch);
            assert!(polygon::owner(polygon_b) == tx_context::sender(ctx), EOwnerMismatch);
            assert!(polygon::touches_by_edge(polygon_a, polygon_b), ENotAdjacent);

            old_area_sum =
                polygon::checked_area_sum(
                    polygon::area_fp2(polygon_a),
                    polygon::area_fp2(polygon_b),
                );
            old_bounds_a = polygon::bounds(polygon_a);
            old_bounds_b = polygon::bounds(polygon_b);

            let old_cells_ref_a = polygon::cells(polygon_a);
            let mut i = 0;
            let old_cell_count_a = vector::length(
                old_cells_ref_a,
            );
            while (i < old_cell_count_a) {
                vector::push_back(
                    &mut old_cells_a,
                    *vector::borrow(old_cells_ref_a, i),
                );
                i = i + 1;
            };

            let old_cells_ref_b = polygon::cells(polygon_b);
            let mut j = 0;
            let old_cell_count_b = vector::length(
                old_cells_ref_b,
            );
            while (j < old_cell_count_b) {
                vector::push_back(
                    &mut old_cells_b,
                    *vector::borrow(old_cells_ref_b, j),
                );
                j = j + 1;
            };
        };

        let (
            new_parts_a,
            new_aabb_a,
            new_total_vertices_a,
            new_part_count_a,
        ) = polygon::prepare_geometry(
            a_parts_xs,
            a_parts_ys,
            index::max_vertices_per_part(index),
        );
        index::assert_vertex_limit(
            index,
            new_total_vertices_a,
            new_part_count_a,
        );
        let (
            new_parts_b,
            new_aabb_b,
            new_total_vertices_b,
            new_part_count_b,
        ) = polygon::prepare_geometry(
            b_parts_xs,
            b_parts_ys,
            index::max_vertices_per_part(index),
        );
        index::assert_vertex_limit(
            index,
            new_total_vertices_b,
            new_part_count_b,
        );

        let new_area_sum = polygon::checked_area_sum(
            polygon::area_fp2_from_parts(&new_parts_a),
            polygon::area_fp2_from_parts(&new_parts_b),
        );
        polygon::assert_area_conserved(
            old_area_sum,
            new_area_sum,
        );

        assert!(
            !polygon::intersects_parts_by_parts(
                &new_parts_a,
                &new_aabb_a,
                &new_parts_b,
                &new_aabb_b,
            ),
            EOverlap,
        );

        // ── Union AABB containment: prevent polygon teleportation ────────────
        // Both output AABBs must lie within the union bounding box of the
        // original pair.  This blocks an attacker from moving the victim's
        // remaining land to arbitrary coordinates.
        let union_min_x = if (aabb::min_x(&old_bounds_a) < aabb::min_x(&old_bounds_b)) {
            aabb::min_x(&old_bounds_a)
        } else {
            aabb::min_x(&old_bounds_b)
        };
        let union_min_y = if (aabb::min_y(&old_bounds_a) < aabb::min_y(&old_bounds_b)) {
            aabb::min_y(&old_bounds_a)
        } else {
            aabb::min_y(&old_bounds_b)
        };
        let union_max_x = if (aabb::max_x(&old_bounds_a) > aabb::max_x(&old_bounds_b)) {
            aabb::max_x(&old_bounds_a)
        } else {
            aabb::max_x(&old_bounds_b)
        };
        let union_max_y = if (aabb::max_y(&old_bounds_a) > aabb::max_y(&old_bounds_b)) {
            aabb::max_y(&old_bounds_a)
        } else {
            aabb::max_y(&old_bounds_b)
        };
        assert!(
            aabb::min_x(&new_aabb_a) >= union_min_x
            && aabb::min_y(&new_aabb_a) >= union_min_y
            && aabb::max_x(&new_aabb_a) <= union_max_x
            && aabb::max_y(&new_aabb_a) <= union_max_y,
            ENotContained,
        );
        assert!(
            aabb::min_x(&new_aabb_b) >= union_min_x
            && aabb::min_y(&new_aabb_b) >= union_min_y
            && aabb::max_x(&new_aabb_b) <= union_max_x
            && aabb::max_y(&new_aabb_b) <= union_max_y,
            ENotContained,
        );

        // ── Post-adjacency: outputs must still share an edge ─────────────────
        assert!(
            polygon::touches_by_edge_by_parts(
                &new_parts_a,
                &new_aabb_a,
                &new_parts_b,
                &new_aabb_b,
            ),
            ENotAdjacent,
        );

        if (index::count(index) > 2) {
            assert_no_overlap_with_others_pair(
                index,
                a_id,
                b_id,
                &new_parts_a,
                &new_aabb_a,
                &new_parts_b,
                &new_aabb_b,
            );
        };

        let max_depth = index::max_depth(index);

        let (new_min_gx_a, new_min_gy_a, new_max_gx_a, new_max_gy_a) = index::grid_bounds_for_aabb(
            index,
            &new_aabb_a,
        );
        let new_depth_a = index::natural_depth(
            new_min_gx_a,
            new_min_gy_a,
            new_max_gx_a,
            new_max_gy_a,
            max_depth,
        );
        let shift_a = max_depth - new_depth_a;
        let new_cell_key_a = morton::depth_prefix(
            morton::interleave_n(
                new_min_gx_a >> shift_a,
                new_min_gy_a >> shift_a,
                new_depth_a,
            ),
            new_depth_a,
        );

        let (new_min_gx_b, new_min_gy_b, new_max_gx_b, new_max_gy_b) = index::grid_bounds_for_aabb(
            index,
            &new_aabb_b,
        );
        let new_depth_b = index::natural_depth(
            new_min_gx_b,
            new_min_gy_b,
            new_max_gx_b,
            new_max_gy_b,
            max_depth,
        );
        let shift_b = max_depth - new_depth_b;
        let new_cell_key_b = morton::depth_prefix(
            morton::interleave_n(
                new_min_gx_b >> shift_b,
                new_min_gy_b >> shift_b,
                new_depth_b,
            ),
            new_depth_b,
        );

        index::unregister_from_cells(index, a_id, &old_cells_a);
        let _new_area_a = index::set_polygon_geometry(
            index,
            a_id,
            new_parts_a,
            new_cell_key_a,
        );
        index::register_in_cell(
            index,
            a_id,
            new_cell_key_a,
            new_depth_a,
        );

        index::unregister_from_cells(index, b_id, &old_cells_b);
        let _new_area_b = index::set_polygon_geometry(
            index,
            b_id,
            new_parts_b,
            new_cell_key_b,
        );
        index::register_in_cell(
            index,
            b_id,
            new_cell_key_b,
            new_depth_b,
        );

        event::emit(RegionsRepartitioned {
            a_id,
            b_id,
            caller: tx_context::sender(ctx),
        });
    }

    /// Split parent into N children (2 ≤ N ≤ 10). Area conserved.
    /// SAFETY: Low-level protocol operation. Callers must enforce application-level invariants
    /// tax, and pause checks.
    public fun split_replace(
        index: &mut Index,
        parent_id: ID,
        children_parts_xs: vector<vector<vector<u64>>>,
        children_parts_ys: vector<vector<vector<u64>>>,
        ctx: &mut tx_context::TxContext,
    ): vector<ID> {
        let parent_polygon = index::get(index, parent_id);
        let parent_area = polygon::area_fp2(parent_polygon);
        let parent_owner = polygon::owner(parent_polygon);
        assert!(parent_owner == tx_context::sender(ctx), EOwnerMismatch);

        let old_cells_ref = polygon::cells(parent_polygon);
        let mut old_cells = vector::empty<u64>();
        let mut old_i = 0;
        let old_count = vector::length(old_cells_ref);
        while (old_i < old_count) {
            vector::push_back(
                &mut old_cells,
                *vector::borrow(old_cells_ref, old_i),
            );
            old_i = old_i + 1;
        };

        let mut children_parts_xs = children_parts_xs;
        let mut children_parts_ys = children_parts_ys;
        let child_count = vector::length(&children_parts_xs);
        assert!(child_count == vector::length(&children_parts_ys), ENotContained);
        assert!(child_count >= MIN_SPLIT_CHILDREN, EInvalidChildCount);
        assert!(child_count <= MAX_SPLIT_CHILDREN, ETooManyChildren);

        let mut prepared_children = vector::empty<polygon::Polygon>();
        let mut i = 0;
        let mut new_area_sum: u128 = 0;
        while (i < child_count) {
            let child_parts_xs = vector::remove(
                &mut children_parts_xs,
                0,
            );
            let child_parts_ys = vector::remove(
                &mut children_parts_ys,
                0,
            );
            let (
                child_parts,
                _child_aabb,
                child_vertices,
                child_part_count,
            ) = polygon::prepare_geometry(
                child_parts_xs,
                child_parts_ys,
                index::max_vertices_per_part(index),
            );
            index::assert_vertex_limit(
                index,
                child_vertices,
                child_part_count,
            );
            let mut child_polygon = polygon::new(
                child_parts,
                ctx,
            );
            polygon::set_owner(
                &mut child_polygon,
                parent_owner,
            );
            new_area_sum =
                polygon::checked_area_sum(
                    new_area_sum,
                    polygon::area_fp2(&child_polygon),
                );
            vector::push_back(
                &mut prepared_children,
                child_polygon,
            );
            i = i + 1;
        };

        polygon::assert_area_conserved(
            parent_area,
            new_area_sum,
        );

        // F-01 fix: verify every child is geometrically contained within
        // the parent polygon.  Without this check an attacker can teleport
        // children to arbitrary map coordinates while preserving total area.
        {
            let parent_ref = index::get(index, parent_id);
            let mut k = 0;
            while (k < child_count) {
                assert!(
                    polygon::contains_polygon(
                        parent_ref,
                        vector::borrow(&prepared_children, k),
                    ),
                    ENotContained,
                );
                k = k + 1;
            };
        };

        let mut a = 0;
        while (a < child_count) {
            let child_a = vector::borrow(&prepared_children, a);
            let mut b = a + 1;
            while (b < child_count) {
                let child_b = vector::borrow(
                    &prepared_children,
                    b,
                );
                if (polygon::intersects(child_a, child_b)) {
                    abort EOverlap
                };
                b = b + 1;
            };
            a = a + 1;
        };

        i = 0;
        while (i < child_count) {
            let child = vector::borrow(&prepared_children, i);
            let child_aabb = polygon::bounds(child);
            let (min_gx, min_gy, max_gx, max_gy) = index::grid_bounds_for_aabb(index, &child_aabb);
            let candidate_ids = index::broadphase_from_aabb(
                index,
                min_gx,
                min_gy,
                max_gx,
                max_gy,
            );
            let mut c = 0;
            let candidate_count = vector::length(
                &candidate_ids,
            );
            while (c < candidate_count) {
                let candidate_id = *vector::borrow(&candidate_ids, c);
                if (candidate_id != parent_id) {
                    let candidate_polygon = index::get(
                        index,
                        candidate_id,
                    );
                    if (
                        polygon::intersects(
                            child,
                            candidate_polygon,
                        )
                    ) {
                        abort EOverlap
                    };
                };
                c = c + 1;
            };
            i = i + 1;
        };

        index::unregister_from_cells(
            index,
            parent_id,
            &old_cells,
        );
        // Clean up metadata on parent polygon before destruction (META-01)
        metadata::force_remove_metadata(
            index::uid_mut(index),
            parent_id,
        );
        let removed_parent = index::take_polygon(
            index,
            parent_id,
        );
        polygon::destroy(removed_parent);
        index::decrement_count(index);
        event::emit(RegionRetired {
            polygon_id: parent_id,
            caller: tx_context::sender(ctx),
        });

        let max_depth = index::max_depth(index);
        let mut child_ids = vector::empty<ID>();
        while (vector::length(&prepared_children) > 0) {
            let mut child_polygon = vector::remove(
                &mut prepared_children,
                0,
            );
            let child_bounds = polygon::bounds(&child_polygon);
            let (min_gx, min_gy, max_gx, max_gy) = index::grid_bounds_for_aabb(
                index,
                &child_bounds,
            );
            let child_depth = index::natural_depth(
                min_gx,
                min_gy,
                max_gx,
                max_gy,
                max_depth,
            );
            let shift = max_depth - child_depth;
            let child_cell_key = morton::depth_prefix(
                morton::interleave_n(
                    min_gx >> shift,
                    min_gy >> shift,
                    child_depth,
                ),
                child_depth,
            );
            polygon::set_cells(
                &mut child_polygon,
                vector[child_cell_key],
            );
            let child_id = index::put_polygon(
                index,
                child_polygon,
            );
            index::register_in_cell(
                index,
                child_id,
                child_cell_key,
                child_depth,
            );
            index::increment_count(index);
            vector::push_back(&mut child_ids, child_id);
        };
        vector::destroy_empty(prepared_children);

        let mut emitted_child_ids = vector::empty<ID>();
        i = 0;
        let id_count = vector::length(&child_ids);
        while (i < id_count) {
            vector::push_back(
                &mut emitted_child_ids,
                *vector::borrow(&child_ids, i),
            );
            i = i + 1;
        };
        event::emit(RegionSplit {
            parent_id,
            child_ids: emitted_child_ids,
            caller: tx_context::sender(ctx),
        });

        child_ids
    }

    /// Merge two adjacent same-owner regions. Area conserved.
    /// SAFETY: Low-level protocol operation. Callers must enforce application-level invariants
    /// tax, and pause checks.
    #[allow(lint(prefer_mut_tx_context))]
    public fun merge_keep(
        index: &mut Index,
        keep_id: ID,
        absorb_id: ID,
        merged_parts_xs: vector<vector<u64>>,
        merged_parts_ys: vector<vector<u64>>,
        ctx: &tx_context::TxContext,
    ) {
        assert!(keep_id != absorb_id, ESelfMerge);

        let mut old_cells_keep = vector::empty<u64>();
        let old_area_sum: u128;
        {
            let keep_polygon = index::get(index, keep_id);
            let absorb_polygon = index::get(index, absorb_id);
            assert!(polygon::owner(keep_polygon) == polygon::owner(absorb_polygon), EOwnerMismatch);
            assert!(polygon::owner(keep_polygon) == tx_context::sender(ctx), EOwnerMismatch);
            assert!(
                polygon::touches_by_edge(
                    keep_polygon,
                    absorb_polygon,
                ),
                ENotAdjacent,
            );

            old_area_sum =
                polygon::checked_area_sum(
                    polygon::area_fp2(keep_polygon),
                    polygon::area_fp2(absorb_polygon),
                );

            let old_cells_keep_ref = polygon::cells(
                keep_polygon,
            );
            let mut i = 0;
            let old_cell_count_keep = vector::length(
                old_cells_keep_ref,
            );
            while (i < old_cell_count_keep) {
                vector::push_back(
                    &mut old_cells_keep,
                    *vector::borrow(old_cells_keep_ref, i),
                );
                i = i + 1;
            };
        };

        let (
            merged_parts,
            merged_aabb,
            merged_total_vertices,
            merged_part_count,
        ) = polygon::prepare_geometry(
            merged_parts_xs,
            merged_parts_ys,
            index::max_vertices_per_part(index),
        );
        index::assert_vertex_limit(
            index,
            merged_total_vertices,
            merged_part_count,
        );
        let merged_area = polygon::area_fp2_from_parts(
            &merged_parts,
        );
        polygon::assert_area_conserved(
            old_area_sum,
            merged_area,
        );

        if (index::count(index) > 2) {
            assert_no_overlap_with_others_merged(
                index,
                keep_id,
                absorb_id,
                &merged_parts,
                &merged_aabb,
            );
        };

        let (new_min_gx, new_min_gy, new_max_gx, new_max_gy) = index::grid_bounds_for_aabb(
            index,
            &merged_aabb,
        );
        let new_depth = index::natural_depth(
            new_min_gx,
            new_min_gy,
            new_max_gx,
            new_max_gy,
            index::max_depth(index),
        );
        let shift = index::max_depth(index) - new_depth;
        let new_cell_key = morton::depth_prefix(
            morton::interleave_n(
                new_min_gx >> shift,
                new_min_gy >> shift,
                new_depth,
            ),
            new_depth,
        );

        index::unregister_from_cells(
            index,
            keep_id,
            &old_cells_keep,
        );
        let _new_keep_area = index::set_polygon_geometry(
            index,
            keep_id,
            merged_parts,
            new_cell_key,
        );
        index::register_in_cell(
            index,
            keep_id,
            new_cell_key,
            new_depth,
        );

        // Clean up metadata on absorbed polygon before destruction (META-01)
        metadata::force_remove_metadata(
            index::uid_mut(index),
            absorb_id,
        );
        index::remove_unchecked(index, absorb_id);

        event::emit(RegionRetired {
            polygon_id: absorb_id,
            caller: tx_context::sender(ctx),
        });
        event::emit(RegionsMerged {
            keep_id,
            absorbed_id: absorb_id,
            caller: tx_context::sender(ctx),
        });
    }

    /// Remove a polygon with metadata cleanup. Wraps `index::remove` with
    /// `force_remove_metadata` to prevent dynamic field orphaning (META-01).
    /// Market layers should call this instead of `index::remove` directly.
    /// SAFETY: Low-level protocol operation. Callers must enforce application-level invariants
    /// tax, and pause checks.
    public fun remove_polygon(index: &mut Index, polygon_id: ID, ctx: &mut tx_context::TxContext) {
        metadata::force_remove_metadata(
            index::uid_mut(index),
            polygon_id,
        );
        index::remove(index, polygon_id, ctx);
    }

    fun assert_no_overlap_with_others_pair(
        index: &Index,
        a_id: ID,
        b_id: ID,
        new_parts_a: &vector<polygon::Part>,
        new_aabb_a: &aabb::AABB,
        new_parts_b: &vector<polygon::Part>,
        new_aabb_b: &aabb::AABB,
    ) {
        // Separate broadphase for each output polygon's AABB
        let (min_gx_a, min_gy_a, max_gx_a, max_gy_a) = index::grid_bounds_for_aabb(
            index,
            new_aabb_a,
        );
        let (min_gx_b, min_gy_b, max_gx_b, max_gy_b) = index::grid_bounds_for_aabb(
            index,
            new_aabb_b,
        );

        let mut candidate_ids = index::broadphase_from_aabb(
            index,
            min_gx_a,
            min_gy_a,
            max_gx_a,
            max_gy_a,
        );
        let candidates_b = index::broadphase_from_aabb(
            index,
            min_gx_b,
            min_gy_b,
            max_gx_b,
            max_gy_b,
        );

        // Merge candidates_b into candidate_ids (deduplicate)
        let mut i = 0;
        while (i < vector::length(&candidates_b)) {
            let id = *vector::borrow(&candidates_b, i);
            if (!vector::contains(&candidate_ids, &id)) {
                vector::push_back(&mut candidate_ids, id);
            };
            i = i + 1;
        };
        let mut c = 0;
        let candidate_count = vector::length(&candidate_ids);
        while (c < candidate_count) {
            let candidate_id = *vector::borrow(&candidate_ids, c);
            if (candidate_id != a_id && candidate_id != b_id) {
                let candidate_polygon = index::get(
                    index,
                    candidate_id,
                );
                if (
                    polygon::intersects_polygon_by_parts(
                    new_parts_a,
                    new_aabb_a,
                    candidate_polygon,
                )
                    || polygon::intersects_polygon_by_parts(
                        new_parts_b,
                        new_aabb_b,
                        candidate_polygon,
                    )
                ) {
                    abort EOverlap
                };
            };
            c = c + 1;
        };
    }

    fun assert_no_overlap_with_others_merged(
        index: &Index,
        keep_id: ID,
        absorb_id: ID,
        merged_parts: &vector<polygon::Part>,
        merged_aabb: &aabb::AABB,
    ) {
        let (min_gx, min_gy, max_gx, max_gy) = index::grid_bounds_for_aabb(index, merged_aabb);
        let candidate_ids = index::broadphase_from_aabb(
            index,
            min_gx,
            min_gy,
            max_gx,
            max_gy,
        );
        let mut c = 0;
        let candidate_count = vector::length(&candidate_ids);
        while (c < candidate_count) {
            let candidate_id = *vector::borrow(&candidate_ids, c);
            if (candidate_id != keep_id && candidate_id != absorb_id) {
                let candidate_polygon = index::get(
                    index,
                    candidate_id,
                );
                if (
                    polygon::intersects_polygon_by_parts(
                        merged_parts,
                        merged_aabb,
                        candidate_polygon,
                    )
                ) {
                    abort EOverlap
                };
            };
            c = c + 1;
        };
    }
}
