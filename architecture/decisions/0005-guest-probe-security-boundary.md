# ADR 0005: Guest probe security boundary

- Status: Accepted
- Date: 2026-07-28

## Context

Azure Run Command executes as `SYSTEM` on Windows by default. That is useful for
narrow machine bootstrap, but it cannot demonstrate that a normal user can use
installed tools, mounted storage, SQL connectivity, or a manual restore flow.

## Decision

S4 control-plane probes verify Azure resources, security settings, VM-agent
readiness, stop and resume, idempotency, and cleanup. One supervised Bastion
access check completes the interactive S4 access evidence.

Any operation intentionally running as `SYSTEM` declares that boundary and may
not receive database credentials, user secrets, or private restore content.
Its evidence is limited to machine-wide postconditions.

S5 introduces an ephemeral, VNet-connected guest probe identity with no Azure
deployment or deletion rights. It verifies private SQL connectivity,
normal-user software behavior, storage access, and sample-data outcomes.
The generated backup restore script remains preview-first and is not
automatically executed to make a canary pass.

## Consequences

- Machine bootstrap and user-experience claims cannot be conflated.
- S4 can progress before the full SQL/data solution pack exists.
- Sensitive guest evidence stays outside deployment and cleanup identities.

