---
name: adlt-verify
description: Run the Azure Data Lab Toolkit local gate correctly — module script lock refresh, import smoke test, full build, and hash-stability checks. Use before every commit or push to this repo, and after any change under src/AzureDataLabToolkit/. Also use when the whole Pester suite fails at once, when a test complains about an "unexpected or unlocked script", or when coverage is near the 80% gate.
---

# Verify an Azure Data Lab Toolkit change

The gate is slow (~25 min) and unforgiving. Run the steps in order. Skipping step 1 produces a
failure that looks like something else entirely.

## 1. Refresh the module script lock — FIRST, if any `.ps1` changed

`AzureDataLabToolkit.psm1` verifies every file listed in
`src/AzureDataLabToolkit/Support/module-scripts.lock.json`, and performs a **closed-world**
check that no unlocked `.ps1` exists. Load order comes from the lock's `files` array, **not**
the filesystem.

`Update-AdltBuiltModuleScriptLock` only **rehashes entries that already exist**, and throws if a
listed file is missing. It does **not** discover new files.

So if you added, moved, renamed, or deleted a `.ps1` under `src/AzureDataLabToolkit/`:

1. Hand-edit the `files` array in `Support/module-scripts.lock.json` first — add, move, or
   remove the `{ "path": ..., "sha256": ... }` entry. **Position matters**: a file that
   registers something (a contributor, an engine) must be ordered after what it depends on. Put
   a new `Private/NN-*.ps1` in numeric position. The array is authoritative; the numeric
   prefixes currently agree with it exactly across all 69 entries, but nothing asserts that, so
   keep both in agreement.
2. Then refresh hashes and the pinned lock digest:

```bash
cd <repo root>
. ./build.ps1
Update-AdltBuiltModuleScriptLock -ModulePath ./src/AzureDataLabToolkit
```

That rewrites every `sha256` and rewrites `$script:AzureDataLabToolkitScriptLockHash` in the
psm1. `build.ps1` is dot-sourceable: it returns early when invoked with `.`.

Schemas, catalogs, profiles, templates and `Support/*.json` are **not** in the lock — only
`.ps1`. `Install-AzureDataLabToolkitDependencies.ps1` is also not in the lock.

**Symptom of a stale lock:** every test fails, or import throws
`The module contains an unexpected or unlocked script` /
`Locked module script '<path>' failed content verification`. The cause is step 1, not your code.

## 2. Import smoke test

Cheap, and it proves the lock, load order, and closed-world check all agree before you spend 25
minutes:

```bash
pwsh -NoProfile -Command "Import-Module ./src/AzureDataLabToolkit/AzureDataLabToolkit.psd1 -Force; (Get-Command -Module AzureDataLabToolkit).Count"
```

Expect **24**, or 24 plus any command you deliberately added. A mismatch against
`FunctionsToExport` in the psd1 fails the build later anyway.

## 3. Full gate

```bash
pwsh -NoProfile -File ./build.ps1 -Task All
```

**Use `pwsh -NoProfile -File`.** `./build.ps1` is not executable and fails with
`permission denied`. Do not pipe it to `tail` or `head` — that masks the exit code behind the
pipe and a failed run reports success.

Long-running: start it in the background and poll, rather than blocking.

`-Task All` runs Clean, Analyze, Test, Package. Narrower tasks: `Analyze`, `Test`, `Build`,
`Package`, `Clean`.

For a fast loop on specific files, skip `build.ps1`:

```bash
pwsh -NoProfile -Command '
$c = New-PesterConfiguration
$c.Run.Path = "tests/Unit/<File>.Tests.ps1"
$c.Run.PassThru = $true; $c.Output.Verbosity = "None"
$r = Invoke-Pester -Configuration $c
"passed=$($r.PassedCount) failed=$($r.FailedCount)"
$r.Failed | ForEach-Object { "FAILED: $($_.Name)"; "  $($_.ErrorRecord.Exception.Message)" }'
```

This skips the lock verification path, so it will not catch a stale lock. Step 2 still matters.

## 4. Pass criteria

