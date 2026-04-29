# API Reference

Mercator is a spatial uniqueness library for Sui Move. This is the full public function reference for the `mercator` package. For conceptual background, see [concepts.md](./concepts.md). For step-by-step workflows with code examples, see [guide.md](./guide.md).

Functions marked *(package)* are `public(package)` — callable only from within the `mercator` package itself, not from external modules.

---

## `mercator::registry`

Package initializer. Called once at deploy time to create the shared Index and transfer the TransferCap to the deployer.

### `init_for_testing`
Test-only wrapper to call `init()` in tests.
`#[test_only] public fun init_for_testing(ctx: &mut TxContext)`

---

## `mercator::index`

The shared spatial index. One `Index` object exists per deployment. See [guide.md — Registering a Region](./guide.md#workflow-1-registering-a-region) for usage examples.

### Capability Structs

**`TransferCap`** — authorizes forced ownership transfers (no owner check). Bound to a specific index at mint time via `index_id`.
```
public struct TransferCap has key, store { id: object::UID, index_id: ID }
```

### Events

| Event | Key fields |
|-------|-----------|
| `Registered` | `polygon_id`, `owner`, `part_count`, `cell_count`, `depth` |
| `Removed` | `polygon_id`, `owner` |
| `Transferred` | `polygon_id`, `from`, `to` |
| `ConfigUpdated` | all Config fields |

### Construction

**`new`** *(package)*
Create a new `Index` with default config.
`public(package) fun new(ctx: &mut TxContext): Index`

**`with_config`** *(package)*
Create a new `Index` with explicit config values.
`public(package) fun with_config(cell_size: u64, max_depth: u8, max_vertices: u64, max_parts: u64, max_broadphase_span: u64, max_cell_occupancy: u64, max_probes_per_call: u64, ctx: &mut TxContext): Index`

**`share`** *(package)*
Create a default `Index` and immediately share it.
`public(package) fun share(ctx: &mut TxContext)`

**`share_existing`** *(package)*
Share an already-created owned `Index`.
`public(package) fun share_existing(index: Index)`

**`share_with_config`** *(package)*
Create an `Index` with custom configuration and make it a shared object.
`public(package) fun share_with_config(cell_size: u64, max_depth: u8, max_vertices: u64, max_parts: u64, max_broadphase_span: u64, max_cell_occupancy: u64, max_probes_per_call: u64, ctx: &mut TxContext)`

**`destroy_empty`** *(package)*
Destroy an empty index, freeing its UID. Aborts with `EIndexNotEmpty` if any regions remain.
`public(package) fun destroy_empty(index: Index)`

### Registration

See [guide.md — Registering a Region](./guide.md#workflow-1-registering-a-region).

**`register`**
Register a new polygon region. No capability required. Aborts with `EOverlap` if it intersects an existing region. Returns the ID of the newly registered polygon.
`public fun register(index: &mut Index, parts_xs: vector<vector<u64>>, parts_ys: vector<vector<u64>>, ctx: &mut TxContext): ID`

**`remove`**
Remove a region. Caller must be the region owner.
`public fun remove(index: &mut Index, polygon_id: ID, ctx: &mut TxContext)`

**`remove_unchecked`** *(package)*
Remove a region without ownership check.
`public(package) fun remove_unchecked(index: &mut Index, polygon_id: ID)`

### Ownership

See [guide.md — Transferring Ownership](./guide.md#workflow-3-transferring-ownership).

**`transfer_ownership`**
Transfer polygon ownership. Caller must be the current owner.
`public fun transfer_ownership(index: &mut Index, polygon_id: ID, new_owner: address, ctx: &TxContext)`

**`force_transfer`**
Force-transfer polygon ownership. Requires `TransferCap` — no owner check.
`public fun force_transfer(_cap: &TransferCap, index: &mut Index, polygon_id: ID, new_owner: address)`

### Queries

See [guide.md — Querying Regions](./guide.md#workflow-2-querying-regions).

**`candidates`**
Broadphase: return IDs of regions in overlapping quadtree cells (all depths) with `query_id`. Does not run SAT — use `overlapping` for exact results.
`public fun candidates(index: &Index, query_id: ID): vector<ID>`

**`overlaps`**
True iff two regions geometrically overlap (full SAT check).
`public fun overlaps(index: &Index, id_a: ID, id_b: ID): bool`

**`overlapping`**
Return IDs of all regions that geometrically overlap with `query_id`.
`public fun overlapping(index: &Index, query_id: ID): vector<ID>`

**`outer_contains_inner`**
True iff the polygon `outer_id` in `outer_index` fully contains the polygon `inner_id` in `inner_index`.
`public fun outer_contains_inner(outer_index: &Index, outer_id: ID, inner_index: &Index, inner_id: ID): bool`

**`query_viewport`**
Return IDs of regions overlapping the given bounding box. Broadphase only — no SAT.
`public fun query_viewport(index: &Index, min_x: u64, min_y: u64, max_x: u64, max_y: u64): vector<ID>`

**`count`**
Total number of registered regions.
`public fun count(index: &Index): u64`

**`get`**
Look up a registered region by ID. Aborts with `ENotFound` if not registered.
`public fun get(index: &Index, polygon_id: ID): &Polygon`

### Config

**`new_config`**
Construct a `Config` with explicit limits. `max_depth` is not part of `Config` — it's fixed at index creation time.
`public fun new_config(max_vertices: u64, max_parts_per_polygon: u64, scaling_factor: u64, max_broadphase_span: u64, max_cell_occupancy: u64, max_probes_per_call: u64): Config`

**`set_config`** *(package)*
Replace the current config.
`public(package) fun set_config(index: &mut Index, config: Config)`

**Config accessors** — all take `index: &Index`:

| Function | Returns |
|----------|---------|
| `cell_size` | `u64` — finest cell size in coordinate units |
| `max_depth` | `u8` — maximum quadtree depth |
| `max_vertices_per_part` | `u64` |
| `max_parts_per_polygon` | `u64` |
| `scaling_factor` | `u64` — 1,000,000 by default |
| `max_broadphase_span` | `u64` |
| `max_cell_occupancy` | `u64` |
| `max_probes_per_call` | `u64` |

### Capabilities

**`mint_transfer_cap`** *(package)* — mint a `TransferCap` bound to this index.
`public(package) fun mint_transfer_cap(index: &Index, ctx: &mut TxContext): TransferCap`

**`assert_transfer_cap_authorized`** *(package)* — abort if `TransferCap` doesn't belong to this index.
`public(package) fun assert_transfer_cap_authorized(index: &Index, cap: &TransferCap)`

---

## `mercator::mutations`

Area-conserving geometry mutations. All check that the caller owns the relevant regions. No capability required. See [guide.md — Geometry Mutations](./guide.md#workflow-4-geometry-mutations).

### Events

| Event | Key fields |
|-------|-----------|
| `RegionReshaped` | `polygon_id`, `old_area`, `new_area`, `caller` — emitted when a region is reshaped |
| `RegionSplit` | `parent_id`, `child_ids`, `caller` — emitted when a region is split into children |
| `RegionsMerged` | `keep_id`, `absorbed_id`, `caller` — emitted when two regions are merged |
| `RegionsRepartitioned` | `a_id`, `b_id`, `caller` — emitted when the boundary between two regions is redrawn |
| `RegionRetired` | `polygon_id`, `caller` — emitted when a region is destroyed (split parent or merge absorb) |

### Functions

**`reshape_unclaimed`**
Reshape a single region. New geometry must contain old geometry. Area may grow but never shrink — aborts with `EAreaShrunk` (5009) if `new_area < old_area`. No overlaps with other regions. Caller must be the polygon owner.
`public fun reshape_unclaimed(index: &mut Index, polygon_id: ID, new_parts_xs: vector<vector<u64>>, new_parts_ys: vector<vector<u64>>, ctx: &TxContext)`

**`split_replace`**
Split a parent into N children (2 ≤ N ≤ 10). Parent area equals sum of children. Each child must be geometrically contained within the parent boundary. Children inherit parent's owner. Caller must be the polygon owner. Aborts with `ETooManyChildren` (5008) if N > 10.
`public fun split_replace(index: &mut Index, parent_id: ID, children_parts_xs: vector<vector<vector<u64>>>, children_parts_ys: vector<vector<vector<u64>>>, ctx: &mut TxContext): vector<ID>`

**`merge_keep`**
Merge two adjacent same-owner regions. Area conserved. Absorb is retired, keep receives merged geometry. Caller must own both polygons.
`public fun merge_keep(index: &mut Index, keep_id: ID, absorb_id: ID, merged_parts_xs: vector<vector<u64>>, merged_parts_ys: vector<vector<u64>>, ctx: &TxContext)`

**`repartition_adjacent`**
Repartition two adjacent regions. Total area conserved. Both receive new geometry. Both output polygons must remain within the union AABB of the originals and must still share an edge. Caller must own both polygons.
`public fun repartition_adjacent(index: &mut Index, a_id: ID, a_parts_xs: vector<vector<u64>>, a_parts_ys: vector<vector<u64>>, b_id: ID, b_parts_xs: vector<vector<u64>>, b_parts_ys: vector<vector<u64>>, ctx: &TxContext)`

---

## `mercator::polygon`

Multi-part polygon representation. A `Polygon` is a union of convex `Part`s. See [concepts.md — Polygon Model](./concepts.md#polygon-model).

You don't construct `Polygon` objects directly in most workflows — `index::register` handles that. These functions are useful for reading region data after fetching via `index::get`.

**`part`**
Construct a convex `Part` from vertex arrays. Rejects non-convex input, fewer than 3 vertices, more than 64 vertices, and edges shorter than SCALE units (1 meter at default scale).
`public fun part(xs: vector<u64>, ys: vector<u64>): Part`

**`new`**
Construct a `Polygon` from convex parts. Enforces topology rules: no pairwise overlap, adjacency only via shared edges, connected union.
`public fun new(parts: vector<Part>, ctx: &mut TxContext): Polygon`

**`intersects`**
True iff two polygons have positive-area overlap (AABB pre-filter + SAT). Pure touching returns `false`.
`public fun intersects(a: &Polygon, b: &Polygon): bool`

**`contains_polygon`**
True iff outer fully contains inner. Checks AABB containment, vertex containment, and edge-sampling at t=1/3 and t=2/3.
`public fun contains_polygon(outer: &Polygon, inner: &Polygon): bool`

**`touches_by_edge`**
True iff two polygons share at least one edge.
`public fun touches_by_edge(a: &Polygon, b: &Polygon): bool`

**Accessors** — all take `polygon: &Polygon`:

| Function | Returns |
|----------|---------|
| `bounds` | `AABB` — global bounding box |
| `area` | `u64` — area in base-unit² (square meters at default scale) |
| `area_fp2` | `u128` — exact twice-area for conservation checks |
| `parts` | `u64` — number of convex parts |
| `vertices` | `u64` — total vertex count |
| `owner` | `address` |
| `created_epoch` | `u64` |
| `cells` | `&vector<u64>` — quadtree cell key(s) |

**`prepare_geometry`** *(package)*
Prepare parts from vertex arrays without creating a Polygon object. Returns `(parts, global_aabb, total_vertices, part_count)`. Used by mutations.
`public(package) fun prepare_geometry(parts_xs: vector<vector<u64>>, parts_ys: vector<vector<u64>>, max_vertices_per_part: u64): (vector<Part>, AABB, u64, u64)`

**`assert_area_conserved`** *(package)*
Assert old area equals new area. Aborts with `EAreaConservationViolation`.
`public(package) fun assert_area_conserved(old_fp2: u128, new_fp2: u128)`

---

## `mercator::metadata`

Per-region string metadata. See [guide.md — Metadata](./guide.md#workflow-5-metadata).

**`set_metadata`**
Set or update string metadata for a region. Caller must be the current owner. Idempotent: calling twice overwrites the previous value. Aborts with `EValueTooLong` (6002) if value exceeds 128 bytes.
`public fun set_metadata(index: &mut Index, polygon_id: ID, value: String, ctx: &TxContext)`

**`get_metadata`**
Get the metadata value and updated epoch for a region. Aborts with `EMetadataNotFound` (6001) if no metadata set.
`public fun get_metadata(index: &Index, polygon_id: ID): (String, u64)`

**`has_metadata`**
Returns true iff metadata has been set for the given region.
`public fun has_metadata(index: &Index, polygon_id: ID): bool`

**`remove_metadata`**
Remove metadata for a region. Caller must be the current owner.
`public fun remove_metadata(index: &mut Index, polygon_id: ID, ctx: &TxContext)`

---

## `mercator::aabb`

Axis-Aligned Bounding Box. Used for broadphase spatial filtering.

| Function | Signature |
|----------|-----------|
| `new` | `public fun new(min_x: u64, min_y: u64, max_x: u64, max_y: u64): AABB` |
| `from_vertices` | `public fun from_vertices(xs: &vector<u64>, ys: &vector<u64>): AABB` |
| `intersects` | `public fun intersects(a: &AABB, b: &AABB): bool` |
| `min_x` / `min_y` / `max_x` / `max_y` | `public fun min_x(aabb: &AABB): u64` (and similarly) |

---

## `mercator::sat`

Separating Axis Theorem narrowphase for convex polygon overlap. Pure edge or corner touching returns `false` — only positive-area overlap counts.

| Function | Signature |
|----------|-----------|
| `overlaps` | `public fun overlaps(xs_a: &vector<u64>, ys_a: &vector<u64>, xs_b: &vector<u64>, ys_b: &vector<u64>): bool` |
| `overlaps_with_aabb` | Same signature — adds AABB pre-filter |
| `sat_intersect_parts` | Same signature — operates on convex part arrays |

---

## `mercator::morton`

Morton (Z-order) codes and quadtree key operations. See [concepts.md — The Spatial Index](./concepts.md#the-spatial-index).

| Function | Signature |
|----------|-----------|
| `interleave` | `public fun interleave(x: u32, y: u32): u64` |
| `interleave_n` | `public fun interleave_n(x: u32, y: u32, bits: u8): u64` |
| `depth_prefix` | `public fun depth_prefix(morton_code: u64, depth: u8): u64` |
| `parent_key` | `public fun parent_key(key: u64): u64` |
| `max_depth` | `public fun max_depth(): u8` — returns 31 |

---

## `mercator::signed`

Signed integer arithmetic for SAT computation. Represents signed values as `(magnitude: u128, negative: bool)`. Rarely called directly from external modules.

| Function | Signature |
|----------|-----------|
| `new` | `public fun new(magnitude: u128, negative: bool): Signed` |
| `from_u64` | `public fun from_u64(value: u64): Signed` |
| `sub_u64` | `public fun sub_u64(a: u64, b: u64): Signed` |
| `mul` / `add` | `public fun mul(a: &Signed, b: &Signed): Signed` |
| `lt` / `le` / `gt` / `ge` / `eq` | `public fun lt(a: &Signed, b: &Signed): bool` |
| `magnitude` | `public fun magnitude(s: &Signed): u128` |
| `is_negative` | `public fun is_negative(s: &Signed): bool` |
| `cross_sign` | `public fun cross_sign(ax: u64, ay: u64, bx: u64, by: u64, cx: u64, cy: u64): Signed` |
