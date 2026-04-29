# Developer Guide

Step-by-step workflows for building on Mercator. For background on coordinates, the quadtree, and the capability model, see [concepts.md](./concepts.md). For the full function reference, see [api.md](./api.md).

---

## Setup: Deploying Mercator

Publishing the package runs `registry::init()` automatically. It creates a shared `Index` and mints a `TransferCap` — both transferred to the deployer.

```move
// What init() does under the hood:
let index = index::new(ctx);                                    // shared Index, default config
let transfer_cap  = index::mint_transfer_cap(&index, ctx);      // → deployer
index::share_existing(index);
```

The deployer transfers the `TransferCap` into their own module or multisig and exposes controlled entry points for `force_transfer`. Default config: `cell_size` = 1m, `max_depth` = 20, `max_broadphase_span` = 1024, `max_cell_occupancy` = 64, `max_probes_per_call` = 2,000,000.

---

## Workflow 1: Registering a Region

`index::register` takes vertex arrays for each convex part and returns the new region's `ID`. Coordinates are in fixed-point units where `1,000,000 = 1 meter at default SCALE`. No capability is required — registration is open.

### Simple rectangle (single part)

```move
use mercator::index::{Self, Index};

// Register a 100m × 100m square at position (1000m, 2000m)
public fun register_square(
    index: &mut Index,
    ctx: &mut TxContext,
): ID {
    // Vertices listed counter-clockwise (or clockwise — both work)
    let xs = vector[
        1_000_000_000,  // 1000m
        1_100_000_000,  // 1100m
        1_100_000_000,  // 1100m
        1_000_000_000,  // 1000m
    ];
    let ys = vector[
        2_000_000_000,  // 2000m
        2_000_000_000,  // 2000m
        2_100_000_000,  // 2100m
        2_100_000_000,  // 2100m
    ];
    // parts_xs and parts_ys are vectors of vertex arrays, one per part
    index::register(index, vector[xs], vector[ys], ctx)
}
```

### Triangle (single part, 3 vertices)

```move
public fun register_triangle(
    index: &mut Index,
    ctx: &mut TxContext,
): ID {
    let xs = vector[0, 1_000_000_000, 500_000_000]; // 0m, 1000m, 500m
    let ys = vector[0, 0, 866_000_000];             // 0m, 0m, 866m (equilateral)
    index::register(index, vector[xs], vector[ys], ctx)
}
```

### L-shaped region (two convex parts)

An L-shape isn't convex, so decompose it into two rectangles that share an edge:

```
+-------+
|   A   |
+---+---+
| B |
+---+
```

```move
// Part A: top rectangle (100m wide, 50m tall, at y=50m)
let xs_a = vector[0, 100_000_000, 100_000_000, 0];
let ys_a = vector[50_000_000, 50_000_000, 100_000_000, 100_000_000];
// Part B: bottom-left (50m × 50m). Shares edge (0,50m)→(50m,50m) with A.
let xs_b = vector[0, 50_000_000, 50_000_000, 0];
let ys_b = vector[0, 0, 50_000_000, 50_000_000];

index::register(index, vector[xs_a, xs_b], vector[ys_a, ys_b], ctx)
```

Parts must share edges (not just corners). Overlapping parts or point-only contact aborts registration.

---

## Workflow 2: Querying Regions

```move
use mercator::index;
use mercator::polygon;

// Load all regions visible in a map viewport (broadphase, no SAT)
let ids = index::query_viewport(index, min_x, min_y, max_x, max_y);

// Exact overlap check between two registered regions
let overlapping = index::overlaps(index, id_a, id_b);

// All regions that geometrically overlap a given region (broadphase + SAT)
let neighbors = index::overlapping(index, query_id);

// Read region fields
let p = index::get(index, id);
let owner = polygon::owner(p);
let area  = polygon::area(p);   // base-unit² (square meters at default SCALE)
let parts = polygon::parts(p);  // number of convex parts
```

