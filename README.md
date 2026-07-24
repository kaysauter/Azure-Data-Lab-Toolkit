# Azure Data Lab Toolkit

Azure Data Lab Toolkit is a planned PowerShell module for building repeatable, secure-by-default, and cost-aware data labs across Azure data services and self-managed database platforms.

> **Project status:** This repository is an early architecture scaffold. It does not contain deployable cmdlets yet and is not production ready. SQL Server on Azure VM remains the first implementation target because it provides the foundation for compatibility and deployment testing.

## Documentation

Read the [Azure Data Lab Toolkit documentation](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/) for the project goal, architecture, security and cost guardrails, target roadmap, community catalog, version history, and [pitch deck](https://kaysauter.github.io/Azure-Data-Lab-Toolkit/pitch/deck/).

## Relationship to Azure SQLVM Toolkit

[Azure SQLVM Toolkit](https://github.com/kaysauter/azure-sqlvm-toolkit) is the current working project for SQL Server on Azure VM. Its [documentation website](https://kaysauter.github.io/azure-sqlvm-toolkit/) remains the reference for that implementation.

Azure Data Lab Toolkit is the broader successor architecture. The existing project will remain available while capabilities are designed, migrated, and verified here.

## Intended Experience

Users will describe a lab in a schema-validated YAML file and use PowerShell cmdlets to:

- validate configuration and prerequisites;
- assess source systems and candidate targets;
- preview resources, security decisions, and costs;
- deploy through PowerShell, with Bicep and Terraform engines added later;
- load sample, community, private, or user-provided data;
- install approved tools and supporting software;
- test the deployed lab and export machine-readable and HTML results;
- shut down or remove resources with a reviewed deletion summary.

Templates and an optional terminal interface are planned so users can start from guided scenarios without learning every command-line option.

## Target Order

1. SQL Server on Azure VM
2. Azure SQL Database
3. Azure SQL Managed Instance
4. Microsoft Fabric
5. Azure Database for PostgreSQL
6. SQL Server and PostgreSQL on Linux VMs and containers
7. Kubernetes-based targets in a later phase

## Planned Scope

- **Data and assessment:** Microsoft samples, community databases, private files and URLs, checksums, Azure Arc, current Microsoft-supported assessment paths, and later migration/import paths such as BACPAC.
- **Tools:** dbatools, Brent Ozar's First Responder Kit, Tabular Editor, TMDL tooling, Rayfin demonstrations, FUAM, and user-defined packages.
- **Storage:** Azure Data Lake Storage Gen2, Blob Storage, and Azure Files shares that can be mounted by VMs.
- **Microsoft Fabric:** workspace and item creation, deployment guidance, CI/CD, SQL databases, warehouses, lakehouses, shortcuts, and FUAM validation or deployment guidance.
- **Git and CI/CD:** GitHub first, with Azure DevOps, GitLab, Gitea, Forgejo, and other providers kept behind provider boundaries.
- **Operations:** deployment validation, cost estimation, budgets, shutdown schedules, teardown previews, and sensitive-data tagging.

## Architecture Direction

```text
AzureDataLabToolkit
  Core
    Config
    Templates
    Plan
    Assessment
    Catalog
    CostGuardrails
    RunState
    Teardown
  Providers
    SqlVm
    AzureSqlDatabase
    AzureSqlManagedInstance
    PostgreSql
    Fabric
    Databricks
    Storage
    Git
    Software
  Engines
    PowerShell
    Bicep
    Terraform
```

Core produces a validated, engine-neutral plan. Providers describe target-specific behavior. Engines translate approved plan actions into deployment operations.

## Design Principles

- YAML is the primary input and is validated against a versioned schema.
- PowerShell remains a first-class deployment route.
- Risky or sensitive actions require explicit configuration, flags, or confirmation.
- Key Vault, managed identities, private networking, and Azure Bastion are preferred defaults.
- Cost estimation is an explicit operation and can produce HTML output.
- Assessment and validation are separate from migration and import.
- Deployment and teardown are idempotent, inspectable, and recorded in run state.
- The same provider contract is tested across PowerShell, Bicep, and Terraform where supported.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `architecture/` | System design, provider contracts, decisions, and security boundaries |
| `docs-site/` | Astro/Starlight documentation and Slidev pitch deck |
| `src/` | PowerShell module, core services, providers, and deployment engines |
| `tests/` | Unit, contract, integration, deployment, and teardown tests |
| `.github/workflows/` | GitHub Actions checks and deployment-test orchestration |

## Roadmap

The dependency-ordered backlog is maintained in [Feature Requests](FEATURE_REQUESTS.md), tracked through [GitHub issues](https://github.com/kaysauter/Azure-Data-Lab-Toolkit/issues), and organized on the public [Azure Data Lab Toolkit Roadmap](https://github.com/users/kaysauter/projects/6/views/1).

Notable changes are recorded in the [Changelog](CHANGELOG.md).

## Development

The next step is to make the architecture decision-complete before adding the initial PowerShell module and SQL VM provider. Planned functionality in this README should not be treated as shipped behavior.

## License

Azure Data Lab Toolkit is available under the [MIT License](LICENSE). Microsoft products, SQL Server images, sample databases, and third-party tools retain their own terms and licenses.
