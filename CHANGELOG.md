# Changelog

This file records notable changes to Azure Data Lab Toolkit. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

## [0.1.0-alpha1] - 2026-10-12

The first alpha prerelease. Nothing in it has ever been executed against live
Azure; see the [release notes](release-notes/0.1.0-alpha1.md).

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
- Deterministic normalized SQL VM plans with RFC 8785-style serialization, SHA-256
  hashes, field-level provenance, stable semantic IDs, structured unverified
  facts, ownership intent, idempotency, approvals, and teardown intent.
- Execution-intent hashes that bind action idempotency keys to the toolkit
  version, active contributor contracts and implementations, selected engine
  contract, catalog revisions, resolved configuration, and catalog selections.
- Public offline commands for validation, planning, template and catalog
  discovery, support-matrix inspection, JSON, Markdown, or HTML export, and an
  offline browser-based YAML configuration wizard
  (`Start-AzureDataLabConfigurationWizard`, ADR 0006).
- Azure sign-in through `Connect-AzureDataLabAccount` with process-scoped
  context, disabled autosave, secure-string ARM tokens, and identity plus
  token-cache re-verification on every Azure call outside sign-in and context
  management.
- A fail-closed Azure command boundary allowlisting four modules and nineteen
  commands, each of which must be exported by its locked module manifest, with
  exact parameter-shape checks on nine of them, including the only two that
  change Azure resources (`New-AzDeployment`, `Remove-AzResource`) and
  `Get-AzAccessToken`; the other ten are not yet clamped.
- Live resolution through `Resolve-AzureDataLabPlan` and native ARM What-If
  reconciliation through `Test-AzureDataLabWhatIf`, both run, with a live cost
  estimate and a teardown preview, by `Invoke-AzureDataLabPreflight`.
- The locked `sqlvm-first-canary/v1` deployment profile and the offline
  `Test-AzureDataLabDeploymentConfiguration` eligibility check. What-If
  reconciliation, deployment, probes, and teardown accept only configurations
  bound to that profile by ID and hash.
- A PowerShell deployment engine that compiles an approved plan to ARM,
  deterministically recompiles and byte-compares it before submission, and
  applies it through `Start-AzureDataLabDeployment`, with resume and reconcile
  paths.
- Post-deployment readiness probing through `Test-AzureDataLabDeployment`.
- Approval-gated teardown through `Start-AzureDataLabTeardown`: typed approval
  phrase, fresh-inventory hash match, mutation lease, and etag plus
  observation-fingerprint re-verification immediately before each delete.
- Local run state, evidence, and hash-chained execution records with owner-only
  filesystem permissions asserted on read and write. `New-AzureDataLabRun`
  creates a run and `Get-AzureDataLabRun` reads it back;
  `Get-AzureDataLabEvidence` reads and verifies an evidence artifact, and
  `Export-AzureDataLabEvidence` exports one as JSON, Markdown, or HTML.
- A per-file SHA-256 module script lock with a closed-world check, a runtime
  dependency lock, a build-tool lock, an SPDX 2.3 SBOM, and GitHub build
  provenance and SBOM attestations on release.
- A `build-provenance.json` file list in every packaged build. A packaged
  module refuses to authorize a deployment when its files no longer match it.
- A cross-platform `module-ci` workflow running analysis, tests, build, and
  packaging on Linux, Windows, and macOS.
- `Module checks` and `Docs checks` gate jobs, required on `main`. Both
  workflows run on every pull request, and each gate passes only when its
  checks passed or nothing they cover changed.
- A tag-driven release workflow. Pushing `v<version>` runs the Linux, Windows,
  and macOS checks. A read-only job then requires the tag to name the tested
  commit, be reachable from `main`, and match the manifest version; requires
  `release-notes/<version>.md` and exactly one changelog section for that
  version; checks the package's name, layout, and build provenance; and writes
  its SHA-256 file and an SPDX 2.3 SBOM. Only then does a job that runs no
  repository code attest the package's build provenance and SBOM, confirm the
  tag still names the verified commit, and publish the GitHub release with the
  package, its SHA-256 file, and the SBOM. A prerelease is never marked as the
  latest release.
- `Install-AzureDataLabToolkitDependencies.ps1`, shipped in the module, which
  installs the exact runtime dependency versions from the lock and checks
  their installed content against it.
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
- Manual SQL VM backup-restore solution-pack plan with a derived pinned
  dbatools dependency, separate offline rendering and future remote staging
  actions, preview by default, explicit execution, and database replacement
  refused. Nothing in this release renders, stages, or runs a restore script.
- Structured policy findings with stable IDs, explicit blockers, targeted
  acknowledgements, and a requirement to bind future acknowledgement to the
  exact plan hash.
