function Resolve-AzureDataLabDeployment {
    <#
    .SYNOPSIS
    Reconciles a previously started SQL VM deployment without resubmitting it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('StatePath')]
        [string] $RunPath
    )

    process {
        $preliminary = Get-AdltVerifiedLocalRunContext `
            -RunPath $RunPath
        $scopeLock = Open-AdltAzureScopeOperationLock `
            -Scope $preliminary.State.scope
        $operationLock = $null
        try {
            $operationLock = Open-AdltLocalRunOperationLock `
                -RunPath $RunPath
            $context = Get-AdltVerifiedLocalRunContext `
                -RunPath $RunPath
            if (
                $context.Plan.planHash -cne $preliminary.Plan.planHash -or
                (ConvertTo-AdltCanonicalJson `
                    -InputObject $context.State.scope) -cne
                (ConvertTo-AdltCanonicalJson `
                    -InputObject $preliminary.State.scope)
            ) {
                throw 'The protected run changed while acquiring operation locks.'
            }
            if (@($context.Artifacts).Count -ne 1) {
                throw 'Deployment reconciliation requires one execution record.'
            }
            $record = ConvertTo-AdltDictionary `
                -InputObject $context.Artifacts[0]
            Assert-AdltExecutionRecordArtifact `
                -ExecutionRecord $record `
                -State $context.State
            $startEvents = @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq 'operation-started' -and
                        $_.data.operationId -ceq $record.operationId
                    }
            )
            if ($startEvents.Count -ne 1) {
                throw 'Deployment reconciliation requires one start event.'
            }
            $finishEvents = @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq 'operation-finished' -and
                        $_.data.operationId -ceq $record.operationId
                    }
            )
            $deployEvidence = @(
                $context.Evidence |
                    Where-Object {
                        $_.stage -ceq 'deploy' -and
                        $_.payload.operationId -ceq $record.operationId
                    }
            )
            if (
                $finishEvents.Count -eq 1 -and
                $deployEvidence.Count -eq 1
            ) {
                return [pscustomobject][ordered]@{
                    PSTypeName =
                        'AzureDataLabToolkit.DeploymentResult'
                    RunId = $context.State.runId
                    RunPath = [System.IO.Path]::GetFullPath($RunPath)
                    OperationId = $record.operationId
                    DeploymentName = $record.deployment.name
                    ProvisioningState =
                        $deployEvidence[0].payload.provisioningState
                    Status = $context.State.status
                    EvidenceHash = $deployEvidence[0].evidenceHash
                    RequiresReconciliation = $false
                }
            }
            if (
                $finishEvents.Count -gt 1 -or
                $deployEvidence.Count -gt 1 -or
                $context.State.status -notin @(
                    'deploying'
                    'deployment-unknown'
                )
            ) {
                throw 'Deployment reconciliation state is inconsistent.'
            }

            $startedAt = [datetimeoffset]::Parse(
                [string] $startEvents[0].occurredAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            if ($deployEvidence.Count -eq 1) {
                $payload = $deployEvidence[0].payload
                $deploymentResult = [ordered]@{
                    deploymentName = $payload.deploymentName
                    deploymentId = $payload.deploymentId
                    correlationId = $payload.correlationId
                    provisioningState = $payload.provisioningState
                    terminal = $true
                    outcome = $payload.outcome
                }
                return Complete-AdltDeploymentOperation `
                    -RunPath $RunPath `
                    -Plan $context.Plan `
                    -ExecutionRecord $record `
                    -DeploymentResult $deploymentResult `
                    -StartedAt $startedAt `
                    -CompletedAt ([datetimeoffset]::UtcNow)
            }

            try {
                $deploymentResult = Get-AdltSqlVmDeploymentStatus `
                    -Plan $context.Plan `
                    -ExecutionRecord $record
            }
            catch {
                $failureKind = Get-AdltAzureFailureKind `
                    -ErrorRecord $_
                if ($context.State.status -eq 'deploying') {
                    [void] (Add-AdltLocalOperationEvent `
                        -RunPath $RunPath `
                        -EventType operation-uncertain `
                        -Data ([ordered]@{
                            operation = 'deploy'
                            operationId = $record.operationId
                            reason = $failureKind
                        }) `
                        -ActorId AzureDataLabToolkit)
                }
                return [pscustomobject][ordered]@{
                    PSTypeName =
                        'AzureDataLabToolkit.DeploymentResult'
                    RunId = $context.State.runId
                    RunPath = [System.IO.Path]::GetFullPath($RunPath)
                    OperationId = $record.operationId
                    DeploymentName = $record.deployment.name
                    ProvisioningState = 'Unknown'
                    Status = 'deployment-unknown'
                    EvidenceHash = $null
                    RequiresReconciliation = $true
                }
            }
            if (-not [bool] $deploymentResult.terminal) {
                return [pscustomobject][ordered]@{
                    PSTypeName =
                        'AzureDataLabToolkit.DeploymentResult'
                    RunId = $context.State.runId
                    RunPath = [System.IO.Path]::GetFullPath($RunPath)
                    OperationId = $record.operationId
                    DeploymentName = $record.deployment.name
                    ProvisioningState =
                        $deploymentResult.provisioningState
                    Status = $context.State.status
                    EvidenceHash = $null
                    RequiresReconciliation = $true
                }
            }
            return Complete-AdltDeploymentOperation `
                -RunPath $RunPath `
                -Plan $context.Plan `
                -ExecutionRecord $record `
                -DeploymentResult $deploymentResult `
                -StartedAt $startedAt `
                -CompletedAt ([datetimeoffset]::UtcNow)
        }
        finally {
            if ($null -ne $operationLock) {
                $operationLock.Dispose()
            }
            $scopeLock.Dispose()
        }
    }
}
