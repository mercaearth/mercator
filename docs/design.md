# Mercator: Architecture Reference

This document describes the internals of the Mercator spatial library for developers who want to contribute or build on top of it. It's a reference, not a tutorial.

---

## 1. Module Dependency Graph

The library splits cleanly into two layers. The geometry layer has **zero dependency** on the core layer, so it's usable standalone.

```
┌──────────────────────────────────────────────────────────────┐
│                        Core Layer                            │
│                                                              │
│  registry ──► index ──► polygon, morton, aabb                │
│                │                                             │
│  mutations ────┤──► index, polygon, aabb, morton, metadata   │
│                │                                             │
│  metadata ─────┤──► index, metadata_store, polygon           │
│                │                                             │
│  metadata_store ──► sui::dynamic_field (only)                │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│              Geometry Layer  (no core deps)                  │
│                                                              │
│  polygon ──► sat, aabb, topology, signed                     │
│  sat ──► aabb, signed                                        │
│  topology ──► aabb, sat, signed                              │
│  aabb ──► (no internal deps)                                 │
│  signed ──► (no internal deps)                               │
│  morton ──► (no internal deps)                               │
└──────────────────────────────────────────────────────────────┘
```

**Key consequence:** `polygon`, `sat`, `aabb`, `topology`, `signed`, and `morton` can be imported by any Move package without pulling in the on-chain index or capability model.

---

## 2. Data Structures

### Index

The shared quadtree object. One per deployment.

```
Index {
    id: UID
    cells: Table<u64, vector<ID>>   // depth-prefixed Morton key → polygon IDs
    polygons: Table<ID, Polygon>    // polygon ID → full Polygon object
    cell_size: u64                  // finest-level cell side in coordinate units
    max_depth: u8                   // quadtree levels (default: 20, max: 31)
    count: u64                      // total registered regions
    occupied_depths: u32            // bitmask: bit d set iff depth d has ≥1 region
    config: Config
}
```

`max_depth` is immutable after creation. All Morton keys encode depth relative to it, so changing it would invalidate every stored key.

### Config

```
Config {
    max_vertices: u64           // per-part vertex limit (default: 64)
    max_parts_per_polygon: u64  // parts per polygon (default: 10)
    scaling_factor: u64         // coordinate scale (default: 1_000_000)
    max_broadphase_span: u64    // max AABB width in cells at finest depth
    max_cell_occupancy: u64     // max polygon IDs per cell
    max_probes_per_call: u64    // max total cell lookups per operation
}
```

Invariant enforced at construction: `max_probes_per_call >= max_broadphase_span²`.

### Polygon

```
Polygon {
    id: UID
    parts: vector<Part>         // 1-10 convex sub-polygons
    global_aabb: AABB           // bounding box of all parts combined
    cells: vector<u64>          // always length 1: the cell key where stored
    owner: address
    created_epoch: u64
    total_vertices: u64
    part_count: u64
}
```

### Part

```
Part {
    xs: vector<u64>   // vertex x-coordinates (fixed-point)
    ys: vector<u64>   // vertex y-coordinates (fixed-point)
    aabb: AABB        // per-part bounding box (precomputed)
}
```

Each part must be convex. Vertices are in fixed-point coordinates where `SCALE = 1_000_000` (1 unit = 1 micrometer by default). `MAX_WORLD = 40_075_017_000_000` covers Web Mercator Earth, but the library is domain-agnostic.

### AABB

```
AABB { min_x: u64, min_y: u64, max_x: u64, max_y: u64 }
```

Strict intersection (`intersects`): `min_x < b.max_x && max_x > b.min_x && ...`. Touching edges return `false`. Contact detection (`aabbs_may_contact` in topology) uses `<=`/`>=` to catch shared edges.

### Capabilities

```
TransferCap  { id: UID, index_id: ID }   // gates force_transfer (no owner check)
```

Authorization is a single equality check: `cap.index_id == object::uid_to_inner(&index.id)`.

`register`, `remove`, `transfer_ownership`, and all mutations require no capability. `remove`, `transfer_ownership`, and mutations check `tx_context::sender() == polygon.owner` instead.

---

## 3. Registration Pipeline

What happens inside `index::register()`:

