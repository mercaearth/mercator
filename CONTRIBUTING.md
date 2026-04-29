# Contributing to Mercator

Thanks for the interest. Mercator is a small library with a narrow scope — contributions that keep it tight and correct are welcome.

## Before You Start

- **Security-sensitive bugs** go through the private channel in [SECURITY.md](./SECURITY.md), not a public issue or PR.
- **Feature requests** — open an issue first. The project favours a small, stable API. "Nice to have" additions that expand scope will usually be declined unless the use case is clearly in the library's mission (spatial uniqueness as a reusable primitive).
- **Small fixes** (typos, clearer error messages, test gaps, lint cleanups) — send a PR directly.

## Development

```bash
# Build
make build           # sui move build --lint

# Run tests (geometry-heavy — needs raised gas limit)
make test            # sui move test -i 10000000000

# Format
make fmt             # prettier-move (via npx)

# Check format + lint + tests
make verify
```

### Requirements

- `sui` CLI — pinned version tracked in `.github/workflows/ci.yml`.
- `node` + `npx` — only for `prettier-move` formatting.

## Coding Guidelines

- **Move 2024 edition.** Follow existing module layout: `sources/core/`, `sources/geometry/`, `sources/math/`.
- **No silent failures.** Prefer `assert!` with a numbered error code over skipping a branch. Every error code gets a named constant and a comment.
- **Overflow-aware arithmetic.** Use `u128::checked_add` / `checked_mul` where intermediates can exceed 64 bits. See `sources/math/signed.move`.
- **Fail-closed defaults.** Degenerate geometry (zero axis, zero area, collinear triangle) aborts. Do not silently return `false`.
- **Tests are required.** Public-API changes need both a happy-path test and an `#[expected_failure]` test covering the error case.
- **No `#[allow(unused_*)]`** on new code. Existing suppressions are being removed, not added to.

## Test Expectations

| Change type | Minimum coverage |
|-------------|------------------|
| New public function | Unit test + expected-failure test for each error code |
| Geometry algorithm | Invariant test covering boundaries (zero-length edges, max coordinates, touching vs. overlapping) |
| Mutation operation | Area-conservation assertion + no-overlap assertion |
| DOS-budget change | Regression test in `tests/dos_fix_regression_tests.move` |

See `tests/invariant_tests.move` and `tests/security_tests.move` for the style expected on adversarial coverage.

## Pull Request Checklist

- [ ] `make verify` passes locally.
- [ ] New public functions have doc comments.
- [ ] New error codes are numbered and documented.
- [ ] No unrelated changes (formatting the whole repo, renaming unrelated symbols, etc.).
- [ ] Commits are focused. If the branch has drive-by cleanups, split them into separate commits.
- [ ] PR description explains the *why* — the diff shows the *what*.

## Scope Boundaries

Mercator is deliberately small. Contributions that fit the scope:

- Correctness fixes in geometry / index / mutations.
- Gas reductions that do not weaken invariants.
- Better error messages and test coverage.
- Documentation improvements.

Contributions that usually do not fit:

- 3D / spherical / geodesic geometry — see the "When NOT to Use Mercator" table in the README.
- Application-layer features (marketplaces, auctions, games) — those belong in `examples/` or downstream crates.
- Off-chain decomposition or UI helpers — those belong in [exact-poly](https://github.com/fefa4ka/exact-poly).

## License

By contributing, you agree that your contributions are licensed under [Apache-2.0](./LICENSE), the same licence as the project.
