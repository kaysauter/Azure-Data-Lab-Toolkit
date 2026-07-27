# Delivery Segments

This document is the authoritative delivery plan for Azure Data Lab Toolkit. It
defines implementation order, segment exit criteria, and quality gates. It does
not claim that any segment is implemented or released.

> **Current state:** The repository contains architecture, documentation, a
> pitch deck, and backlog artifacts. It has no installable module, deployable
> cmdlets, released providers, or production-ready behavior.

## How To Read The Plan

Delivery sequence and technical dependency are deliberately separate:

- **Delivery sequence** identifies the next product outcome on which the project
  will focus.
- **Technical dependencies** are direct prerequisites recorded in
  [`FEATURE_REQUESTS.md`](../FEATURE_REQUESTS.md).
- A later segment may conduct research or prepare deterministic contract
  fixtures early, but it does not become the active delivery focus before the
  preceding segment passes its exit gate unless the plan explicitly declares a
  parallel lane.
- Bicep and Terraform are scheduled before Fabric, but neither engine depends on
  Fabric and Terraform does not depend technically on Bicep.
- General Git and CI/CD adapters are scheduled before Fabric. Fabric CI/CD
  remains a separate Fabric-specific segment because it depends on Fabric items
  and the Git adapters that Fabric actually supports.
- After S16, S17 Fabric CI/CD and S18 solution packs are parallel conditional
  lanes. A pack waits for S17 only when its accepted design uses Fabric CI/CD.

The architecture keeps seven parts distinct throughout every segment: **Core**,
**target providers**, **capability modules**, **catalog sources**, **solution
packs**, **probes**, and **deployment engines**.

## Quality Gates

| Gate | Required evidence |
| --- | --- |
| **Contract (C)** | Versioned schemas and interfaces; deterministic offline tests and fixtures; no unexpected cloud calls; secret references rather than values; explicit security, cost, ownership, and teardown intent; documented unsupported capabilities. |
| **Live (L)** | Contract gate plus an isolated deployment; positive and negative probes; identity, network, secret-store, vulnerability, cost, TTL or shutdown, failure, teardown, orphan, and still-billable-resource evidence. |
| **Release (R)** | Live gate plus three consecutive clean lifecycles; interrupted resume; duplicate-trigger locking and fencing; drift tests; zero unresolved critical or high security findings; signed package or artifacts; current documentation and support matrix. |

A segment cannot pass by documentation or a successful create command alone.
Evidence must cover useful behavior and cleanup.

## Cross-Cutting Decisions

Every target provider and solution pack must emit a `secretStoreDecision` with
one of these values:

- `deploy-key-vault`;
- `reuse-key-vault`;
- `approved-external-store`;
- `not-applicable`, with a recorded rationale.

The decision appears in Plan, WhatIf, cost, security, ownership, and teardown
evidence. YAML, normalized plans, state, logs, and reports contain secret
references only, never secret values.

Every Azure VM must also emit an `administrativeAccessDecision`. The default is
Azure Bastion with no public IP. Reuse or opt-out requires a rationale and
approval and remains visible in Plan, WhatIf, cost, and security evidence.
VM-hosted containers inherit this rule; managed container platforms do not.
Key Vault and Bastion remain capability modules rather than provider internals.

Local state is sufficient for protected interactive runs. CI, webhook, or other
unattended mutation requires a remote backend with locking, fencing, resumable
state, and short-lived OIDC or managed-identity authentication.

Assessment is a release requirement where applicable. It is not a prerequisite
for planning, security policy, cost estimation, or an initial deployment.

## Segment Plan