```
Input: parts_xs: vector<vector<u64>>, parts_ys: vector<vector<u64>>
  │
  ├─ 1. Part construction  (polygon::part per part)
  │     ├─ Coordinate bounds: all x,y ≤ MAX_WORLD
  │     ├─ Vertex count: 3 ≤ n ≤ MAX_VERTICES_PER_PART (64)
  │     ├─ Edge length: each edge² ≥ MIN_EDGE_LENGTH_SQUARED (SCALE²)
  │     ├─ Convexity: cross-product sign consistent across all vertices
  │     └─ AABB computed from vertex extrema
  │
  ├─ 2. Polygon assembly  (polygon::new)
  │     ├─ Multipart topology validation (topology::validate_multipart_topology)
  │     │   ├─ Pairwise SAT overlap check (parts must not overlap)
  │     │   ├─ Shared-edge connectivity (vertex-only contact rejected)
  │     │   ├─ Connected component check (all parts in one component)
  │     │   ├─ Boundary cycle validation (every boundary edge degree = 2)
  │     │   └─ Compactness check (4πA/P² ≥ MIN_COMPACTNESS_PPM / 1_000_000)
  │     └─ Area > 0 check (area_fp2 via shoelace formula)
  │
  ├─ 3. Grid placement
  │     ├─ AABB → grid bounds: min_gx = min_x / cell_size, etc.
  │     ├─ Span check: max_gx - min_gx ≤ max_broadphase_span  [DOS-01]
  │     ├─ Natural depth: shallowest d where AABB fits in one cell
  │     └─ Morton key: depth_prefix(interleave_n(cx, cy, depth), depth)
  │
  ├─ 4. Overlap detection
  │     ├─ Broadphase: broadphase_from_aabb → candidate IDs (VecSet dedup)
  │     │   Budget: span_x × span_y × popcount(occupied_depths) ≤ max_probes
  │     └─ Narrowphase: polygon::intersects per candidate → abort EOverlap
  │
  └─ 5. Storage
        ├─ polygon.cells = [cell_key]
        ├─ cells table: push polygon_id into cell vector  [DOS-02 cap check]
        ├─ polygons table: add polygon
        ├─ count += 1
        ├─ occupied_depths |= (1 << depth)
        └─ emit Registered { polygon_id, owner, part_count, cell_count: 1, depth }
```

---

## 4. Quadtree Addressing

### Coordinate system

The world is a 2D grid of `MAX_WORLD / cell_size` cells per axis. With defaults (`MAX_WORLD = 40_075_017_000_000`, `cell_size = 1_000_000`), that's ~40 million cells per side at the finest level.

### Morton codes

`interleave_n(x, y, bits)` interleaves the low `bits` bits of `x` and `y` into a Z-order code:

```
bit 2i   of result = bit i of x
bit 2i+1 of result = bit i of y
```

This maps 2D coordinates to a 1D key that preserves spatial locality.

### Depth-prefixed keys

`depth_prefix(morton_code, depth)` produces a unique key per cell per depth:

```
key = (1 << (2 * depth)) | (morton_code & ((1 << (2 * depth)) - 1))

depth=0  →  key=1          (root, single cell covering entire world)
depth=1  →  keys 4..7      (four quadrants)
depth=2  →  keys 16..31    (sixteen cells)
depth=d  →  keys in [4^d, 4^(d+1))
```

The sentinel bit at position `2*depth` makes keys from different depths non-overlapping, so a single `Table<u64, vector<ID>>` stores all depths without collision.

### Natural depth

The shallowest depth where a polygon's AABB fits entirely within one cell:

```
natural_depth(min_gx, min_gy, max_gx, max_gy, max_depth):
  depth = max_depth
  while depth > 0:
    shift = max_depth - depth
    if (min_gx >> shift) == (max_gx >> shift)
    && (min_gy >> shift) == (max_gy >> shift):
      return depth
    depth -= 1
  return 0
```

Larger regions get shallower depths. Smaller regions get deeper depths. Every polygon is stored at exactly one cell.

### Quadtree cell hierarchy

```
depth 0:  [         entire world         ]
           /         |         \         \
depth 1:  [NW]      [NE]      [SW]      [SE]
           /|\        ...
depth 2:  [NW.NW] [NW.NE] [NW.SW] [NW.SE]  ...
           ...
depth 20: individual cells (1m × 1m with defaults)
```

A polygon stored at depth 3 is found by broadphase queries at any depth that covers its AABB, because the broadphase iterates all occupied depths and right-shifts grid coordinates to match each depth's resolution.

### `occupied_depths` bitmask

Bit `d` is set iff at least one polygon is stored at depth `d`. The broadphase skips depths where the bit is clear, reducing work from `O(max_depth)` to `O(popcount(occupied_depths))` per axis per query.

---

## 5. Collision Detection Pipeline

### Broadphase (`broadphase_from_aabb`)

```
for each depth d from 0 to max_depth:
    if occupied_depths & (1 << d) == 0: continue   // skip empty depths

    shift = max_depth - d
    cmin_x = min_gx >> shift
    cmax_x = max_gx >> shift
    cmin_y = min_gy >> shift
    cmax_y = max_gy >> shift

    for cy in cmin_y..=cmax_y:
        for cx in cmin_x..=cmax_x:
            key = depth_prefix(interleave_n(cx, cy, d), d)
            if cells[key] exists:
                add all IDs to result (VecSet dedup)

return result as vector<ID>
```

