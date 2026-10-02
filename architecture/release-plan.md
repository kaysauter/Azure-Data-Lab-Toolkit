# Release Plan

How this project gets from "public repository with no release" to a tagged, attested alpha
prerelease that a stranger can install and verify.

**Status:** accepted direction, not yet executed. Written 2026-10-02.

## Where this starts from

The release *machinery* is strong and the release *state* is near zero. Both facts matter.

What already exists in [`module-ci.yml`](../.github/workflows/module-ci.yml): the
`release-provenance` job binds tag → manifest version → tested commit → packaged artifact name
→ packaged module layout → in-package provenance file, then emits an SPDX 2.3 SBOM and two
GitHub attestations, with every third-party action pinned to a commit SHA. Most 1.0 PowerShell
modules ship with none of that.

What does not exist: any tag, any release, and — until PR #104 merges — any implementation on
`main`.

### The live credibility problem

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
3. **Enable the branch ruleset that already exists.** `gh api repos/.../rulesets` shows a
   ruleset named `main` at `"enforcement": "disabled"` — configured and then switched off.
   Set it to `active` and require the `PowerShell module checks` and `Docs checks` status checks
   plus linear history. The release job's `git merge-base --is-ancestor HEAD origin/main` gate
   means exactly as much as `main`'s protection does, which is currently nothing.
4. **Enable GitHub private vulnerability reporting.** [`SECURITY.md`](../SECURITY.md) currently
   routes to email because the feature is off. One toggle, strictly better than email.

## Phase 2 — Make the published claims true

5. **Fix the stale verification numbers.** `release-notes/0.1.0-alpha1.md:98-99` claims
   "76 Pester tests" and "87.19% command coverage". Real figures: 367 tests, ~80.16% against the
   80% gate. The same stale numbers appear in `version-history.mdx` and `CHANGELOG.md`. State
   the margin honestly — coverage sits about 0.1 points above the gate, which is *not* headroom.
6. **Audit `security.mdx` again.** A reviewer reports surviving false clauses at `:6-11` that
   the earlier documentation pass missed. Verify before editing; the earlier pass claimed a
   clean sweep and was wrong about `release-notes/`, so do not trust either claim without
   re-grepping.
7. **Rewrite `third-party-notices.mdx` to be release-scoped.** It currently claims the toolkit
   has no released provider, sample database, community tool or software integration. Add the
   runtime dependencies (`powershell-yaml` 0.4.12, the four Az modules, bundled PSResourceGet)
   and the catalog's third-party references (dbatools, Microsoft `sql-server-samples`). Then
   populate `licenseDeclared` in the SBOM instead of emitting `NOASSERTION` for every package.
8. **Refresh `.github/workflows/README.md`**, which still says "No workflow is added until there
   is executable code."

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

The version currently lives in four production places plus ~8 test files, with the only real
cross-check firing at release time. A bump is a manual sweep with a silent failure mode.

## Phase 4 — Close the four release-gate holes

Each of these makes the existing attestation machinery mean what it appears to mean.

11. **Invert the trigger so verification gates publication.** Today `on: release: types:
    [published]` means the release is **public before** the provenance job runs — roughly a
    45-minute window in which an unverified release is downloadable, and a failure requires
    retraction rather than prevention. Replace with `on: push: tags: ['v*']`, run the full
    matrix plus provenance against the tag, and create the GitHub Release **from the workflow,
    on success only**.
12. **Fail loudly on a malformed tag.** The `startsWith(tag_name, 'v')` guards cause GitHub to
    *skip* the job, producing a green run with no attestation at all. Add a step that runs
    unconditionally and throws on a bad tag, plus a tag ruleset restricting creation to
    `v[0-9]+.[0-9]+.[0-9]+*`.
13. **Require the prerelease flag.** An alpha must never appear as the repository's "Latest
    release". Either require `github.event.release.prerelease == true`, or set the flag from the
    workflow when the manifest's `Prerelease` field is non-empty.
