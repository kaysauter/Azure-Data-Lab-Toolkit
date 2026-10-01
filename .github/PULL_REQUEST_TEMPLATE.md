## What and why

<!-- What changes, and why. If you considered an alternative and rejected it, say so — the
history is used as a design record. -->

Closes #

## Gate result

<!-- Paste the real numbers. "Green" without counts is not a result.
     pwsh -NoProfile -File ./build.ps1 -Task All  — note: NOT ./build.ps1 -->

- [ ] `pwsh -NoProfile -File ./build.ps1 -Task All` is green
- Tests: `___ passed, ___ failed, ___ skipped`
- Coverage: `___%` against the 80% gate — margin: `___`
- Exported commands: `___` (matches `FunctionsToExport`)

## Contract impact

Both values are hash-bound into the authorization chain. A refactor must leave them unchanged;
a deliberate change moves them and **invalidates existing execution records**.

- [ ] `planHash` unchanged — or changed deliberately, and the reason is in the commit message
- [ ] Engine identity digest unchanged — or changed deliberately, as above
- [ ] `tests/Fixtures/sqlvm-minimal.plan.sha256` updated only if the plan contract really changed

## Checklist

- [ ] If any `.ps1` under `src/AzureDataLabToolkit/` was added, moved, renamed or deleted:
      the lock's `files` array was hand-edited **first**, then
      `Update-AdltBuiltModuleScriptLock` was run
- [ ] No test asserts against ambient host state (`$PSHOME`, `PSModulePath`, installed module
      versions, working-tree cleanliness)
- [ ] Rejection paths are tested, not only the happy path
- [ ] A new selectable option landed in all of: configuration schema, defaults and provenance,
      validation, **support matrix**, plan contributor, plan schema, ARM compilation, tests
- [ ] No profile under `Profiles/` was edited as a side effect — that changes its hash and
      invalidates every example and fixture pinning it
- [ ] An ADR was added or amended if an accepted contract changed
- [ ] Documentation updated, and nothing is labelled **Available**
- [ ] `cd docs-site && npm run check:docs` passes, if `docs-site/` was touched

## Security

- [ ] No secret value can reach the plan, run state, evidence, logs, or reports
- [ ] Any new Azure call goes through `Invoke-AdltAzCommand` with an exact parameter clamp
- [ ] Unknown or unsupported input still fails **closed**
- [ ] Mutating paths still require the approval phrase, approver principal, and mutation lease
