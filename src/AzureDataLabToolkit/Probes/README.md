# Probes

Post-deployment probing is implemented, but it currently lives in Core as
`Invoke-AdltPostDeploymentProbe` (`Private/89-DeploymentProbe.ps1`) rather than
behind this boundary. `Test-AzureDataLabDeployment` drives it: it verifies
declared postconditions against live resources and emits readiness evidence
without owning deployment.

Moving it behind a registered engine operation is tracked work; this directory
is the intended destination, not a description of today's layout.
