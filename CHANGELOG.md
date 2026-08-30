# Changelog

This file records notable changes to Azure Data Lab Toolkit. The project has not published its first release.

## Unreleased

### Added

- Initial architecture and repository scaffold.
- Dependency-ordered feature-request catalog.
- Public GitHub issue backlog and project roadmap.
- Astro/Starlight documentation site with dark and light themes.
- Slidev pitch deck.
- GitHub Pages deployment workflow and production-build link validation.
- Architecture, security, licensing, cost, assessment, Fabric, catalog, testing, CI/CD, and community guidance.
- Architecture status model covering Current, Committed design, Backlog, Exploratory, Deferred, and Available behavior.
- Clear Core extension boundaries for target providers, capability modules, catalog sources, solution packs, deployment engines, and probes.
- Documented distinction between offline `-Plan` resolution and Azure-aware, non-mutating `-WhatIf` comparison.
- Roadmap metadata separating technical prerequisites from delivery sequencing.
- Authoritative S0-S22 delivery segments with Contract, Live, and Release gates.
- First-class PowerShell engine, probe/evidence, guest-operations, SQL VM
  solution-pack, remote-state, PostgreSQL VM/container, Git/CI, Key Vault, and
  Bastion feature epics.
- Installable `AzureDataLabToolkit` 0.1.0-alpha1 PowerShell module scaffold for
  PowerShell 7.6.
- Strict, versioned YAML configuration validation with guarded parsing,
  schema defaults, templates, YAML, and explicit flag precedence.
- Deterministic normalized SQL VM plans with RFC 8785 serialization, SHA-256
  hashes, field-level provenance, stable semantic IDs, structured unverified
  facts, ownership intent, idempotency, approvals, and teardown intent.
- Execution-intent hashes that bind action idempotency keys to the toolkit
  version, active contributor contracts and implementations, selected engine
  contract, catalog revisions, resolved configuration, and catalog selections.
- Public offline commands for validation, planning, template and catalog
  discovery, support-matrix inspection, and JSON, Markdown, or HTML export.
- Azure sign-in through `Connect-AzureDataLabAccount` with process-scoped
  context, disabled autosave, secure-string ARM tokens, and identity plus
  token-cache re-verification on every Azure call.
- A fail-closed Azure command boundary allowlisting four modules and seventeen
  cmdlets with per-command parameter-shape enforcement against a locked module
  manifest.
- Live resolution and native ARM `-WhatIf` reconciliation via
  `Test-AzureDataLabWhatIf`.
- A PowerShell deployment engine that compiles an approved plan to ARM,
  deterministically recompiles and byte-compares it before submission, and
  applies it through `Start-AzureDataLabDeployment`, with resume and reconcile
  paths.
- Post-deployment readiness probing through `Test-AzureDataLabDeployment`.
- Approval-gated teardown through `Start-AzureDataLabTeardown`: typed approval
  phrase, fresh-inventory hash match, mutation lease, and etag plus
  observation-fingerprint re-verification immediately before each delete.
- Local run state, evidence, and hash-chained execution records with owner-only
  filesystem permissions asserted on read and write.
- A per-file SHA-256 module script lock with a closed-world check, a runtime
  dependency lock, a build-tool lock, an SPDX 2.3 SBOM, and GitHub build
  provenance and SBOM attestations on release.
- A cross-platform `module-ci` workflow running analysis, tests, build, and
  packaging on Linux, Windows, and macOS.
- Explicit SQL VM support matrix that fails closed for unsupported engines,
  platforms, SQL versions, security controls, secret stores, access choices,
  Bastion tiers, and backup-share modes.
- Fixed secure SQL VM alpha profile with typed desired resource properties,
  explicit Azure API versions, a shared Compute and SQL IaaS resource name,
  Trusted Launch, Secure Boot, vTPM, host encryption, managed identity,
  private networking, disk layout, patch intent, and SQL IaaS least-privilege
  settings.
- Strict SQL IaaS desired-state validation aligned with the 2023-10-01 Azure
  resource contract, including the full underlying VM ARM resource ID.
- Existing disk-encryption-set flag and reused-resource contract that wires
  customer-managed encryption into every planned managed disk and requires
  live compatibility verification.
- Registered networking, Key Vault, Bastion, and Azure Files capability
  contributors plus validated contributor dependencies and cycle detection.
- Private Key Vault plan with RBAC, purge protection, public access disabled,
  private endpoint, private DNS VNet link, and an explicit no-plaintext VM
  administrator secret gate.
- Bastion Basic plan with `/26` subnet, Standard static Bastion public IP, no
  VM public IP, and structured handling for reuse or opt-out.