14. **Attach the assets to the release.** All three artifacts are already built — the zip, its
    `.sha256`, and `sbom.spdx.json` — and then sent to a 90-day *workflow artifact*, which
    anonymous visitors cannot download. Upload them as release assets. Also raise the staging
    artifact's `retention-days: 1`, which does not survive a retry.

## Phase 5 — Give strangers a verifiable install path

15. **Document install-from-release as the default.** Both `README.md` and
    `getting-started.mdx` currently instruct `Import-Module ./src/AzureDataLabToolkit/...` —
    which bypasses the entire supply chain this pipeline exists to build, and runs with build
    provenance enforcement *disabled*. Add a path that: downloads the release zip, verifies it
    against the published `.sha256`, verifies the attestation with `gh attestation verify`,
    expands to a `PSModulePath` directory, and imports by module name. Keep the clone path, but
    label it explicitly as the development path without provenance enforcement.
16. **PowerShell Gallery: not yet.** Publishing an alpha that has never run against Azure to a
    public package feed invites installation by people who will not read the warnings. GitHub
    releases are the right distribution for this maturity. Revisit after the first live run.

## Phase 6 — Bind the changelog and cut the tag

17. Convert `CHANGELOG.md`'s single `## Unreleased` into `## [0.1.0-alpha1] - <date>` plus a
    fresh empty `Unreleased`. Add a release-time check that the CHANGELOG heading, the
    `release-notes/<version>.md` filename, the manifest version and the tag all agree. Use the
    release-notes file as the GitHub release body so the two cannot drift.
18. **Tag `v0.1.0-alpha1`**, then verify the attestation and SBOM are publicly retrievable from
    the release page *before* announcing anywhere.

---

## The alpha gate

Write this down as its own tier, distinct from the Release (R) gate in
[`delivery-segments.md`](delivery-segments.md). An alpha tag requires **all** of:

- [ ] `module-ci` green on Linux, Windows and macOS for the tagged commit
- [ ] version-consistency test passing
- [ ] zero PSScriptAnalyzer findings
- [ ] coverage at or above the gate, with the margin stated
- [ ] release notes and CHANGELOG section matching the tag
- [ ] `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md` present
- [ ] `main` ruleset enforced
- [ ] **no Azure-facing claim stated as verified**

That last item is the honest constraint. Nothing here has run against a live subscription, so
nothing may be labelled **Available** in the project's own status vocabulary.

## What a stranger must be told

The same four warnings, in the same words, in all four places a stranger actually looks: the
**GitHub repository description** (currently a feature sentence with no risk signal at all), the
top of `README.md`, the **GitHub release body**, and a first-run notice.

1. Never run this against a subscription you care about.
2. Nothing here has ever been executed against live Azure. Not once.
3. `Start-AzureDataLabDeployment` creates billable resources.
   `Start-AzureDataLabTeardown` deletes resources.
4. The command surface and plan hashes may change without notice between alpha tags.

## Before the first live run

Not required for the tag, but required before anyone should trust the result:

- A throwaway subscription or dedicated resource group, with a spend cap.
- The untouched `sqlvm-first-canary/v1` profile, not a selectable path.
- A dedicated resource group, because teardown fails closed on any foreign resource in the
  group and a shared group makes the lab un-teardownable through the toolkit.
- Expect ARM to reject something. The compiler asserts its own literals, so it can be
  internally consistent and still produce ARM that Azure refuses — and no test can catch that,
  because the expectations and the output come from the same source.

## Condensed order of operations

settle the tree → merge #104 → enable the ruleset → enable private vulnerability reporting →
fix the stale numbers and `security.mdx` → unify the version and add the consistency test →
invert the trigger, require the prerelease flag, fail on malformed tags, upload release assets →
document the verified install path → green full-matrix run on the candidate commit → cut the
CHANGELOG section → tag `v0.1.0-alpha1` → verify attestation and SBOM are publicly retrievable →
only then announce.
