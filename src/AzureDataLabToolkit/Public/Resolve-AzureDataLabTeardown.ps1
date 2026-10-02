function Resolve-AzureDataLabTeardown {
    <#
    .SYNOPSIS
    Reconciles exact-resource cleanup without resubmitting deletion.
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
            $record = Get-AdltTeardownExecutionRecordFromContext `
                -Context $context
            [void] (Assert-AdltAzureMutationPrincipal `
                -Plan $context.Plan `
                -ExpectedPrincipalId (
                    [string] $record.cleanupLease.approver.id
                ))

            $finishEvents = @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq
                            'teardown-operation-finished' -and
                        $_.data.operationId -ceq $record.operationId
                    }
            )
            if ($finishEvents.Count -eq 1) {
                $proof = @(
                    $context.Evidence |
                        Where-Object {
                            $_.evidenceHash -ceq
                                $finishEvents[0].data.evidenceHash
                        }
                )
                if ($proof.Count -ne 1) {
                    throw 'Completed teardown is missing its cleanup proof.'
                }
                return [pscustomobject][ordered]@{
                    PSTypeName =
                        'AzureDataLabToolkit.TeardownResult'
                    RunId = $context.State.runId
                    RunPath = [System.IO.Path]::GetFullPath($RunPath)
                    OperationId = $record.operationId
                    ResourceGroupName =
                        $record.deleteAction.resourceGroupName
                    Status = 'completed'
                    EvidenceHash = $proof[0].evidenceHash
                    ResourceGroupRetained =
                        $proof[0].payload.resourceGroupState -ceq
                            'present'
                    RetainedUnapprovedResourceCount =
                        [int] $proof[0].payload.
                            retainedUnapprovedResourceCount
                    RequiresReconciliation = $false
                }
            }
            if ($finishEvents.Count -gt 1) {
                throw 'Teardown has duplicate terminal events.'
            }

            $startEvents = @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq
                            'teardown-operation-started' -and
                        $_.data.operationId -ceq $record.operationId
                    }
            )
            if ($startEvents.Count -eq 0) {
                return [pscustomobject][ordered]@{
                    PSTypeName =
                        'AzureDataLabToolkit.TeardownResult'
                    RunId = $context.State.runId
                    RunPath = [System.IO.Path]::GetFullPath($RunPath)
                    OperationId = $record.operationId
                    ResourceGroupName =
                        $record.deleteAction.resourceGroupName
                    Status = 'approved-not-started'
                    EvidenceHash = $null
                    ResourceGroupRetained = $null
                    RetainedUnapprovedResourceCount = $null
                    RequiresReconciliation = $false
                }
            }
            if ($startEvents.Count -ne 1) {
                throw 'Teardown must have exactly one start event.'
            }

            $observation = Get-AdltApprovedResourceDeletionObservation `
                -ExecutionRecord $record
            if (
                $observation.state -ceq
                    'approved-resources-absent'
            ) {
                return Complete-AdltTeardownOperation `
                    -RunPath $RunPath `
                    -Plan $context.Plan `
                    -ExecutionRecord $record `
                    -Observation $observation `
                    -StartedAt ([datetimeoffset]::Parse(
                        [string] $startEvents[0].occurredAt,
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )) `
                    -CompletedAt ([datetimeoffset]::UtcNow)
            }

            if ($context.State.status -ceq 'tearing-down') {
                $reason = if (
                    $observation.failureKind -in @(
                        'unauthenticated'
                        'denied'
                        'absent'
                        'conflict'
                        'throttled'
                        'unknown'
                    )
                ) {
                    $observation.failureKind
                }
                else {
                    'unknown'
                }
                [void] (Add-AdltLocalTeardownOperationEvent `
                    -RunPath $RunPath `
                    -EventType teardown-operation-uncertain `
                    -Data ([ordered]@{
                        operation = 'teardown'
                        operationId = $record.operationId
                        reason = $reason
                    }) `
                    -ActorId AzureDataLabToolkit)
            }
            return [pscustomobject][ordered]@{
                PSTypeName = 'AzureDataLabToolkit.TeardownResult'
                RunId = $context.State.runId
                RunPath = [System.IO.Path]::GetFullPath($RunPath)
                OperationId = $record.operationId
                ResourceGroupName =
                    $record.deleteAction.resourceGroupName
                Status = 'cleanup-unknown'
                EvidenceHash = $null
                ResourceGroupRetained = $null
                RetainedUnapprovedResourceCount = $null
                RequiresReconciliation = $true
            }
        }
        finally {
            if ($null -ne $operationLock) {
                $operationLock.Dispose()
            }
            $scopeLock.Dispose()
        }
    }
}