- Metadata-only catalogs with exact versions, source, licensing, attribution,
  compatibility, integrity policy, privilege, sensitivity, and probe metadata.
- Optional Azure Files backup-share plan with SMB OAuth, disabled shared-key
  access, private endpoint and DNS VNet link, explicit VM managed-identity
  role assignment, drive-mount preparation, and an explicit blocker for the
  not-yet-governed `AzFilesSmbMIClient` guest path.
- Manual SQL VM backup-restore solution pack with a derived pinned dbatools
  dependency, separate offline rendering and future remote staging, preview
  by default, explicit execution, and database replacement refused.
- Structured policy findings with stable IDs, explicit blockers, targeted
  acknowledgements, and a requirement to bind future acknowledgement to the
  exact plan hash.
- Engine, provider, capability, solution-pack, configuration, plan, and catalog
  contract metadata in every normalized plan.
- Cross-platform GitHub pull-request checks and a local build pipeline covering
  parsing, PSScriptAnalyzer, 76 Pester tests, an enforced 80% command-coverage
  floor, clean module import, and ZIP packaging.
- Scope-aware `offline`, `azure`, and `guest` action contracts with
  corresponding preconditions and reconciliation state sources.
- A checked minimal SQL VM plan hash fixture that all CI operating systems must
  reproduce.
- Strict contributor-contract schemas and exact typed ARM ID validation for
  reused Key Vault, Bastion, resource-group, and disk-encryption-set resources.
- Baseline and ADR 0001 documenting the offline foundation and extension
  boundaries.
- Offline-alpha getting-started documentation with explicit password-generation
  and shell-output warnings.

### Changed

- Corrected the relationship to Azure SQLVM Toolkit: it is an unfinished predecessor and source of lessons.
- Aligned the first assessment direction with Azure Arc and the migration component in SQL Server Management Studio.
- Clarified that architecture is committed design, roadmap entries are not shipped behavior, and only verified release functionality can be marked Available.
- Reordered delivery so managed, VM, and containerized PostgreSQL, followed by
  Bicep, Terraform, and general Git/CI adapters, precede Microsoft Fabric.
- Required an explicit secret-store decision for every target and solution pack
  and a Bastion-first administrative-access decision for every Azure VM.
- Separated the toolkit repository's own CI from user-facing Git and pipeline
  integrations, and separated technical prerequisites from scheduled order.
- Reclassified S1 from wholly unimplemented to implemented in the repository,
  including run state, evidence, WhatIf, live resolution, and deployment. No
  segment has passed its Live or Release gate.
- Replaced warning-only security downgrades with structured acknowledgement or
  resolve-before-deploy findings.
- Made a valid offline plan distinct from an executable plan: unresolved
  marketplace image versions, external secure inputs, and catalog integrity
  remain explicit blockers.
- Separated local script rendering from future remote staging dependencies for
  Azure Files mounting and manual restore.
- Expanded Markdown and HTML exports with desired properties, external resource
  IDs, teardown intent, action dependencies and postconditions, RBAC details,
  plus exact blocker and acknowledgement IDs.
- Made Key Vault diagnostic settings and the Azure Files SMB OAuth guest client
  explicit deployment blockers until their governed implementations exist.
- Required an exact resource-group ARM ID for reuse and rejected subscription,
  name, or create-intent contradictions before planning.
- Preserved a deterministic 12-character hash suffix for globally named
  storage accounts and Key Vaults when a long lab name is shortened.
- Scoped deterministic global names to normalized subscription and resource
  group identities so independent labs can coexist without case-only drift.
- Required exact imports of the pinned Pester, PSScriptAnalyzer, and
  powershell-yaml build dependencies.
- Pinned every third-party GitHub Action in module and documentation workflows
  to an immutable commit SHA.
- Required a rationale for reused Bastion and documented the shipped
  preview-first SQL VM backup-restore solution-pack contract.
- Rejected contradictory Bastion resource IDs when administrative access is
  explicitly opted out.

### Current limitations

- The module is an unreleased alpha and its public API may still change.
- Azure authentication, live `-WhatIf`, price lookup, the PowerShell deployment
  engine, post-deployment probes, local run state, resume, and teardown are
  implemented and test-covered, but no release has been published and none has
  been exercised against a live subscription.
- `Start-AzureDataLabDeployment` creates real Azure resources and
  `Start-AzureDataLabTeardown` deletes them. Treat the blast radius as real.
- Guest software installation and database restore remain preview-first and
  user-executed; the toolkit does not perform them.
- Selected catalog artifacts with unresolved integrity metadata block
  deployment.
- Cost estimation requires network access to `prices.azure.com`; there is no
  offline price cache.
- Not production-ready.
