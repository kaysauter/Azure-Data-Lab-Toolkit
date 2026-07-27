# GitHub Project Sub-Issue Manifest

This manifest turns cross-segment epics into implementation-sized Project
items. It is authoritative for child-issue creation; parent epic metadata remains
authoritative in [`FEATURE_REQUESTS.md`](../FEATURE_REQUESTS.md), and segment
entry, exit, gate, and deferral criteria remain authoritative in
[`delivery-segments.md`](delivery-segments.md).

## Mutation Rules

- Create every row below as a native sub-issue of the named parent epic.
- Use the `Child key` in the issue title and body so the mapping remains stable
  even if GitHub issue numbers change.
- Assign the child, not its parent epic, to the row's `Delivery segment` and
  `Quality gate`.
- Convert only the listed technical dependencies into native issue
  dependencies. A reference marked `conditional` becomes a dependency only
  after that condition is accepted in the child contract.
- Every child inherits its parent's outcome and architecture constraints, plus
  the full entry, exit, gate, and explicit-deferral criteria for its segment.
- Every target or solution-pack child must emit a `secretStoreDecision` and keep
  secret values out of YAML, plans, state, logs, and reports.
- Every Azure VM or VM-hosted-container child must emit an
  `administrativeAccessDecision`; Bastion with no public IP is the default.
- New children start in `Backlog`. Workflow status is never inferred from
  maturity or segment.

The acceptance text in the tables is the child-specific delta. It does not
replace the inherited segment gate.

## VM-First Delivery Slices

These children make S1 through S6 executable without allowing release-only
remote coordination to block the interactive S4 canary.

