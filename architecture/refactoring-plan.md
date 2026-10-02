# Refactoring Plan

This is a dependency-ordered sequence, not a wish list. Each step names what it must not break
and the acceptance gate that proves it. Steps are deliberately ordered so that the risky ones
become safe only after the cheap ones have landed.

**Status:** accepted direction, not yet executed. Written 2026-10-02 following a multi-reviewer
assessment at `assessments/`.

## Why

The plan-side extension seam genuinely works: no file in `Private/` or `Public/` references a
contributor function by name, so the registry indirection in
[`05-ExtensionRegistry.ps1`](../src/AzureDataLabToolkit/Private/05-ExtensionRegistry.ps1) is
never bypassed, and the dependency graph rejects cycles under test.

Three things undercut it:

1. The **target provider assembles the plan**, not Core. `SqlVm.Plan.ps1` iterates capability
   fragments and merges resources itself, so a second provider must reimplement composition.
2. **78 call sites cross the declared-but-empty `Engines/` boundary**, including a mutual cycle
   between `12-DeploymentProfile.ps1` and `82-SqlVmArmTemplate.ps1`.
3. The **engine-numbered band is not the engine**. Approval phrases, mutation leases and
   execution records live inside `86-`/`87-`/`88-`, so naively "moving 82–89 behind an engine
   contract" would move Core's approval machinery out of Core. This is why the obvious
   refactoring is the wrong first move.

## The two tripwires that make this safe

Every step below is guarded by two values. Learn them before touching anything.

| Value | How to read it | Current |
| --- | --- | --- |
| `planHash` for `examples/sqlvm-minimal.yaml` | `(New-AzureDataLabPlan ./examples/sqlvm-minimal.yaml).planHash` | `sha256:bec0be2b…` |
| Engine identity digest | `(Get-AdltSqlVmArmEngineIdentity).digest` in module scope | `sha256:37da0b67…` |

`planHash` is computed over the canonical plan minus `planHash` itself
([`40-Canonical.ps1`](../src/AzureDataLabToolkit/Private/40-Canonical.ps1)), and `intentHash`
plus every `action.idempotencyKey` derives from it. The engine digest covers the resource
contract **and its key order**, and is canonical-compared against the authorization record.

A refactor that moves either value is not a refactor. See
[`.claude/skills/adlt-verify/`](../.claude/skills/adlt-verify/) for the exact commands.

---

## R0 — Land the boundary tests first

**Effort:** hours. **Risk:** near zero. **Do this before moving a single line.**

Add to [`tests/Unit/ArchitectureContracts.Tests.ps1`](../tests/Unit/ArchitectureContracts.Tests.ps1):

- **(a)** Parse every path in `Support/module-scripts.lock.json` and assert each `^function`
  name is defined exactly **once** across the module.
- **(b)** Assert the lock's `files` order agrees with the numeric filename prefixes within
  `Private/`. They agree today across all 69 entries — nothing asserts it, which is the actual
  defect. (The earlier claim that the prefixes are "decorative" is wrong; it was inherited from
  the first assessment and propagated into contributor docs before being corrected.)
- **(c)** Assert no `Private/[0-7]*.ps1` references a function defined in
  `Private/8[2-9]*.ps1`, seeded with an explicit allowlist of the 14 known violations
  (`12-:195,196,198`; `65-:409,424,483,498,508`; `66-:656,955`; `69-:292,381,492,1017`).
  **The allowlist may only ever shrink.**

These three assertions turn every later step from a judgement call into a test result. That is
the whole point of doing them first.

## R1 — Delete the dead `New-AdltTargetPlan`

**Effort:** hours. **Risk:** near zero.

