# Release Plan

How this project gets from "public repository with no release" to a tagged, attested alpha
prerelease that a stranger can install and verify.

**Status:** in progress. Written 2026-10-02. By 2026-10-12, Phases 1, 3 and 4 were done (all
but item 12's tag ruleset), as were items 5, 6, 8, 15 and 17 and the four security items that
gate the alpha; each has a dated note below. Items 7 and 18 remain open.

## Where this starts from

When this plan was written, the release *machinery* was strong and the release *state* was near
zero. Both facts matter.

What already existed in [`module-ci.yml`](../.github/workflows/module-ci.yml): the
`release-provenance` job bound tag → manifest version → tested commit → packaged artifact name
→ packaged module layout → in-package provenance file, then emitted an SPDX 2.3 SBOM and two
GitHub attestations, with every third-party action pinned to a commit SHA. Most 1.0 PowerShell
modules ship with none of that.

What did not exist: any tag, any release, or — until PR #104 merged as `756f55e` on 2026-10-06
(UTC) — any implementation on `main`.

### The credibility problem (resolved)

*Resolved 2026-10-06 (UTC) by PR #104, merged as `756f55e`.* `git ls-tree -r 756f55e -- src`
returns 115 paths; at its parent it returned only `src/README.md`. The rest of this section
records the problem as it stood before the merge.

**The repository is already public, and `main` contains no implementation.** `git ls-tree -r
origin/main -- src` returns one path: `src/README.md`. A stranger arriving today reads extensive
documentation and a published docs site describing a module that, on the default branch, is not
there.

This is the single largest issue in this document, and unlike everything else it is live right
now. Fix it first, by merging rather than by hiding — module CI is green on all three platforms
as of `cbde0ee`, so there is no longer a reason to wait.

---

## Phase 1 — Stop the bleeding

1. **Settle the working tree.** A tag must point at a commit, and release-relevant changes must
   not be uncommitted. Run the full gate, confirm both hash tripwires, commit.
2. **Merge PR #104.** This is what makes `main` describe reality.

   *Done 2026-10-06 (UTC)*: merged as `756f55e`, which also settles item 1 — the implementation
   is committed on `main`.
3. **Enable the branch ruleset that already exists.** `gh api repos/.../rulesets` shows a
   ruleset named `main` at `"enforcement": "disabled"` — configured and then switched off.
   Set it to `active` and require the `PowerShell module checks` and `Docs checks` status checks
   plus linear history. The release job's `git merge-base --is-ancestor HEAD origin/main` gate
   means exactly as much as `main`'s protection does, which is currently nothing.

   *Done 2026-10-12.* The ruleset also had an empty branch condition, so it targeted nothing;
   it now targets the default branch and requires a pull request, linear history, and the
   `Module checks` and `Docs checks` jobs from the GitHub Actions app. Those are gate jobs, not
   the workflows: both workflows were path-filtered, and a required check that never reports
   blocks a pull request forever. A tag ruleset restricting names to `v<major>.<minor>.<patch>`
   was attempted and the API rejected its `tag_name_pattern` rule, so the release workflow's
   own tag check is the only one.
4. **Enable GitHub private vulnerability reporting.** [`SECURITY.md`](../SECURITY.md) currently
   routes to email because the feature is off. One toggle, strictly better than email.

   *Done 2026-10-12*, and `SECURITY.md` now routes reports to it.

## Phase 2 — Make the published claims true

5. **Fix the stale verification numbers.** `release-notes/0.1.0-alpha1.md:98-99` claims
   "76 Pester tests" and "87.19% command coverage". Real figures when this was written: 367
   tests, ~80.16% against the 80% gate. The same stale numbers appear in `version-history.mdx`
   and `CHANGELOG.md`. State the margin honestly — coverage sat about 0.1 points above the gate,
   which is *not* headroom.

   *Done 2026-10-12.* None of the three files carries the stale figures any more. The release
   notes and `version-history.mdx` quote the final gate run on 2026-10-12, which passed
   423 tests with 1 skipped and measured 80.06%
   command coverage (8,774 of 10,959 commands), 6
   commands above the 80% gate.
6. **Audit `security.mdx` again.** A reviewer reports surviving false clauses at `:6-11` that
   the earlier documentation pass missed. Verify before editing; the earlier pass claimed a
   clean sweep and was wrong about `release-notes/`, so do not trust either claim without
   re-grepping.

   *Done 2026-10-12.* Four of the box's five clauses were false: the alpha does more than
   enforce offline plan safeguards, and it does authenticate to Azure, check live controls such
   as the reused Key Vault's security settings, and deploy resources. Only "no production
   security baseline" held, and the box never said that teardown deletes resources. The
   re-audit corrected three more claims: analysis and Pester do not run on every pull request,
   only on those that change what they cover; secret scanning is enabled, not a backlog
   control; and no "security evidence" stage exists for decisions to appear in.
7. **Rewrite `third-party-notices.mdx` to be release-scoped.** It currently claims the toolkit
   has no released provider, sample database, community tool or software integration. Add the
   runtime dependencies (`powershell-yaml` 0.4.12, the five Az modules — Az.Accounts 5.5.0,
   Az.Compute 11.6.0, Az.KeyVault 6.5.0, Az.Monitor 8.0.0, Az.Resources 10.0.0 — and bundled
   PSResourceGet) and the catalog's third-party references (dbatools, Microsoft
   `sql-server-samples`). Then populate `licenseDeclared` in the SBOM instead of emitting
   `NOASSERTION` for every package.
