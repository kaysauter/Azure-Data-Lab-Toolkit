# ADR 0002: SQL VM canary boundaries

- Status: Accepted
- Date: 2026-07-28

## Context

The toolkit needs real Azure SQL VM lifecycle evidence without allowing a test
workflow to bypass the same ownership, approval, state, and teardown contracts
that users receive.

## Decision

Canary delivery has three explicit maturity levels:

1. S4 uses an interactively authenticated, supervised canary with protected
   local state.
2. An experimental S4-CI lane may pull forward a canary-only slice of remote
   state and GitHub OIDC. Its evidence can contribute to S6, but it does not
   advertise unattended deployment as supported product behavior.
3. S6 releases remote execution only after locking, fencing, resume, drift,
   duplicate-trigger, and three-clean-lifecycle gates pass.

Live evidence must exercise public toolkit lifecycle commands. A bootstrap
script that calls Azure PowerShell directly can prepare the isolated canary
control plane, but cannot satisfy provider or engine acceptance criteria.

Pull requests remain credential-free. Live workflows execute only protected
repository code after a plan-specific approval. Deployer, verifier, cleanup,
and later guest-probe identities remain separate.

The recurring canary uses one stable workload scope and a persistent, reused
control-plane Key Vault. A separate supervised lane verifies Key Vault create
and recovery behavior without depending on reuse of a soft-deleted vault name.

## Consequences

- The first live milestone remains supervised and debuggable.
- CI automation cannot get ahead of the remote-state safety contract.
- Raw Azure deployment success is not sufficient evidence that the toolkit
  works.
- Key Vault retention does not make recurring canary names unusable.

