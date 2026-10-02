# Quality Baseline

A dated, weighted score so later progress is measurable rather than impressionistic. Update it
when a dimension genuinely moves, and keep the old rows — the trend is the useful part.

Local assessment write-ups live in `assessments/`, which is git-ignored. This file is the
tracked summary.

## 2026-10-02 — **6.2 / 10**

Measured at commit `5a0b055`. Derived from five parallel independent reviews (architecture,
code quality, tests, security, release readiness) with every load-bearing claim verified
against source before being accepted.

| Dimension | Weight | Score | Contribution |
| --- | --- | --- | --- |
| Security engineering | 25% | 7 | 1.75 |
| Correctness confidence (tests) | 20% | 6 | 1.20 |
| Architecture / changeability | 15% | 6 | 0.90 |
| Code quality | 15% | 7 | 1.05 |
| Release & delivery readiness | 15% | 5 | 0.75 |
| Documentation accuracy | 10% | 5 | 0.50 |
| **Total** | | | **6.15** |

Security was 8 before the adversarial re-review falsified two documented invariants, and
documentation accuracy was 6 before those same findings showed a published invariant was
false. Both revisions are downward on evidence, which is the intended behaviour of this
document.

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

**Security — 7.** Revised down from 8 after an adversarial re-review that falsified two stated
invariants. See the security findings section below.

**Security (original assessment basis, retained for comparison) —** The first security pass failed on a tooling
error (structured-output retry cap, not an analysis failure) and has been relaunched as three
adversarial passes that attempt to falsify the invariants rather than confirm them. One finding
from the test review already bears on this score: `Invoke-AdltAzCommand`, the gate in front of
every Azure mutation, is itself only ~60% executed, so the *assurance* behind the design is
weaker than the design. Expect this number to settle at 7–8 rather than rise.

Verified: the VM administrator password structurally cannot enter the process
(ARM `secureString` + Key Vault reference with a pinned `secretVersion`); teardown re-verifies
etag and observation fingerprint *inside* the deletion loop — **but not the proof hash for
every relationship**, see below; closed-world module
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

---

## Security findings — adversarial re-review, 2026-10-02

Three adversarial passes attempted to **falsify** the stated invariants rather than confirm
them. The core claims survived: no path was found to extract a secret the module itself
produces, and no way to mint a mutation without a matching typed phrase, the live-verified
approver, a valid lease and an intact hash chain. Replay across runs and across plans, and a
second execution of the same run, are all genuinely blocked.

Two documented invariants were **falsified**, both verified against source. Score revised 8 → 7.

### Blocks a public alpha

**B1 — The proof hash is not re-verified before every delete.**
`Private/88-TeardownOperation.ps1:755-760` gates the fresh proof-hash recomputation on
`$Resource.relationship -in @('planned-taggable','planned-descendant')`. Four deletable
relationships exist; `vm-managed-disk` and `sql-iaas-agent-extension` are deleted on an
id/type/etag/fingerprint match alone — and for an implicitly created managed disk that
fingerprint is near-empty, carrying neither etag nor tags.

Both this document and `assessments/assessment-2026-30-08-12.44.md:86` previously claimed the
proof hash is re-verified before **each** delete. That claim was wrong and is corrected above.
For a tool that has never run live, the documented invariants are the primary assurance
artifact, so a false one is worse than a missing one. Either extend the gate to all four
relationships — mirroring the inventory-time switch at
`Private/87-TeardownInventory.ps1:1213-1310` — or state precisely which relationships are
covered. Add a per-relationship test either way; there is none today.

**B2 — The module manifest bypasses the closed-world script lock.**
`AzureDataLabToolkit.psd1` is outside every content digest (`module-scripts.lock.json` contains
zero `.psd1` entries), and `RootModule`, `ScriptsToProcess`, `NestedModules`,
`RequiredAssemblies`, `FormatsToProcess` and `TypesToProcess` all execute before or instead of
the psm1's closed-world check. Demonstrated three ways, with the lock reporting success while
injected code ran at import.

