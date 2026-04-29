# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-04-23

Initial public release. Library-first API: open registration on a shared `Index`, owner-gated mutations, `TransferCap` for admin override.

### Added

- `mercator::index` — shared quadtree spatial index with Morton-coded cell addressing and configurable DOS budgets.
- `mercator::polygon` — multi-part convex polygon primitive with area, bounds, intersection, and containment queries.
- `mercator::mutations` — area-conserving operations: `reshape`, `split`, `merge`, `repartition`.
- `mercator::metadata` — attach arbitrary key-value data to registered regions.
- `mercator::sat` — Separating Axis Theorem narrowphase for convex part pairs, with AABB pre-filter.
- `mercator::aabb` — axis-aligned bounding box with intersection and containment tests.
- `mercator::topology` — multi-part polygon validation (connectivity, hole detection, T-junction classification).
- `mercator::morton` — Z-order curve encoding and depth-prefix addressing for quadtree cells.
- `mercator::signed` — signed integer arithmetic on `(u128, bool)` pairs with overflow checks.
- `mercator::registry` — init-only package initializer that creates a shared `Index` and transfers `TransferCap` to the deployer.
- Examples: `spatial_auction`, `territory_game`, `zone_registry`.
- Documentation: `docs/api.md`, `docs/concepts.md`, `docs/design.md`, `docs/guide.md`.
- Test suite: 24 test modules, ~350 test functions, 135 `#[expected_failure]` negative tests, including adversarial security cases and property-based invariant verification (count, area conservation, retrievability, no-teleportation).

### Security

- Broadphase probe budget (`max_probes_per_call`) and per-cell occupancy cap (`max_cell_occupancy`) to bound gas costs per registration.
- Fail-closed degenerate-geometry handling in SAT (`EZeroAxis`) and polygon construction (`ENotConvex`, `EZeroAreaRegion`).
- Overflow-checked 128-bit arithmetic in `signed` and `polygon::area`.

[Unreleased]: https://github.com/fefa4ka/mercator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/fefa4ka/mercator/releases/tag/v0.1.0
