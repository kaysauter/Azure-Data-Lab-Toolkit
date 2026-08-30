# Deployment engines

A PowerShell deployment engine ships and is used by
`Start-AzureDataLabDeployment`, `Test-AzureDataLabWhatIf`, and
`Start-AzureDataLabTeardown`. It compiles an approved immutable plan into an ARM
template, submits it, inventories the result, and deletes approved resources.

It currently lives in Core (`Private/82-SqlVmArmTemplate.ps1` through
`Private/89-DeploymentProbe.ps1`) rather than behind this boundary, and dispatch
to it is hardcoded to the `sqlVm` target. Extracting it behind a registered
engine contract keyed on `(engine, targetType)` is tracked work; this directory
is the intended destination, not a description of today's layout.

The configuration selector is `engine.type`, whose schema enum already admits
`bicep` and `terraform`. Neither is implemented. Engines consume an approved
plan and may not redefine planning, ownership, approvals, or teardown policy.
