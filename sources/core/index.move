/// Quadtree spatial index — an alternative to the uniform grid index.
/// Stores each polygon at its "natural depth" (the shallowest quadtree cell
/// that fully encloses its AABB), reducing dynamic field allocations from O(K)
/// to O(1) per polygon. Uses Morton codes for cell addressing.
module mercator::index {
    use mercator::{aabb, metadata_store, morton, polygon};
    use sui::{event, table::{Self, Table}, vec_set::{Self, VecSet}};

    // === Errors ===

    const ENotFound: u64 = 4005;
    const ENotOwner: u64 = 4006;
    const EBadVertices: u64 = 4001;
    const EMismatch: u64 = 4002;
    const EBadMaxDepth: u64 = 4009;
    const ETooManyParts: u64 = 4010;
    const EOverlap: u64 = 4012;
    const EIndexNotEmpty: u64 = 4013;
    const EBadCellSize: u64 = 4014;
    const ECoordinateTooLarge: u64 = 4016;
    const EZeroAreaRegion: u64 = 4017;
    const EBadConfig: u64 = 4018;
    const ECapIndexMismatch: u64 = 4019;
    const EQueryTooLarge: u64 = 4021;
    const EIndexEmpty: u64 = 4022;
    /// [DOS-01] Broadphase probe budget exceeded — caller must reduce AABB span
    /// or wait until occupied depths thin out.
    const EBroadphaseBudgetExceeded: u64 = 4023;
    /// [DOS-02] Per-cell polygon cap exceeded — cell cannot accept new region.
    const ECellOccupancyExceeded: u64 = 4024;

    // === Constants ===

    const DEFAULT_CELL_SIZE: u64 = 1_000_000;
    const DEFAULT_MAX_DEPTH: u8 = 20;
    /// Coordinate scale factor. See `polygon::SCALE` for semantics.
    const SCALE: u64 = 1_000_000;
    const MAX_GRID_COORD: u64 = 4_294_967_295;

    // === Structs ===

    /// Protocol configuration for the quadtree index.
    /// Note: max_depth is intentionally NOT here — it lives on Index and is
    /// immutable after creation (cell keys depend on it). See F-13.
    public struct Config has copy, drop, store {
        max_vertices: u64,
        max_parts_per_polygon: u64,
        scaling_factor: u64,
        max_broadphase_span: u64,
        max_cell_occupancy: u64,
        max_probes_per_call: u64,
    }

    /// The shared quadtree index. One per deployment.
    /// Each polygon is stored in exactly one cell at its natural depth.
    public struct Index has key, store {
        id: object::UID,
        /// Maps depth-prefixed Morton keys to polygon IDs stored at that cell.
        cells: Table<u64, vector<ID>>,
        /// Maps polygon IDs to Polygon objects.
        polygons: Table<ID, polygon::Polygon>,
        /// Size of the finest-level cell in coordinate units.
        cell_size: u64,
        /// Maximum quadtree depth (finest level). World covers 2^max_depth cells.
        max_depth: u8,
        /// Total registered regions.
        count: u64,
        /// Bitmask of occupied quadtree depths.
        occupied_depths: u32,
        config: Config,
    }

    /// Market authorization capability. Holder can force-transfer polygon ownership.
    public struct TransferCap has key, store {
        id: object::UID,
        index_id: ID,
    }

    // === Events ===

    /// Emitted when a region is registered.
    public struct Registered has copy, drop {
        polygon_id: ID,
        owner: address,
        part_count: u64,
        cell_count: u64,
        depth: u8,
    }

    /// Emitted when a region is removed.
    public struct Removed has copy, drop {
        polygon_id: ID,
        owner: address,
    }

    /// Emitted when region ownership is transferred.
    public struct Transferred has copy, drop {
        polygon_id: ID,
        from: address,
        to: address,
    }

    /// Emitted when admin updates Index configuration (F-07 fix).
    public struct ConfigUpdated has copy, drop {
        max_vertices: u64,
        max_parts_per_polygon: u64,
        scaling_factor: u64,
        max_broadphase_span: u64,
        max_cell_occupancy: u64,
        max_probes_per_call: u64,
    }

    // === Public Functions ===

