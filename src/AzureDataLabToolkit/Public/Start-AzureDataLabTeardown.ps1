function Start-AzureDataLabTeardown {
    <#
    .SYNOPSIS
    Inventories, approves, and removes one exact toolkit-owned resource set.
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
        $initialPlanHash = [string] $preliminary.Plan.planHash
        $initialScope = ConvertTo-AdltCanonicalJson `
            -InputObject $preliminary.State.scope
        $scopeLock = Open-AdltAzureScopeOperationLock `
            -Scope $preliminary.State.scope
        $operationLock = $null
        try {
            $operationLock = Open-AdltLocalRunOperationLock `
                -RunPath $RunPath
            $context = Get-AdltVerifiedLocalRunContext `
                -RunPath $RunPath
            if (
                $context.Plan.planHash -cne $initialPlanHash -or
                (ConvertTo-AdltCanonicalJson `
                    -InputObject $context.State.scope) -cne
                    $initialScope
            ) {
                throw 'The protected run changed while acquiring teardown locks.'
            }
            if ($context.Plan.target.type -cne 'sqlVm') {
                throw 'Only SQL VM teardown is implemented.'
            }
            if ($context.State.status -in @(
                'planned'
                'authorizing'
                'deploying'
                'deployment-unknown'
                'tearing-down'
                'completed'
            )) {
                throw (
                    "Run status '$($context.State.status)' cannot start a " +
                    'new teardown operation.'
                )
            }

            $deploymentRecord =
                Get-AdltDeploymentExecutionRecordFromContext `
                    -Context $context
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
            if (
                $deploymentRecord.deployment.
                    expectedGeneratedResourceSetHash -cne
                    $generatedSetHash
            ) {
                throw (
                    'The deployment record generated-resource contract ' +
                    'does not match the current bound compiler.'
                )
            }
            $principalId = Get-AdltCurrentInteractivePrincipalId `
                -Plan $context.Plan
            $completedDeployment = @(
                $context.Evidence |
                    Where-Object {
                        $_.stage -ceq 'deploy' -and
                        $_.status -ceq 'pass'
                    }
            ).Count -eq 1

            $existingTeardownRecords = @(
                $context.Artifacts |
                    Where-Object {
                        $_.kind -ceq
                            'AzureDataLabTeardownExecutionRecord'
                    }
            )
            $teardownRecord = $null
            $inventory = $null
            if ($existingTeardownRecords.Count -eq 0) {
                $inventory = Get-AdltSqlVmTeardownInventory `
                    -Plan $context.Plan `
                    -State $context.State `
                    -Compilation $compilation `
                    -RequireCompleteDeployment:$completedDeployment
                $expectedPhrase = Get-AdltTeardownApprovalPhrase `
                    -State $context.State `
                    -Inventory $inventory
            }
            elseif (
                $existingTeardownRecords.Count -eq 1 -and
                $context.State.status -ceq 'teardown-pending'
            ) {
                $teardownRecord = ConvertTo-AdltDictionary `
                    -InputObject $existingTeardownRecords[0]
                $inventory = Get-AdltSqlVmTeardownInventory `
                    -Plan $context.Plan `
                    -State $context.State `
                    -Compilation $compilation `
                    -RequireCompleteDeployment:$completedDeployment
                if (
                    $inventory.inventoryHash -cne
                        $teardownRecord.inventory.inventoryHash
                ) {
                    throw (
                        'Fresh Azure inventory drifted after teardown ' +
                        'authorization. No deletion was attempted.'
                    )
                }
                $expectedPhrase = Get-AdltTeardownApprovalPhrase `
                    -State $context.State `
                    -Inventory $inventory
                Assert-AdltTeardownExecutionRecordArtifact `
                    -ExecutionRecord $teardownRecord `
                    -State $context.State
                if (
                    $teardownRecord.deploymentExecutionRecordHash -cne
                        $deploymentRecord.executionRecordHash
                ) {
                    throw (
                        'Teardown record is not bound to the deployment ' +
                        'execution record.'
                    )
                }
                if (
                    $principalId -cne
                        $teardownRecord.cleanupLease.approver.id
                ) {
                    throw (
                        'Pending teardown must be resumed by the same ' +
                        'interactive Azure user who authorized it.'
                    )
                }
            }
            else {
                throw 'The protected run has an invalid teardown record set.'
            }

            $target = '{0}/{1}' -f
                $context.State.scope.subscriptionId,
                $context.State.scope.resourceGroupName
            if (-not $PSCmdlet.ShouldProcess(
                $target,
                "Delete exact protected lab resources '$expectedPhrase'"
            )) {
                return [pscustomobject][ordered]@{
                    PSTypeName =
                        'AzureDataLabToolkit.TeardownApprovalPreview'
                    RunId = $context.State.runId
                    RunPath = [System.IO.Path]::GetFullPath($RunPath)
                    Status = 'approval-required'
                    ResourceGroupName =
                        $context.State.scope.resourceGroupName
                    ResourceCount = [int] $inventory.resourceCount
                    InventoryHash = $inventory.inventoryHash
                    Resources = @($inventory.resources)
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

            $freshInventory = Get-AdltSqlVmTeardownInventory `
                -Plan $context.Plan `
                -State $context.State `
                -Compilation $compilation `
                -RequireCompleteDeployment:$completedDeployment
            if (
                $freshInventory.inventoryHash -cne
                    $inventory.inventoryHash
            ) {
                throw (
                    'Azure inventory changed while authorizing teardown. ' +
                    'Review a new preview before trying again.'
                )
            }

            if ($null -eq $teardownRecord) {
                $createdAt = [datetimeoffset]::UtcNow
                $teardownRecord = New-AdltTeardownExecutionRecord `
                    -Plan $context.Plan `
                    -State $context.State `
                    -DeploymentExecutionRecord $deploymentRecord `
                    -Inventory $freshInventory `
                    -ApproverId $principalId `
                    -CreatedAt $createdAt
                [void] (Add-AdltLocalTeardownExecutionRecord `
                    -RunPath $RunPath `
                    -ExecutionRecord $teardownRecord `
                    -ActorId $principalId `
                    -OccurredAt $createdAt)
            }
            else {
                $authorizationAt = [datetimeoffset]::UtcNow
                $effectiveLease = Get-AdltEffectiveTeardownCleanupLease `
                    -Context $context `
                    -ExecutionRecord $teardownRecord
                $approvedAt = [datetimeoffset]::Parse(
                    [string] $effectiveLease.approvedAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
                $expiresAt = [datetimeoffset]::Parse(
                    [string] $effectiveLease.expiresAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
                if ($authorizationAt -lt $approvedAt) {
                    throw 'The pending cleanup lease begins in the future.'
                }
                if ($authorizationAt -ge $expiresAt) {
                    [void] (Add-AdltLocalTeardownAuthorizationRefresh `
                        -RunPath $RunPath `
                        -ActorId $principalId `
                        -InventoryHash $freshInventory.inventoryHash `
                        -OccurredAt $authorizationAt)
                }
                else {
                    Assert-AdltTeardownCleanupLease `
                        -CleanupLease $effectiveLease `
                        -ExecutionRecord $teardownRecord `
                        -AsOf $authorizationAt
                }
            }

            $authorizationContext = Get-AdltVerifiedLocalRunContext `
                -RunPath $RunPath
            $teardownRecord = Get-AdltTeardownExecutionRecordFromContext `
                -Context $authorizationContext
            $deploymentRecord = Get-AdltDeploymentExecutionRecordFromContext `
                -Context $authorizationContext
            $effectiveLease = Get-AdltEffectiveTeardownCleanupLease `
                -Context $authorizationContext `
                -ExecutionRecord $teardownRecord
            $mutationLease = New-AdltTeardownMutationLease `
                -CleanupLease $effectiveLease `
                -ExecutionRecord $teardownRecord `
                -AuthorizationKind start `
                -AuthorizationEventHash (
                    [string] $authorizationContext.TailEvent.eventHash
                )
            $mutationAuthorizedAt = [datetimeoffset]::UtcNow
            Assert-AdltTeardownExecutionRecordForExecution `
                -ExecutionRecord $teardownRecord `
                -State $authorizationContext.State `
                -DeploymentExecutionRecord $deploymentRecord `
                -CleanupLease $mutationLease `
                -AsOf $mutationAuthorizedAt
            [void] (Assert-AdltAzureMutationPrincipal `
                -Plan $context.Plan `
                -ExpectedPrincipalId (
                    [string] $mutationLease.approver.id
                ))
            $startedAt = [datetimeoffset]::UtcNow
            [void] (Add-AdltLocalTeardownOperationEvent `
                -RunPath $RunPath `
                -EventType teardown-operation-started `
                -Data ([ordered]@{
                    operation = 'teardown'
                    operationId = $teardownRecord.operationId
                    teardownExecutionRecordHash =
                        $teardownRecord.teardownExecutionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $startedAt)
            $deleteFailureKind = $null
            try {
                [void] (Invoke-AdltApprovedResourceDeletion `
                    -Plan $context.Plan `
                    -Compilation $compilation `
                    -ExecutionRecord $teardownRecord `
                    -CleanupLease $mutationLease
                )
            }
            catch {
                $deleteFailureKind = Get-AdltAzureFailureKind `
                    -ErrorRecord $_
            }
            $observation = Get-AdltApprovedResourceDeletionObservation `
                -ExecutionRecord $teardownRecord
            if (
                $observation.state -ceq
                    'approved-resources-absent'
            ) {
                return Complete-AdltTeardownOperation `
                    -RunPath $RunPath `
                    -Plan $context.Plan `
                    -ExecutionRecord $teardownRecord `
                    -Observation $observation `
                    -StartedAt $startedAt `
                    -CompletedAt ([datetimeoffset]::UtcNow)
            }

            $reason = if (
                $null -ne $deleteFailureKind -and
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
                    operationId = $teardownRecord.operationId
                    reason = $reason
                }) `
                -ActorId AzureDataLabToolkit)
            return [pscustomobject][ordered]@{
                PSTypeName = 'AzureDataLabToolkit.TeardownResult'
                RunId = $context.State.runId
                RunPath = [System.IO.Path]::GetFullPath($RunPath)
                OperationId = $teardownRecord.operationId
                ResourceGroupName =
                    $teardownRecord.deleteAction.resourceGroupName
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
