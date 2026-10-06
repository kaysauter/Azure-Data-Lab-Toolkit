# ADR 0003: Execution authorization envelope

- Status: Accepted
- Date: 2026-07-28

## Context

An offline plan hash does not include live image resolution, current Azure
state, cost evidence, or the exact module artifact that will execute it.
Approving only that hash leaves a time-of-check/time-of-use gap.

## Decision

Every mutation requires a versioned execution authorization envelope containing:

- plan and intent hashes;
- live-resolution and WhatIf evidence hashes;
- cost-evidence and teardown-plan hashes;
- toolkit package digest, commit, engine contract, and engine implementation;
- tenant, subscription, resource group, and permitted resource IDs;
- approval identity, approval mechanism, creation time, and expiration time;
- maximum estimated run cost and runtime;
- the acknowledgement IDs accepted for this plan.

Canonical JSON is authoritative. The envelope has its own SHA-256 hash. CI also
binds the reviewed workflow artifact digest and protected-environment approval
record.

Immediately before the first mutation, the engine repeats context and live
reconciliation. Any changed hash, expired authorization, expanded operation,
new blocker, or scope mismatch requires a new approval. Timestamp-only evidence
fields are excluded from semantic comparison by an explicit allowlist.

Teardown uses a different plan and authorization hash. A canary may approve its
teardown before deployment so an `always()` job can execute it, but scheduling
cleanup never grants deletion authority.

## Consequences

- Approval is specific to code, Azure scope, live facts, cost, and cleanup.
- Reconciliation drift fails closed.
- Interactive and CI executions share the same authorization contract.