| Segment | User-visible outcome | Included feature work | Entry criteria | Exit criteria | Gate | Explicitly deferred |
| --- | --- | --- | --- | --- | --- | --- |
| **S0 Architecture and contract spine** | A decision-complete product model and delivery graph that contributors can implement without inventing new boundaries. | FR-001, FR-004; design records for FR-033 through FR-044. | Repository scaffold and latest product vision are available. | Seven-part architecture, status vocabulary, technical dependencies, segment order, security decisions, engine boundary, state boundary, and quality gates are accepted and internally consistent. | C | Runtime implementation, Azure mutation, provider claims. |
| **S1 Installable offline core** | Users can install the module, validate versioned YAML, resolve flags and templates, produce deterministic Plan output, and render HTML without Azure access. | FR-002, FR-003, FR-005, FR-006 local-state slice, FR-008 policy slice, FR-009 offline slice, FR-010 template slice, FR-011 metadata slice, FR-013 contract slice, FR-033 offline/export slice, FR-034. | S0 accepted. | Module imports on supported PowerShell versions; schemas reject invalid input; identical inputs produce the same canonical plan hash; provenance, secret-store and access decisions, ownership, cost intent, and teardown intent are represented; local state and evidence fixtures pass Contract tests. | C | Azure authentication or mutation, polished TUI, live prices, live provider behavior. |
| **S2 GitHub engineering CI baseline** | Every change to the toolkit receives repeatable build, test, documentation, dependency, secret, and vulnerability checks. | FR-012 and the CI-facing test slice of FR-013. | S1 contracts and package layout are stable enough to test. | GitHub pull requests run pinned PowerShell, schema, Pester, analysis, docs, link, dependency, secret, and vulnerability checks without cloud credentials; release and live lanes are defined but protected. | C | User-facing Git providers, unapproved Azure deployment, broad live matrices. |
| **S3 Read-only SQL VM plan** | A user can run Plan, WhatIf, and CostEstimate for one secure SQL VM profile without changing Azure. | Read-only slices of FR-008, FR-009, FR-013, FR-014, FR-033, FR-034, FR-043, and FR-044. | S1 and S2 pass; a permitted test subscription exists for authenticated reads. | Offline Plan and Azure-aware WhatIf agree on stable IDs; `secretStoreDecision` and `administrativeAccessDecision` are explicit; default access is Bastion with no public IP; prices include source, timestamp, currency, confidence, and unknowns; denied access is not treated as absence; no Azure mutation occurs. | C | VM creation, guest operations, SQL configuration, data and tools. |
| **S4 Secure Azure VM canary** | A user can deploy, access, stop, resume, and remove a private Windows VM through the guarded PowerShell path. | Mutating slices of FR-006, FR-008, FR-009, FR-013, FR-014, FR-033, FR-034, FR-035, FR-043, and FR-044. | S3 plan is approved; isolated subscription, quota, interactive identity, budget, and cleanup owner are available. | Private VM, managed identity, Key Vault decision, Bastion decision, protected local run state, interactive resume, probes, shutdown, teardown preview, confirmed deletion, orphan query, and still-billable-resource report pass in an isolated run. | L | Remote unattended execution, SQL readiness, sample data, community tools, broad image or region support. |
| **S5 Useful SQL VM data lab** | The VM is SQL-ready and can receive governed sample or private data and approved tools. | FR-015, FR-016, FR-017, FR-034, FR-035, FR-036, plus SQL and guest slices of FR-014. | S4 passes and the catalog trust policy is accepted. | SQL connectivity passes; backup staging and restore work; one Microsoft sample, one curated community tool, and one custom local or URL artifact pass provenance, integrity, license, sensitivity, install or restore, verification, and removal probes; optional Azure Files mounting is evidenced. | L | Broad catalogs, automatic migration, production workloads, third-party executable extensions. |
| **S6 First SQL VM release** | SQL Server on Azure VM has a reusable, supported lifecycle from YAML through cleanup proof. | Remaining FR-007 through FR-017 work, completed FR-033 through FR-037, FR-043, and FR-044. | S5 passes and release identities, remote state, signing, and support policy are ready. | Applicable assessment, GitHub OIDC deployment, remote locking and fencing, interrupted resume, duplicate-trigger handling, drift, reports, three clean lifecycles, signed package, current docs, and zero unresolved critical or high findings pass the Release gate. | R | Other target providers, Bicep, Terraform, autonomous approval, automatic migration. |
| **S7 Azure SQL Database** | Users can create or reuse a secure Azure SQL Database lab, load approved data, verify it, and remove owned resources. | FR-018 plus applicable FR-007 through FR-013, FR-015, FR-016, FR-033, FR-034, FR-037, and FR-043 slices. | S6 passes; provider permissions, private endpoint, DNS, Entra, and quota contracts are accepted. | Create and reuse paths, Entra authentication, private access, `secretStoreDecision`, optional sample load, cost, probes, drift, teardown, and cleanup pass the Release gate. | R | SQL MI behavior, automatic migration, parity for every engine. |
| **S8 Azure SQL Managed Instance** | Users can build a private SQL MI lab with realistic duration, quota, networking, restore, and cleanup expectations. | FR-019 plus applicable assessment, storage, data, probe, state, engine, and FR-043 work. | S7 passes; subnet, DNS, quota, regional availability, long-running operation, and pricing contracts are accepted. | Private connectivity, Entra and SQL access boundaries, `secretStoreDecision`, restore path, deployment-time and cost evidence, interruption recovery, teardown, and cleanup pass the Release gate. | R | Automatic migration and unsupported service operations. |
| **S9 Azure Database for PostgreSQL** | Users can create or reuse a secure PostgreSQL Flexible Server lab and validate dump or restore workflows. | FR-025 plus applicable FR-007 through FR-013, FR-015, FR-016, FR-033, FR-034, FR-037, and FR-043 slices. | S8 passes; PostgreSQL identity, network, version, extension, and backup contracts are accepted. | Private access, supported Entra or PostgreSQL authentication, `secretStoreDecision`, compatibility evidence, sample or dump/restore, probes, cost, drift, teardown, and cleanup pass the Release gate. | R | PostgreSQL VM, containers, Kubernetes, every extension or version. |
| **S10 PostgreSQL on Azure VM** | Users can run a native PostgreSQL lab on a secured Linux VM. | FR-038, FR-040, and applicable FR-015 through FR-017, FR-033, FR-034, FR-037, FR-043, and FR-044 work. | S9 passes; Linux guest, package source, version, patch, and access contracts are accepted. | Private Linux VM, managed identity, `secretStoreDecision`, Bastion-first `administrativeAccessDecision`, PostgreSQL installation, data load or restore, probes, patch evidence, shutdown, teardown, and cleanup pass the Release gate. | R | Containers, SQL Server on Linux, Kubernetes, broad distributions. |
| **S11 Containerized PostgreSQL** | Users can run PostgreSQL through an explicitly supported container-host adapter. | FR-039, FR-041, and applicable FR-015 through FR-017, FR-033, FR-034, FR-037, and FR-043 work; FR-040 and FR-044 when VM-hosted. | S10 passes; one container host, image provenance, persistence, network, and update contract are accepted. | The declared host passes image integrity, `secretStoreDecision`, storage, backup/restore, probes, upgrade or replacement, cost, teardown, and cleanup. A VM-hosted adapter also passes the Bastion-first VM gate. | R | Kubernetes and any container host not named in the support matrix. |
| **S12 Bicep deployment engine** | Users can select Bicep for supported stable plans while retaining toolkit approvals and evidence. | FR-028 plus conformance fixtures for stable target capabilities. | S11 passes in delivery order; normalized plan, state, evidence, and at least the SQL VM and Azure SQL Database provider contracts are stable. | Deterministic build, Azure what-if attachment, export, apply, partial-failure evidence, stable-ID mapping, teardown, and conformance against advertised capabilities pass the Release gate. | R | Terraform implementation and Fabric IaC parity. |
| **S13 Terraform deployment engine** | Users can select Terraform with an explicit, protected engine-state boundary. | FR-029 plus independent conformance fixtures for stable target capabilities. | S12 passes in delivery order; Terraform version, licensing, backend, locking, import, and state-protection policy are accepted. | Format, validate, saved-plan attachment, apply, drift, import boundary, secure remote state, destroy, stable-ID mapping, and capability conformance pass the Release gate. | R | Fabric IaC parity and any assumption that Terraform depends technically on Bicep. |
| **S14 General Git and CI/CD providers** | Users can express one validate-plan-approve-deploy-probe-report-teardown intent across supported Git and pipeline systems. | FR-042 and FR-027. | S13 passes in delivery order; remote state and approval contracts are released. | GitHub reference workflows and each advertised Azure DevOps, GitLab, Gitea, or Forgejo adapter pass contract tests; supported hosted adapters pass protected live and release lanes; capability differences are explicit. | R | Fabric-specific CI/CD; hosting a Git service unless a separate solution pack passes its own gate. |
| **S15 Fabric guidance and workspaces** | Users receive guided Fabric target choices and can validate or create permitted capacity and workspace resources. | FR-020 plus applicable core, engine, probe, state, cost, and FR-043 work. | S14 passes; tenant, licensing, capacity, workspace, role, API, and unsupported-operation contracts are accepted. | SQL database versus Warehouse versus Lakehouse guidance is evidenced; prerequisite validation, workspace lifecycle, `secretStoreDecision`, cost, roles, probes, and cleanup pass the Live gate. | L | Fabric items, shortcuts, CI/CD, and unproven IaC parity. |
| **S16 Fabric items and shortcuts** | Users can create supported Fabric items and understand shortcut ownership, access, freshness, and deletion. | FR-021, FR-022, FR-034, FR-043, and applicable storage work. | S15 passes and a versioned Fabric item support matrix exists. | Each advertised item and shortcut type passes dependency, identity, data-location, freshness, probe, failure, ownership, teardown, and cleanup tests. Unsupported types fail explicitly. | L | Fabric CI/CD and solution packs. |
| **S17 Fabric CI/CD** | Users can use a documented, supported Fabric delivery path without an unsupported IaC claim. | FR-023 plus the Fabric items and Git adapters actually supported by Fabric. | S16 passes; current Fabric Git, deployment-pipeline, API, and item support matrices are verified. | Supported Git integration, staged workspaces, deployment pipelines or APIs, parameters, approvals, probes, rollback limits, and metadata-versus-data evidence pass the Release gate. | R | Git providers Fabric does not support and complete PowerShell/Bicep/Terraform parity. |
| **S18 Fabric solution-pack lane** | Users can run separately versioned FUAM, Rayfin, and TMDL demonstrations with honest prerequisites and ownership. | FR-024 split into one sub-issue per solution pack, plus FR-034 and FR-043. | S16 has passed and the exact Fabric workspace or item children required by that pack have passed; S17 is required only when the accepted pack design uses Fabric CI/CD. | Each advertised pack independently passes provenance, licensing, `secretStoreDecision`, prerequisites, existing-installation detection, user-confirmed changes, probes, recovery, teardown, and current documentation. | R | Treating all packs as one dependency chain or requiring complete Fabric CI/CD when a pack does not use it. |
| **S19 Azure Databricks** | Users can create or reuse a governed Databricks lab with storage, compute, notebooks, cost, and cleanup evidence. | FR-026 plus applicable FR-015, FR-016, FR-034, FR-037, and FR-043 work. | S18 passes in delivery order; workspace, Unity Catalog, identity, network, compute, and storage contracts are accepted. | Workspace and Unity Catalog path, ADLS, notebook, compute policy, `secretStoreDecision`, cost, probes, termination, teardown, and cleanup pass the Release gate. | R | Unbounded compute, unsupported clouds, later target providers. |
| **S20 Later data providers** | Additional platforms are introduced one at a time without turning FR-032 into a catch-all implementation. | FR-032 split into one child epic per candidate such as Cosmos DB, Azure Data Explorer, Event Hubs, MySQL, or MariaDB. | S19 passes in delivery order and a provider-specific architecture decision is accepted. | Each advertised provider independently defines its target, data, identity, `secretStoreDecision`, cost, probes, lifecycle, and engine support and passes its own Release gate. | R per provider | Any unscoped “support everything” claim; providers without an accepted use case. |
| **S21 SQL Server on Linux and containers** | Users can run separately supported SQL Server Linux VM and container labs. | Revised FR-030 plus FR-040, FR-041, FR-043, FR-044 for VM variants, and applicable catalog and data work. | S20 follows in delivery order; Linux and container contracts are mature from S10 and S11. | Each advertised VM or container variant independently passes licensing, image or package integrity, `secretStoreDecision`, Bastion-first VM access when applicable, SQL setup, restore, tools, probes, patch or replacement, cost, teardown, and cleanup. | R per variant | PostgreSQL, which is delivered in S9 through S11; Kubernetes. |
| **S22 Kubernetes** | Users can build explicitly supported AKS or Kubernetes data-lab scenarios with repeatable storage, secrets, isolation, cost, and cleanup. | FR-031 plus mature container, probe, state, secret-store, and provider-specific work. | S21 passes in delivery order; the required container workload has already passed a Release gate and a Kubernetes architecture decision is accepted. | Cluster or namespace ownership, workload identity, `secretStoreDecision`, policy, storage, network, probes, upgrades, cost, teardown, orphan checks, and cleanup pass the Release gate. | R | Unlisted operators, distributions, or production platform guarantees. |

## Release Discipline

The first target after S6 may not inherit an **Available** label from SQL VM.
Every provider, capability, engine, adapter, and solution pack must publish its
own support matrix and evidence. Likewise, a release of one PostgreSQL or
container variant does not imply that every version, host, Linux distribution,
or Kubernetes operator is supported.

GitHub issues remain the implementation epics. Sub-issues carry segment slices
when an epic spans more than one segment. Project fields show delivery sequence;
native issue dependencies show only technical prerequisites.
