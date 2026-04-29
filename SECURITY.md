# Security Policy

Mercator enforces an on-chain uniqueness invariant. A vulnerability here can allow overlapping registrations, bypass of owner gating, area-conservation failures, or denial-of-service against the shared index — any of which undermines the primitive for every downstream user. Security reports are therefore high priority.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security bugs.**

Report privately through **GitHub's Private Vulnerability Reporting**:

1. Go to the [Security tab](https://github.com/fefa4ka/mercator/security) of this repository.
2. Click **Report a vulnerability**.
3. Fill in the advisory form.

This keeps the report invisible to the public until a fix is coordinated. GitHub notifies the maintainer directly; no email is exposed to spam or indexing.

A useful report includes:

- Affected module(s) and functions (e.g. `mercator::sat::overlaps`, `mercator::index::register`).
- Impact — what invariant breaks and how an attacker could exploit it (overlap bypass, area leak, DoS, ownership confusion, etc.).
- A reproducer: Move test, transaction inputs, or pseudocode that triggers the issue.
- Affected versions (tag or commit SHA).
- Your name / handle for credit, if you want it.

### Response timeline

| Stage | Target |
|-------|--------|
| Initial acknowledgement | within 72 hours |
| Triage & severity assessment | within 7 days |
| Fix + coordinated disclosure | depends on severity; critical issues prioritised |

If you do not get an acknowledgement within 72 hours, ping on the advisory thread — GitHub notifications occasionally miss.

## Scope

In scope:

- Any module under `sources/` — geometry, index, mutations, metadata, registry.
- On-chain invariant violations: overlap bypass, area non-conservation, ownership bypass, broadphase budget bypass, cell-occupancy bypass, coordinate overflow, signed-arithmetic errors.
- Gas-cost griefing that escapes the documented DOS budgets.

Out of scope:

- Issues reproducible only by forking and modifying `sources/` or `registry.move`.
- Gas optimisation suggestions without a concrete attack.
- Documentation typos (open a normal issue or PR).
- Vulnerabilities in third-party code (Sui framework, MoveStdlib) — report those upstream to MystenLabs.

## Supported Versions

Pre-1.0: only the current `main` branch and the latest tagged release receive security fixes. Post-1.0, a support policy will be published here.

## Disclosure

Fixes land in `main` and a new release is cut. A security advisory is published on GitHub with CVE where appropriate. Reporters are credited unless they request otherwise.