8. **Refresh `.github/workflows/README.md`**, which still says "No workflow is added until there
   is executable code."

   *Done 2026-10-12.* It now describes the three workflows and their triggers, the two required
   checks, and how a pushed tag becomes a release.

## Phase 3 — Single-source the version

9. Make [`AzureDataLabToolkit.psd1`](../src/AzureDataLabToolkit/AzureDataLabToolkit.psd1)
   authoritative. Derive `$script:AzureDataLabToolkitVersion` from the manifest at import or
   generate it at build time; compute `$builtModulePath` and `$packagePath` in `build.ps1:15-16`
   from `Import-PowerShellDataFile` instead of the hardcoded `0.1.0` and
   `AzureDataLabToolkit-0.1.0-alpha1.zip`.
10. Add a test asserting **psd1 `ModuleVersion` + `Prerelease` == the psm1 constant == the built
    directory name == the package filename**, replacing the bare literal in
    `tests/Unit/Module.Tests.ps1:12`. Roughly a dozen test literals can then read from a shared
    helper.

    *Done 2026-10-12, by a different route for the psm1.* The manifest is the source of truth;
    `build.ps1` derives the built-module directory and the package name from it through one
    helper, and so do the tests that need them. The psm1 keeps its literal as a reviewed
    constant, so importing the module never depends on parsing the manifest. Generating it at
    build time was rejected because the version feeds every `planHash`, the engine identity and
    the extension descriptors: the value the suite runs with must be the value that ships,
    unlike the script-lock digest the build already rewrites, which reaches no output.
    `Module.Tests.ps1` holds the psm1 equal to the manifest in the source tree, and
    `Private/67-RuntimeIdentity.ps1` rejects a packaged module whose provenance version
    disagrees; the test also checks that the manifest version has the shape the release
    workflow can tag.
    The `0.1.0-alpha1` literals left in tests are sample data and say so: a full run with the
    version bumped to `0.2.0-beta1` failed only the golden plan-hash fixture, which is correct —
    plans and the engine identity embed the toolkit version, so a bump moves `planHash` and the
    engine digest by design.

When this was written, the version lived in four production places plus ~8 test files, with
the only real cross-check firing at release time, and a bump was a manual sweep with a silent
failure mode. It now lives in the manifest and the psm1, held equal by a test.

## Phase 4 — Close the four release-gate holes

Each of these makes the existing attestation machinery mean what it appears to mean.

11. **Invert the trigger so verification gates publication.** Today `on: release: types:
    [published]` means the release is **public before** the provenance job runs — roughly a
    45-minute window in which an unverified release is downloadable, and a failure requires
    retraction rather than prevention. Replace with `on: push: tags: ['v*']`, run the full
    matrix plus provenance against the tag, and create the GitHub Release **from the workflow,
    on success only**.

    *Done 2026-10-12.* `module-ci.yml` no longer runs on `release`. A pushed `v*` tag runs the
    three platform checks, then **Protected release provenance**, then **Publish release**,
    which attests the package and its SBOM and only then creates the release.
12. **Fail loudly on a malformed tag.** The `startsWith(tag_name, 'v')` guards cause GitHub to
    *skip* the job, producing a green run with no attestation at all. Add a step that runs
    unconditionally and throws on a bad tag, plus a tag ruleset restricting creation to
    `v[0-9]+.[0-9]+.[0-9]+*`.

    *Done 2026-10-12, except the ruleset.* The `startsWith` guards are gone. Once the platform
    checks pass, **Protected release provenance** runs for every `v*` tag and fails the run
    unless the tag is `v<major>.<minor>.<patch>`, optionally followed by a `-<prerelease>` of
    letters and digits, and equals `v` plus the manifest version. The tag ruleset could not be
    created; see item 3.
