# Tests

The test strategy will cover:

- PowerShell unit tests with Pester;
- schema and configuration validation;
- provider contract tests;
- engine plan-parity tests;
- mocked deployment and teardown tests;
- opt-in Azure integration tests;
- post-deployment probes and cost-guardrail checks.

Integration tests must use explicit budgets, deterministic naming, time limits, and cleanup verification.
