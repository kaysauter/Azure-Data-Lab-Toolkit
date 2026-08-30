# Azure Data Lab Toolkit Baseline

Azure Data Lab Toolkit exists to make repeatable data labs easier to describe,
review, build, compare, and remove. The idea has been a goal for years; its
scope is now large enough that AI assistance from Codex and Claude is part of
how the project can be built. Architecture, security decisions, testing,
licensing, and releases remain the maintainer's responsibility.

## Product direction

- PowerShell remains the first user and deployment path. Bicep and Terraform
  will follow through the same normalized plan rather than separate products.
- YAML is the durable input. Templates, a future terminal UI, and explicit
  command flags all resolve into the same versioned configuration.
- SQL Server on Azure VM is the first proof point. Azure SQL Database, Azure SQL
  Managed Instance, PostgreSQL, Git and CI/CD integrations, and Microsoft
  Fabric follow in the documented delivery order.
- Microsoft and community software and sample data are optional catalog
  choices. Users will also be able to stage private files and URL artifacts
  under explicit integrity, licensing, and sensitivity rules.
- Plan, WhatIf, cost, deployment, probes, reports, shutdown, resume, and
  teardown are distinct lifecycle stages.

## Non-negotiable contracts

- `Plan` is deterministic and offline.
- Live Azure facts remain `unverified` until an authenticated read-only stage.
- Secret values never belong in YAML, plans, state, logs, or reports.
- Every lab records a secret-store decision. Every Azure VM records its
  administrative-access decision; Bastion with no VM public IP is the default.
- Ownership intent is not proof of ownership. Unknown resources are never
  overwritten, replaced, adopted, or deleted.
- Mutating actions require an approved plan hash and reconciliation before and
  after execution.
- Teardown uses a separate preview and approval.
- Catalog entries use exact IDs and versions. Mutable sources or unresolved
  integrity cannot reach unattended execution.
- The optional backup-share capability plans private Azure Files. Its manual
  SQL VM backup-restore solution pack pins dbatools as a dependency and leaves
  restore preview-first, user-executed, and replacement-disabled.

## Current implementation boundary

The first alpha implementation provides an installable PowerShell module for
validation, deterministic planning, catalog discovery, support matrix
inspection, and JSON, Markdown, or HTML plan export. It also signs in to Azure,
estimates live prices, reconciles a plan against live state, deploys resources,
probes them, and tears them down under a typed approval phrase.

It does not install guest software or restore databases; the backup-restore
solution pack stays preview-first and user-executed. Everything above is
implemented and test-covered but unreleased and never run against a live
subscription.

The first fixed SQL VM profile records engine-facing desired properties,
private networking, Key Vault and Bastion capability contracts, structured
policy findings, and plan-hash-bound acknowledgement requirements. Authenticated
reconciliation and the PowerShell engine are delivered, so the profile is
executable; it is gated by explicit approval phrases rather than by absence of
an engine.

This baseline guides implementation. Published releases and their evidence
remain the authority for behavior that is actually available.
