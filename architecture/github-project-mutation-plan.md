# GitHub Issue And Project Mutation Plan

This is an operational handoff for a later GitHub writer pass. It does not
authorize GitHub mutation and is not a second product backlog. The authoritative
issue metadata is the table in [`FEATURE_REQUESTS.md`](../FEATURE_REQUESTS.md);
segment outcomes and quality gates come from
[`delivery-segments.md`](delivery-segments.md). Cross-segment and conditional
implementation slices come from
[`github-project-sub-issue-manifest.md`](github-project-sub-issue-manifest.md).

## Verified Starting Point

- Repository: `kaysauter/Azure-Data-Lab-Toolkit`
- Existing issues: open issues `#1` through `#32`
- Existing mapping: issue `#n` carries `FR-nnn`
- Existing label on all 32 issues: `enhancement`
- Existing issue titles need reconciliation with the current feature-request
  table.
- The current GitHub CLI token can read issues but lacks `read:project`, so the
  writer must refresh Project authorization before inspecting or changing
  Project fields.

## Deterministic Issue Manifest

For every row in the `FEATURE_REQUESTS.md` backlog table:

1. Use the `ID` as the stable identifier.
2. Set the title to `[<ID>] <Feature request>`.
3. Copy `Intended outcome`, `Phase`, `Priority`, `Depends on`,
   `Scheduled after`, `Segment`, and `Maturity` exactly from that row.
4. Preserve the Project's existing workflow vocabulary: `Backlog`, `Ready`,
   `In progress`, `Blocked`, and `Done`. New items start in `Backlog` unless
   there is verified evidence for another state; maturity is not workflow
   status.
5. Derive `Quality gate` from the assigned segment:

   | Segments | Gate |
   | --- | --- |
   | S0-S3 | Contract |
   | S4-S5 | Live |
   | S6-S14 | Release |
   | S15-S16 | Live |
   | S17-S22 | Release |

6. Treat direct `Depends on` values as architectural prerequisites. Convert one
   into a native parent-to-parent dependency only when the entire upstream epic
   must be complete. When either epic spans segments, use the corresponding
   child-to-child dependency from the sub-issue manifest and retain the
   parent-level value as metadata. Do not create a dependency from `Scheduled
   after`.
7. Add an issue-body link to the exact segment row and include its entry,
   exit, and explicit-deferral text.
8. Add the cross-cutting security acceptance criteria to every target provider
   and solution pack:
   - one explicit `secretStoreDecision`;
   - references rather than secret values in YAML, plans, state, logs, and
     reports.
9. Add the VM acceptance criteria to every Azure VM issue and any VM-hosted
   container child issue:
   - one explicit `administrativeAccessDecision`;
   - Bastion with no public IP by default;
   - rationale, approval, cost, and security evidence for reuse or opt-out.

### Existing Issues To Update

Update issues `#1` through `#32` from rows `FR-001` through `FR-032`,
respectively. Do not close or recreate them. Preserve relevant discussion and
links, replace stale title or body metadata, and keep the `enhancement` label.

The most visible title changes are:

| Issue | Required title |
| --- | --- |
| #4 | `[FR-004] Core and extension contracts` |
| #6 | `[FR-006] Local run state, retries, and audit trail` |
| #8 | `[FR-008] Security, identity, and network policy` |
| #12 | `[FR-012] Toolkit repository CI and vulnerability gates` |
| #13 | `[FR-013] Deployment validation and WhatIf framework` |
| #14 | `[FR-014] SQL Server on Azure VM target provider` |
| #15 | `[FR-015] Storage and backup-staging capability module` |
| #18 | `[FR-018] Azure SQL Database target provider` |
| #19 | `[FR-019] Azure SQL Managed Instance target provider` |
| #25 | `[FR-025] Azure Database for PostgreSQL target provider` |
| #26 | `[FR-026] Azure Databricks target provider` |
| #27 | `[FR-027] Additional Git and pipeline adapters` |
| #30 | `[FR-030] SQL Server on Linux and containers` |
| #32 | `[FR-032] Later data target portfolio` |

All other existing titles must still be compared with the authoritative table
and updated when punctuation or wording differs.

### New Issues To Create

Create these issues in order. If another issue is created concurrently, keep the
FR identifier and returned GitHub issue number distinct rather than forcing an
incorrect numeric match.

| ID | Required title | Segment |
| --- | --- | --- |
| FR-033 | `[FR-033] PowerShell deployment engine` | S1 |
| FR-034 | `[FR-034] Probe and evidence framework` | S1 |
| FR-035 | `[FR-035] Windows guest-operations capability` | S4 |
| FR-036 | `[FR-036] SQL VM solution pack` | S5 |
| FR-037 | `[FR-037] Remote state and execution coordination` | S6 |
| FR-038 | `[FR-038] PostgreSQL on Azure VM target provider` | S10 |
| FR-039 | `[FR-039] Containerized PostgreSQL target provider` | S11 |
| FR-040 | `[FR-040] Linux guest-operations capability` | S10 |
| FR-041 | `[FR-041] Container-runtime capability` | S11 |
| FR-042 | `[FR-042] Git and CI/CD intent contract with GitHub reference adapter` | S14 |
| FR-043 | `[FR-043] Secret-store decision and Key Vault capability` | S3 |
| FR-044 | `[FR-044] VM administrative access and Bastion capability` | S3 |