This is not a privilege crossing — it needs write access to the module directory, the same
primitive as editing the psm1 — so it is medium, not critical. What makes it matter is that the
published claim *"only locked, hash-verified module scripts load"* is demonstrably false, and
the lock's own machinery says OK. Fix: a ~10-line contract test asserting the manifest declares
none of those fields and that `RootModule` is exactly `AzureDataLabToolkit.psm1`.

**B3 — The single-gate architecture test has an incomplete verb regex.**
`tests/Unit/Module.Tests.ps1:98` matches
`^(Connect|Disconnect|Get|New|Set|Remove|Invoke)-Az(?!ureDataLab)`. The invariant holds at this
commit, but `Update-AzVM`, `Stop-AzVM`, `Start-AzVM`, `Move-AzResource` and
`Register-AzResourceProvider` would all pass the suite today. One-line fix to
`^[A-Z][A-Za-z]+-Az(?!ureDataLab)`. This is the test that keeps the headline allowlist claim
true as pull requests land on a public repository.

### Other verified findings

**S1 — `Export-AzureDataLabPlan` is the only persistence boundary with no secret-free gate.**
It calls `Assert-AdltPlanHash` alone (`:304`), skipping `Assert-AdltPlanContract` — which is
what invokes `Assert-AdltSecretFreeBoundary` (`Private/47-PlanContract.ps1:8`) — and skipping
plan schema validation. Demonstrated by execution: a planted literal secret appeared verbatim
in both stdout and the written file. It is also the only export written non-privately
(`Write-AdltAtomicText` without `-Private`, mode 0644), where `Export-AzureDataLabEvidence`
passes `-Private` and gets 0600. Not currently reachable through module-produced plans, so
defence in depth — but it is the last gate before data leaves the tool, and it is the one
missing. **Open question for the owner:** plan reports are *meant* to be shared, so 0600 may be
wrong for their purpose; the inconsistency with evidence export should be resolved deliberately
rather than by copying the flag.

**S2 — `packageDigest` is a false attestation.** It is compared against itself at
`Install-AzureDataLabToolkitDependencies.ps1:909-910` and never computed from any artifact, then
written into the evidence record as a verified value (`Private/67-RuntimeIdentity.ps1:309`).
`contentDigest` provides the real guarantee. Either verify `packageDigest` against the
downloaded package or remove it — shipping an evidence record asserting a digest nothing
checked undercuts the auditability the project is built on.

**S3 — The secret detectors are narrower than the claim.** Broken five ways: the forbidden-key
regex is anchored to exactly ten names (`adminPassword`, `apiKey`, `privateKey` and similar all
evade it); both detectors only recurse into `IDictionary`/`IList`, so a `PSObject` terminates
the walk; `char[]`/`byte[]` payloads evade detection *and* survive canonicalisation; and the
bearer-token detector is reachable only from the `configuration`|`plan` boundaries, not from
evidence, artifact or compilation assertions. None is reachable today, because the configuration
schema admits no free-form object (25 `additionalProperties: false`) and `ConvertTo-AdltDictionary`
normalises `PSObject` at every entry point. Defence in depth, not a vulnerability.

**S4 — Read-only run-store reads mutate without the lock.**
`Get-AdltVerifiedLocalRunContext` takes no lock yet deletes unreferenced pending execution
records, which can permanently wedge a run and strand live Azure resources.

**S5 — Teardown authorization is not bound to runtime identity**, unlike deploy.
`Assert-AdltRuntimeAuthorizationBinding` is called only on the deploy path.

**S6 — The `cbde0ee` digest-removal reasoning was sound but one premise was false**, and the
"recorded as evidence" claim in that comment does not hold — the digest is computed and
discarded, not recorded. The comment should be corrected.

### Confirmed intact

No way found to unwrap a `SecureString` (no `AsPlainText`, `ConvertFrom-SecureString`,
`NetworkCredential` or `SecureStringToBSTR` anywhere), no Key Vault read cmdlet reachable,
`Get-AzAccessToken` clamped to `Arm` + `AsSecureString`, no literal ARM password parameter
constructible, all 12 run-store persistence sites gated, run-event payloads key-allowlisted
regardless of a permissive schema, and the teardown lease and approver genuinely re-asserted
per resource inside the deletion loop.
