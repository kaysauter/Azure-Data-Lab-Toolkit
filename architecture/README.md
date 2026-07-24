# Architecture

This folder will hold the decision record for Azure Data Lab Toolkit.

The architecture is split into three layers:

```text
Core -> Providers -> Engines
```

- **Core** owns configuration, templates, planning, assessment, catalogs, cost guardrails, run state, and teardown coordination.
- **Providers** own target-specific capabilities and validation for services such as SQL VM, Azure SQL, PostgreSQL, Fabric, storage, Git, and software.
- **Engines** translate the approved plan into PowerShell operations or, later, Bicep and Terraform.

Each deployable provider is expected to support this lifecycle where applicable:

```text
ResolveDefaults
ValidateConfig
Assess
Plan
Deploy
Probe
ExportBicep
ExportTerraform
TeardownPreview
Teardown
```

Architecture documents added here should distinguish current behavior from planned behavior and record security, cost, identity, networking, testability, and backward-compatibility decisions.
