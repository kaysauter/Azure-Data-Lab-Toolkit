# Azure Data Lab Toolkit

Azure Data Lab Toolkit is the committed design for a PowerShell module that will build repeatable, secure-by-default, and cost-aware data labs across Azure data services and self-managed database platforms.

> **Current state:** This repository contains architecture documentation, a documentation website, a pitch deck, and a feature backlog. It has no installable module, deployable cmdlets, released providers, or production-ready behavior.

## Goal

The toolkit will turn a readable, schema-validated YAML definition into a
reviewable lab lifecycle: validate, plan, estimate cost, deploy, probe, report,
shut down, and tear down. Applicable assessment can add evidence before or
after planning without becoming a mandatory gate for every lab. The toolkit
will support Microsoft and community samples as well as private data, software,
and artifacts supplied by the user.

SQL Server on Azure VM is the first implementation target. It is the proving ground for identity, networking, storage, guest configuration, software delivery, restore workflows, testing, and cleanup.

## Intended Workflow

1. Describe a lab in YAML, start from a template, or use command flags and a future optional terminal UI.
2. Run `-Plan` offline to validate inputs and explain defaults, derived values, resources, actions, and guardrails.
3. Run `-WhatIf` after Azure sign-in to compare the resolved plan with live resources without changing them.
4. Run `-CostEstimate` when a shareable estimate is needed, then review security, licensing, data sensitivity, cost, and deletion decisions.
5. Deploy through PowerShell first. Bicep and Terraform become additional engines after the shared contracts and first target paths are stable and before Fabric delivery begins.
6. Load approved data and software, run probes, and produce console, JSON, Markdown, or HTML evidence.
7. Shut down, resume, or tear down the lab with explicit lifecycle safeguards.

Everything in this workflow is **committed design** or **backlog** until a published release verifies it.

## Architecture

The Core owns configuration, planning, policy, run state, reporting, and lifecycle orchestration. It works through distinct extension contracts:

- **Target providers** describe deployable platforms such as SQL Server on Azure VM, Azure SQL Database, Azure SQL Managed Instance, managed or self-hosted PostgreSQL, and Microsoft Fabric.
- **Capability modules** integrate supporting services such as storage, Git, identity, assessment, and cost data.
- **Catalog sources** describe governed data, software, and template entries with provenance, licensing, integrity, and compatibility metadata.
- **Solution packs** combine targets, data, tools, and guidance into reproducible scenarios.
- **Deployment engines** translate approved actions for PowerShell first and later Bicep or Terraform.
- **Probes** verify deployed resources and create evidence without owning deployment.

Read the [architecture documentation](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/architecture/) for the contracts, lifecycle, security boundaries, and accepted decisions.

## Delivery Order

The project first establishes the offline Core and its own GitHub CI baseline.
It then delivers product outcomes in this order:

1. SQL Server on Azure VM, from read-only planning through the first release
2. Azure SQL Database
3. Azure SQL Managed Instance
4. Azure Database for PostgreSQL
5. PostgreSQL on Azure VM
6. Containerized PostgreSQL
7. Bicep, then Terraform, as additional deployment engines
8. General Git and CI/CD adapters for GitHub, Azure DevOps, GitLab, Gitea, and Forgejo
9. Microsoft Fabric guidance, workspaces, items, and shortcuts, followed by parallel conditional CI/CD and solution-pack lanes
10. Azure Databricks and later data providers
11. SQL Server on Linux and containers
12. Kubernetes-based targets

Delivery order is not the same as technical dependency. Terraform does not
depend technically on Bicep, Fabric workspace creation does not depend on Git,
and no PostgreSQL provider depends on Fabric. Read the
[authoritative segment plan](architecture/delivery-segments.md) for S0 through
S22 and their exit gates.

## Security Decisions In Every Lab

Every target and solution pack will emit a `secretStoreDecision`: deploy or
reuse Azure Key Vault, use an approved external store, or record why a secret
store is not applicable. The decision remains visible in Plan, WhatIf, cost,
security, ownership, and teardown evidence. Secret values never belong in YAML,
plans, state, or reports.

Every Azure VM will also emit an `administrativeAccessDecision`. Azure Bastion
with no public IP is the default. Reuse or opt-out requires an explicit rationale
and approval and remains visible in planning, cost, and security evidence.
Key Vault and Bastion are reusable capability modules, not hidden provider
implementation details.

## Relationship to Azure SQLVM Toolkit

[Azure SQLVM Toolkit](https://github.com/kaysauter/azure-sqlvm-toolkit) is an unfinished predecessor, not a working implementation of Azure Data Lab Toolkit. It remains online with its [documentation website](https://kaysauter.github.io/azure-sqlvm-toolkit/) as a record of experiments and lessons.

The repositories are separate. A feature present or described in Azure SQLVM Toolkit is not available in Azure Data Lab Toolkit unless it is implemented, tested, documented, and included in a published Azure Data Lab Toolkit release.

## Documentation

- [Documentation website](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/)
- [Project status](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/status/)
- [Architecture](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/architecture/)
- [Roadmap](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/roadmap/)
- [Pitch deck](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/pitch/deck/)
- [Delivery segments](architecture/delivery-segments.md)
- [Feature requests](FEATURE_REQUESTS.md)
- [Changelog](CHANGELOG.md)

## Repository Layout

| Path | Current purpose |
| --- | --- |
| `architecture/` | Committed design, decisions, contracts, security boundaries, and authoritative delivery segments |
| `docs-site/` | Astro/Starlight documentation and Slidev pitch deck |
| `FEATURE_REQUESTS.md` | Backlog with technical prerequisites separated from delivery sequence |
| `src/` | Reserved for the PowerShell module and extensions; no deployable toolkit exists yet |
| `tests/` | Reserved for unit, contract, integration, deployment, and teardown tests |
| `.github/workflows/` | Documentation checks now; module and deployment checks remain backlog |

## Source of Truth

Published releases and release notes will define **Available** behavior. Until the first release, the repository contents describe current artifacts, committed design, backlog, exploratory work, and deferred work. Architecture is not proof of implementation, and roadmap order is not a delivery commitment.

## License

Azure Data Lab Toolkit is available under the [MIT License](LICENSE). Microsoft products, SQL Server images, sample databases, and third-party tools retain their own terms and licenses.
