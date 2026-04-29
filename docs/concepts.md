# Mercator Concepts

This document explains the mental model behind Mercator: how coordinates work, how regions are stored and found, and what rules govern their geometry and ownership. Read this before the [guide](./guide.md) or [API reference](./api.md).

---

## What Mercator Is

Mercator is an **on-chain spatial uniqueness library** — a shared index that guarantees non-overlapping polygon regions. It lets you register spatial claims on a shared coordinate plane and enforce that guarantee on-chain. No two registered regions can occupy the same space.

The library is domain-agnostic. You bring the meaning; Mercator enforces the geometry.

> **Standalone usage:** The geometry modules (`polygon`, `sat`, `aabb`, `signed`, `morton`) have no dependency on `Index` or `registry`. You can use them independently for 2D collision detection, area calculation, or spatial hashing without deploying the full index.

---

## Use Cases

Because Mercator only cares about shapes and coordinates, it works for any application that needs exclusive spatial claims:

**Territory games** — players claim hexagonal or polygonal zones on a game map. Mercator prevents two players from owning the same tile. Mutations let territories expand, split, or merge as gameplay evolves.

**Spatial auctions** — auction off coverage zones for wireless networks, advertising displays, or delivery areas. Each winning bid locks a polygon region that no other bidder can overlap.

**Coverage maps** — ISPs, logistics companies, or service providers register their coverage polygons. The index makes it trivial to query which provider covers a given point or viewport.

**Virtual worlds** — regions of virtual space in a metaverse, where each plot is a polygon with an on-chain owner and optional IPFS metadata pointing to its content.

**Event zones** — temporary exclusive zones for events, pop-ups, or permits. Register for a time window, then remove when done.

Any application that needs "one owner per area" can build on Mercator.

---

## Coordinate System

Mercator uses fixed-point integer coordinates (default: Web Mercator scale, but any 2D domain works) with integer arithmetic. There are no floating-point numbers anywhere on-chain. The library works for any 2D fixed-point space — geographic coordinates are the default, but the same index can represent game maps, floor plans, or any other planar domain.

**Scale:** `1 unit = 1 micrometer by default (SCALE = 1,000,000). Fork to change.` One meter is `1,000,000` units (the `SCALE` constant).

**World bounds:** `0` to `40,075,017,000,000` — Earth's circumference at default scale. Fork `MAX_WORLD` for other domains.

Why fixed-point? Floating-point arithmetic is non-deterministic across hardware. Two validators running the same transaction could produce different results. Fixed-point integers give exact, reproducible geometry on every node.

**Practical sizes:**

| Real-world size | Coordinate span |
|----------------|----------------|
| 1 meter | 1,000,000 (at default SCALE) |
| 100 meters | 100,000,000 |
| 1 kilometer | 1,000,000,000 |
| 1 degree of latitude (~111 km) | ~111,000,000,000 |

A 100m × 100m region at position (1000m, 2000m) spans:
- x: `1,000,000,000` to `1,100,000,000`
- y: `2,000,000,000` to `2,100,000,000`

All coordinates are unsigned 64-bit integers. Signed arithmetic needed for SAT collision detection is handled internally by `mercator::signed`.

---

## The Spatial Index

One shared `Index` object exists per deployment. It's the single source of truth for all registered regions.

The index uses a **quadtree** structure. Space is recursively divided into four quadrants, each quadrant into four more, down to `max_depth` levels (default: 20). Each cell at the finest level covers `cell_size` coordinate units per side (default: `1,000,000` = 1 meter at default SCALE).

### Morton Codes

Cells are addressed by **Morton (Z-order) codes** — a way of interleaving the bits of x and y grid coordinates into a single integer. This maps 2D space onto a 1D key that preserves spatial locality: nearby cells have nearby keys.

```
Quadtree cell structure (depth 2 example):

+-------+-------+
|  0,1  |  1,1  |
|  Z=2  |  Z=3  |
+-------+-------+
|  0,0  |  1,0  |
|  Z=0  |  Z=1  |
+-------+-------+

Each cell key = depth_prefix(morton_code, depth)
This makes keys unique across depths.
```

`depth_prefix(morton_code, depth)` prepends a sentinel bit so that a depth-2 key and a depth-3 key for the same spatial location are distinct integers. This lets the index store regions at different depths in the same table without collisions.

### Natural Depth

Each polygon is stored at exactly **one cell** — its "natural depth." This is the shallowest quadtree level where the polygon's bounding box fits entirely within a single cell. A tiny region sits deep in the tree; a large region sits near the root.

This means registration costs O(1) dynamic field writes regardless of polygon size, and the broadphase search only needs to check cells at all depths that intersect the query AABB.

### Broadphase and Narrowphase

Collision detection runs in two stages:

