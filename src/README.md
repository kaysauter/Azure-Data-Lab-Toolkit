# PowerShell Source

`AzureDataLabToolkit/` contains the installable offline module.

| Path | Responsibility |
| --- | --- |
| `Private/` | Azure-neutral configuration, validation, canonicalization, registries, and catalog primitives |
| `Public/` | Implemented public cmdlets only |
| `Providers/` | Target-specific normalized plan contributors, beginning with SQL VM |
| `Capabilities/` | Reusable networking, Key Vault, Bastion, and optional Azure Files plan contributors |
| `Catalogs/` | Metadata-only software and sample-data catalogs |
| `Schemas/` | Versioned configuration, plan, catalog, support-matrix, and TUI handoff contracts |
| `Support/` | Explicit capability matrices; unsupported combinations fail closed |
| `Templates/` | Built-in YAML defaults that remain below user YAML and flags in precedence |
| `Engines/` | Reserved for plan translators and deployment engines; none are shipped |
| `Probes/` | Reserved for postcondition evidence; none are shipped |
| `SolutionPacks/` | Scenario composition, currently the manual SQL VM backup-restore contract |
| `Tui/` | TUI-neutral handoff contract; no terminal UI is shipped |

Module import loads only trusted PowerShell source from the known `Private`,
`Providers`, `Capabilities`, `SolutionPacks`, and `Public` directories. Catalog data, guest
scripts, future engine output, and TUI code are never dot-sourced into Core.

The module authenticates to Azure, calls Azure management APIs, deploys
resources, and deletes them under explicit approval. It performs no SQL
operations: guest software installation and database restore stay preview-first
and user-executed.
