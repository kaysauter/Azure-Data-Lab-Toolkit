function Resume-AzureDataLabDeployment {
    <#
    .SYNOPSIS
    Re-approves one deployment submission after Azure proves the first was absent.
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
                throw (
                    'The protected run changed while acquiring deployment ' +
                    'resume locks.'
                )
            }
            if ($context.State.status -cne 'deployment-unknown') {
                throw (
                    'Only a deployment-unknown run can resubmit an Azure ' +
                    'deployment.'
                )
            }
            $startEvents = @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq 'operation-started'
                    }
            )
            if ($startEvents.Count -ne 1) {
                throw 'Deployment resume requires one original start event.'
            }
            $startedAt = [datetimeoffset]::Parse(
                [string] $startEvents[0].occurredAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            $persisted =
                Assert-AdltPersistedDeploymentExecutionRecord `
                    -Context $context `
                    -AsOf $startedAt
            $record = $persisted.ExecutionRecord
            $compilation = $persisted.Compilation
            $terminalEvents = @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq 'operation-finished' -and
                        $_.data.operationId -ceq $record.operationId
                    }
            )
            $terminalEvidence = @(
                $context.Evidence |
                    Where-Object {
                        $_.stage -ceq 'deploy' -and
                        $_.payload.operationId -ceq $record.operationId
                    }
            )
            if (
                $terminalEvents.Count -ne 0 -or
                $terminalEvidence.Count -ne 0
            ) {
                throw (
                    'A terminal deployment outcome cannot be resubmitted.'
                )
            }

            $principalId = Assert-AdltAzureMutationPrincipal `
                -Plan $context.Plan `
                -ExpectedPrincipalId (
                    [string] $record.authorization.approval.approver.id
                )
            Assert-AdltSqlVmDeploymentRecordAbsent `
                -Plan $context.Plan `
                -ExecutionRecord $record
            Assert-AdltSqlVmDeploymentTargetAbsence `
                -Plan $context.Plan `
                -Compilation $compilation

            $expectedPhrase = Get-AdltDeploymentResumeApprovalPhrase `
                -State $context.State `
                -ExecutionRecord $record
            $target = '{0}/{1}' -f
                $context.State.scope.subscriptionId,
                $context.State.scope.resourceGroupName
            if (-not $PSCmdlet.ShouldProcess(
                $target,
                "Resubmit absent protected deployment '$expectedPhrase'"
            )) {
                return [pscustomobject][ordered]@{
                    PSTypeName =
                        'AzureDataLabToolkit.DeploymentResumeApprovalPreview'
                    RunId = $context.State.runId
                    RunPath = [System.IO.Path]::GetFullPath($RunPath)
                    Status = 'approval-required'
                    OperationId = $record.operationId
                    DeploymentName = $record.deployment.name
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

            $fresh = Get-AdltVerifiedLocalRunContext `
                -RunPath $RunPath
            if (
                $fresh.TailEvent.eventHash -cne
                    $context.TailEvent.eventHash -or
                $fresh.State.status -cne 'deployment-unknown'
            ) {
                throw (
                    'The protected run changed while authorizing deployment ' +
                    'resume. Review a new preview.'
                )
            }
            Assert-AdltSqlVmDeploymentRecordAbsent `
                -Plan $context.Plan `
                -ExecutionRecord $record
            Assert-AdltSqlVmDeploymentTargetAbsence `
                -Plan $context.Plan `
                -Compilation $compilation

            $approvedAt = [datetimeoffset]::UtcNow
            $resumeResult = Add-AdltLocalOperationEvent `
                -RunPath $RunPath `
                -EventType operation-resumed `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $record.operationId
                    executionRecordHash =
                        $record.executionRecordHash
                    confirmationPhraseHash =
                        Get-AdltSha256Identifier -Value $expectedPhrase
                    approvedAt =
                        ConvertTo-AdltUtcTimestamp -Value $approvedAt
                    expiresAt = ConvertTo-AdltUtcTimestamp `
                        -Value $approvedAt.AddMinutes(10)
                }) `
                -ActorType interactive-user `
                -ActorId $principalId `
                -OccurredAt $approvedAt
            $mutationLease = New-AdltDeploymentMutationLease `
                -ExecutionRecord $record `
                -ResumeEvent $resumeResult.RunEvent

            $deploymentFailureKind = $null
            try {
                $deploymentResult = Invoke-AdltSqlVmDeployment `
                    -Plan $context.Plan `
                    -Compilation $compilation `
                    -ExecutionRecord $record `
                    -MutationLease $mutationLease
            }
            catch {
                $deploymentFailureKind = Get-AdltAzureFailureKind `
                    -ErrorRecord $_
                try {
                    $deploymentResult = Get-AdltSqlVmDeploymentStatus `
                        -Plan $context.Plan `
                        -ExecutionRecord $record
                }
                catch {
                    $statusFailureKind = Get-AdltAzureFailureKind `
                        -ErrorRecord $_
                    $reason = if (
                        $deploymentFailureKind -in @(
                            'unauthenticated'
                            'denied'
                            'absent'
                            'conflict'
                            'throttled'
                        )
                    ) {
                        $deploymentFailureKind
                    }
                    elseif (
                        $statusFailureKind -in @(
                            'unauthenticated'
                            'denied'
                            'absent'
                            'conflict'
                            'throttled'
                        )
                    ) {
                        $statusFailureKind
                    }
                    else {
                        'unknown'
                    }
                    [void] (Add-AdltLocalOperationEvent `
                        -RunPath $RunPath `
                        -EventType operation-uncertain `
                        -Data ([ordered]@{
                            operation = 'deploy'
                            operationId = $record.operationId
                            reason = $reason
                        }) `
                        -ActorId AzureDataLabToolkit)
                    return [pscustomobject][ordered]@{
                        PSTypeName =
                            'AzureDataLabToolkit.DeploymentResult'
                        RunId = $context.State.runId
                        RunPath =
                            [System.IO.Path]::GetFullPath($RunPath)
                        OperationId = $record.operationId
                        DeploymentName = $record.deployment.name
                        ProvisioningState = 'Unknown'
                        Status = 'deployment-unknown'
                        EvidenceHash = $null
                        RequiresReconciliation = $true
                    }
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
                    Status = 'deploying'
                    EvidenceHash = $null
                    RequiresReconciliation = $true
                }
            }
            return Complete-AdltDeploymentOperation `
                -RunPath $RunPath `
                -Plan $context.Plan `
                -ExecutionRecord $record `
                -DeploymentResult $deploymentResult `
                -StartedAt $approvedAt `
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