1. **Broadphase** — find candidate regions by checking which quadtree cells overlap the query AABB. Fast, approximate.
2. **Narrowphase** — run SAT (Separating Axis Theorem) against each candidate. Exact, but only on the small set of candidates.

SAT works by projecting both polygons onto each edge normal and checking for a gap. If any axis separates them, they don't overlap. Pure edge or corner touching returns `false` — only positive-area overlap counts.

---

## Polygon Model

A `Polygon` is a **union of convex parts**. Each part is a convex polygon with 3 to 64 vertices. A polygon can have 1 to 10 parts.

Why convex parts? SAT only works on convex shapes. Complex registered regions — L-shapes, U-shapes, regions with notches — are represented as a union of convex pieces.

### Topology Rules

When you register a multi-part spatial claim, the library enforces:

- **No overlap between parts** — parts can't intersect each other
- **Adjacency only via shared edges** — parts touch only along identical edge segments, not at single points
- **Connected union** — the parts form a single connected region
- **Valid boundary cycle** — the outer boundary is a single closed loop
- **Minimum edge length** — every edge must be at least SCALE units (1 meter at default scale)

### Area Calculation

Area is computed using the **Shoelace formula** with `u128` arithmetic to avoid overflow. The result is in base-unit² (square meters at default scale) (since 1 unit = 1 micrometer by default, 1 square meter = 1,000,000 × 1,000,000 = 10^12 square units, and the formula divides by 2 × SCALE²).

The internal `area_fp2` value is the exact twice-area in fixed-point squared units. Mutation checks compare `area_fp2` values directly to avoid any rounding.

---

## Capability Model

Mercator is a library. Fork it and add your own access control on top.

**Registration is open.** Anyone with access to the shared `Index` can call `register()`. No capability is required to add a new region.

**Destructive operations are owner-gated.** The library checks `tx_context::sender()` against the stored region owner before allowing:
- `remove` — delete a region
- `transfer_ownership` — change region owner
- All mutations: `reshape_unclaimed`, `split_replace`, `merge_keep`, `repartition_adjacent`

**`TransferCap`** — the one capability that exists. Required for:
- `force_transfer` — change region owner with no owner check

`TransferCap` is bound to a specific `Index` via `index_id`. A cap minted for one index won't work on another. It's intended for admin override, dispute resolution, or market/escrow modules that need to move ownership without the current owner's signature.

### Init Model

`registry::init()` runs once at deploy time. It creates the shared `Index` and mints a single `TransferCap`, both transferred to the deployer.

```
Deploy → init() runs
           ├── creates shared Index
           └── mints TransferCap → deployer

Anyone can call register() on the shared Index.
Deployer's module holds TransferCap for admin force-transfer.
```

The deployer wraps the `TransferCap` in their own module and adds whatever access control they need around `force_transfer`: multisig, governance, dispute resolution flows, etc.

---

## Mutations and Area Conservation

All geometry mutations preserve total area. This is a general invariant: the library checks it on-chain using exact `area_fp2` comparisons, regardless of what the regions represent.

**Reshape** (`reshape_unclaimed`) — change a region's boundary. The new geometry must fully contain the old geometry (vertex containment + edge-sample checks). Area can grow but never shrink. Useful for correcting geometry errors or expanding a region into adjacent unclaimed space.

**Split** (`split_replace`) — divide one region into 2 to 10 children. Each child must be geometrically contained within the parent. The sum of children's areas must equal the parent's area. The parent is retired (destroyed) and children are registered as new regions.

**Merge** (`merge_keep`) — combine two adjacent same-owner regions into one. The "absorb" region is retired; the "keep" region receives the merged geometry. Total area is conserved.

**Repartition** (`repartition_adjacent`) — redraw the boundary between two adjacent regions. Both regions get new geometry. Total area across both is conserved. Both must still share an edge after repartition.

All mutations check that the caller owns the relevant regions.

---

## DOS Protection

The index has three configurable limits that prevent griefing attacks:

**`max_broadphase_span`** — caps the per-axis cell span of any query AABB. A polygon whose bounding box spans more than this many cells in x or y will be rejected. Default: 1024 cells. This prevents someone from registering a planet-sized polygon that forces every future query to scan thousands of cells.

**`max_cell_occupancy`** — caps how many polygons can share a single quadtree cell. Default: 64. Without this, an attacker could pack hundreds of tiny regions into one cell, making every future registration touching that cell pay O(N) SAT checks.

**`max_probes_per_call`** — caps total broadphase work per transaction as `span_x × span_y × populated_depths`. Default: 2,000,000. This bounds computation cost even when many depth levels are occupied.

These limits are set at index creation time. The `Config` struct lets you adjust `max_broadphase_span`, `max_cell_occupancy`, and `max_probes_per_call` after creation via `set_config` (package-internal). `max_depth` and `cell_size` are immutable after creation because all stored cell keys depend on them.