| Check | Expected |
| --- | --- |
| PSScriptAnalyzer | 0 findings |
| Pester | 0 failed |
| Coverage | ≥ 80% — **report the margin, not just pass/fail** |
| Exported commands | matches `FunctionsToExport` |
| Exit code | 0 |

**Coverage is the trap.** The gate is 80% and recent runs sit at ~80.1% — roughly a dozen
commands of headroom. A new `throw` branch without a test can fail the build with every test
passing. Always report the actual percentage and how much room is left.

## 5. Hash stability

Two values must not move unintentionally.

```bash
# planHash — the offline plan contract
pwsh -NoProfile -Command "Import-Module ./src/AzureDataLabToolkit/AzureDataLabToolkit.psd1 -Force; (New-AzureDataLabPlan ./examples/sqlvm-minimal.yaml).planHash"
```

```bash
# engine identity digest — hash-bound into the authorization chain
pwsh -NoProfile -Command "
Import-Module ./src/AzureDataLabToolkit/AzureDataLabToolkit.psd1 -Force
\$m = Get-Module AzureDataLabToolkit
& \$m { (Get-AdltSqlVmArmEngineIdentity).digest }"
```

Recorded baselines, verified at commit `5a0b055` on `codex/powershell-foundation`:

| Value | Baseline |
| --- | --- |
| `planHash` for `examples/sqlvm-minimal.yaml` | `sha256:bec0be2b060e597e3319b5a2c4b03200dcc2ed5ddbb3c3601077cb5d86f7f523` |
| engine identity digest | `sha256:37da0b677925699b8f10ca7cde77e43f5bae9f0d58e1b638574cbc84873a7906` |

Update this table in the same commit that deliberately changes either value, so the table is
always the last intended state rather than a stale note.

- A **refactor** must leave both unchanged. If either moves, the change was not behaviour-neutral.
- A **deliberate** contract change moves them. That is fine, but it invalidates existing
  execution records, so say so explicitly in the commit message rather than letting it surprise
  someone. `Private/66-AuthorizationModel.ps1` canonical-compares the authorization's engine
  against the compilation's.

## 5b. Two other tripwires that look like unrelated mass failure

**Deployment profile hash.** Editing anything in `Profiles/*.json` changes that profile's
hash. Every `examples/*.yaml` and test fixture pins `deploymentProfile.hash`, so one added line
produces dozens of failures reading
`Configuration deployment profile hash is stale. Regenerate the YAML with this module version.`
from `Private/12-DeploymentProfile.ps1`. The binding is working as designed. Treat a profile
edit as its own deliberate change with the fixture and example regeneration it implies — never
as a side effect of adding a field elsewhere.

**Golden plan hash.** `tests/Fixtures/sqlvm-minimal.plan.sha256` pins `planHash` as a
cross-platform determinism guard (`tests/Unit/Plan.Tests.ps1`). Adding a configuration field
legitimately changes it. Update the fixture in the same commit and say in the message that the
plan contract changed — do not update it reflexively to make a test pass, because the whole
point of the fixture is that an *unexpected* change is caught.

Symptom pattern: when dozens of tests fail at once, count the distinct exception messages
before diagnosing. One root cause with 53 symptoms is common here.

```bash
grep -E "^\s+(RuntimeException|InvalidOperationException|Expected)" <log> \
  | sed 's/^ *//' | sort | uniq -c | sort -rn | head
```

## 6. Docs, when docs changed

```bash
cd docs-site && npm run check:docs
```

Runs slide-source checks, the Astro and Slidev builds, and internal link validation. Required
by the `docs-checks` workflow for any `docs-site/**` change.

## Reporting

State the real numbers: tests passed/failed/skipped, coverage percentage **and margin**, exit
code, and whether the two hashes moved. If something was skipped, say which and why. Do not
report "green" without the counts.

## Red flags to call out, not silently fix

- A test that reads ambient host state — `$PSHOME`, `PSModulePath`, installed module versions,
  whether the working tree is dirty. These pass locally and fail on other platforms. Five of
  them did exactly that here. Prefer an injected fixture or an explicit parameter.
- A byte-exact digest pinned to a hosted runner image. Those images rotate; the pin rots with
  them.
- A numeric claim in docs or a commit message that was not counted from the source.