13. **Require the prerelease flag.** An alpha must never appear as the repository's "Latest
    release". Either require `github.event.release.prerelease == true`, or set the flag from the
    workflow when the manifest's `Prerelease` field is non-empty.

    *Done 2026-10-12*, by the second route: when the manifest's `Prerelease` is non-empty,
    **Publish release** creates the release with `--prerelease --latest=false`.
14. **Attach the assets to the release.** All three artifacts are already built — the zip, its
    `.sha256`, and `sbom.spdx.json` — and then sent to a 90-day *workflow artifact*, which
    anonymous visitors cannot download. Upload them as release assets. Also raise the staging
    artifact's `retention-days: 1`, which does not survive a retry.

    *Done 2026-10-12.* **Publish release** attaches the zip, its `.sha256` file and
    `sbom.spdx.json` to the release. The staging artifact is now kept for 7 days, long enough
    to re-run the failed release jobs.

## Phase 5 — Give strangers a verifiable install path

15. **Document install-from-release as the default.** Both `README.md` and
    `getting-started.mdx` currently instruct `Import-Module ./src/AzureDataLabToolkit/...` —
    which bypasses the entire supply chain this pipeline exists to build, and runs with build
    provenance enforcement *disabled*. Add a path that: downloads the release zip, verifies it
    against the published `.sha256`, verifies the attestation with `gh attestation verify`,
    expands to a `PSModulePath` directory, and imports by module name. Keep the clone path, but
    label it explicitly as the development path without provenance enforcement.

    *Done 2026-10-12.* Both now lead with the release path: download the zip, check it against
    its `.sha256` file and with `gh attestation verify`, expand it into a `PSModulePath`
    directory, install the locked dependencies with the bundled
    `Install-AzureDataLabToolkitDependencies.ps1`, and import the module by name. The clone path
    stays, labelled as the development path without build-provenance enforcement.
16. **PowerShell Gallery: not yet.** Publishing an alpha that has never run against Azure to a
    public package feed invites installation by people who will not read the warnings. GitHub
    releases are the right distribution for this maturity. Revisit after the first live run.

## Phase 6 — Bind the changelog and cut the tag

17. Convert `CHANGELOG.md`'s single `## Unreleased` into `## [0.1.0-alpha1] - <date>` plus a
    fresh empty `Unreleased`. Add a release-time check that the CHANGELOG heading, the
    `release-notes/<version>.md` filename, the manifest version and the tag all agree. Use the
    release-notes file as the GitHub release body so the two cannot drift.

    *Done 2026-10-12.* `CHANGELOG.md` has its `## [0.1.0-alpha1] - 2026-10-12` section below an
    empty Unreleased section. For every tag, **Protected release provenance** requires the tag to
    equal `v` plus the manifest version, `release-notes/<version>.md` to be a non-empty file and
    `CHANGELOG.md` to have exactly one `## [<version>]` section, and **Publish release** uses
    that release-notes file as the release body.
18. **Tag `v0.1.0-alpha1`**, then verify the attestation and SBOM are publicly retrievable from
    the release page *before* announcing anywhere.

---

## Security items that gate the alpha

From the adversarial re-review recorded in [`quality-baseline.md`](quality-baseline.md). All
four gate for the same reason: each one makes a *published claim* false, and for software that
has never run live the documented invariants are the main assurance artifact.

1. **Proof-hash re-verification** (`88-TeardownOperation.ps1:755-760`) covers 2 of 4 deletable
   relationships. Either extend it to all four or state precisely which are covered — and add a
   per-relationship test. Documents claiming "before each delete" are already corrected.

   *Resolved 2026-10-02 in `2888331`*, which reached `main` with PR #104 — see B1 in
   [`quality-baseline.md`](quality-baseline.md). The gate is now
   `88-TeardownOperation.ps1:778-951`. It recomputes the full proof for `planned-taggable`,
   `planned-descendant` and `sql-iaas-agent-extension`, re-checks only the disk's own
   `ManagedBy`, size and storage type for `vm-managed-disk`, because the VM that carries the
   rest of that proof is deleted first, and throws for any other relationship.
   `TeardownResolution.Tests.ps1` tests each relationship.
2. **Manifest-surface contract test** — ~10 lines asserting `AzureDataLabToolkit.psd1` declares
   no `ScriptsToProcess`, `NestedModules`, `RequiredAssemblies`, `FormatsToProcess` or
   `TypesToProcess`, and that `RootModule` is exactly `AzureDataLabToolkit.psm1`. Until then
   "only locked, hash-verified module scripts load" is demonstrably false.

   *Resolved 2026-10-02 in `2888331`*, as proposed — see B2.