Budget check before the loop:
```
span_x * span_y * popcount(occupied_depths) ≤ max_probes_per_call
```

If the budget is exceeded, the call aborts with `EBroadphaseBudgetExceeded`. An empty index skips the check entirely.

### Narrowphase (`polygon::intersects`)

For each candidate from broadphase:

1. **Global AABB pre-filter**: if `global_aabb` of A and B don't overlap (strict), return false immediately.
2. **Per-part AABB filter**: for each part pair (A_i, B_j), skip if their AABBs don't overlap.
3. **SAT check** (`sat::overlaps`): project both parts onto each edge normal of A, then each edge normal of B. If any axis separates the projections, return false. If no separating axis found, return true.

SAT projection uses `signed` arithmetic throughout. The `projections_overlap` check is strict (`gt`, not `ge`), so touching edges and corners return false.

```
projections_overlap(min_a, max_a, min_b, max_b):
    max_a > min_b  &&  max_b > min_a
```

---

## 6. Mutation Invariants

All mutations check that the caller is the region owner. The owner check is the first thing each function does.

### Reshape (`reshape_unclaimed`)

Replaces a polygon's geometry with a larger shape.

- Caller must be the current owner.
- New AABB must contain old AABB (AABB containment check first, then full `contains_polygon_by_parts`).
- `contains_polygon_by_parts` checks every vertex of the old polygon lies inside the new geometry. For multi-part outers, it also samples two asymmetric points per edge (t=1/3, t=2/3) to catch edges that bridge concave gaps.
- New area must be ≥ old area (`area_fp2` comparison, exact fixed-point). Shrinking aborts `EAreaShrunk`.
- Broadphase + narrowphase overlap check against all neighbors (excluding self).
- Old cell unregistered, new cell computed and registered.

### Split (`split_replace`)

Replaces one polygon with N children (2 ≤ N ≤ 10).

- Caller must be the current owner.
- `area_fp2` sum of all children must equal parent's `area_fp2` exactly. Uses `checked_area_sum` (u128 checked add) to prevent overflow masking conservation violations.
- Every child must be geometrically contained within the parent (`contains_polygon`).
- Children must not overlap each other (pairwise SAT, O(N²), capped at 45 pairs for N=10).
- Each child checked against external neighbors via broadphase + narrowphase.
- Parent is destroyed (metadata cleaned up via `force_remove_metadata`). Children get new IDs.
- Children inherit parent's owner.

### Merge (`merge_keep`)

Combines two adjacent same-owner polygons into one.

- Both must have the same owner, and caller must be that owner.
- Adjacency required: `touches_by_edge` must return true (shared edge, not just vertex contact).
- `area_fp2` of merged result must equal sum of both inputs exactly.
- Merged geometry checked against external neighbors.
- `absorb_id` is destroyed (metadata cleaned up). `keep_id` gets the new geometry.

### Repartition (`repartition_adjacent`)

Redistributes area between two adjacent same-owner polygons.

- Both must have the same owner, and caller must be that owner.
- Pre-condition: inputs must share an edge (`touches_by_edge`).
- Total `area_fp2` conserved exactly.
- Outputs must not overlap each other.
- Both output AABBs must lie within the union AABB of the original pair (prevents teleportation).
- Post-condition: outputs must still share an edge (`touches_by_edge_by_parts`).
- Both outputs checked against external neighbors.

---

## 7. DOS Protection Model

Three independent budgets bound gas cost regardless of index state.

### `max_broadphase_span`

Maximum AABB width in cells at the finest depth, checked per axis:

```
max_gx - min_gx ≤ max_broadphase_span
max_gy - min_gy ≤ max_broadphase_span
```

Rejects regions whose bounding box spans too many cells. Prevents O(span²) broadphase on giant bounding boxes. Constraint: `max_broadphase_span ≤ 2^max_depth`.

### `max_cell_occupancy`

Maximum polygon IDs stored in any single cell:

```
len(cells[key]) < max_cell_occupancy  before push
```

Prevents cell-stuffing attacks where many tiny polygons accumulate in one cell, forcing every subsequent registration touching that cell to pay O(occupancy) SAT checks. Checked in `register_in_cell`.

### `max_probes_per_call`

Maximum total cell lookups per broadphase call:

```
span_x × span_y × popcount(occupied_depths) ≤ max_probes_per_call
```

The `popcount` factor reflects that the per-depth span shrinks monotonically as depth decreases (right-shift halves extent). The bitmask skip means empty depths cost nothing.