`query_viewport` and `candidates` are broadphase only. Some returned IDs may not visually intersect the query if their AABB does but their actual geometry doesn't. Use `overlapping` when you need exact results.

---

## Workflow 3: Transferring Ownership

```move
// Owner-initiated: caller must be the current owner
index::transfer_ownership(index, region_id, new_owner, ctx);

// Force-transfer: TransferCap holder, no owner check (dispute resolution)
index::force_transfer(transfer_cap, index, region_id, new_owner);
```

`transfer_ownership` aborts if `ctx.sender()` is not the current owner. `force_transfer` takes no `TxContext` — there's no owner check at all.

---

## Workflow 4: Geometry Mutations

All mutations check that the caller owns the relevant regions. No capability is required.

### Reshape: expand a region's boundary

New geometry must fully contain the old geometry. Area can grow but never shrink.

```move
use mercator::mutations;
mutations::reshape_unclaimed(index, region_id, new_parts_xs, new_parts_ys, ctx);
```

### Split: divide one region into children

The parent is retired. Children inherit the parent's owner. Area sum must equal parent area.

```move
public fun subdivide(
    index: &mut Index,
    parent_id: ID,
    ctx: &mut TxContext,
): vector<ID> {
    // Two children that together cover the parent exactly
    // Child A: left half of a 200m × 100m parent
    let child_a_xs = vector[vector[0, 100_000_000, 100_000_000, 0]];
    let child_a_ys = vector[vector[0, 0, 100_000_000, 100_000_000]];
    // Child B: right half
    let child_b_xs = vector[vector[100_000_000, 200_000_000, 200_000_000, 100_000_000]];
    let child_b_ys = vector[vector[0, 0, 100_000_000, 100_000_000]];

    mutations::split_replace(
        index, parent_id,
        vector[child_a_xs, child_b_xs],
        vector[child_a_ys, child_b_ys],
        ctx,
    )
    // Returns vector of new child IDs
}
```

### Merge: combine two adjacent regions

The "absorb" region is retired. The "keep" region gets the merged geometry. Both must be adjacent (share an edge) and owned by the caller.

```move
mutations::merge_keep(index, keep_id, absorb_id, merged_parts_xs, merged_parts_ys, ctx);
```

### Repartition: redraw the boundary between two regions

Both regions get new geometry. Total area is conserved. Both must still share an edge after repartition.

```move
mutations::repartition_adjacent(
    index,
    a_id, a_new_xs, a_new_ys,
    b_id, b_new_xs, b_new_ys,
    ctx,
);
```

---

## Workflow 5: Metadata

Attach string metadata to a region. The caller must be the region owner. Calling again overwrites the previous value. Values are capped at 128 bytes.

```move
use mercator::metadata;
use std::string;

// Set or update
metadata::set_metadata(index, region_id, string::utf8(metadata_value), ctx);

// Read back: returns (value, epoch_when_set)
let (value, epoch) = metadata::get_metadata(index, region_id);

// Check existence
let exists = metadata::has_metadata(index, region_id);

// Remove
metadata::remove_metadata(index, region_id, ctx);
```

---

## Using Geometry Primitives Standalone

You don't need the full spatial index to use Mercator's geometry. The `sat`, `aabb`, `polygon`, `signed`, and `morton` modules work independently.

### SAT Collision Check

```move
use mercator::sat;

// Check if two convex shapes overlap
let collides = sat::overlaps(
    &vector[0, 100, 100, 0],       // shape A x-coords
    &vector[0, 0, 100, 100],       // shape A y-coords
    &vector[50, 150, 150, 50],     // shape B x-coords
    &vector[50, 50, 150, 150],     // shape B y-coords
);
// collides == true (shapes overlap)
```

### AABB Broadphase Filter

