# Mercator

[![CI](https://github.com/mercaearth/mercator/actions/workflows/ci.yml/badge.svg)](https://github.com/mercaearth/mercator/actions/workflows/ci.yml)

On-chain spatial uniqueness primitive for Sui. SAT collision detection + quadtree indexing + Morton encoding, all in Move.

Register non-overlapping polygon regions in a shared spatial index. Build whatever you want on top.

---

## What It Does

- **Shared spatial index** backed by a quadtree with Z-order curve addressing
- **Register polygon regions of any shape** (decomposed into convex parts) with guaranteed non-overlap via SAT narrowphase
- **Area-conserving mutations** — reshape, split, merge, repartition
- **Open registration, owner-gated mutations** — anyone can register; remove/transfer/mutations check ownership; TransferCap for admin force-transfer
- **DOS protection** — configurable broadphase budgets and cell occupancy limits per deployment

---

## Why This Exists

Most chains have no on-chain collision detection. Mercator gives you exact spatial uniqueness as a reusable primitive.

**SAT narrowphase in Move** — exact polygon overlap detection via pairwise convex-part checks. Register any shape — L, U, irregular — as long as it's decomposed into convex pieces. Most chains can't do this at all.

**Quadtree + Morton addressing** — reusable beyond geography. Works for 2D game boards, tile maps, any hierarchical spatial partition.

**Area-conserving mutations** — an elegant invariant enforced on-chain. Useful anywhere you need resource conservation: spectrum, zoning, fractional ownership.

**Signed integer arithmetic** — Move has no native signed integers. The `mercator::signed` module is a standalone useful primitive for any on-chain geometry.

**DOS-budget design** — configurable computation limits per transaction. Production-grade gas protection for shared-object operations.

---

## Use Cases

| Use Case | What You'd Build |
|----------|-----------------|
| Property registry | Non-overlapping ownership claims with transfer |
| Game world | Territory control, base placement, fog of war |
| Spectrum allocation | Frequency band registration with overlap prevention |
| Zoning / planning | Administrative boundary management |
| Ad placement | Non-overlapping visual regions on a shared canvas |
| Coverage maps | Service areas, franchise zones, cellular towers |

[merca.earth](https://merca.earth) is built on Mercator — a spatial property registry on Sui mainnet.

### When NOT to Use Mercator

| Scenario | Why not | What to use instead |
|----------|---------|-------------------|
| Spherical / geodesic math | Mercator operates on a flat 2D plane. No Haversine, no great-circle distance. | Project to Web Mercator off-chain first, use Mercator for the on-chain index. |
| Real-time 60fps physics | On-chain SAT costs gas per check. Fine for registration-time validation, not for frame-by-frame simulation. | Run physics off-chain, commit results on-chain. |
| Curved geometry | Only straight-edge polygons (decomposed into convex parts). No arcs, splines, or circles. | Approximate curves as polylines before registering. |
| Legally binding land title | Software doesn't create sovereign recognition. Mercator enforces spatial uniqueness, not legal ownership. | Use Mercator as the technical layer under a jurisdiction-specific legal wrapper. |
| 3D volumes | 2D only. No height, no z-axis. | Flatten to 2D footprints or use a different primitive. |

---

## Quick Start

### Add as a dependency

```toml
[dependencies]
mercator = { git = "https://github.com/mercaearth/mercator.git", subdir = ".", rev = "main" }
```

### Register a region

```move
use mercator::index::{Self, Index};

// Register a rectangular region (100m × 100m at position 1000,2000)
public fun claim_region(
    index: &mut Index,
    ctx: &mut TxContext,
): ID {
    index::register(
        index,
        vector[vector[1_000_000_000, 1_100_000_000, 1_100_000_000, 1_000_000_000]],
        vector[vector[2_000_000_000, 2_000_000_000, 2_100_000_000, 2_100_000_000]],
        ctx,
    )
}
```

Coordinates use fixed-point integers where **1,000,000 units = 1 meter (default SCALE; fork to change)**. See [Coordinate System](#coordinate-system) below.

---

## Companion Library: exact-poly

Mercator requires polygons pre-decomposed into convex parts. Arbitrary simple polygons (L-shapes, U-shapes, concave geometry) must be split off-chain before submission.

[**exact-poly**](https://github.com/mercaearth/exact-poly) — companion Rust/WASM library — handles this:

- Integer-only arithmetic with the same `SCALE = 1_000_000` as Mercator — results are bit-exact and match on-chain validation.
- Convex decomposition via cascade strategy (ExactPartition → Bayazit → EarClip + Hertel-Mehlhorn).
- Ring operations (CCW/CW, simplicity, collinear removal), point-in-polygon, SAT, topology validation.
- Ships as an npm package for browsers and Node, plus a Rust `rlib` for native use.

**Typical flow:**

```
user draws polygon in UI
        ↓
exact-poly (WASM in browser) → convex parts
        ↓
Mercator::register (Move on Sui) → on-chain validation + storage
```

Because both libraries use identical integer arithmetic, a polygon accepted off-chain is guaranteed to validate on-chain — no floating-point drift, no cross-platform divergence.

---

## Module Map

| Module | What |
|--------|------|
| `mercator::registry` | Package init — creates Index + TransferCap on deploy |
| `mercator::index` | Shared spatial index — register/remove/query/transfer |
| `mercator::polygon` | Arbitrary polygon as union of convex parts, area, intersection |
| `mercator::mutations` | Area-conserving geometry operations |
| `mercator::metadata` | Attach arbitrary key-value data to registered regions |
| `mercator::aabb` | Axis-aligned bounding box (broadphase filter) |
| `mercator::sat` | Separating Axis Theorem collision detection |
| `mercator::topology` | Multi-part polygon validation |
| `mercator::morton` | Z-order curve encoding for quadtree cells |
| `mercator::signed` | Signed integer arithmetic for cross-product math |

---

## Standalone Geometry Primitives

The geometry modules have **zero dependency on the spatial index**. You can use them independently for any 2D math:

```move
use mercator::sat;
use mercator::aabb;
use mercator::polygon;
use mercator::signed;
use mercator::morton;
```

No `Index`, no `registry::init`, no capabilities needed. Just add `mercator` as a dependency and use the modules directly.

**Examples:**
- SAT collision detection between two convex shapes
- AABB intersection checks for broadphase filtering
- Morton code encoding for any quadtree/spatial hashing
- Signed integer arithmetic for cross-product geometry
- Polygon area calculation via Shoelace formula

```move
// Standalone SAT check — no Index needed
let overlaps = sat::overlaps(
    &xs_a, &ys_a,  // convex shape A vertices
    &xs_b, &ys_b,  // convex shape B vertices
);

// Standalone AABB check
let box_a = aabb::new(0, 0, 100, 100);
let box_b = aabb::new(50, 50, 150, 150);
let hit = aabb::intersects(&box_a, &box_b);

// Morton code for spatial hashing
let code = morton::interleave(x, y);
let cell_key = morton::depth_prefix(code, depth);
```

The full `Index` adds spatial uniqueness enforcement (non-overlap guarantee) and persistent on-chain storage. The geometry modules are pure math.

---

## Coordinate System

Mercator uses fixed-point arithmetic throughout:

- **Scale**: 1,000,000 units = 1 meter at default SCALE (micrometer precision by default)
- **World bounds**: `0` to `40,075,017,000,000` (Earth's circumference at default scale. Fork MAX_WORLD for other domains.)
- **Minimum edge**: SCALE units (1 meter at default scale)
- All coordinates are unsigned 64-bit integers. Signed arithmetic for SAT is handled internally by `mercator::signed`.

### Polygon Constraints

| Constraint | Value |
|-----------|-------|
| Parts per polygon | 1 to 10 |
| Vertices per part | 3 to 64 |
| Minimum edge length | SCALE units (1 meter at default scale) |
| Shape requirement | Each part must be convex |

Multi-part polygons let you represent non-contiguous regions as a single on-chain object.

---

## How Registration Works

A single shared `Index` object exists per deployment. On registration:

1. The polygon's AABB is computed for broadphase filtering.
2. Candidate regions in overlapping quadtree cells are fetched.
3. SAT narrowphase runs against each candidate.
4. If no overlap is found, the region is stored and its ID returned.

Broadphase budget limits (max cells checked, max candidates per cell) are set at deploy time.

### Authorization

Registration is open. Anyone with access to the shared `Index` can call `register()` — no capability required.

Destructive operations are owner-gated:

- **`remove`** — caller must be the region owner
- **`transfer_ownership`** — caller must be the current owner
- **All mutations** (`reshape`, `split`, `merge`, `repartition`) — caller must own the relevant regions

One capability object exists:

- **TransferCap** — required for `force_transfer`, which moves ownership with no owner check. Intended for admin override, dispute resolution, or market/escrow modules.

Fork `mercator::registry` to customize how the `TransferCap` is held and distributed.

### Geometry Mutations

All mutations preserve total area. The library enforces this invariant on-chain:

- **Reshape** — change a region's boundary while keeping area constant
- **Split** — divide one region into two; combined area equals original
- **Merge** — combine two adjacent regions into one
- **Repartition** — redistribute area across multiple regions simultaneously

### Choosing DOS Budget Values

The default `registry.move` calls `index::new()` which uses budgets tuned for Earth-scale geography with micrometer precision. If you fork `registry.move` and call `index::with_config(...)`, choose values appropriate to your domain:

| Parameter | What it limits | Default | Game board (1000×1000) | Notes |
|-----------|---------------|---------|----------------------|-------|
| `cell_size` | Finest quadtree cell side | 1,000,000 | 1 | 1 unit = 1 tile |
| `max_depth` | Quadtree levels | 20 | 10 | 2^10 = 1024 cells per side |
| `max_broadphase_span` | Max AABB width in cells | 1024 | 32 | Reject giant regions |
| `max_cell_occupancy` | Max regions per cell | 64 | 16 | Lower = cheaper registration |
| `max_probes_per_call` | Max cell checks per tx | 2,000,000 | 1,024 | Must be ≥ span² |

**Constraint:** `max_probes_per_call >= max_broadphase_span²`. This ensures the broadphase can always complete.

**Rule of thumb:** for an N×N grid, set `max_depth ≈ log₂(N)`, `cell_size = 1`, and scale the budgets down proportionally. The defaults are deliberately generous for a 40-trillion-unit world — a 1000-tile game board needs ~1000× smaller budgets.

---

## Gas Benchmarks (Sui Testnet)

Raw gas costs measured on Sui testnet (protocol v121). Median of 3 runs unless noted. 1 SUI = 10⁹ MIST ≈ $4 at time of writing.

### Registration — vertex scaling

| Vertices | Compute | Storage | Net (MIST) | ≈ SUI | Runs |
|----------|---------|---------|------------|-------|------|
| 4 | 1,000,000 | 9,401,200 | **7,045,496** | 0.007 | 3 |
| 8 | 1,000,000 | 9,887,600 | **7,531,896** | 0.008 | 3 |
| 16 | 1,000,000 | 10,860,400 | **8,504,696** | 0.009 | 3 |
| 32 | 1,670,000 | 12,806,000 | **11,120,296** | 0.011 | 3 |
| 64 | 7,140,000 | 16,697,200 | **20,481,496** | 0.020 | 3 |

Two cost drivers scale independently:

- **Compute (SAT):** Sub-floor (< 1M) up to 16 vertices. Breaks through at 32v (1.67M) and dominates at 64v (7.14M). SAT is O(n²) in edge count — each candidate check tests every edge pair.
- **Storage (object size):** Grows linearly with vertex count. +486K per 4 additional vertices (vertex data stored on-chain).

### Registration — cost vs index size

| Region # | Compute | Storage | Net (MIST) | ≈ SUI |
|----------|---------|---------|------------|-------|
| #1 | 1,000,000 | 9,401,200 | 7,045,496 | 0.007 |
| #5 | 1,000,000 | 9,401,200 | 7,045,496 | 0.007 |
| #10 | 1,000,000 | 9,401,200 | 7,045,496 | 0.007 |
| #15 | 1,000,000 | 9,401,200 | 7,045,496 | 0.007 |
| #20 | 1,000,000 | 9,401,200 | 7,045,496 | 0.007 |

Identical cost from region #1 through #20 when regions are spatially distributed (each lands in a different quadtree cell). The `occupied_depths` bitmask skips empty depth layers, keeping broadphase cost proportional to populated depths, not total region count.

**Caveat:** this holds for distributed regions. When regions cluster in the same cell (approaching `max_cell_occupancy`), each registration pays O(occupancy) SAT checks. That worst case is bounded by DOS budget parameters — see [Choosing DOS Budget Values](#choosing-dos-budget-values).

### Other operations

| Operation | Compute | Storage | Net (MIST) | ≈ SUI | Notes |
|-----------|---------|---------|------------|-------|-------|
| `remove` | 1,000,000 | 3,389,600 | **−4,917,588** | −0.005 | Storage rebate > cost — you get MIST back |
| `transfer_ownership` | 1,000,000 | 3,389,600 | **1,033,896** | 0.001 | In-place owner field update |
| `count` (read) | 1,000,000 | 988,000 | **1,009,880** | 0.001 | Near-minimum gas |

### Not yet benchmarked

Mutations (reshape, split, merge, repartition), multi-part registration, overlap abort gas cost, force_transfer, dense-cell worst case (max_cell_occupancy bound). Contributions welcome.

### Reproduce

```bash
cd bench && npm install
# Set SUI_PRIVATE_KEY, PACKAGE_ID, INDEX_ID, TRANSFER_CAP_ID in .env
npm run bench
```

---

## Build & Test

```bash
sui move build
sui move test -i 10000000000
```

Tests live in `sources/tests.move` and `sources/poc_tests.move`. Geometry-heavy tests require the increased instruction limit.

---

## Examples

See `examples/` for a minimal index deployment built on top of Mercator. It covers:

- Deploying the index
- Registering regions from user input
- Querying neighbors
- Attaching metadata

---

## License

Apache-2.0. See LICENSE.