    /// Create a new Index with default config.
    public(package) fun new(ctx: &mut tx_context::TxContext): Index {
        with_config(
            DEFAULT_CELL_SIZE,
            DEFAULT_MAX_DEPTH,
            polygon::max_vertices_per_part(),
            polygon::max_parts(),
            1024,
            64,
            2_000_000,
            ctx,
        )
    }

    /// Create a new Index with explicit config values.
    public(package) fun with_config(
        cell_size: u64,
        max_depth: u8,
        max_vertices: u64,
        max_parts: u64,
        max_broadphase_span: u64,
        max_cell_occupancy: u64,
        max_probes_per_call: u64,
        ctx: &mut tx_context::TxContext,
    ): Index {
        assert!(cell_size > 0, EBadCellSize);
        assert!(max_depth > 0 && max_depth <= morton::max_depth(), EBadMaxDepth);
        Index {
            id: object::new(ctx),
            cells: table::new(ctx),
            polygons: table::new(ctx),
            cell_size,
            max_depth,
            count: 0,
            occupied_depths: 0,
            config: new_config(
                max_vertices,
                max_parts,
                SCALE,
                max_broadphase_span,
                max_cell_occupancy,
                max_probes_per_call,
            ),
        }
    }

    /// Create a Index and make it a shared object.
    /// Restricted to package-internal callers for governed creation.
    public(package) fun share(ctx: &mut tx_context::TxContext) {
        let index = new(ctx);
        transfer::share_object(index);
    }

    /// Share an already-created owned Index.
    /// Intentional: `public(package)` restricts callers to this package only,
    /// and `store` on Index is required for dynamic fields / transfers.
    /// The owned→shared transition is safe because all call sites create
    /// the Index in the same transaction before sharing.
    #[allow(lint(custom_state_change, share_owned))]
    public(package) fun share_existing(index: Index) {
        transfer::share_object(index);
    }

    /// Create a Index with custom configuration and make it a shared object.
    /// Restricted to package-internal callers for governed creation.
    public(package) fun share_with_config(
        cell_size: u64,
        max_depth: u8,
        max_vertices: u64,
        max_parts: u64,
        max_broadphase_span: u64,
        max_cell_occupancy: u64,
        max_probes_per_call: u64,
        ctx: &mut tx_context::TxContext,
    ) {
        let index = with_config(
            cell_size,
            max_depth,
            max_vertices,
            max_parts,
            max_broadphase_span,
            max_cell_occupancy,
            max_probes_per_call,
            ctx,
        );
        transfer::share_object(index);
    }

    /// Mint a TransferCap for authorized callers (e.g., a market or trading module).
    public(package) fun mint_transfer_cap(
        index: &Index,
        ctx: &mut tx_context::TxContext,
    ): TransferCap {
        TransferCap {
            id: object::new(ctx),
            index_id: object::id(index),
        }
    }

    #[test_only]
    public fun mint_transfer_cap_for_testing(
        index: &mut Index,
        ctx: &mut tx_context::TxContext,
    ): TransferCap {
        mint_transfer_cap(index, ctx)
    }

