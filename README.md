# Azure Data Lab Toolkit

Azure Data Lab Toolkit is a PowerShell project for repeatable, secure-by-default, and cost-aware data labs across Azure data services and self-managed database platforms.

> **Current state:** The repository contains an installable **unreleased alpha**
> module. Beyond YAML validation, deterministic SQL VM planning, catalog
> discovery, support-matrix inspection, and plan export, it authenticates to
> Azure, reconciles plans against live state, deploys resources, probes them,
> and tears them down.
>
> **It creates and deletes real Azure resources.** Nothing here has been run
> against a live subscription, no release has been published, and it is not
> production-ready. Treat it accordingly.

## Goal

The toolkit will turn a readable, schema-validated YAML definition into a
reviewable lab lifecycle: validate, plan, estimate cost, deploy, probe, report,
shut down, and tear down. Applicable assessment can add evidence before or
after planning without becoming a mandatory gate for every lab. The toolkit
will support Microsoft and community samples as well as private data, software,
and artifacts supplied by the user.

SQL Server on Azure VM is the first implementation target. It is the proving ground for identity, networking, storage, guest configuration, software delivery, restore workflows, testing, and cleanup.

## Try the alpha

PowerShell 7.6 and the pinned YAML parser are required:

```powershell
Install-PSResource powershell-yaml -Version 0.4.12 -Repository PSGallery
Import-Module ./src/AzureDataLabToolkit/AzureDataLabToolkit.psd1

Test-AzureDataLabConfiguration ./examples/sqlvm-minimal.yaml
$plan = New-AzureDataLabPlan ./examples/sqlvm-minimal.yaml
Export-AzureDataLabPlan $plan -Format Html -Path ./sqlvm-plan.html
```

Build, analyze, test, and create the distributable ZIP:

```powershell
./build.ps1 -Task All
```

Those three commands touch nothing outside your machine. The plan they produce
is review evidence: live Azure facts it cannot prove locally stay marked
`unverified` until `Test-AzureDataLabWhatIf` resolves them against a real
subscription.

With the default `powershell` engine the plan reports
`contracts.engine.implementationStatus` as `available`, so it can be carried
through to deployment. `bicep` and `terraform` report `unavailable`. Review
`$plan.approval.blockingFindingIds` and
`$plan.approval.requiredAcknowledgementIds` before going further; a valid
configuration can still be correctly blocked from execution.

## Intended Workflow

1. Describe a lab in YAML, start from a template, or use explicit command flags or the optional guided browser wizard.
2. Use `New-AzureDataLabPlan` now to validate inputs and explain defaults,
   derived values, resources, actions, and guardrails offline. A future
   lifecycle command will expose the equivalent `-Plan` mode.
3. Run `-WhatIf` after Azure sign-in to compare the resolved plan with live resources without changing them.
4. Run `-CostEstimate` when a shareable estimate is needed, then review security, licensing, data sensitivity, cost, and deletion decisions.
5. Deploy through PowerShell first. Bicep and Terraform become additional engines after the shared contracts and first target paths are stable and before Fabric delivery begins.
6. Load approved data and software, run probes, and produce console, JSON, Markdown, or HTML evidence.
7. Shut down, resume, or tear down the lab with explicit lifecycle safeguards.

Steps 1-7 are implemented and test-covered, and are therefore **current**.
They are not **available**: only a published release that has been verified
against a live subscription earns that label. Shutdown remains **backlog**.

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
implementation details. The current fixed alpha profile plans Trusted Launch,
Secure Boot, vTPM, encryption at host, a system-assigned VM identity, private
VM networking, Key Vault private access, and Bastion Basic.

`-GeneratePassword` and `-ShowGeneratedPassword` are separate explicit flags,
and both record plan intent only. The module does not generate or print a
password: `-ShowGeneratedPassword` sets `allowShellOutput`, which raises a
`high` acknowledge-required policy finding and appears in the support matrix,
but nothing consumes it to write a value to the host.

During deployment the VM administrator password never enters the toolkit
process at all. It is an ARM `secureString` parameter fed by a Key Vault
reference with a pinned secret version. A future generator must use a
cryptographically secure source, write directly to the approved vault, keep
plaintext out of plans, state, and logs, and pass security review.

## Relationship to Azure SQLVM Toolkit

[Azure SQLVM Toolkit](https://github.com/kaysauter/azure-sqlvm-toolkit) is an unfinished predecessor, not a working implementation of Azure Data Lab Toolkit. It remains online with its [documentation website](https://kaysauter.github.io/azure-sqlvm-toolkit/) as a record of experiments and lessons.

The repositories are separate. A feature present or described in Azure SQLVM Toolkit is not available in Azure Data Lab Toolkit unless it is implemented, tested, documented, and included in a published Azure Data Lab Toolkit release.

## Documentation

- [Documentation website](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/)
- [Project status](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/status/)
- [Try the alpha](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/getting-started/)
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
| `src/AzureDataLabToolkit/` | Installable offline module, schemas, provider and capability plan contributors, catalogs, templates, and support data |
| `tests/Unit/` | Current Pester tests for import, validation, plans, safety, catalogs, reports, and capability boundaries |
| `examples/` | Minimal SQL VM and optional backup-share YAML inputs |
| `.github/workflows/` | Documentation checks, Pages deployment, and cross-platform offline module checks |

## Source of Truth

Published releases and release notes define **Available** behavior. Before the
first release, checked-in implementation plus passing tests defines current
development behavior. Architecture is not proof of implementation, and roadmap
order is not a delivery commitment.

## License

Azure Data Lab Toolkit is available under the [MIT License](LICENSE). Microsoft products, SQL Server images, sample databases, and third-party tools retain their own terms and licenses.