```move
use mercator::aabb;

let box_a = aabb::from_vertices(
    &vector[0, 100, 100, 0],
    &vector[0, 0, 100, 100],
);
let box_b = aabb::from_vertices(
    &vector[200, 300, 300, 200],
    &vector[200, 200, 300, 300],
);
let might_collide = aabb::intersects(&box_a, &box_b);
// might_collide == false — skip expensive SAT check
```

### Morton Codes for Spatial Hashing

```move
use mercator::morton;

let code = morton::interleave(42, 17);          // Z-order interleave
let cell = morton::depth_prefix(code, 10);      // quadtree cell key at depth 10
let parent = morton::parent_key(cell);           // one level up
```

These are pure functions — no shared objects, no capabilities, no transaction context needed.

---

## Building Your Own Module on Top

Mercator is a low-level library. You're expected to wrap it with your own access control, business logic, and user-facing entry points.

### Example 1: Geographic spatial claims

A minimal module that wraps Mercator with rectangular zone registration for geographic use cases (coverage areas, service zones, etc.):

```move
module my_app::spatial_claims;

use mercator::index::{Self, Index};
use sui::object::ID;
use sui::tx_context::TxContext;

/// Register a rectangular spatial claim given bottom-left corner and dimensions.
/// Coordinates in fixed-point units (SCALE = 1,000,000; 1 meter at default scale).
public fun register_zone(
    index: &mut Index,
    x: u64,
    y: u64,
    width: u64,
    height: u64,
    ctx: &mut TxContext,
): ID {
    let xs = vector[x, x + width, x + width, x];
    let ys = vector[y, y, y + height, y + height];
    index::register(index, vector[xs], vector[ys], ctx)
}
```

### Example 2: Territory game

A game where players claim hexagonal territories on a map. Mercator enforces that no two players can hold the same tile. The game module adds a coin payment gate:

```move
module game::territory;

use mercator::index::{Self, Index};
use sui::coin::Coin;
use sui::sui::SUI;
use sui::object::ID;
use sui::tx_context::TxContext;

const CLAIM_FEE: u64 = 1_000_000_000; // 1 SUI

/// Claim a territory tile. Requires payment and a valid polygon (decomposed into convex parts).
/// Mercator aborts if the tile overlaps any existing territory.
public fun claim_territory(
    index: &mut Index,
    payment: Coin<SUI>,
    tile_xs: vector<u64>,
    tile_ys: vector<u64>,
    ctx: &mut TxContext,
): ID {
    assert!(sui::coin::value(&payment) >= CLAIM_FEE, 0);
    // Transfer fee to game treasury (omitted for brevity)
    sui::transfer::public_transfer(payment, @treasury);
    // Register the tile — aborts with EOverlap if already claimed
    index::register(index, vector[tile_xs], vector[tile_ys], ctx)
}
```

Registration is open — anyone can call `register()` directly. Your wrapper module is where you add payment gates, allowlists, pause mechanisms, or governance checks.

A more complete module might:

- Gate `register` behind payment or governance vote
- Maintain an allowlist of addresses that can register
- Emit its own events with application-specific metadata
- Wrap `force_transfer` behind a dispute resolution flow

The library enforces geometry correctness and overlap prevention. Everything else is your call.

### Listening to Events

Every state change emits a Sui event. Subscribe to these off-chain to keep your indexer in sync:

| Event | Trigger |
|-------|---------|
| `mercator::index::Registered` | New region registered |
| `mercator::index::Removed` | Region deleted |
| `mercator::index::Transferred` | Ownership changed |
| `mercator::mutations::RegionReshaped` | Region boundary changed |
| `mercator::mutations::RegionSplit` | Parent region split into children |
| `mercator::mutations::RegionsMerged` | Two regions merged |
| `mercator::mutations::RegionsRepartitioned` | Boundary redrawn between two regions |
| `mercator::mutations::RegionRetired` | Region destroyed (split parent or merge absorb) |
| `mercator::metadata::MetadataSet` | string metadata attached or updated |
| `mercator::metadata::MetadataRemoved` | string metadata removed |