    /// Register a new region.
    /// Stores the polygon at its natural quadtree depth (single cell).
    /// Aborts with EOverlap if it intersects an existing region.
    public fun register(
        index: &mut Index,
        parts_xs: vector<vector<u64>>,
        parts_ys: vector<vector<u64>>,
        ctx: &mut tx_context::TxContext,
    ): ID {
        let part_count = vector::length(&parts_xs);
        assert!(part_count >= 1, ETooManyParts);
        assert!(part_count == vector::length(&parts_ys), EMismatch);
        assert!(part_count <= index.config.max_parts_per_polygon, ETooManyParts);

        let mut parts_xs = parts_xs;
        let mut parts_ys = parts_ys;
        let mut parts_vec = vector::empty<polygon::Part>();
        let mut total_vertex_count = 0;
        let mut i = 0;
        while (i < part_count) {
            let xs = vector::remove(&mut parts_xs, 0);
            let ys = vector::remove(&mut parts_ys, 0);
            let vertex_count = vector::length(&xs);
            assert!(vertex_count >= 3, EBadVertices);
            total_vertex_count = total_vertex_count + vertex_count;
            vector::push_back(
                &mut parts_vec,
                polygon::part(xs, ys),
            );
            i = i + 1;
        };
        assert!(total_vertex_count <= index.config.max_vertices * part_count, EBadVertices);

        let mut polygon_obj = polygon::new(parts_vec, ctx);
        assert!(polygon::area(&polygon_obj) > 0, EZeroAreaRegion);
        let aabb = polygon::bounds(&polygon_obj);

        let (min_gx, min_gy, max_gx, max_gy) = grid_bounds_for_aabb(index, &aabb);

        // Find natural depth: shallowest depth where AABB fits in one cell
        let depth = natural_depth(
            min_gx,
            min_gy,
            max_gx,
            max_gy,
            index.max_depth,
        );
        let shift: u8 = index.max_depth - depth;
        let cx = min_gx >> shift;
        let cy = min_gy >> shift;
        let cell_key = morton::depth_prefix(
            morton::interleave_n(cx, cy, depth),
            depth,
        );

        // Check no overlaps with existing polygons
        check_no_overlaps(
            index,
            &polygon_obj,
            min_gx,
            min_gy,
            max_gx,
            max_gy,
        );

        // Store polygon at single cell
        let cells = vector[cell_key];
        polygon::set_cells(&mut polygon_obj, cells);

        let polygon_id = object::id(&polygon_obj);
        let owner = polygon::owner(&polygon_obj);
        let registered_part_count = polygon::parts(
            &polygon_obj,
        );

        register_in_cell(index, polygon_id, cell_key, depth);
        table::add(
            &mut index.polygons,
            polygon_id,
            polygon_obj,
        );
        index.count = index.count + 1;

        event::emit(Registered {
            polygon_id,
            owner,
            part_count: registered_part_count,
            cell_count: 1,
            depth,
        });

        polygon_id
    }

    /// Remove a region. Caller must be the owner.
    public fun remove(index: &mut Index, polygon_id: ID, ctx: &mut tx_context::TxContext) {
        assert!(table::contains(&index.polygons, polygon_id), ENotFound);
        let existing = table::borrow(
            &index.polygons,
            polygon_id,
        );
        assert!(polygon::owner(existing) == tx_context::sender(ctx), ENotOwner);
        remove_unchecked(index, polygon_id);
    }

    /// Remove a region without ownership check.
    public(package) fun remove_unchecked(index: &mut Index, polygon_id: ID) {
        assert!(table::contains(&index.polygons, polygon_id), ENotFound);
        let existing = table::borrow(
            &index.polygons,
            polygon_id,
        );
        let owner = polygon::owner(existing);
        let cells_copy = *polygon::cells(existing);
        metadata_store::force_remove_metadata(
            &mut index.id,
            polygon_id,
        );
        unregister_from_cells(index, polygon_id, &cells_copy);
        let removed = table::remove(
            &mut index.polygons,
            polygon_id,
        );
        polygon::destroy(removed);
        index.count = index.count - 1;
        event::emit(Removed { polygon_id, owner });
    }

    /// Transfer polygon ownership. Caller must be the current owner.
    #[allow(lint(prefer_mut_tx_context))]
    public fun transfer_ownership(
        index: &mut Index,
        polygon_id: ID,
        new_owner: address,
        ctx: &tx_context::TxContext,
    ) {
        assert!(table::contains(&index.polygons, polygon_id), ENotFound);
        let existing = table::borrow(
            &index.polygons,
            polygon_id,
        );
        let from = polygon::owner(existing);
        assert!(from == tx_context::sender(ctx), ENotOwner);
        let polygon = table::borrow_mut(
            &mut index.polygons,
            polygon_id,
        );
        polygon::set_owner(polygon, new_owner);
        event::emit(Transferred {
            polygon_id,
            from,
            to: new_owner,
        });
    }

    /// Force-transfer polygon ownership. Requires TransferCap — no owner check.
    public fun force_transfer(
        _cap: &TransferCap,
        index: &mut Index,
        polygon_id: ID,
        new_owner: address,
    ) {
        assert_transfer_cap_authorized(index, _cap);
        assert!(table::contains(&index.polygons, polygon_id), ENotFound);
        let existing = table::borrow(
            &index.polygons,
            polygon_id,
        );
        let from = polygon::owner(existing);
        let polygon = table::borrow_mut(
            &mut index.polygons,
            polygon_id,
        );
        polygon::set_owner(polygon, new_owner);
        event::emit(Transferred {
            polygon_id,
            from,
            to: new_owner,
        });
    }

    /// Return an immutable reference to the Index's UID for dynamic field reads.
    public(package) fun uid(index: &Index): &UID { &index.id }