3. **Single-gate verb regex** (`tests/Unit/Module.Tests.ps1:98`) — one line, from
   `^(Connect|Disconnect|Get|New|Set|Remove|Invoke)-Az` to `^[A-Z][A-Za-z]+-Az`. This is the
   test that keeps the headline allowlist claim true as pull requests land on a public repo.

   *Resolved 2026-10-02 in `2888331`*, as proposed — see B3.
4. **`packageDigest`** is written into the evidence record as verified but is never computed
   from any artifact. Verify it or remove it before shipping an attestation that asserts it.

   *Resolved 2026-10-12 by relabelling, not by verification* — see S2 in
   [`quality-baseline.md`](quality-baseline.md). The self-comparison is gone and the code,
   `SECURITY.md` and the baseline all say the field is recorded, not measured. Removing it would
   change the execution-authorization shape; verifying it needs the package archive, which the
   installer never has.

## The alpha gate

Write this down as its own tier, distinct from the Release (R) gate in
[`delivery-segments.md`](delivery-segments.md). An alpha tag requires **all** of:

- [ ] `module-ci` green on Linux, Windows and macOS for the tagged commit
- [ ] version-consistency test passing
- [ ] zero PSScriptAnalyzer findings
- [ ] coverage at or above the gate, with the margin stated
- [ ] release notes and CHANGELOG section matching the tag
- [x] `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md` present
- [x] `main` ruleset enforced
- [ ] **no Azure-facing claim stated as verified**

That last item is the honest constraint. Nothing here has run against a live subscription, so
nothing may be labelled **Available** in the project's own status vocabulary.

The release workflow will not publish unless the first five items hold for the tagged commit:
each platform check runs `./build.ps1 -Task All`, which fails on a failing test, an analyzer
finding or coverage below 80%, and **Protected release provenance** checks the release notes and
the CHANGELOG section against the tag. Stating the margin is still a manual step.

## What a stranger must be told

The same four warnings, in the same words, in all four places a stranger actually looks: the
**GitHub repository description** (currently a feature sentence with no risk signal at all), the
top of `README.md`, the **GitHub release body**, and a first-run notice.

1. Never run this against a subscription you care about.
2. Nothing here has ever been executed against live Azure. Not once.
3. `Start-AzureDataLabDeployment` creates billable resources.
   `Start-AzureDataLabTeardown` deletes resources.
4. The command surface and plan hashes may change without notice between alpha tags.

*Done 2026-10-12 in three of the four places:* the top of `README.md`, the release body
(`release-notes/0.1.0-alpha1.md`), and, in place of a first-run notice,
`Connect-AzureDataLabAccount`, which repeats these warnings before it signs in. The GitHub
repository description is a repository setting, not a file, and still reads as a feature
sentence.

## Before the first live run

Not required for the tag, but required before anyone should trust the result:

- A throwaway subscription or dedicated resource group, with a spend cap.
- The untouched `sqlvm-first-canary/v1` profile, not a selectable path.
- A dedicated resource group, because teardown fails closed on any foreign resource in the
  group and a shared group makes the lab un-teardownable through the toolkit.
- Expect ARM to reject something. The compiler asserts its own literals, so it can be
  internally consistent and still produce ARM that Azure refuses — and no test can catch that,
  because the expectations and the output come from the same source.
- **Fix the Azure command boundary first — found 2026-10-12, known issue in v0.1.0-alpha1.**
  `Invoke-AdltAzCommand` (`Private/70-AzureCommand.ps1`) admits only cmdlets, but the locked
  Az.Resources 10.0.0 and Az.Monitor 8.0.0 export `Get-AzADUser` and
  `Get-AzDiagnosticSetting` as functions. Live resolution needs both, so it cannot complete
  and no deployment can be authorized. Every test mocks the boundary, which is why the suite
  passes. Admitting functions safely means proving they come from the locked module's own
  verified files, so this deserves its own reviewed change, with a test that exercises the
  real boundary against the locked manifests.

## Condensed order of operations

settle the tree → merge #104 → enable the ruleset → enable private vulnerability reporting →
fix the stale numbers and `security.mdx` → unify the version and add the consistency test →
invert the trigger, require the prerelease flag, fail on malformed tags, upload release assets →
document the verified install path → green full-matrix run on the candidate commit → cut the
CHANGELOG section → tag `v0.1.0-alpha1` → verify attestation and SBOM are publicly retrievable →
only then announce.