| Child key | Parent | Segment | Gate | Required title | Technical dependencies | Child acceptance delta |
| --- | --- | --- | --- | --- | --- | --- |
| FR-006/S1 | FR-006 | S1 | Contract | `[FR-006/S1] Local run-state contract` | FR-005 | Local run IDs, immutable plans, append-only events, locking, snapshots, redaction, and interactive resume fixtures pass offline. |
| FR-008/S1 | FR-008 | S1 | Contract | `[FR-008/S1] Offline security policy contract` | FR-003, FR-004, FR-005 | Identity, network, secret, sensitive-data, public-access, and approval decisions are deterministic and serializable without secret values. |
| FR-009/S1 | FR-009 | S1 | Contract | `[FR-009/S1] Offline cost and lifecycle contract` | FR-005, FR-006/S1, FR-008/S1 | Cost intent, budget, TTL, shutdown, ownership, teardown, uncertainty, and HTML evidence fixtures pass without live prices. |
| FR-013/S1 | FR-013 | S1 | Contract | `[FR-013/S1] Validation and WhatIf contracts` | FR-004, FR-005, FR-006/S1, FR-008/S1, FR-009/S1 | Provider-independent fixtures cover no-change, create, reuse, replace, conflict, drift, denied access, and cleanup evidence. |
| FR-033/S1 | FR-033 | S1 | Contract | `[FR-033/S1] PowerShell offline engine contract` | FR-004, FR-005, FR-006/S1, FR-008/S1, FR-013/S1 | PowerShell export is deterministic, capability-aware, non-mutating, and emits stable IDs and structured errors. |
| FR-034/S1 | FR-034 | S1 | Contract | `[FR-034/S1] Probe and evidence envelope` | FR-004, FR-005, FR-006/S1 | Versioned probe specifications and one evidence envelope render consistently as console, JSON, Markdown, and HTML. |
| FR-013/S2 | FR-013 | S2 | Contract | `[FR-013/S2] Repository CI validation fixtures` | FR-012, FR-013/S1 | Pull-request CI runs deterministic positive and negative fixtures without cloud credentials or mutating workflows. |
| FR-008/S3 | FR-008 | S3 | Contract | `[FR-008/S3] Read-only SQL VM security decisions` | FR-008/S1 | SQL VM identity, private network, Key Vault, Bastion, and exception decisions are explicit before any mutation. |
| FR-009/S3 | FR-009 | S3 | Contract | `[FR-009/S3] SQL VM live cost estimate` | FR-009/S1 | Authenticated price evidence records source, time, currency, confidence, unknowns, Bastion cost, and still-billable resources without mutation. |
| FR-013/S3 | FR-013 | S3 | Contract | `[FR-013/S3] Azure-aware SQL VM WhatIf` | FR-013/S1, FR-013/S2 | Live reads distinguish absence, denial, reuse, drift, conflict, and unknown ownership and never mutate Azure. |
| FR-033/S3 | FR-033 | S3 | Contract | `[FR-033/S3] PowerShell read-only SQL VM adapter` | FR-033/S1, FR-013/S3 | The engine performs only declared reads and attaches live comparison evidence to the immutable plan hash. |
| FR-034/S3 | FR-034 | S3 | Contract | `[FR-034/S3] SQL VM plan and WhatIf evidence` | FR-034/S1, FR-013/S3 | Plan, WhatIf, security, cost, ownership, and teardown-intent evidence share stable resource and action IDs. |
| FR-043/S3 | FR-043 | S3 | Contract | `[FR-043/S3] Key Vault decision and capability contract` | FR-008/S1, FR-034/S1 | Deploy, reuse, approved external store, and justified not-applicable paths are schema-valid, costed, ownership-aware, and reference-only. |
| FR-044/S3 | FR-044 | S3 | Contract | `[FR-044/S3] Bastion decision and capability contract` | FR-008/S1, FR-009/S1, FR-034/S1 | Bastion with no public IP is the default; reuse and opt-out require rationale, approval, cost, and security evidence. |
| FR-014/S3 | FR-014 | S3 | Contract | `[FR-014/S3] Read-only SQL VM plan` | FR-008/S3, FR-009/S3, FR-013/S3, FR-033/S3, FR-034/S3, FR-043/S3, FR-044/S3 | One secure SQL VM profile produces matching Plan, WhatIf, and cost evidence with explicit unsupported capabilities and no mutation. |
| FR-006/S4 | FR-006 | S4 | Live | `[FR-006/S4] Interactive VM state and resume` | FR-006/S1, FR-014/S3 | Protected local state supports interruption, reconciliation, idempotent interactive resume, and failure handoff for the canary. |
| FR-008/S4 | FR-008 | S4 | Live | `[FR-008/S4] Secure VM policy enforcement` | FR-008/S3, FR-014/S3 | Managed identity, private access, secret references, approvals, and public-access refusal are enforced and probed. |
| FR-009/S4 | FR-009 | S4 | Live | `[FR-009/S4] VM cost and lifecycle enforcement` | FR-009/S3, FR-006/S4 | Budget, TTL or shutdown, ownership-aware teardown, orphan query, and still-billable-resource evidence pass live. |
| FR-013/S4 | FR-013 | S4 | Live | `[FR-013/S4] Secure VM canary validation` | FR-013/S3, FR-006/S4 | Positive, negative, partial-failure, retry, teardown, and cleanup-proof lanes pass in an isolated subscription. |
| FR-033/S4 | FR-033 | S4 | Live | `[FR-033/S4] Guarded PowerShell VM mutation` | FR-033/S3, FR-006/S4, FR-013/S4 | Apply and teardown dispatch only approved actions, preserve stable IDs, and stop safely on unsupported or expanded scope. |
| FR-034/S4 | FR-034 | S4 | Live | `[FR-034/S4] Secure VM live evidence` | FR-034/S3, FR-013/S4 | Deployment, probe, failure, shutdown, teardown, orphan, and billing evidence is complete and redacted. |
| FR-035/S4 | FR-035 | S4 | Live | `[FR-035/S4] Windows guest canary operations` | FR-034/S4, FR-043/S3 | Narrow, idempotent Windows bootstrap proves least privilege and keeps database and user secrets out of SYSTEM context. |
| FR-043/S4 | FR-043 | S4 | Live | `[FR-043/S4] Key Vault live capability` | FR-043/S3, FR-008/S4, FR-034/S4 | Create and reuse paths prove RBAC, network, retention, ownership, references, and teardown behavior without leaking values. |
| FR-044/S4 | FR-044 | S4 | Live | `[FR-044/S4] Bastion live capability` | FR-044/S3, FR-008/S4, FR-009/S4, FR-034/S4 | Private administrative access, chosen tier, no-public-IP default, reuse or opt-out evidence, cost, and teardown behavior pass live. |
| FR-014/S4 | FR-014 | S4 | Live | `[FR-014/S4] Secure Azure VM canary` | FR-006/S4, FR-008/S4, FR-009/S4, FR-013/S4, FR-033/S4, FR-034/S4, FR-035/S4, FR-043/S4, FR-044/S4 | A private Windows VM can be deployed, accessed, stopped, resumed, and removed interactively with cleanup proof. |
| FR-014/S5 | FR-014 | S5 | Live | `[FR-014/S5] SQL VM readiness` | FR-014/S4, FR-035/S4 | SQL connectivity, supported configuration, restore boundary, and target probes pass without broadening guest privilege. |
| FR-015/S5 | FR-015 | S5 | Live | `[FR-015/S5] SQL VM storage and backup staging` | FR-014/S4, FR-034/S4 | One owned or reused staging path, optional Azure Files mount, transfer, probe, cost, ownership, and removal path pass live. |
| FR-016/S5 | FR-016 | S5 | Live | `[FR-016/S5] SQL VM governed data onboarding` | FR-011, FR-014/S5, FR-015/S5 | One Microsoft sample and one local or URL data path pass provenance, integrity, licensing, sensitivity, restore, probe, and removal checks. |
| FR-017/S5 | FR-017 | S5 | Live | `[FR-017/S5] SQL VM governed software delivery` | FR-011, FR-014/S5, FR-015/S5 | One curated community tool and one custom artifact pass version, integrity, privilege, install, verification, and removal checks. |
| FR-035/S5 | FR-035 | S5 | Live | `[FR-035/S5] SQL guest operations` | FR-035/S4, FR-014/S5 | SQL-related guest changes remain narrow, idempotent, redacted, and verified by postconditions. |
| FR-034/S5 | FR-034 | S5 | Live | `[FR-034/S5] Useful SQL VM lab evidence` | FR-034/S4, FR-014/S5, FR-015/S5, FR-016/S5, FR-017/S5 | Data, software, storage, SQL readiness, removal, and retained-resource evidence render as one coherent report. |
| FR-036/S5 | FR-036 | S5 | Live | `[FR-036/S5] Useful SQL VM solution pack` | FR-014/S5, FR-015/S5, FR-016/S5, FR-017/S5, FR-034/S5, FR-035/S5, FR-043/S4, FR-044/S4 | One YAML definition composes the approved VM, storage, data, tool, Key Vault, Bastion, probe, and teardown paths. |
| FR-037/S6 | FR-037 | S6 | Release | `[FR-037/S6] Remote state and execution coordination` | FR-006/S4, FR-008/S4, FR-034/S5 | Encrypted remote state, OIDC or managed identity, locking, fencing, duplicate-trigger refusal, retention, and resumable handoff pass release tests. |
| FR-006/S6 | FR-006 | S6 | Release | `[FR-006/S6] Release run state, retries, and audit` | FR-006/S4, FR-037/S6 | Local and remote state boundaries, interrupted resume, retries, audit retention, and recovery evidence pass three clean lifecycles. |
| FR-007/S6 | FR-007 | S6 | Release | `[FR-007/S6] SQL VM assessment and decision report` | FR-014/S5, FR-034/S5 | Applicable Azure Arc and SSMS migration-component evidence is distinct from migration and can revise, but never silently mutate, a plan. |
| FR-008/S6 | FR-008 | S6 | Release | `[FR-008/S6] SQL VM release security evidence` | FR-008/S4, FR-037/S6 | Identity, network, secret, sensitive-data, CI, vulnerability, approval, and exception evidence has no unresolved critical or high finding. |
| FR-009/S6 | FR-009 | S6 | Release | `[FR-009/S6] SQL VM release cost and lifecycle evidence` | FR-009/S4, FR-037/S6 | Three clean lifecycles prove estimates, budget and TTL policy, shutdown, teardown confirmation, orphan queries, and post-delete billing evidence. |
| FR-013/S6 | FR-013 | S6 | Release | `[FR-013/S6] SQL VM release validation` | FR-013/S4, FR-037/S6 | Protected live lanes cover resume, duplicate triggers, drift, failure, teardown, cleanup, and retained-resource reporting. |
| FR-014/S6 | FR-014 | S6 | Release | `[FR-014/S6] SQL VM provider release` | FR-014/S5, FR-006/S6, FR-008/S6, FR-009/S6, FR-013/S6, FR-037/S6 | The advertised SQL VM support matrix passes three complete YAML-to-cleanup lifecycles and publishes its limitations. |
| FR-015/S6 | FR-015 | S6 | Release | `[FR-015/S6] Storage capability release` | FR-015/S5, FR-037/S6 | Advertised storage paths pass retry, drift, reuse, ownership, retention, teardown, and cleanup release evidence. |
| FR-016/S6 | FR-016 | S6 | Release | `[FR-016/S6] Data onboarding release` | FR-016/S5, FR-037/S6 | Advertised sources pass repeatable acquisition, validation, load, sensitivity, failure, and removal release evidence. |
| FR-017/S6 | FR-017 | S6 | Release | `[FR-017/S6] Software delivery release` | FR-017/S5, FR-037/S6 | Advertised sources pass repeatable resolution, integrity, install, verification, privilege, failure, and removal release evidence. |
| FR-033/S6 | FR-033 | S6 | Release | `[FR-033/S6] PowerShell engine release conformance` | FR-033/S4, FR-037/S6 | Apply, resume, drift, partial failure, teardown, stable IDs, and capability refusal pass the release conformance suite. |
| FR-034/S6 | FR-034 | S6 | Release | `[FR-034/S6] Release evidence framework` | FR-034/S5, FR-037/S6 | Signed release evidence covers plan through cleanup and remains complete, redacted, versioned, and machine-readable. |
| FR-035/S6 | FR-035 | S6 | Release | `[FR-035/S6] Windows guest operations release` | FR-035/S5, FR-037/S6 | Advertised guest operations pass repeatability, restart, patch, least-privilege, redaction, failure, and removal tests. |
| FR-043/S6 | FR-043 | S6 | Release | `[FR-043/S6] Key Vault capability release` | FR-043/S4, FR-037/S6 | Advertised create and reuse paths pass drift, recovery, retention, ownership, teardown, and no-secret-leakage release evidence. |
| FR-044/S6 | FR-044 | S6 | Release | `[FR-044/S6] Bastion capability release` | FR-044/S4, FR-037/S6 | Advertised tiers and reuse paths pass access, cost, drift, recovery, teardown, and no-public-IP release evidence. |
| FR-036/S6 | FR-036 | S6 | Release | `[FR-036/S6] First SQL VM solution-pack release` | FR-007/S6, FR-014/S6, FR-015/S6, FR-016/S6, FR-017/S6, FR-033/S6, FR-034/S6, FR-035/S6, FR-043/S6, FR-044/S6 | The signed pack, docs, support matrix, and three clean end-to-end lifecycles satisfy the complete S6 Release gate. |

