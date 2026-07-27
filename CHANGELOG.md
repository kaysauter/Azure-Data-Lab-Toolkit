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

### Current limitations

- No installable PowerShell module or deployable cmdlets.
- No released providers, deployment engines, YAML schema, or stable public API.
- No implemented `-Plan`, `-WhatIf`, deployment, probe, or teardown workflow.
- Not production-ready.
