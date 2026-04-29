---
name: Bug report
about: A correctness or behaviour problem in the library
title: "[bug] "
labels: bug
---

> If this is a **security vulnerability** (overlap bypass, area leak, ownership bypass, DoS outside documented budgets), **do not file here** — use GitHub's **Private Vulnerability Reporting** via the [Security tab](https://github.com/fefa4ka/mercator/security). See [SECURITY.md](../../SECURITY.md).

## Summary

_One or two sentences: what breaks, and where._

## Reproduction

Minimal Move test or transaction inputs that trigger the bug:

```move
// e.g. a failing test in tests/<file>.move
```

Or, if reproduced on-chain: transaction digest + Index object ID.

## Expected behaviour

_What the library should do._

## Actual behaviour

_What happens instead. Include the abort code (e.g. `EOverlap (4012)`) if applicable._

## Environment

- Mercator version / commit: `<tag or SHA>`
- Sui CLI version: `sui --version` output
- OS: `<macOS / Linux / ...>`

## Additional context

_Anything else relevant: polygon shape, index configuration (`with_config` parameters), recent changes to a fork, etc._