[`05-ExtensionRegistry.ps1:394-418`](../src/AzureDataLabToolkit/Private/05-ExtensionRegistry.ps1#L394)
is unreachable: `05-` loads at lock index 2, `42-PlanModel.ps1` at index 9, and the `42-`
definition wins. The dead copy also *omits* `Set-AdltPlanIntentBinding` and
`Assert-AdltPlanContract`, so it is the dangerous one to accidentally revive.

Nothing to preserve — it never runs, so no hash moves.

## R2 — Extract the filesystem primitives out of `62-LocalRunStore.ps1`

**Effort:** hours. **Risk:** low.

Move `Set-AdltPrivatePathMode`, `Assert-AdltPrivatePathMode` and `Write-AdltPrivateAtomicText`
into a new `Private/56-PrivateFilesystem.ps1`, inserted in the lock **before**
`58-AtomicFile.ps1`. This removes the backward 58→62 edge. Four subsystems depend on these
primitives; none should depend on the run store to get them.

Pure move, no signature change. The real cost is the lock hand-edit plus the psm1 lock-hash
refresh. Guard: the ACL assertions in `tests/Unit/RunState.Tests.ps1`.

## R3 — Single-source the literals the compiler asserts

**Effort:** days. **Risk:** medium-high — this is the `planHash` tripwire.

`Assert-AdltSqlVmArmPlanProfile`
([`82-:471-617`](../src/AzureDataLabToolkit/Private/82-SqlVmArmTemplate.ps1#L471)) inlines
expected `desiredProperties` that the capability producers already emit. The Bastion CIDR
`10.42.2.0/26` exists in **four** places; there are 13 duplicated `apiVersion` literals.

Move the expected shapes and the resource contract into one data file that **both** the
producers (`Networking.Plan.ps1`, `Bastion.Plan.ps1`, `SqlVm.Plan.ps1`) and the asserter read.

**Must not break.** The change has to be value-preserving *to the byte*. Load the data file into
an **ordered** dictionary preserving today's exact key sequence — `resourceContract` and
`actionDependencies` feed the engine identity digest, so any key reordering changes it.

**Do not "DRY away" the double declaration itself.** The compiler re-stating what the producers
emit is deliberate defence in depth: it is a reviewed-shape allowlist. The goal is one *source*
for the values, not one *statement* of them.

**Acceptance gate:** golden fixture unchanged, engine digest unchanged, `SqlVmArmTemplate.Tests`
green — all checked *before* accepting the diff.

## R4 — Pull the Core concerns out of `86-`/`87-`/`88-`

**Effort:** days. **Risk:** medium.

| Move | From | To |
| --- | --- | --- |
| Approval-phrase derivation | `87-:1356`, `88-:1189`, `86-:441` | `66-AuthorizationModel.ps1` |
| Mutation leases | `86-:198,240`, `88-:811,848` | `68-RunOrchestration.ps1` |
| Execution-record build/assert | `87-:1379,1507,1545` | `69-ExecutionRecord.ps1` |
| Run-store appends | `88-:123,248,366` | `62-LocalRunStore.ps1` |
| Evidence builders | `88-:1209`, `86-:460` | `64-EvidenceModel.ps1` |

**Must not break** the authorization chain: `authorizationHash`, `teardownPlanHash`, the
state-tail binding at `66-:717-732`, and the per-delete etag + fingerprint + proof
re-verification with approver and lease re-asserted *inside* the deletion loop at `88-:887`.

**Pure moves only.** No signature or payload changes, or every artifact hash shifts.
`tests/Unit/Authorization.Tests.ps1` (2,537 lines) is the net — run it before and after with
identical fixtures.

This step is what makes R6 possible. Without it, R6 would relocate approvals out of Core.

## R5 — Invert the Core→engine references

**Effort:** days. **Risk:** medium, security-sensitive.

- Move `Assert-AdltSqlVmStaticDeploymentEligibility` out of `12-DeploymentProfile.ps1:183-204`
  into the engine band, so `12-` owns only profile load and binding. **This breaks the 12↔82
  cycle.**
- Change `65-:409,424` and `69-:292,381,1017` to **accept** the compilation and parameter
  document as parameters rather than invoking the compiler themselves.
- Replace `66-:656` and `66-:955` with a dispatched `Assert-AdltEngineCompilation` resolving the
  verifier by `$Compilation.engine.name` through the same `Get-Command`-by-descriptor pattern
  already proven at `05-:416`.

**Must not touch** `66-:698-705`. That digest-and-engine equality check is already
engine-agnostic and is the load-bearing assertion of the whole chain.

## R6 — Create the engine registry and move `82-89` behind it

**Effort:** days to weeks. **Risk:** high breadth, low semantic risk *once R4 and R5 have
landed*.

Add `Register-AdltEngineOperation` to `05-ExtensionRegistry.ps1`, keyed on the pair
**(engine, targetType)** with operations `Compile` / `Verify` / `WhatIf` / `Apply` /
`Inventory` / `Delete` / `Probe`, mirroring the capability descriptor shape that already works.

Relocate the now cleanly separated engine functions to `Engines/PowerShellArm/`, convert the
Public call sites to registry dispatch, and replace the five hardcoded guards
(`Start-AzureDataLabDeployment.ps1:41`, `Start-AzureDataLabTeardown.ps1:39`,
`Invoke-AzureDataLabPreflight.ps1:25`, `89-:589`, `80-:45`) with
*"no engine registered for (engine, targetType)"*.

**Why the pair and not the engine alone:** `engine.type` already admits `bicep` and `terraform`
in schema while `target.type` is a closed single-value enum, and the operation implementations
are specific to the *combination*. Keying on one axis mislabels the code and books a second
refactor.

**Must not break:** `Get-AdltSqlVmArmEngineIdentity` moves **verbatim** so the digest is
byte-identical, and the whole-template recompile-and-byte-compare at `82-:1468-1476` must still
run on the authorization path.

At this point R0(c)'s allowlist should be empty, and `Engines/README.md` and `Probes/README.md`
become descriptions rather than intentions.

## R7 — Move the plan assembler from the provider into Core

**Effort:** days. **Risk:** medium-high.

Relocate the fragment-merge loops at `SqlVm.Plan.ps1:257-275` and `:418-440` into
`42-PlanModel.ps1`, so `New-AdltTargetPlan` composes provider, capability and solution-pack
fragments and then binds hashes. The provider returns only its own resources, actions, findings
and decisions.

**Must not break:** merge **order** determines array order, which determines canonical JSON,
which determines `planHash`. Preserve today's sequence exactly — provider resources first, then
capabilities in ordinal name order (`05-:436-437`), then solution packs.

This is the step that actually makes a second target provider cheap, so it is worth the care.

## R8 — Open the configuration schema, last

**Effort:** weeks. **Risk:** high. **Behind a `schemaVersion` bump.**

Today `configuration.schema.json` is a closed world Core owns: `additionalProperties: false`
throughout, a named `sqlVm` block at top level, and `target.type` as a single-value enum. A
first-party contributor cannot own its own configuration surface.

Extend `New-AdltContributorDescriptor` with a `ConfigurationSchemaFragment` supplied at
registration; relax `capabilities` and `solutionPacks` to per-contributor sub-schemas; widen
`target.type`; move the `sqlVm` block to a provider-owned fragment. Also move the SQL-specific
`desiredProperties` names out of `plan.schema.json`.

**Must not break:** the configuration is embedded in the plan, so every schema-visible change
moves `planHash`. Do this as an **explicit `schemaVersion` increment** with a regenerated golden
fixture and a documented migration — never as a silent relaxation. All templates and all three
examples must still validate.

---

## Separate from the sequence

These do not depend on R0–R8 and can be done at any time.

**Close the Azure allowlist's fail-open default.** 10 of 19 allowlisted cmdlets have no
parameter clamp — `Connect-AzAccount`, `Set-AzContext`, `Clear-AzContext`,
`Disconnect-AzAccount`, `Disable-AzContextAutosave`, `Get-AzContext`, `Get-AzResourceProvider`,
`Get-AzComputeResourceSku`, `Get-AzVMImage`, `Get-AzDiagnosticSetting`. Both *mutating* cmdlets
are clamped, so this is a defence-in-depth gap rather than an exploitable hole — but the
`if ($CommandName -eq …)` chain has no terminal `else { throw }`, so adding a cmdlet without a
clamp is silent. Convert the nine sequential guards into one contract table keyed by command
name, dispatch uniformly through `Assert-AdltExactValueSet`, throw for an allowlisted command
with no contract, and **add a parity test asserting the allowlist and contract key sets are
identical.** That also drops `Invoke-AdltAzCommand`'s complexity substantially.

**Rename the mutating `Test-` command.** `Test-AzureDataLabDeployment` acquires locks, calls
live Azure, writes evidence and advances the run state machine under a `Test-` verb with plain
`[CmdletBinding()]` — no `ShouldProcess`, no `-WhatIf`. Rename it and add
`SupportsShouldProcess`. Keep `Test-` only for the three genuinely side-effect-free commands.
This is a breaking change the moment anything ships, so do it before the first tag.

Note: the `Resolve-` verbs are **fine**. All three really do mean "reconcile against live
state". The first assessment overstated that one.

**Write the why-comments.** There are roughly four explanatory comments in ~22k lines of code
whose correctness rests entirely on non-obvious invariants. Highest value first:
`82-:471` (this block is a reviewed-shape allowlist, the duplication is intentional, do not DRY
it), the hash chain in `62-` and `64-` (what each link proves and what breaks without it), the
10-minute lease window in `88-`, and the canary scope limits. The standard to match already
exists in `Install-AzureDataLabToolkitDependencies.ps1`.

**Add `.EXAMPLE` and `.PARAMETER` to all 24 exported commands**, starting with the four that
require a typed approval phrase — and document each phrase's format in the help of the command
that demands it, since a user currently has to run the command once to discover it. Add a test
asserting every exported command has at least one `.EXAMPLE`.

**Fix the three test defects that undermine their own claims.**
`tests/Unit/AzureRead.Tests.ps1:648` passes `-ModuleName Az.KeyVault`, which is outside the
`[ValidateSet]`, so its bare `Should -Throw` is satisfied by parameter binding and never reaches
the allowlist it claims to test — pin the message and use an allowlisted module with a
non-allowlisted command. `tests/Unit/Module.Tests.ps1:53` asserts session-global state
(`@(Get-Module -Name 'Az.*').Count`) and fails on any machine with an Az module loaded. And
`40-Canonical.ps1` is documented as RFC 8785 but emits uppercase `\uXXXX` hex and escapes
`U+007F`, which the RFC leaves raw — either conform or correct the claim to "RFC 8785-style",
and add a test pinning the chosen behaviour.

**Make the Azure fakes non-circular.** Every Az object and exception in the suite is hand-built
and has never been compared against a real one, so passing tests prove self-consistency rather
than agreement with Azure. CI already stages the real pinned Az modules — add contract checks
that assert the fake shapes match the real cmdlets' output types and that the error types raised
match what Azure actually throws. This is the highest-value test work available and it does not
need a subscription.

**Cover the gate and the recovery paths.** `Private/70-AzureCommand.ps1` sits at ~60% with 136
missed commands inside `Invoke-AdltAzCommand`, because scenario tests mock above the validator;
and the Resolve/Resume commands sit at 35–58%, which is exactly what a failed live deployment
exercises. Note also that overall coverage is **79.05% without the 16 build-running tests** —
below the gate — so the headline figure overstates unit coverage of the module.

**Decompose the large functions** along the phase boundaries that already exist in the code,
guarded by the two hash tripwires. Then add a function-length and complexity budget to the
Analyze task so the gain cannot silently erode.

## Verification for every step

```bash
# After ANY .ps1 add/move: hand-edit the lock files array FIRST, then
. ./build.ps1; Update-AdltBuiltModuleScriptLock -ModulePath ./src/AzureDataLabToolkit

pwsh -NoProfile -Command "Import-Module ./src/AzureDataLabToolkit/AzureDataLabToolkit.psd1 -Force; (Get-Command -Module AzureDataLabToolkit).Count"
pwsh -NoProfile -File ./build.ps1 -Task All    # NOT ./build.ps1
```

Then confirm both tripwires. A refactor that moves either has changed behaviour — stop and find
out why rather than updating the fixture.

Coverage sits roughly 0.1 points above the 80% gate, so any new branch needs its test or the
build fails with every test passing.
