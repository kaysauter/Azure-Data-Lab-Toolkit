function Start-AzureDataLabDeployment {
    <#
    .SYNOPSIS
    Approves and starts one protected SQL VM deployment operation.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('StatePath')]
        [string] $RunPath,

        [AllowEmptyString()]
        [string] $ApprovalPhrase,

        [string[]] $AcknowledgementId = @()
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
                throw 'The protected run changed while acquiring operation locks.'
            }
            if ($context.Plan.target.type -cne 'sqlVm') {
                throw 'Only a SQL VM execution record is implemented.'
            }

            $record = $null
            $compilation = $null
            if (
                $context.State.status -eq 'authorizing' -and
                @($context.Artifacts).Count -eq 0
            ) {
                $evidenceSet = Get-AdltVerifiedPreflightEvidenceSet `
                    -Context $context
                if ($null -eq $evidenceSet.TeardownPreview) {
                    throw 'Deployment requires the complete protected preflight.'
                }
                $expectedPhrase = 'DEPLOY {0} {1}' -f
                    $context.State.scope.resourceGroupName,
                    $context.State.runId.Replace(
                        '-',
                        ''
                    ).Substring(0, 8).ToLowerInvariant()
                $target = '{0}/{1}' -f
                    $context.State.scope.subscriptionId,
                    $context.State.scope.resourceGroupName
                if (-not $PSCmdlet.ShouldProcess(
                    $target,
                    "Start protected deployment '$expectedPhrase'"
                )) {
                    return [pscustomobject][ordered]@{
                        PSTypeName =
                            'AzureDataLabToolkit.DeploymentApprovalPreview'
                        RunId = $context.State.runId
                        RunPath = [System.IO.Path]::GetFullPath($RunPath)
                        Status = 'approval-required'
                        RequiredApprovalPhrase = $expectedPhrase
                        RequiredAcknowledgementIds = @(
                            $context.Plan.approval.requiredAcknowledgementIds
                        )
                    }
                }
                if (-not [string]::Equals(
                    $ApprovalPhrase,
                    $expectedPhrase,
                    [System.StringComparison]::Ordinal
                )) {
                    throw "Approval phrase must exactly match '$expectedPhrase'."
                }
                Assert-AdltExactValueSet `
                    -Actual @($AcknowledgementId) `
                    -Expected @(
                        $context.Plan.approval.requiredAcknowledgementIds
                    ) `
                    -Name 'Deployment acknowledgement IDs'

                try {
                    $finalGate = New-AdltFinalDeploymentGate `
                        -Plan $context.Plan `
                        -LiveResolutionEvidence `
                            $evidenceSet.LiveResolution `
                        -WhatIfEvidence $evidenceSet.WhatIf `
                        -RunId $context.State.runId
                    $createdAt = [datetimeoffset]::UtcNow
                    $stateExpiresAt = [datetimeoffset]::Parse(
                        [string] $context.State.expiresAt,
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                    $teardownExpiresAt = $createdAt.AddMinutes(60)
                    if ($teardownExpiresAt -gt $stateExpiresAt) {
                        $teardownExpiresAt = $stateExpiresAt
                    }
                    if ($teardownExpiresAt -le $createdAt.AddMinutes(5)) {
                        throw (
                            'The run expires too soon to authorize a safe ' +
                            'deployment and teardown.'
                        )
                    }
                    $teardownPlan = New-AdltTeardownPlan `
                        -Plan $context.Plan `
                        -State $context.State `
                        -ObservedStateEvidence `
                            $evidenceSet.TeardownPreview `
                        -LiveResolutionEvidence `
                            $evidenceSet.LiveResolution `
                        -WhatIfEvidence $evidenceSet.WhatIf `
                        -CreatedAt $createdAt `
                        -ExpiresAt $teardownExpiresAt
                    $approval = [ordered]@{
                        approver = [ordered]@{
                            type = 'user'
                            id = $evidenceSet.LiveResolution.payload.
                                principalObjectId
                        }
                        mechanism = 'interactive'
                        approvedAt = ConvertTo-AdltUtcTimestamp `
                            -Value $createdAt
                        recordId = 'interactive:{0}' -f
                            [guid]::NewGuid().ToString()
                    }
                    $authorizationExpiresAt =
                        $createdAt.AddMinutes(10)
                    if (
                        $authorizationExpiresAt -gt
                        $teardownExpiresAt
                    ) {
                        $authorizationExpiresAt = $teardownExpiresAt
                    }
                    $compilation = New-AdltSqlVmArmCompilation `
                        -Plan $context.Plan `
                        -LiveResolutionEvidence `
                            $evidenceSet.LiveResolution
                    $maximumRunCost =
                        $context.Plan.configuration.cost.maximumRunCost
                    $authorization = New-AdltExecutionAuthorization `
                        -Operation deploy `
                        -Plan $context.Plan `
                        -State $context.State `
                        -LiveResolutionEvidence `
                            $evidenceSet.LiveResolution `
                        -WhatIfEvidence $evidenceSet.WhatIf `
                        -CostEvidence $evidenceSet.Cost `
                        -TeardownPlan $teardownPlan `
                        -ObservedStateEvidence `
                            $evidenceSet.TeardownPreview `
                        -Compilation $compilation `
                        -Approval $approval `
                        -MaximumCostMinorUnits (
                            [int64] $maximumRunCost.amountMinorUnits
                        ) `
                        -MaximumCostCurrency (
                            [string] $maximumRunCost.currency
                        ) `
                        -MaximumRuntimeMinutes (
                            [int] $context.Plan.configuration.lifecycle.
                                maximumRuntimeMinutes
                        ) `
                        -AcknowledgementIds @($AcknowledgementId) `
                        -CreatedAt $createdAt `
                        -ExpiresAt $authorizationExpiresAt
                    $record = New-AdltDeploymentExecutionRecord `
                        -Plan $context.Plan `
                        -State $context.State `
                        -LiveResolutionEvidence `
                            $evidenceSet.LiveResolution `
                        -WhatIfEvidence $evidenceSet.WhatIf `
                        -CostEvidence $evidenceSet.Cost `
                        -TeardownPreviewEvidence `
                            $evidenceSet.TeardownPreview `
                        -Compilation $compilation `
                        -Authorization $authorization `
                        -TeardownPlan $teardownPlan `
                        -FinalGate $finalGate `
                        -CreatedAt $createdAt
                    [void] (Add-AdltLocalExecutionRecord `
                        -RunPath $RunPath `
                        -ExecutionRecord $record `
                        -ActorId $approval.approver.id `
                        -OccurredAt $createdAt)
                }
                catch {
                    $authorizationFailure = $_.Exception
                    [void] (Set-AdltRunBlocked `
                        -RunPath $RunPath `
                        -ActorId AzureDataLabToolkit)
                    throw [System.InvalidOperationException]::new(
                        'Deployment authorization or final gate failed.',
                        $authorizationFailure
                    )
                }
            }
            elseif (
                $context.State.status -eq 'ready' -and
                @($context.Artifacts).Count -eq 1
            ) {
                $persisted =
                    Assert-AdltPersistedDeploymentExecutionRecord `
                        -Context $context
                $record = $persisted.ExecutionRecord
                $compilation = $persisted.Compilation
                $target = '{0}/{1}' -f
                    $context.State.scope.subscriptionId,
                    $context.State.scope.resourceGroupName
                if (-not $PSCmdlet.ShouldProcess(
                    $target,
                    "Resume approved operation '$($record.operationId)'"
                )) {
                    return [pscustomobject][ordered]@{
                        PSTypeName =
                            'AzureDataLabToolkit.DeploymentApprovalPreview'
                        RunId = $context.State.runId
                        RunPath = [System.IO.Path]::GetFullPath($RunPath)
                        Status = 'approved-not-started'
                        OperationId = $record.operationId
                        DeploymentName = $record.deployment.name
                    }
                }
            }
            else {
                throw (
                    "Run status '$($context.State.status)' cannot start a " +
                    'new Azure deployment.'
                )
            }

            $launchContext = Get-AdltVerifiedLocalRunContext `
                -RunPath $RunPath
            $launchValidation =
                Assert-AdltPersistedDeploymentExecutionRecord `
                    -Context $launchContext `
                    -AsOf ([datetimeoffset]::UtcNow)
            $record = $launchValidation.ExecutionRecord
            $compilation = $launchValidation.Compilation
            $mutationLease = New-AdltDeploymentMutationLease `
                -ExecutionRecord $record
            [void] (Assert-AdltAzureMutationPrincipal `
                -Plan $context.Plan `
                -ExpectedPrincipalId (
                    [string] $record.authorization.approval.approver.id
                ))
            $startedAt = [datetimeoffset]::UtcNow
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $RunPath `
                -EventType operation-started `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $record.operationId
                    executionRecordHash = $record.executionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $startedAt)
            try {
                $deploymentResult = Invoke-AdltSqlVmDeployment `
                    -Plan $context.Plan `
                    -Compilation $compilation `
                    -ExecutionRecord $record `
                    -MutationLease $mutationLease
            }
            catch {
                try {
                    $deploymentResult = Get-AdltSqlVmDeploymentStatus `
                        -Plan $context.Plan `
                        -ExecutionRecord $record
                }
                catch {
                    $failureKind = Get-AdltAzureFailureKind `
                        -ErrorRecord $_
                    $current = Get-AdltVerifiedLocalRunContext `
                        -RunPath $RunPath
                    if ($current.State.status -eq 'deploying') {
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
