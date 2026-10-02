# ADR 0004: Remote state, locking, and fencing

- Status: Accepted
- Date: 2026-07-28

## Context

GitHub concurrency cannot protect against runner loss, retries from another
orchestrator, or stale processes that continue after a lock changes ownership.
Disposable workload resources also cannot contain their own recovery state.

## Decision

Interactive S4 runs use protected local state. Any unattended mutation uses an
Azure Blob-backed state store outside the disposable workload scope.

Each run records an immutable plan, append-only events, snapshots, evidence
references, exact observed ownership, and cleanup status. State contains no
secret values.

Concurrency is enforced in three layers:

1. orchestrator concurrency prevents ordinary duplicate jobs;
2. a renewable Blob lease provides exclusive access to a scope and run;
3. an ETag-protected, monotonically increasing generation is the fencing token.

Every mutation and authoritative state write verifies the active generation.
A stale process stops even if it still holds local credentials. Unknown results
are reconciled by stable resource ID before retry.

The state account disables anonymous and shared-key access, requires Entra
authentication and TLS, and enables versioning and recovery. Lease recovery and
state restoration are human break-glass operations with an audit event.

## Consequences

- A workflow crash can be resumed without blind retries.
- A Blob lease alone is not treated as sufficient stale-writer protection.
- The canary cleanup watchdog can act independently from the deployment job.

