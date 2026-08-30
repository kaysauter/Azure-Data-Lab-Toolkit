# ADR 0006: Browser-based configuration wizard

- Status: Accepted
- Date: 2026-08-30
- Supersedes: the terminal UI portion of [ADR 0001](0001-offline-powershell-foundation.md)

## Context

ADR 0001 reserved a guided-input route as a versioned data contract and deferred
a polished terminal UI to a later out-of-process implementation. The contract
shipped as `Schemas/tui-selection.schema.json`, with an empty `Tui/` boundary
directory holding only a placeholder.

A terminal UI is expensive for the value it returns here. Guided configuration
is a wide, branching form: templates, catalog selections, network and secret
decisions, policy acknowledgements. That is ordinary form layout in a browser
and bespoke widget work in a terminal. A terminal UI would also need its own
rendering, input, and accessibility handling on three platforms, and would still
have to emit exactly the same neutral selection document.

A browser page needs none of that. Every machine that runs the toolkit already
has a browser, and the page can be served from the local filesystem with no
server, no network access, and no build step.

## Decision

Guided configuration is a browser page, launched by
`Start-AzureDataLabConfigurationWizard`. No terminal UI is planned.

- The wizard is a self-contained HTML, CSS, and JavaScript bundle staged in a
  private temporary directory with owner-only permissions and opened over
  `file://`.
- It makes no network request. It never accepts a password, token, or other
  secret value, and it applies no policy.
- It holds no Azure token, approves no plan, and deploys nothing. Its only
  output is ordinary schema-valid YAML or the neutral selection handoff.
- The handoff contract is renamed to `Schemas/ui-selection.schema.json` with
  kind `AzureDataLabUiSelection`, because the contract was never terminal
  specific. The `Tui/` boundary directory is removed.
- Guided input remains optional. Templates, YAML, and explicit flags stay
  first-class routes, and the wizard is never required to produce a plan.

## Consequences

- The guided route ships now rather than remaining deferred work.
- The boundary in ADR 0001 is preserved in substance: guided input is still an
  out-of-process, non-privileged producer of a neutral document that Core
  validates like any other input.
- The wizard bundle is a shipped artifact and carries the module's supply-chain
  obligations. It is covered by the module package and reviewed as source, not
  fetched at runtime.
- Serving over `file://` gives the page an opaque origin, so a meta `script-src
  'self'` policy may not match sibling scripts and `frame-ancestors` cannot be
  set from a meta tag. The page therefore depends on being local, offline, and
  free of `innerHTML`, `eval`, and network APIs rather than on CSP alone.
- Every temporary bundle is currently left on disk after launch. Cleanup is
  tracked separately.
- A future terminal UI is not precluded by the contract, but it is not planned
  and no part of the codebase reserves space for one.
