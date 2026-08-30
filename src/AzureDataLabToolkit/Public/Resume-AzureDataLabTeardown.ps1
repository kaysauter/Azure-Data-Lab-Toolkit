function Resume-AzureDataLabTeardown {
    <#
    .SYNOPSIS
    Re-approves and retries only the still-present resources from a prior teardown.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('StatePath')]
        [string] $RunPath,

        [AllowEmptyString()]
        [string] $ApprovalPhrase
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
                $context.Plan.planHash -cne
                    $preliminary.Plan.planHash -or
                (ConvertTo-AdltCanonicalJson `
                    -InputObject $context.State.scope) -cne
                (ConvertTo-AdltCanonicalJson `
                    -InputObject $preliminary.State.scope)
            ) {
                throw 'The protected run changed while acquiring teardown resume locks.'
            }
            if ($context.State.status -cne 'cleanup-unknown') {
                throw 'Only a cleanup-unknown run can resume teardown.'
            }
            $record = Get-AdltTeardownExecutionRecordFromContext `
                -Context $context
            $principalId = Assert-AdltAzureMutationPrincipal `
                -Plan $context.Plan `
                -ExpectedPrincipalId (
                    [string] $record.cleanupLease.approver.id
                )
            $liveResolution = Get-AdltRunEvidenceByStage `
                -Evidence $context.Evidence `
                -Stage live-resolution
            $compilation = New-AdltSqlVmArmCompilation `
                -Plan $context.Plan `
                -LiveResolutionEvidence $liveResolution
            $generatedSetHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson `
                    -InputObject $compilation.expectedGeneratedResources
            )
            $deploymentRecord =
                Get-AdltDeploymentExecutionRecordFromContext `
                    -Context $context
            if (
                $deploymentRecord.deployment.
                    expectedGeneratedResourceSetHash -cne
                    $generatedSetHash
            ) {
                throw 'Teardown resume compiler contract does not match deployment.'
            }

            $remaining = Get-AdltRemainingApprovedResourceSet `
                -ExecutionRecord $record `
                -Plan $context.Plan `
                -Compilation $compilation
            if ([int] $remaining.resourceCount -eq 0) {
                $observation =
                    Get-AdltApprovedResourceDeletionObservation `
                        -ExecutionRecord $record
                if (
                    $observation.state -cne
                        'approved-resources-absent'
                ) {
                    throw 'Azure did not prove the approved resource set absent.'
                }
                $startEvent = @(
                    $context.Events |
                        Where-Object {
                            $_.eventType -ceq
                                'teardown-operation-started' -and
                            $_.data.operationId -ceq $record.operationId
                        }
                )
                return Complete-AdltTeardownOperation `
                    -RunPath $RunPath `
                    -Plan $context.Plan `
                    -ExecutionRecord $record `
                    -Observation $observation `
                    -StartedAt ([datetimeoffset]::Parse(
                        [string] $startEvent[0].occurredAt,
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )) `
                    -CompletedAt ([datetimeoffset]::UtcNow)
            }

            $expectedPhrase = Get-AdltTeardownResumeApprovalPhrase `
                -ExecutionRecord $record `
                -RemainingResourceSet $remaining
            $target = '{0}/{1}' -f
                $context.State.scope.subscriptionId,
                $context.State.scope.resourceGroupName
            if (-not $PSCmdlet.ShouldProcess(
                $target,
                "Retry exact protected lab resources '$expectedPhrase'"
            )) {
                return [pscustomobject][ordered]@{
                    PSTypeName =
                        'AzureDataLabToolkit.TeardownResumeApprovalPreview'
                    RunId = $context.State.runId
                    RunPath = [System.IO.Path]::GetFullPath($RunPath)
                    Status = 'approval-required'
                    ResourceGroupName =
                        $context.State.scope.resourceGroupName
                    ResourceCount = [int] $remaining.resourceCount
                    ResourceSetHash = $remaining.resourceSetHash
                    Resources = @($remaining.resources)
                    RequiredApprovalPhrase = $expectedPhrase
                }
            }
            if (-not [string]::Equals(
                $ApprovalPhrase,
                $expectedPhrase,
                [System.StringComparison]::Ordinal
            )) {
                throw "Approval phrase must exactly match '$expectedPhrase'."
            }

            $freshRemaining = Get-AdltRemainingApprovedResourceSet `
                -ExecutionRecord $record `
                -Plan $context.Plan `
                -Compilation $compilation
            if (
                $freshRemaining.resourceSetHash -cne
                    $remaining.resourceSetHash
            ) {
                throw (
                    'Remaining Azure resources changed while authorizing ' +
                    'teardown resume. Review a new preview.'
                )
            }
            $approvedAt = [datetimeoffset]::UtcNow
            $resumeAttachment = Add-AdltLocalTeardownOperationEvent `
                -RunPath $RunPath `
                -EventType teardown-operation-resumed `
                -Data ([ordered]@{
                    operation = 'teardown'
                    operationId = $record.operationId
                    teardownExecutionRecordHash =
                        $record.teardownExecutionRecordHash
                    remainingResourceSetHash =
                        $freshRemaining.resourceSetHash
                    confirmationPhraseHash =
                        Get-AdltSha256Identifier -Value $expectedPhrase
                    approvedAt =
                        ConvertTo-AdltUtcTimestamp -Value $approvedAt
                    expiresAt = ConvertTo-AdltUtcTimestamp `
                        -Value $approvedAt.AddMinutes(10)
                }) `
                -ActorId $principalId `
                -OccurredAt $approvedAt
            $effectiveLease = Copy-AdltValue `
                -InputObject $record.cleanupLease
            $effectiveLease.approvedAt =
                [string] $resumeAttachment.RunEvent.data.approvedAt
            $effectiveLease.expiresAt =
                [string] $resumeAttachment.RunEvent.data.expiresAt
            $mutationLease = New-AdltTeardownMutationLease `
                -CleanupLease $effectiveLease `
                -ExecutionRecord $record `
                -AuthorizationKind resume `
                -AuthorizationEventHash (
                    [string] $resumeAttachment.RunEvent.eventHash
                )
            Assert-AdltTeardownExecutionRecordForExecution `
                -ExecutionRecord $record `
                -State $context.State `
                -DeploymentExecutionRecord $deploymentRecord `
                -CleanupLease $mutationLease `
                -AsOf $approvedAt

            $deleteFailureKind = $null
            try {
                [void] (Invoke-AdltApprovedResourceDeletion `
                    -Plan $context.Plan `
                    -Compilation $compilation `
                    -ExecutionRecord $record `
                    -CleanupLease $mutationLease)
            }
            catch {
                $deleteFailureKind = Get-AdltAzureFailureKind `
                    -ErrorRecord $_
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
                    -StartedAt $approvedAt `
                    -CompletedAt ([datetimeoffset]::UtcNow)
            }

            $reason = if (
                $deleteFailureKind -in @(
                    'unauthenticated'
                    'denied'
                    'absent'
                    'conflict'
                    'throttled'
                    'unknown'
                )
            ) {
                $deleteFailureKind
            }
            elseif (
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
