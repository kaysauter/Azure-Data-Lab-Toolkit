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

**Security — 8, pending an adversarial re-review.** The first security pass failed on a tooling
error (structured-output retry cap, not an analysis failure) and has been relaunched as three
adversarial passes that attempt to falsify the invariants rather than confirm them. One finding
from the test review already bears on this score: `Invoke-AdltAzCommand`, the gate in front of
every Azure mutation, is itself only ~60% executed, so the *assurance* behind the design is
weaker than the design. Expect this number to settle at 7–8 rather than rise.

Verified: the VM administrator password structurally cannot enter the process
(ARM `secureString` + Key Vault reference with a pinned `secretVersion`); teardown re-verifies
etag, observation fingerprint and proof hash *inside* the deletion loop; closed-world module
script lock, dependency lock, build-tool lock, SPDX SBOM, SHA-pinned actions. Held below 9 by
the allowlist's fail-open default — 10 of 19 cmdlets have no parameter clamp and nothing tests
allowlist/contract parity — and by the removal of the bundled-PSResourceGet content digest,
which was justified but is a real reduction in tamper detection.

**Tests — 6.** Independently reviewed and scored 6, matching the initial estimate. What exists
is unusually disciplined: 224 `BeExactly` assertions, 66 message-pinned `Should -Throw`,
tamper-after-rehash mutation-style tests, real resume/idempotency/lease/drift scenarios, and
injected seams for git and the clock. The gate demonstrably works — it caught a 59-failure
regression that a 20-test subset had passed.

Held at 6 by findings that are worse than first assumed, each verified:

- **The Azure fake is circular.** Every Az object and Az exception in the suite is a hand-built
  `pscustomobject` written by the same author as the code that reads it. None has ever been
  checked against a real Az response or a real Az error type. Passing tests therefore establish
  that the code agrees with itself, not that it agrees with Azure — which is the property a live
  deployment needs.
- **The security gate is the least-tested part of the security boundary.**
  `Private/70-AzureCommand.ps1` is ~60% covered, with 136 missed commands inside
  `Invoke-AdltAzCommand` itself. Scenario tests mock *above* the validator, so the
  caller→validator path never executes.
- **The 80% coverage figure is partly an artifact.** Excluding the 16 tests that run `build.ps1`
  and package the module, coverage is **79.05%** — below the gate. The headline number is
  carried by build-running tests rather than by unit coverage of the module.
- **Recovery paths are the least covered.** `Resolve-AzureDataLabTeardown` 34.9%,
  `Resolve-AzureDataLabDeployment` 42.2%, `Resume-AzureDataLabDeployment` 47.9%,
  `Resume-AzureDataLabTeardown` 55.3%, `Start-AzureDataLabDeployment` 57.9% — exactly the
  branches a live deployment hits when something goes wrong.
- **One security test passes for the wrong reason.** `tests/Unit/AzureRead.Tests.ps1:648`
  asserts that Key Vault secret retrieval is refused, but passes `-ModuleName Az.KeyVault`,
  which is not in the `[ValidateSet]`. The bare `Should -Throw` is satisfied by parameter
  binding and never reaches the allowlist. It would still pass if the allowlist were deleted.
- **Canonical JSON diverges from RFC 8785**, which the documentation claims. Verified: `U+001F`
  is emitted as `\u001F` where the RFC requires lowercase hex, and `U+007F` is escaped where the
  RFC leaves it raw. Low practical risk while plan strings stay pattern-constrained, but the
  point of canonicalisation is cross-implementation agreement on bytes — a second engine
  canonicalising per the actual RFC would compute different hashes.
- Host coupling remains: `tests/Unit/Module.Tests.ps1:53` asserts session-global state
  (`@(Get-Module -Name 'Az.*').Count | Should -Be 0`), which fails on any machine with an Az
  module already loaded.
- No ARM template validation, no recorded-response tier, no multi-process concurrency tests on
  the run store, no property-based or mutation testing. The suite takes 41–45 minutes on CI,
  which rules it out as a development loop.

A 7 is roughly a week away: contract-check the fakes against the real Az modules CI already
stages, and unit-test the recovery branches. A 9–10 additionally needs a live tier with
recorded real responses.

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