## Conditional And Pack Slices

These children prevent a capability needed by one variant from blocking every
variant of its parent epic.

| Child key | Parent | Segment | Gate | Required title | Technical dependencies | Child acceptance delta |
| --- | --- | --- | --- | --- | --- | --- |
| FR-039/S11-managed | FR-039 | S11 | Release | `[FR-039/S11-managed] PostgreSQL on a non-VM container host` | FR-041, FR-043 | One named non-VM host passes image, secret, network, storage, backup, upgrade, cost, teardown, and cleanup tests; FR-044 is not a dependency. |
| FR-039/S11-vm | FR-039 | S11 | Release | `[FR-039/S11-vm] PostgreSQL on a VM-hosted container` | FR-038, FR-040, FR-041, FR-043, FR-044 | The host additionally passes the Bastion-first `administrativeAccessDecision`, Linux guest, patch, shutdown, and VM cleanup gates. |
| FR-021/S16-fuam | FR-021 | S16 | Live | `[FR-021/S16-fuam] Fabric item prerequisites for FUAM` | FR-020, FR-034, FR-043 | The exact versioned Fabric item types required by the accepted FUAM contract can be created or reused, probed, ownership-classified, and removed independently. |
| FR-021/S16-rayfin | FR-021 | S16 | Live | `[FR-021/S16-rayfin] Fabric item prerequisites for Rayfin` | FR-020, FR-034, FR-043 | The exact versioned Fabric item types required by the accepted Rayfin contract can be created or reused, probed, ownership-classified, and removed independently. |
| FR-021/S16-tmdl | FR-021 | S16 | Live | `[FR-021/S16-tmdl] Fabric item prerequisites for TMDL` | FR-020, FR-034, FR-043 | The exact versioned Fabric item types required by the accepted TMDL contract can be created or reused, probed, ownership-classified, and removed independently. |
| FR-024/S18-fuam | FR-024 | S18 | Release | `[FR-024/S18-fuam] FUAM solution pack` | FR-020, FR-021/S16-fuam, FR-034, FR-043; FR-023 conditional on accepted pack design | FUAM-specific prerequisites, existing-installation detection, user-confirmed salvage or changes, probes, recovery, ownership, and teardown pass independently. |
| FR-024/S18-rayfin | FR-024 | S18 | Release | `[FR-024/S18-rayfin] Rayfin solution pack` | FR-020, FR-021/S16-rayfin, FR-034, FR-043; FR-023 conditional on accepted pack design | Rayfin-specific provenance, prerequisites, secret-store decision, probes, recovery, ownership, and teardown pass independently. |
| FR-024/S18-tmdl | FR-024 | S18 | Release | `[FR-024/S18-tmdl] TMDL solution pack` | FR-020, FR-021/S16-tmdl, FR-034, FR-043; FR-023 conditional on accepted pack design | TMDL-specific provenance, prerequisites, source-control behavior, probes, recovery, ownership, and teardown pass independently. |
| FR-030/S21-vm | FR-030 | S21 | Release | `[FR-030/S21-vm] SQL Server on a Linux Azure VM` | FR-040, FR-043, FR-044 | The Linux VM variant passes licensing, package integrity, secret-store, Bastion-first access, SQL setup, restore, patch, cost, teardown, and cleanup evidence. |
| FR-030/S21-vm-container | FR-030 | S21 | Release | `[FR-030/S21-vm-container] SQL Server in a VM-hosted container` | FR-040, FR-041, FR-043, FR-044 | The VM-hosted container variant passes image, persistence, secret-store, Bastion-first access, patch or replacement, cost, teardown, and cleanup evidence. |
| FR-030/S21-managed-container | FR-030 | S21 | Release | `[FR-030/S21-managed-container] SQL Server on a non-VM container host` | FR-041, FR-043 | One named non-VM host passes licensing, image, secret, persistence, replacement, cost, teardown, and cleanup tests; FR-044 is not a dependency. |

## Verification

After mutation, verify:

1. every child key appears exactly once;
2. every child has exactly one native parent;
3. every technical dependency resolves to an epic or child key;
4. no dependency cycle exists;
5. no S4 child depends on FR-037 or another S6-only child;
6. non-VM container children do not depend on FR-044;
7. VM and VM-hosted-container children do depend on FR-044;
8. Fabric packs depend on FR-023 only when their accepted design uses CI/CD;
9. all children inherit the correct segment gate and start in `Backlog`.