Invariant at config creation: `max_probes_per_call ≥ max_broadphase_span²`. This guarantees that any valid region (one that passes the span check) can always complete its broadphase at depth 0 without hitting the probe budget.

**Together:** span limits region size, occupancy limits per-cell density, probes limits total work. Gas cost is bounded to `O(max_probes_per_call × max_cell_occupancy)` per registration, independent of how many polygons are in the index.

---

## 8. Capability and Init Model

`registry::init()` runs exactly once at package deploy:

```
init(ctx):
    index = index::new(ctx)          // default config
    transfer_cap = mint_transfer_cap(&index, ctx)
    share_existing(index)            // index becomes shared object
    transfer(transfer_cap, sender)
```

No `AdminCap`. No governance. No sealing mechanism. The deployer receives the `TransferCap` and decides what to do with it.

**Registration is open**: `register` requires no capability. Anyone with access to the shared `Index` can register a region.

**Owner checks protect destructive ops**: `remove`, `transfer_ownership`, and all mutations (`reshape_unclaimed`, `split_replace`, `merge_keep`, `repartition_adjacent`) verify `tx_context::sender() == polygon.owner` before proceeding.

**`TransferCap`** gates: `force_transfer` only. No owner check, so it's intended for market/escrow modules that need to move ownership without the current owner's signature.

---

## 9. Metadata System

Per-region string metadata stored as Sui dynamic fields on the Index's UID.

```
MetadataKey { polygon_id: ID }  →  MetadataState { value: String, updated_epoch: u64 }
```

**Storage**: `metadata_store` wraps `sui::dynamic_field` directly. `upsert_metadata` removes the old field before adding the new one (dynamic fields don't support in-place update).

**Access control**: `set_metadata` and `remove_metadata` check `polygon::owner == tx_context::sender`. No cap required for reads.

**Cleanup**: `force_remove_metadata` is called by `index::remove_unchecked`, `mutations::split_replace`, and `mutations::merge_keep` before destroying a polygon. This prevents orphaned dynamic fields that would be unremovable after the polygon ID is gone.

**Limits**: `MAX_VALUE_LENGTH = 128` bytes. Enforced in `set_metadata` before the dynamic field write.

---

## 10. Design Decisions and Tradeoffs

**Single cell per polygon.** Each polygon is stored at exactly one quadtree cell (its natural depth). This keeps registration O(1) in storage writes and makes removal trivial. The tradeoff is that broadphase must check all occupied depths to find both large polygons (shallow) and small polygons (deep) that might overlap a query AABB.

**`occupied_depths` bitmask.** Without it, broadphase would iterate all 20 depth levels even if only 3 are populated. The bitmask reduces that to `O(popcount)` depth iterations. It's updated on every register and unregister. The `popcount_u32` implementation uses Kernighan's bit-clearing trick, running in O(popcount) not O(32).

**Exact area conservation.** Mutations use `area_fp2` (twice-area in fixed-point² units, u128) for all conservation checks. `area()` (the public display function) truncates to u64 and is explicitly documented as lossy. Using the exact value means no rounding tolerance accumulates across many split/merge/repartition operations.

**Topology validation on construction.** Multipart polygons are validated once when `polygon::new` is called. The checks (pairwise overlap, shared-edge connectivity, boundary cycle, compactness) are expensive but run only once. After construction, the polygon is correct by invariant and no re-validation is needed on reads.

**Immutable `max_depth`.** Set at Index creation, never changed. All Morton keys encode depth relative to `max_depth` via the shift `max_depth - depth`. Changing `max_depth` would make every stored key point to the wrong cell. It lives on `Index` directly, not in `Config`, to make this immutability explicit.

**No floating-point.** All geometry uses integer fixed-point arithmetic. `signed` emulates signed integers as `(magnitude: u128, negative: bool)`. This is deterministic across all validators with no platform-dependent rounding. `SCALE = 1_000_000` gives micrometer precision at Earth scale; for other domains, fork and adjust.

**Compactness check.** The topology validator rejects pathologically thin polygons using an L1-perimeter approximation of the isoperimetric ratio: `8_000_000 * twice_area ≥ MIN_COMPACTNESS_PPM * perimeter²`. `MIN_COMPACTNESS_PPM = 150_000` (15% of a circle's ratio). This prevents needle-shaped polygons that pass convexity but would cause numerical issues in SAT projections.

**`area_fp2` vs `area`.** The shoelace formula computes twice-area directly in fixed-point² units. Dividing by `AREA_DIVISOR = 2 * SCALE²` gives whole square meters. The factor of 2 comes from the shoelace formula itself; the `SCALE²` converts from coordinate-unit² to meter². Conservation checks always use `area_fp2` to avoid the lossy division.