    /// Return a mutable reference to the Index's UID for dynamic field writes.
    public(package) fun uid_mut(index: &mut Index): &mut UID {
        &mut index.id
    }

    /// Broadphase: return IDs of regions that might overlap with query_id.
    /// Searches all quadtree depths for cells intersecting the query AABB,
    /// checking both ancestors (large polygons) and descendants (small polygons).
    public fun candidates(index: &Index, query_id: ID): vector<ID> {
        assert!(table::contains(&index.polygons, query_id), ENotFound);
        let query_polygon = table::borrow(
            &index.polygons,
            query_id,
        );
        let aabb = polygon::bounds(query_polygon);

        let (min_gx, min_gy, max_gx, max_gy) = grid_bounds_for_aabb(index, &aabb);

        let all_ids = broadphase_from_aabb(
            index,
            min_gx,
            min_gy,
            max_gx,
            max_gy,
        );

        // Filter out query_id
        let mut result = vector::empty<ID>();
        let mut i = 0;
        while (i < vector::length(&all_ids)) {
            let pid = *vector::borrow(&all_ids, i);
            if (pid != query_id) {
                vector::push_back(&mut result, pid);
            };
            i = i + 1;
        };
        result
    }

    /// True iff two regions geometrically overlap (full SAT check).
    public fun overlaps(index: &Index, id_a: ID, id_b: ID): bool {
        assert!(table::contains(&index.polygons, id_a), ENotFound);
        assert!(table::contains(&index.polygons, id_b), ENotFound);
        let poly_a = table::borrow(&index.polygons, id_a);
        let poly_b = table::borrow(&index.polygons, id_b);
        polygon::intersects(poly_a, poly_b)
    }

    /// Returns true iff the polygon identified by `inner_id` in `inner_index` is fully
    /// geometrically contained within the polygon identified by `outer_id` in `outer_index`.
    /// Uses `polygon::contains_polygon` which checks that all inner vertices lie inside outer.
    public fun outer_contains_inner(
        outer_index: &Index,
        outer_id: ID,
        inner_index: &Index,
        inner_id: ID,
    ): bool {
        let outer = get(outer_index, outer_id);
        let inner = get(inner_index, inner_id);
        polygon::contains_polygon(outer, inner)
    }

    /// Return IDs of all regions that overlap with query_id.
    public fun overlapping(index: &Index, query_id: ID): vector<ID> {
        let broadphase = candidates(index, query_id);
        let query_polygon = table::borrow(
            &index.polygons,
            query_id,
        );
        let query_bounds = polygon::bounds(query_polygon);

        let mut result = vector::empty<ID>();
        let mut i = 0;
        let n = vector::length(&broadphase);
        while (i < n) {
            let candidate_id = *vector::borrow(&broadphase, i);
            let candidate = table::borrow(
                &index.polygons,
                candidate_id,
            );
            if (
                aabb::intersects(
                    &query_bounds,
                    &polygon::bounds(candidate),
                )
            ) {
                if (
                    polygon::intersects(
                        query_polygon,
                        candidate,
                    )
                ) {
                    vector::push_back(
                        &mut result,
                        candidate_id,
                    );
                };
            };
            i = i + 1;
        };
        result
    }

    /// Viewport query: return IDs of regions overlapping the given viewport bounding box.
    /// Takes fixed-point coordinate bounds and performs a broadphase spatial search across all quadtree depths.
    /// Used for viewport-based polygon loading in the UI.
    public fun query_viewport(
        index: &Index,
        min_x: u64,
        min_y: u64,
        max_x: u64,
        max_y: u64,
    ): vector<ID> {
        let (min_gx, min_gy, max_gx, max_gy) = grid_bounds_for_aabb(
            index,
            &aabb::new(min_x, min_y, max_x, max_y),
        );
        broadphase_from_aabb(
            index,
            min_gx,
            min_gy,
            max_gx,
            max_gy,
        )
    }