- Engine, provider, capability, solution-pack, configuration, plan, and catalog
  contract metadata in every normalized plan.
- Cross-platform GitHub pull-request checks and a local build pipeline covering
  parsing, PSScriptAnalyzer, the Pester unit suite, an enforced 80%
  command-coverage floor, clean module import, and ZIP packaging.
- Scope-aware `offline`, `azure`, and `guest` action contracts with
  corresponding preconditions and reconciliation state sources.
- A checked minimal SQL VM plan hash fixture that all CI operating systems must
  reproduce.
- Strict contributor-contract schemas and exact typed ARM ID validation for
  reused Key Vault, Bastion, resource-group, and disk-encryption-set resources.
- Baseline and ADR 0001 documenting the offline foundation and extension
  boundaries, and accepted ADRs 0002-0006 documenting the SQL VM canary
  boundaries, the execution authorization envelope, remote state, locking, and
  fencing, the guest probe security boundary, and the browser configuration
  wizard, which supersedes ADR 0001's terminal UI boundary.
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
  including the local run-state and evidence contracts, and recorded that live
  resolution, WhatIf, and deployment from later segments are implemented and
  test-covered too. No segment has passed its Live or Release gate.
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
- Made Key Vault audit diagnostics a deployment blocker that only live
  resolution of a reused vault can clear, and the Azure Files SMB OAuth guest
  client a deployment blocker until its governed implementation exists.
- Required an exact resource-group ARM ID for reuse and rejected subscription,
  name, or create-intent contradictions before planning.
- Preserved a deterministic 12-character hash suffix for globally named
  storage accounts and Key Vaults when a long lab name is shortened.
- Scoped deterministic global names to normalized subscription and resource
  group identities so independent labs can coexist without case-only drift.
- Required exact imports of the pinned Pester and PSScriptAnalyzer build tools
  and of the pinned powershell-yaml runtime dependency.
- Pinned every third-party GitHub Action in module and documentation workflows
  to an immutable commit SHA.
- Required a rationale for reused Bastion and documented the shipped
  preview-first SQL VM backup-restore solution-pack contract.
- Rejected contradictory Bastion resource IDs when administrative access is
  explicitly opted out.
- `Export-AzureDataLabPlan` runs the full plan contract before exporting: the
  secret-free and plan-hash checks plus schema and structure validation and
  the intent-hash and idempotency-key bindings, so a report cannot look
  authoritative while being bound to nothing.
- Documented the runtime lock's `packageDigest` as recorded from the reviewed
  lock and never verified: nothing in the module downloads or hashes a
  package archive. The dependency installer no longer compares it, because
  that compared the lock with itself. `contentDigest`, measured from the
  installed files, is the verified guarantee.
- Made the module manifest the source of truth for the version. `build.ps1`
  derives the built-module directory and the package name from it, and a test
  fails unless the root module's version literal matches it. A version bump
  still edits the manifest, that literal in `AzureDataLabToolkit.psm1`, and
  `tests/Fixtures/sqlvm-minimal.plan.sha256`, because the plan hash binds the
  toolkit version.
- Made the build fail when a test file fails during discovery or an
  `AfterAll` block fails. Before, it failed only on a failed test, so a test
  file that broke during discovery could drop all its tests without failing
  the build.
- `SECURITY.md` routes vulnerability reports to GitHub private vulnerability
  reporting.

### Current limitations

- The module is an alpha prerelease and its public API may still change.
- Azure authentication, live `-WhatIf`, price lookup, the PowerShell deployment
  engine, post-deployment probes, local run state, resume, and teardown are
  implemented and test-covered, but none has been exercised against a live
  subscription.
- `Start-AzureDataLabDeployment` and `Resume-AzureDataLabDeployment` create
  real Azure resources, and `Start-AzureDataLabTeardown` and
  `Resume-AzureDataLabTeardown` delete them. Treat the blast radius as real.
- Deployment accepts only configurations bound to the `sqlvm-first-canary/v1`
  deployment profile. The default `sqlvm-secure` template, a new Key Vault, a
  generated password, a disk encryption set, catalog items, the backup share,
  the backup-restore pack, and reused Bastion or resource groups are planning
  only.
- Guest software installation and database restore remain preview-first and
  user-executed; the toolkit does not perform them.
- Selected catalog artifacts with unresolved integrity metadata block
  deployment.
- Cost estimation requires network access to `prices.azure.com`; there is no
  offline price cache.
- Not production-ready.

[0.1.0-alpha1]: https://github.com/kaysauter/Azure-Data-Lab-Toolkit/releases/tag/v0.1.0-alpha1
