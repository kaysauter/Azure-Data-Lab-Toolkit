# Contributing

Thanks for looking. This is a single-maintainer project in pre-release alpha, so read
[SECURITY.md](SECURITY.md) first for what the software actually does and does not do.

No review timeline is promised. Issues and pull requests are read, and you will get an honest
answer about whether something will be taken — including "no" — rather than silence.

## Before you write code

Open an issue first for anything beyond a typo. The project has an explicit delivery order in
[`architecture/delivery-segments.md`](architecture/delivery-segments.md) and a roadmap in
[`FEATURE_REQUESTS.md`](FEATURE_REQUESTS.md); a change that jumps the order is likely to be
declined even if it is good, because the segments have exit gates.

Accepted architecture lives in [`architecture/decisions/`](architecture/decisions/). If your
change contradicts an ADR, the ADR has to change first — propose that in the issue.

## Prerequisites

- PowerShell **7.6** or later
- `pwsh` on `PATH`
- Node 22 only if you touch `docs-site/`

Everything else — Pester, PSScriptAnalyzer, `powershell-yaml`, the Az modules — is pinned and
verified by the build against `src/AzureDataLabToolkit/Support/build-tools.lock.json`. Do not
install your own versions and expect them to be used; the build stages the locked ones
deliberately.

## The local gate

```bash
pwsh -NoProfile -File ./build.ps1 -Task All
```

Takes roughly 25 minutes. Runs Clean, Analyze, Test, Package. It must be green before you open
a pull request.

**Two traps that will cost you a run.** Both are real and both have caught the maintainer:

1. **Use `pwsh -NoProfile -File ./build.ps1`.** The script is not executable, so `./build.ps1`
   fails with `permission denied`. If you pipe it to `tail` or `head`, the pipe masks the exit
   code and a failed run looks like a pass.

2. **If you add, move, rename or delete any `.ps1` under `src/AzureDataLabToolkit/`, edit the
   lock first.** The module performs a closed-world check: every script must be listed in
   `src/AzureDataLabToolkit/Support/module-scripts.lock.json`, and the `files` array is the
   authoritative **load order** — the numeric filename prefixes are decorative. Add your
   `{ "path": ..., "sha256": ... }` entry in the right position by hand, then:

   ```bash
   . ./build.ps1
   Update-AdltBuiltModuleScriptLock -ModulePath ./src/AzureDataLabToolkit
   ```

   `Update-AdltBuiltModuleScriptLock` only rehashes entries that already exist. It does **not**
   discover new files. Skip this and you get hundreds of failures, or
   `The module contains an unexpected or unlocked script` at import — pointing nowhere near the
   real cause.

A fast loop for one file, which skips the lock verification path:

```bash
pwsh -NoProfile -Command '
$c = New-PesterConfiguration
$c.Run.Path = "tests/Unit/<File>.Tests.ps1"
$c.Run.PassThru = $true; $c.Output.Verbosity = "None"
$r = Invoke-Pester -Configuration $c
"passed=$($r.PassedCount) failed=$($r.FailedCount)"
$r.Failed | ForEach-Object { "FAILED: $($_.Name)"; "  $($_.ErrorRecord.Exception.Message)" }'
```

A green subset is not a green gate. Run the full gate before you push.

If you use Claude Code, [`.claude/skills/adlt-verify/`](.claude/skills/adlt-verify/) encodes all
of this.

## Coverage

The build enforces **80% command coverage** and recent runs sit at about 80.1% — roughly a
dozen commands of headroom. A new `throw` branch without a test can fail the build with every
test passing. Report the margin, not just pass or fail.

## Writing tests

Two rules, both learned the hard way:

- **Never assert against ambient host state.** No `$PSHOME`, no `PSModulePath`, no installed
  module versions, no "is the working tree dirty". Five tests did this, passed locally, and
  failed on all three CI platforms. Inject a fixture or take an explicit parameter — the
  functions have `-PowerShellHome` and `-Candidates` parameters for exactly this.
- **Assert the rejection, not just the acceptance.** This codebase's value is that it fails
  closed. A test that only proves the happy path proves the least interesting half.

Architecture rules are enforced in
[`tests/Unit/ArchitectureContracts.Tests.ps1`](tests/Unit/ArchitectureContracts.Tests.ps1)
rather than by convention. If your change establishes a boundary, assert it there.

## Two tripwires that look like unrelated breakage

- **Deployment profile hash.** Editing anything in `src/AzureDataLabToolkit/Profiles/*.json`
  changes that profile's hash, and every `examples/*.yaml` and fixture pins it. One added line
  produces dozens of `Configuration deployment profile hash is stale` failures. That binding is
  working as designed. Treat a profile edit as its own change with the regeneration it implies.
- **Golden plan hash.** `tests/Fixtures/sqlvm-minimal.plan.sha256` pins `planHash` as a
  cross-platform determinism guard. Adding a configuration field legitimately changes it —
  update the fixture *and say so in the commit message*. Never update it reflexively to make a
  test pass; catching unexpected change is the entire point.

When dozens of tests fail at once, count the distinct exception messages before diagnosing.
One root cause with fifty symptoms is normal here.

## Contract changes

Two values are hash-bound into the authorization chain and must not move by accident:

- `planHash` — the offline plan contract
- the engine identity digest from `Get-AdltSqlVmArmEngineIdentity`

A refactor must leave both unchanged. A deliberate contract change moves them and **invalidates
existing execution records** — say so explicitly in the commit message.

## Commits and pull requests

[Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`,
`test:`, `ci:`, `chore:`, `refactor:`.

Write commit messages that explain *why*, including what you considered and rejected. The
history is used as a design record.

Branch from `main`. Fill in the pull request template — the checklist is the review.

## Documentation accuracy

The documentation describes an unreleased alpha, and it recently had to be corrected for
claiming capabilities did not exist when they did. Both directions of inaccuracy are bugs.

The project's status vocabulary is precise and is defined in
[`docs-site/src/content/docs/status.mdx`](docs-site/src/content/docs/status.mdx):

- **Current** — verified repository behavior; does not mean deployable
- **Available** — released, documented, and verified. Nothing is Available yet.
- **Committed design** — accepted, not implemented

Do not label anything **Available**. If you touch `docs-site/`:

```bash
cd docs-site && npm run check:docs
```

## Licence

Contributions are accepted under the [MIT Licence](LICENSE).