The outcome, phase, priority, maturity, technical prerequisites, scheduled
order, and complete issue body for each new issue come directly from its
`FEATURE_REQUESTS.md` row and assigned segment. Do not summarize away those
fields during creation.

### Sub-Issues To Create

After the 44 parent epics are reconciled, create every row in
[`github-project-sub-issue-manifest.md`](github-project-sub-issue-manifest.md)
as a native sub-issue. Copy its child key, parent, segment, gate, title,
technical dependencies, and acceptance delta exactly.

Parent epics remain the product-level backlog. Child issues carry actual segment
work and conditional capability dependencies. In particular:

- S4 interactive canary children must not depend on FR-037 or another S6-only
  remote-execution child;
- VM-hosted container children depend on FR-044, while non-VM container
  children do not;
- each FR-024 pack has its own dependencies, and FR-023 is added only when that
  pack's accepted design uses CI/CD.

## Issue Body Template

```markdown
## Outcome

<Intended outcome from FEATURE_REQUESTS.md>

## Delivery

- Segment: <S0-S22>
- Phase: <Phase>
- Priority: <Priority>
- Maturity: <Maturity>
- Quality gate: <Contract, Live, or Release>

## Technical dependencies

<Direct Depends on values, or None>

## Scheduled after

<Scheduled after value, explicitly labeled as delivery order rather than a
technical dependency>

## Segment acceptance

**Entry:** <Entry criteria from delivery-segments.md>

**Exit:** <Exit criteria from delivery-segments.md>

**Deferred:** <Explicitly deferred text from delivery-segments.md>

## Architecture constraints

- Preserve the Core, target-provider, capability-module, catalog-source,
  solution-pack, probe, and deployment-engine boundaries.
- Do not place secret values in YAML, plans, state, logs, or reports.
- Do not infer resource ownership from a name, resource group, or tag.
- Record unsupported capabilities explicitly.

<Add secret-store and VM-access criteria when applicable.>

## Evidence required

<Quality-gate evidence from delivery-segments.md plus feature-specific tests.>
```

## Project Fields

Inspect the current Project before mutation. Preserve existing fields and add or
reconcile these typed fields:

| Field | Type | Values or use |
| --- | --- | --- |
| `Status` | Single select | Preserve `Backlog`, `Ready`, `In progress`, `Blocked`, `Done` |
| `Delivery segment` | Single select | `S0` through `S22` |
| `Phase` | Single select | Values used in `FEATURE_REQUESTS.md` |
| `Priority` | Single select | `P0`, `P1`, `P2`, `P3` |
| `Maturity` | Single select | `Committed design`, `Backlog`, `Exploratory`, `Deferred`, `Available` |
| `Quality gate` | Single select | `Contract`, `Live`, `Release` |
| `Architecture boundary` | Single select | Seven architecture parts plus `Governance` and `Engineering` for non-runtime work |
| `Target` | Single select | Shared, SQL VM, Azure SQL DB, SQL MI, PostgreSQL managed, PostgreSQL VM, PostgreSQL container, Fabric, Databricks, later target |
| `Scheduled after` | Text | Delivery order only; never converted automatically into issue blocking |
| `Release` | Text or iteration | Intended release or milestone |
| `Risk` | Single select | `Low`, `Medium`, `High`, `Critical` |
| `Effort` | Number | Relative estimate agreed during refinement |

Prefer native issue dependencies for technical `Depends on`, at child level
when work spans segments. Keep the existing text dependency field during
migration until native relationships and the absence of false later-segment
blockers have been verified.

## Project Views

Create or reconcile these views:

| View | Filter or grouping |
| --- | --- |
| `VM First` | Segments S0-S6, grouped by segment, then priority |
| `Current Segment` | Open items in the active segment |
| `PostgreSQL To Fabric` | Segments S9-S18, grouped by segment |
| `Dependency Chain` | Open items with native blocking relationships |
| `Boundary Coverage` | Group by architecture boundary |
| `Security Decisions` | FR-043, FR-044, all target providers, and all solution packs |
| `Release Evidence` | Group by quality gate and release; show maturity and risk |
| `Exploratory And Deferred` | Maturity is Exploratory or Deferred |

## Mutation Safety

Before writing:

1. obtain `read:project` and `project` authorization;
2. export the current issue bodies, field definitions, item values, views, and
   native dependencies;
3. verify that issues `#1` through `#32` still map to `FR-001` through
   `FR-032`;
4. stop on concurrent issue creation, changed issue identity, or an unknown
   Project field rather than guessing;
5. apply parent-issue updates, then sub-issues, before Project fields and views;
6. re-read all 44 FR issues and every manifest child and compare them with the
   checked-in sources;
7. publish a mutation report listing created issues, changed issues, field
   changes, dependency changes, and any skipped item.

The verification must fail if an S4 child is blocked by FR-037, an S6 child, or
the completion of a cross-segment parent when a narrower child dependency
exists.
