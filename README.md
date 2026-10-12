# Azure Data Lab Toolkit

Azure Data Lab Toolkit is a PowerShell project for repeatable, secure-by-default, and cost-aware data labs across Azure data services and self-managed database platforms.

> **Current state:** The repository contains an installable **alpha** module.
> v0.1.0-alpha1 is the first alpha prerelease, published on
> [GitHub Releases](https://github.com/kaysauter/Azure-Data-Lab-Toolkit/releases)
> and not on the PowerShell Gallery. Beyond YAML validation, deterministic SQL
> VM planning, catalog discovery, support-matrix inspection, and plan export,
> the module authenticates to Azure, reconciles plans against live state,
> deploys resources, probes them, and tears them down.
>
> **It creates and deletes real Azure resources.** It is not production-ready.
> Treat it accordingly:
>
> - Never run this against a subscription you care about.
> - Nothing here has ever been executed against live Azure. Not once.
> - `Start-AzureDataLabDeployment` creates billable resources. `Start-AzureDataLabTeardown` deletes resources.
> - The command surface and plan hashes may change without notice between alpha tags.
>
> `Connect-AzureDataLabAccount` repeats these warnings before it signs in.
>
> **Known issue in v0.1.0-alpha1:** live resolution stops at the toolkit's
> Azure command boundary, so no deployment can be authorized yet. See the
> [release notes](release-notes/0.1.0-alpha1.md#known-issues).

## Goal

The toolkit will turn a readable, schema-validated YAML definition into a
reviewable lab lifecycle: validate, plan, estimate cost, deploy, probe, report,
shut down, and tear down. Applicable assessment can add evidence before or
after planning without becoming a mandatory gate for every lab. The toolkit
will support Microsoft and community samples as well as private data, software,
and artifacts supplied by the user.

SQL Server on Azure VM is the first implementation target. It is the proving ground for identity, networking, storage, guest configuration, software delivery, restore workflows, testing, and cleanup.

## Try the alpha

Install a release to use the module. Work from a clone to read or change the
code: that is the development path, and it runs without build-provenance
enforcement.

### Install a release

Alpha releases are GitHub prereleases. Each one carries the module ZIP, its
`.sha256` checksum file, and an SPDX SBOM, `sbom.spdx.json`; the "Source code"
archives GitHub adds to every release are a copy of the repository, not the
packaged module. You need PowerShell 7.6, access to the PowerShell Gallery, and
the [GitHub CLI](https://cli.github.com/) signed in with `gh auth login`, which
`gh attestation verify` requires.

Download `AzureDataLabToolkit-0.1.0-alpha1.zip` and
`AzureDataLabToolkit-0.1.0-alpha1.zip.sha256` from the
[v0.1.0-alpha1 release page](https://github.com/kaysauter/Azure-Data-Lab-Toolkit/releases/tag/v0.1.0-alpha1),
or with the GitHub CLI, and check the ZIP before you expand it:

```powershell
# A prerelease is never the latest release, so name the tag.
gh release download v0.1.0-alpha1 --repo kaysauter/Azure-Data-Lab-Toolkit `
    --pattern 'AzureDataLabToolkit-0.1.0-alpha1.zip*'

$zip = 'AzureDataLabToolkit-0.1.0-alpha1.zip'
$expected = (Get-Content -LiteralPath "$zip.sha256" -Raw).Split(' ')[0]
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
    throw "$zip does not match its published checksum."
}
gh attestation verify $zip --repo kaysauter/Azure-Data-Lab-Toolkit --signer-workflow kaysauter/Azure-Data-Lab-Toolkit/.github/workflows/module-ci.yml
```

Stop if either check fails. In a Linux or macOS shell,
`sha256sum -c AzureDataLabToolkit-0.1.0-alpha1.zip.sha256`, or `shasum -a 256 -c`
with the same file, does the checksum step. The checksum only shows that the
ZIP matches the file published beside it; the attestation ties the ZIP to a
GitHub Actions run in this repository.

Then expand it into a `PSModulePath` directory, install the locked
dependencies, and import the module by name:

```powershell
$modules = ($env:PSModulePath -split [System.IO.Path]::PathSeparator)[0]
Expand-Archive -LiteralPath $zip -DestinationPath $modules
if (-not $IsWindows) {
    chmod -R go-w (Join-Path $modules 'AzureDataLabToolkit')
}
pwsh -NoProfile -File (Join-Path $modules 'AzureDataLabToolkit/0.1.0/Install-AzureDataLabToolkitDependencies.ps1') -TrustRepository
Import-Module AzureDataLabToolkit
```

The archive's root is `AzureDataLabToolkit/0.1.0/`, the layout `Import-Module`
looks for in each `PSModulePath` directory; delete any earlier
`AzureDataLabToolkit/0.1.0` there first. On Linux and macOS the module refuses
to load while its `Support` folder, the script and dependency lock files in it,
or its script folders and scripts are writable by group or others, and
`Expand-Archive` creates folders according to your umask; the `chmod` removes
that write access. The dependency script installs `powershell-yaml` 0.4.12 and
five Az modules at their locked versions in your user scope, then imports the
module and checks each installed dependency against the lock. `-TrustRepository`
trusts the PowerShell Gallery for those installs only; add `-WhatIf` to list
them first. The script uses only the PSResourceGet 1.2.0 that ships inside
PowerShell, and it refuses a PowerShell installation directory that other users
can write to.

Leave the installed folder exactly as extracted, because a release enforces its
build provenance. Its build recorded every module file, and the Git commit it
was built from, in `build-provenance.json`. Before
`Start-AzureDataLabDeployment` authorizes a deployment, the module checks its
files against that record and refuses if anything was added, changed, or
removed; a Finder `.DS_Store` is enough.

### Work from a clone (development path)

Importing from `src/` is the development path, and it runs **without
build-provenance enforcement**. The source tree has no `build-provenance.json`,
so the module identifies itself by a digest of whatever files are in its folder
(`revisionKind: content-derived`) instead of a build record that names a Git
commit, and that digest is what a deployment authorization records. The script
lock still applies: every script the module loads must match
`src/AzureDataLabToolkit/Support/module-scripts.lock.json`. `./build.ps1` turns
the enforcement on in the copy it packages. Use this path to read and change
the code; install a release for anything that touches Azure.

You need PowerShell 7.6 and a clone of
`https://github.com/kaysauter/Azure-Data-Lab-Toolkit.git`. From its root:

```powershell
Install-PSResource powershell-yaml -Version 0.4.12 -Repository PSGallery
Import-Module ./src/AzureDataLabToolkit/AzureDataLabToolkit.psd1
```

On Linux and macOS, a clone made under a umask such as `002` leaves the
module's folders and files group-writable, and the import then fails with a
message ending in "writable by another user."; run
`chmod -R go-w src/AzureDataLabToolkit` and import again.

`powershell-yaml` 0.4.12 is the only dependency the module needs to load and
to run the offline commands below. The Azure-facing commands also need the five
locked Az modules, which the dependency script installs along with
`powershell-yaml`:

```powershell
pwsh -NoProfile -File ./src/AzureDataLabToolkit/Install-AzureDataLabToolkitDependencies.ps1 -TrustRepository
```

`./build.ps1 -Task All` analyzes, tests, and packages the module into
`out/packages/`. It downloads nothing, so install Pester 5.7.1 and
PSScriptAnalyzer 1.25.0 first, and the six runtime dependencies with the
dependency script above. The build accepts only unmodified PowerShell Gallery
copies at the versions pinned in `src/AzureDataLabToolkit/Support/`, and each
pinned version must resolve to exactly one module manifest on `PSModulePath`:

```powershell
Install-PSResource Pester -Version 5.7.1 -Repository PSGallery
Install-PSResource PSScriptAnalyzer -Version 1.25.0 -Repository PSGallery
./build.ps1 -Task All
```

### Validate, plan, and export

A release ZIP holds only the module, so after installing a release, take the
example from the repository at the same tag; a clone already has it:

```powershell
New-Item -ItemType Directory -Path ./examples -Force | Out-Null
Invoke-WebRequest -Uri https://raw.githubusercontent.com/kaysauter/Azure-Data-Lab-Toolkit/v0.1.0-alpha1/examples/sqlvm-minimal.yaml -OutFile ./examples/sqlvm-minimal.yaml
```

Then, on either path:

```powershell
Test-AzureDataLabConfiguration ./examples/sqlvm-minimal.yaml
$plan = New-AzureDataLabPlan ./examples/sqlvm-minimal.yaml
Export-AzureDataLabPlan $plan -Format Html -Path (Join-Path $PWD 'sqlvm-plan.html')
```

Those three commands touch nothing outside your machine. The plan they produce
is review evidence: live Azure facts it cannot prove locally are marked
`unverified`, and the plan keeps those markers; live checks are recorded as
separate evidence. After `Connect-AzureDataLabAccount`,
`Invoke-AzureDataLabPreflight` runs those checks for a run created by
`New-AzureDataLabRun`. `Resolve-AzureDataLabPlan` checks provider registration,
the marketplace image version, VM size availability, the reused Key Vault, and
the signed-in principal. `Test-AzureDataLabWhatIf` refuses to run without
passing evidence from that step, then compares the planned resources with live
state. The preflight then prices the plan and previews its teardown, and
`Start-AzureDataLabDeployment` requires that complete preflight.

With the default `powershell` engine the plan reports
`contracts.engine.implementationStatus` as `available`. That does not make this
example deployable: it plans a new Key Vault, which the support matrix marks
`unavailable` for deployment, so `target.deploymentStatus` is `unavailable`, and
it does not bind the `sqlvm-first-canary/v1` deployment profile that
`Test-AzureDataLabDeploymentConfiguration` checks;
`examples/sqlvm-first-canary.yaml` does. `bicep` and `terraform` are refused
before a plan exists:
`New-AzureDataLabPlan ./examples/sqlvm-minimal.yaml -Engine bicep` fails with
"The SQL VM plan contract does not support engine 'bicep'." Review
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

Steps 1-5, the probes and evidence export in step 6, and teardown in step 7 are
implemented and test-covered, and are therefore **current**. Loading data and
installing software are not: the backup-restore solution pack plans script
rendering and staging, but no code renders or stages a script, and the toolkit
uploads no file, mounts no drive, and restores no database. The only deployment
profile, `sqlvm-first-canary/v1`, refuses a lab that enables the backup share or
the restore pack, or that selects catalog software or sample data. None of it is
**available**: only a published release that has been verified against a live
subscription earns that label. Shutdown, and resuming a shut-down lab, remain
**backlog**; `Resume-AzureDataLabDeployment` and `Resume-AzureDataLabTeardown`
only retry a deployment or teardown whose outcome is unknown.

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
| `src/AzureDataLabToolkit/` | Installable module: offline validation and planning plus the Azure-facing sign-in, WhatIf, deployment, probe, and teardown commands, schemas, provider and capability plan contributors, catalogs, templates, support data, and the dependency installer |
| `tests/Unit/` | Current Pester tests for import, validation, plans, safety, catalogs, reports, and capability boundaries |
| `examples/` | Minimal SQL VM and optional backup-share planning inputs, and `sqlvm-first-canary.yaml`, the only example bound to the `sqlvm-first-canary/v1` deployment profile |
| `.github/workflows/` | Documentation checks, Pages deployment, cross-platform offline module checks, and the tag-triggered release that verifies, attests, and publishes the package |

## Source of Truth

Published releases and their notes define **Available** behavior, and only for
what they state was verified against a live subscription; no release has stated
that yet. The checked-in implementation plus passing tests defines current
development behavior. Architecture is not proof of implementation, and roadmap
order is not a delivery commitment.

## License

Azure Data Lab Toolkit is available under the [MIT License](LICENSE). Microsoft products, SQL Server images, sample databases, and third-party tools retain their own terms and licenses.
