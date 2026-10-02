# Quality Baseline

A dated, weighted score so later progress is measurable rather than impressionistic. Update it
when a dimension genuinely moves, and keep the old rows — the trend is the useful part.

Local assessment write-ups live in `assessments/`, which is git-ignored. This file is the
tracked summary.

## 2026-10-02 — **6.5 / 10**

Measured at commit `5a0b055`. Derived from five parallel independent reviews (architecture,
code quality, tests, security, release readiness) with every load-bearing claim verified
against source before being accepted.

| Dimension | Weight | Score | Contribution |
| --- | --- | --- | --- |
| Security engineering | 25% | 8 | 2.00 |
| Correctness confidence (tests) | 20% | 6 | 1.20 |
| Architecture / changeability | 15% | 6 | 0.90 |
| Code quality | 15% | 7 | 1.05 |
| Release & delivery readiness | 15% | 5 | 0.75 |
| Documentation accuracy | 10% | 6 | 0.60 |
| **Total** | | | **6.50** |

### Why these weights

Weighting drives the number, so it is stated rather than implied. This is a pre-release tool
whose purpose is to create and delete cloud resources, so security engineering and correctness
confidence carry the most: a defect there is an Azure bill or a deleted resource, not a bad
user experience. Release readiness is weighted meaningfully because the repository is already
public. Documentation accuracy is weighted lowest in isolation but is the trust surface for a
public project, and it has already been wrong in both directions.

### Why not the earlier 8 / 10

The first assessment (`assessments/assessment-2026-30-08-12.44.md`) rated 8/10. The difference
is almost entirely weighting, not disagreement about facts:

- It weighted security engineering very heavily and treated **"never run against live Azure"**
  as a note. This baseline treats it as a dimension cap: for a deployment tool, code that has
  never deployed is unvalidated by definition.
- It did not weight release state at all, which for an already-public repository matters.
- It contained at least one factual error — the Azure allowlist holds **19** cmdlets, not 17 —
  which is a reminder to verify inherited claims rather than compound them.

### Per-dimension notes

**Security — 8.** Verified: the VM administrator password structurally cannot enter the process
(ARM `secureString` + Key Vault reference with a pinned `secretVersion`); teardown re-verifies
etag, observation fingerprint and proof hash *inside* the deletion loop; closed-world module
script lock, dependency lock, build-tool lock, SPDX SBOM, SHA-pinned actions. Held below 9 by
the allowlist's fail-open default — 10 of 19 cmdlets have no parameter clamp and nothing tests
allowlist/contract parity — and by the removal of the bundled-PSResourceGet content digest,
which was justified but is a real reduction in tamper detection.

**Tests — 6.** 367 tests, ~80.16% command coverage, architecture rules enforced by tests rather
than convention, and a cross-platform golden-hash determinism guard. The gate demonstrably
works: it caught a 59-failure regression that a 20-test subset had passed. Held down because
the uncovered fraction clusters in the Azure-facing error paths — precisely the ones that matter
mid-deployment — because five tests asserted against ambient host state and passed locally while
failing on three CI platforms, and because there is no fault injection.

**Architecture — 6.** The plan-side seam genuinely works: contributors have measured zero fan-in
from Core, so the registry indirection is never bypassed. Held down because the provider rather
than Core assembles the plan, 78 call sites cross the declared-but-empty `Engines/` boundary
(including a 12↔82 cycle), the engine-numbered band contains Core approval concerns, and the
closed-world configuration schema prevents a contributor owning its own configuration surface.
See [`refactoring-plan.md`](refactoring-plan.md).

**Code quality — 7.** Measured rather than inferred: zero PSScriptAnalyzer findings, one
unreferenced function out of 367, zero TODO/FIXME markers, zero empty catch blocks, deliberate
and correct ordinal-comparison discipline. Held down by roughly four explanatory comments in
~22k lines of invariant-dependent code, a mutating command under a `Test-` verb with no
`ShouldProcess`, and no `.EXAMPLE` on any of the 24 exported commands.

**Release — 5.** The machinery is excellent and the state is near zero. See
[`release-plan.md`](release-plan.md).

**Documentation — 6.** Substantially corrected in 2026-10, but the release notes still
overstated coverage and understated test count by nearly 5× *after* a sweep had been declared
clean. There is no automated consistency check between documented figures and measured ones.

## The single biggest lever

**Run it against a live subscription once.** Tests, security and release readiness are all
capped by the absence of field validation, so one successful canary deploy and teardown moves
three dimensions at once. Every other item in either plan is secondary to it.

## Target sequence

1. Merge PR #104 — stop the public repository describing an empty `src/`
2. One live canary deploy and teardown, throwaway subscription, spend cap
3. Allowlist parity test, then clamp the remaining 10 cmdlets
4. Fault-injection tests on the Azure error paths
5. Close the four release-gate holes; enable the disabled `main` ruleset
6. Single-source the version; add a documentation-consistency test
7. Engine contract extraction — **last**, and scoped per `refactoring-plan.md` R0–R8 rather
   than as a naive file move
