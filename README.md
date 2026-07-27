# Azure Data Lab Toolkit

Azure Data Lab Toolkit is the committed design for a PowerShell module that will build repeatable, secure-by-default, and cost-aware data labs across Azure data services and self-managed database platforms.

> **Current state:** This repository contains architecture documentation, a documentation website, a pitch deck, and a feature backlog. It has no installable module, deployable cmdlets, released providers, or production-ready behavior.

## Goal

The toolkit will turn a readable, schema-validated YAML definition into a reviewable lab lifecycle: validate, assess, plan, estimate cost, deploy, probe, report, shut down, and tear down. It will support Microsoft and community samples as well as private data, software, and artifacts supplied by the user.

SQL Server on Azure VM is the first implementation target. It is the proving ground for identity, networking, storage, guest configuration, software delivery, restore workflows, testing, and cleanup.

## Intended Workflow

1. Describe a lab in YAML, start from a template, or use command flags and a future optional terminal UI.
2. Run `-Plan` offline to validate inputs and explain defaults, derived values, resources, actions, and guardrails.
3. Run `-WhatIf` after Azure sign-in to compare the resolved plan with live resources without changing them.
4. Run `-CostEstimate` when a shareable estimate is needed, then review security, licensing, data sensitivity, cost, and deletion decisions.
5. Deploy through PowerShell first; Bicep and Terraform follow after the shared contracts are stable.
6. Load approved data and software, run probes, and produce console, JSON, Markdown, or HTML evidence.
7. Shut down, resume, or tear down the lab with explicit lifecycle safeguards.

Everything in this workflow is **committed design** or **backlog** until a published release verifies it.

## Architecture

The Core owns configuration, planning, policy, run state, reporting, and lifecycle orchestration. It works through distinct extension contracts:

- **Target providers** describe deployable platforms such as SQL Server on Azure VM, Azure SQL Database, Azure SQL Managed Instance, Microsoft Fabric, and PostgreSQL.
- **Capability modules** integrate supporting services such as storage, Git, identity, assessment, and cost data.
- **Catalog sources** describe governed data, software, and template entries with provenance, licensing, integrity, and compatibility metadata.
- **Solution packs** combine targets, data, tools, and guidance into reproducible scenarios.
- **Deployment engines** translate approved actions for PowerShell first and later Bicep or Terraform.
- **Probes** verify deployed resources and create evidence without owning deployment.

Read the [architecture documentation](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/architecture/) for the contracts, lifecycle, security boundaries, and accepted decisions.

## Target Order

1. SQL Server on Azure VM
2. Azure SQL Database
3. Azure SQL Managed Instance
4. Microsoft Fabric
5. Azure Database for PostgreSQL
6. SQL Server and PostgreSQL on Linux VMs and containers
7. Kubernetes-based targets in a later phase

Delivery order is not the same as technical dependency. For example, PostgreSQL follows Fabric on the roadmap but must not depend on Fabric contracts.

## Relationship to Azure SQLVM Toolkit

[Azure SQLVM Toolkit](https://github.com/kaysauter/azure-sqlvm-toolkit) is an unfinished predecessor, not a working implementation of Azure Data Lab Toolkit. It remains online with its [documentation website](https://kaysauter.github.io/azure-sqlvm-toolkit/) as a record of experiments and lessons.

The repositories are separate. A feature present or described in Azure SQLVM Toolkit is not available in Azure Data Lab Toolkit unless it is implemented, tested, documented, and included in a published Azure Data Lab Toolkit release.

## Documentation

- [Documentation website](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/)
- [Project status](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/status/)
- [Architecture](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/architecture/)
- [Roadmap](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/roadmap/)
- [Pitch deck](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/pitch/deck/)
- [Feature requests](FEATURE_REQUESTS.md)
- [Changelog](CHANGELOG.md)

## Repository Layout

| Path | Current purpose |
| --- | --- |
| `architecture/` | Committed design, decisions, contracts, and security boundaries |
| `docs-site/` | Astro/Starlight documentation and Slidev pitch deck |
| `FEATURE_REQUESTS.md` | Backlog with technical prerequisites separated from delivery sequence |
| `src/` | Reserved for the PowerShell module and extensions; no deployable toolkit exists yet |
| `tests/` | Reserved for unit, contract, integration, deployment, and teardown tests |
| `.github/workflows/` | Documentation checks now; module and deployment checks remain backlog |

## Source of Truth

Published releases and release notes will define **Available** behavior. Until the first release, the repository contents describe current artifacts, committed design, backlog, exploratory work, and deferred work. Architecture is not proof of implementation, and roadmap order is not a delivery commitment.

## License

Azure Data Lab Toolkit is available under the [MIT License](LICENSE). Microsoft products, SQL Server images, sample databases, and third-party tools retain their own terms and licenses.
