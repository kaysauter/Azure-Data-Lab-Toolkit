# Terminal UI boundary

No terminal UI is shipped.

The versioned contract is `Schemas/tui-selection.schema.json`. A future
out-of-process UI may discover templates and catalog metadata, then emit
ordinary schema-valid YAML or this neutral selection handoff. It may not hold
Azure tokens, collect secret values, apply policy, approve plans, or deploy
resources.