    /// Create a new Config value for admin updates.
    /// Validates all parameters to prevent pathological values that break protocol invariants.
    /// max_depth is not configurable — it is fixed at Index creation time (F-13).
    public fun new_config(
        max_vertices: u64,
        max_parts_per_polygon: u64,
        scaling_factor: u64,
        max_broadphase_span: u64,
        max_cell_occupancy: u64,
        max_probes_per_call: u64,
    ): Config {
        assert!(max_vertices > 0, EBadConfig);
        assert!(max_parts_per_polygon > 0, EBadConfig);
        assert!(scaling_factor > 0, EBadConfig);
        assert!(max_broadphase_span >= 2, EBadConfig);
        assert!(max_cell_occupancy >= 1, EBadConfig);
        assert!(max_probes_per_call >= max_broadphase_span * max_broadphase_span, EBadConfig);
        Config {
            max_vertices,
            max_parts_per_polygon,
            scaling_factor,
            max_broadphase_span,
            max_cell_occupancy,
            max_probes_per_call,
        }
    }

    public(package) fun set_config(index: &mut Index, config: Config) {
        assert!(config.max_broadphase_span <= (1u64 << index.max_depth), EBadConfig);
        event::emit(ConfigUpdated {
            max_vertices: config.max_vertices,
            max_parts_per_polygon: config.max_parts_per_polygon,
            scaling_factor: config.scaling_factor,
            max_broadphase_span: config.max_broadphase_span,
            max_cell_occupancy: config.max_cell_occupancy,
            max_probes_per_call: config.max_probes_per_call,
        });
        index.config = config;
    }

    /// Abort if `cap` does not belong to `index`.
    public(package) fun assert_transfer_cap_authorized(index: &Index, cap: &TransferCap) {
        assert!(cap.index_id == object::uid_to_inner(&index.id), ECapIndexMismatch);
    }

    /// Assert that total vertex count respects the admin-configured max_vertices per part.
    /// Used by mutation functions to enforce the same limit as register().
    public(package) fun assert_vertex_limit(index: &Index, total_vertices: u64, part_count: u64) {
        assert!(total_vertices <= index.config.max_vertices * part_count, EBadVertices);
    }

    /// Destroy an empty index, freeing its UID. Aborts if any regions remain.
    public(package) fun destroy_empty(index: Index) {
        let Index {
            id,
            cells,
            polygons,
            cell_size: _,
            max_depth: _,
            count,
            occupied_depths: _,
            config: _,
        } = index;
        assert!(count == 0, EIndexNotEmpty);
        table::destroy_empty(cells);
        table::destroy_empty(polygons);
        object::delete(id);
    }

    /// Total number of registered regions.
    public fun count(index: &Index): u64 {
        index.count
    }

    /// Finest-level cell size in coordinate units.
    public fun cell_size(index: &Index): u64 {
        index.cell_size
    }

    /// Maximum quadtree depth.
    public fun max_depth(index: &Index): u8 {
        index.max_depth
    }

    /// Admin-configurable maximum vertices per polygon part.
    public fun max_vertices_per_part(index: &Index): u64 {
        index.config.max_vertices
    }

    public fun max_parts_per_polygon(index: &Index): u64 {
        index.config.max_parts_per_polygon
    }

    public fun scaling_factor(index: &Index): u64 {
        index.config.scaling_factor
    }

    public fun max_broadphase_span(index: &Index): u64 {
        index.config.max_broadphase_span
    }

    public fun max_cell_occupancy(index: &Index): u64 {
        index.config.max_cell_occupancy
    }

    public fun max_probes_per_call(index: &Index): u64 {
        index.config.max_probes_per_call
    }

    /// Look up a registered region by ID.
    public fun get(index: &Index, polygon_id: ID): &polygon::Polygon {
        assert!(table::contains(&index.polygons, polygon_id), ENotFound);
        table::borrow(&index.polygons, polygon_id)
    }

    /// Mutate polygon geometry and overwrite single-cell placement.
    public(package) fun set_polygon_geometry(
        index: &mut Index,
        polygon_id: ID,
        new_parts: vector<polygon::Part>,
        new_cell_key: u64,
    ): u64 {
        let polygon = table::borrow_mut(
            &mut index.polygons,
            polygon_id,
        );
        polygon::set_parts(polygon, new_parts);
        polygon::set_cells(polygon, vector[new_cell_key]);
        polygon::area(polygon)
    }

    public(package) fun take_polygon(index: &mut Index, polygon_id: ID): polygon::Polygon {
        assert!(table::contains(&index.polygons, polygon_id), ENotFound);
        table::remove(&mut index.polygons, polygon_id)
    }

