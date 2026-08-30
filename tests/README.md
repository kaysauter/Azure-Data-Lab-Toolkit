# Tests

The first implementation slice is deliberately offline. Its test suites cover:

- module import and public API contracts;
- strict YAML and schema validation;
- configuration precedence and provenance;
- deterministic RFC 8785 plan serialization and SHA-256 hashing;
- a checked minimal-plan hash shared by Linux, Windows, and macOS CI;
- ownership, idempotency, approval, and unsupported-capability contracts;
- scope-specific offline, Azure, and guest preconditions and reconciliation;
- typed desired resource state, contributor dependencies, and DAG validation;
- exact typed ARM IDs and collision-resistant global Azure names;
- Key Vault credential, private network, Bastion, and Azure Files identity contracts;
- structured blockers and plan-hash-bound acknowledgement requirements;
- metadata-only catalogs and support matrices;
- safe JSON, Markdown, and HTML export;
- the optional Azure Files and manual dbatools restore solution-pack boundary.

Run all tests from the repository root:

```powershell
./build.ps1 -Task Test
```

Live Azure deployment and teardown tests begin in later delivery segments. They
must use an isolated subscription, explicit budget, bounded runtime, and cleanup
evidence.
