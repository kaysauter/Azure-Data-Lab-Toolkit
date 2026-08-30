# ADR 0001: Offline PowerShell Foundation

- Status: Accepted; the terminal UI boundary is superseded by
  [ADR 0006](0006-browser-configuration-wizard.md)
- Date: 2026-07-27
- Delivery segment: S1

## Context

The first implementation must establish contracts that later PowerShell,
Bicep, and Terraform engines can share. Starting with Azure mutation would make
configuration precedence, ownership, idempotency, and plan stability difficult
to change safely.

## Decision

The first module slice is offline and targets PowerShell 7.6.

- The module imports without Az modules, Azure authentication, network access,
  SQL libraries, guest tooling, or a TUI runtime.
- YAML parsing uses the pinned `powershell-yaml` 0.4.12 dependency. A guarded
  representation-model pass rejects duplicate keys, aliases, explicit tags,
  multiple documents, oversized files, excessive nodes, and excessive depth.
- Configuration precedence is `schema defaults < template < YAML < flags`.
- Fully resolved configuration is validated against a versioned JSON schema.
  Every leaf records value, type, source, derivation, and validation status.
- The normalized plan uses stable semantic IDs, RFC 8785 serialization over the
  schema's integer numeric domain, and SHA-256 hashing. It contains no
  timestamp, random run ID, machine path, token, or secret value.
- Target and capability contributors register explicitly from trusted module
  directories. Catalog content is metadata-only and never executable.
- Offline ownership is intent plus an expected classification. Observed
  ownership remains `unverified` until authenticated reconciliation.
- Actions declare dependencies, preconditions, postconditions, retry class,
  idempotency key, ownership effect, and stop-on-unknown reconciliation.
- The SQL VM support matrix is data. Unsupported combinations fail rather than
  silently downgrade.
- Azure Files backup staging is an optional capability. The SQL VM
  backup-restore solution pack derives a pinned dbatools dependency and plans
  separate local rendering and future remote staging for a manual,
  preview-first restore script with replacement disabled. It never performs an
  automatic restore.
- Local script rendering has no Azure-resource or guest-execution dependency.
  Remote staging is a separate future action. Azure Files deployment remains
  blocked until the SMB OAuth client artifact, integrity, installation,
  credential refresh, and probe contracts are implemented.
- Action idempotency keys bind to the toolkit, active contributor contracts and
  implementations, selected engine contract, catalog revisions, configuration,
  and exact catalog selections.
- The TUI boundary is a versioned data contract. A polished TUI is deferred and
  will run out of process.
- JSON plan export is the deterministic non-executable action package for S1.
  Markdown and standalone HTML are reader views of the same verified plan.

## Consequences

The module can be built and tested without credentials or spend. It cannot
claim live compatibility, availability, cost, ownership, deployment, restore,
or teardown behavior. Those facts remain structured as unverified and are
resolved by later lifecycle stages.

The alpha public command surface is intentionally small:

- `Test-AzureDataLabConfiguration`
- `New-AzureDataLabPlan`
- `Export-AzureDataLabPlan`
- `Find-AzureDataLabCatalogItem`
- `Get-AzureDataLabSupportMatrix`
- `Get-AzureDataLabTemplate`

This is a prerelease contract. Breaking changes before the first stable release
must be recorded in the changelog and migration notes.