    public(package) fun put_polygon(index: &mut Index, polygon: polygon::Polygon): ID {
        let polygon_id = object::id(&polygon);
        table::add(&mut index.polygons, polygon_id, polygon);
        polygon_id
    }

    public(package) fun increment_count(index: &mut Index) {
        index.count = index.count + 1;
    }

    public(package) fun decrement_count(index: &mut Index) {
        assert!(index.count > 0, EIndexEmpty);
        index.count = index.count - 1;
    }

    // === Private Functions ===

    /// Find the natural depth for an AABB: the deepest depth where
    /// the AABB fits within a single quadtree cell.
    public(package) fun natural_depth(
        min_x: u32,
        min_y: u32,
        max_x: u32,
        max_y: u32,
        max_depth: u8,
    ): u8 {
        let mut depth = max_depth;
        while (depth > 0) {
            let shift: u8 = max_depth - depth;
            if (
                (min_x >> shift) == (max_x >> shift)
                && (min_y >> shift) == (max_y >> shift)
            ) {
                return depth
            };
            depth = depth - 1;
        };
        0
    }

    public(package) fun grid_bounds_for_aabb(
        index: &Index,
        bounds: &aabb::AABB,
    ): (u32, u32, u32, u32) {
        let min_gx64 = aabb::min_x(bounds) / index.cell_size;
        let min_gy64 = aabb::min_y(bounds) / index.cell_size;
        // Inclusive upper bound: intentionally uses floor(max / cell_size) rather
        // than floor((max-1) / cell_size). This makes boundary-aligned polygons
        // straddle one extra cell, which pushes natural_depth one level shallower.
        // The effective max depth is (max_depth - 1), but this ensures the broadphase
        // always finds edge-adjacent polygons as candidates. See [IDX-02].
        let max_gx64 = aabb::max_x(bounds) / index.cell_size;
        let max_gy64 = aabb::max_y(bounds) / index.cell_size;

        assert!(min_gx64 < MAX_GRID_COORD, ECoordinateTooLarge);
        assert!(min_gy64 < MAX_GRID_COORD, ECoordinateTooLarge);
        assert!(max_gx64 < MAX_GRID_COORD, ECoordinateTooLarge);
        assert!(max_gy64 < MAX_GRID_COORD, ECoordinateTooLarge);

        // [IDX-02] Cap per-axis cell span via the index's configured broadphase limit.
        assert!(max_gx64 - min_gx64 <= index.config.max_broadphase_span, EQueryTooLarge);
        assert!(max_gy64 - min_gy64 <= index.config.max_broadphase_span, EQueryTooLarge);

        ((min_gx64 as u32), (min_gy64 as u32), (max_gx64 as u32), (max_gy64 as u32))
    }

    /// Hamming weight of a u32 via Kernighan's bit-clearing trick.
    /// Runs in O(popcount) iterations, not O(32).
    fun popcount_u32(mut x: u32): u8 {
        let mut count: u8 = 0;
        while (x != 0u32) {
            x = x & (x - 1u32);
            count = count + 1;
        };
        count
    }

