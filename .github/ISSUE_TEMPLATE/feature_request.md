---
name: Feature request
about: Suggest an addition or change to the library
title: "[feature] "
labels: enhancement
---

> Mercator has a deliberately narrow scope (see the "When NOT to Use Mercator" and "Scope Boundaries" sections in the README and [CONTRIBUTING.md](../../CONTRIBUTING.md)). Application-layer features belong in downstream crates or in `examples/`. Off-chain geometry belongs in [exact-poly](https://github.com/fefa4ka/exact-poly).

## Problem

_What are you trying to do that Mercator does not currently support? Describe the use case, not the solution._

## Proposed API / change

_If you have one. A rough signature is fine:_

```move
public fun some_new_thing(...);
```

## Alternatives considered

_Have you tried composing existing Mercator primitives (standalone `sat`, `aabb`, `polygon`), or solving this off-chain with `exact-poly`? What did not work?_

## Impact on invariants

_Does this affect: non-overlap, area conservation, ownership gating, DOS budgets? Explain how._

## Willing to contribute?

- [ ] I can send a PR if the direction is agreed.
- [ ] I would use this but cannot implement it myself.