    /// Broadphase search: find all polygon IDs in cells that intersect the AABB.
    /// Iterates over all depths from 0 to max_depth, computing the covered cells
    /// at each depth and looking up stored polygons.
    public(package) fun broadphase_from_aabb(
        index: &Index,
        min_gx: u32,
        min_gy: u32,
        max_gx: u32,
        max_gy: u32,
    ): vector<ID> {
        // [DOS-01] Probe budget: bound iteration work by span * populated depths,
        // using the per-index configured cap.
        // Upper bound on total probes across all depths is
        //   span_x * span_y * popcount(occupied_depths),
        // since the per-depth span is monotonically non-increasing as depth decreases
        // (right-shift halves extent at each coarser level). The popcount factor
        // skips empty depth layers, matching the `occupied & (1 << depth) == 0`
        // early-continue inside the loop. See DOS-01.
        let occupied = index.occupied_depths;
        let span_x = (max_gx as u64) - (min_gx as u64) + 1;
        let span_y = (max_gy as u64) - (min_gy as u64) + 1;
        let populated_depths = (popcount_u32(occupied) as u64);
        // Zero populated depths ⇒ empty index ⇒ no probing, no budget check needed.
        if (populated_depths > 0) {
            assert!(
                span_x * span_y * populated_depths <= index.config.max_probes_per_call,
                EBroadphaseBudgetExceeded,
            );
        };

        let mut result: VecSet<ID> = vec_set::empty();
        let mut depth: u8 = 0;
        while (depth <= index.max_depth) {
            if (occupied & (1u32 << depth) == 0u32) {
                depth = depth + 1;
                continue
            };
            let shift: u8 = index.max_depth - depth;
            let cmin_x = min_gx >> shift;
            let cmax_x = max_gx >> shift;
            let cmin_y = min_gy >> shift;
            let cmax_y = max_gy >> shift;

            let mut cy = cmin_y;
            while (cy <= cmax_y) {
                let mut cx = cmin_x;
                while (cx <= cmax_x) {
                    let key = morton::depth_prefix(
                        morton::interleave_n(cx, cy, depth),
                        depth,
                    );
                    if (table::contains(&index.cells, key)) {
                        let cell_polygons = table::borrow(
                            &index.cells,
                            key,
                        );
                        let mut j = 0;
                        while (j < vector::length(cell_polygons)) {
                            let pid =
                                *vector::borrow(
                                    cell_polygons,
                                    j,
                                );
                            if (
                                !vec_set::contains(
                                    &result,
                                    &pid,
                                )
                            ) {
                                vec_set::insert(
                                    &mut result,
                                    pid,
                                );
                            };
                            j = j + 1;
                        };
                    };
                    cx = cx + 1;
                };
                cy = cy + 1;
            };
            depth = depth + 1;
        };
        vec_set::into_keys(result)
    }

    /// Check that no existing polygon overlaps with a new polygon.
    fun check_no_overlaps(
        index: &Index,
        new_polygon: &polygon::Polygon,
        min_gx: u32,
        min_gy: u32,
        max_gx: u32,
        max_gy: u32,
    ) {
        let candidate_ids = broadphase_from_aabb(
            index,
            min_gx,
            min_gy,
            max_gx,
            max_gy,
        );
        let mut k = 0;
        let num = vector::length(&candidate_ids);
        while (k < num) {
            let cid = *vector::borrow(&candidate_ids, k);
            let existing = table::borrow(&index.polygons, cid);
            if (polygon::intersects(new_polygon, existing)) {
                abort EOverlap
            };
            k = k + 1;
        };
    }

    /// Register a polygon ID in a single cell.
    public(package) fun register_in_cell(
        index: &mut Index,
        polygon_id: ID,
        cell_key: u64,
        depth: u8,
    ) {
        if (!table::contains(&index.cells, cell_key)) {
            table::add(
                &mut index.cells,
                cell_key,
                vector::empty<ID>(),
            );
        };
        let cell_vec = table::borrow_mut(
            &mut index.cells,
            cell_key,
        );
        // Deduplicate: guard against double-registration leaving dangling refs (F-07).
        let (already_present, _) = vector::index_of(
            cell_vec,
            &polygon_id,
        );
        if (!already_present) {
            // [DOS-02] Cap per-cell occupancy to bound narrowphase SAT cost.
            // Attackers who stack many small regions in one cell would otherwise
            // force every later registration touching that cell to pay O(config.max_cell_occupancy)
            // SAT checks. The cap also bounds broadphase inner-loop vector scans.
            assert!(
                vector::length(cell_vec) < index.config.max_cell_occupancy,
                ECellOccupancyExceeded,
            );
            vector::push_back(cell_vec, polygon_id);
            index.occupied_depths = index.occupied_depths | (1u32 << depth);
        };
    }

    /// Unregister a polygon from its cells. Cleans up empty cells.
    public(package) fun unregister_from_cells(
        index: &mut Index,
        polygon_id: ID,
        cells: &vector<u64>,
    ) {
        let mut i = 0;
        let n = vector::length(cells);
        while (i < n) {
            let cid = *vector::borrow(cells, i);
            if (table::contains(&index.cells, cid)) {
                let cell_vec = table::borrow_mut(
                    &mut index.cells,
                    cid,
                );
                let (found, idx) = vector::index_of(
                    cell_vec,
                    &polygon_id,
                );
                if (found) {
                    vector::remove(cell_vec, idx);
                    if (vector::length(cell_vec) == 0) {
                        let empty = table::remove(
                            &mut index.cells,
                            cid,
                        );
                        vector::destroy_empty(empty);
                    };
                };
            };
            i = i + 1;
        };
    }
}
