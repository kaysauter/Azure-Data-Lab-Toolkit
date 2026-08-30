function New-AdltSqlVmReadinessResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('pass', 'fail', 'denied', 'unverified')]
        [string] $Status,

        [AllowNull()]
        [string] $FailureKind,

        [Parameter(Mandatory)]
        [bool] $Retryable,

        [Parameter(Mandatory)]
        [object[]] $Checks
    )

    $result = [ordered]@{
        status = $Status
        failureKind = if (
            [string]::IsNullOrWhiteSpace($FailureKind)
        ) {
            $null
        }
        else {
            $FailureKind
        }
        retryable = $Retryable
        checks = @($Checks)
    }
    $result.readinessHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $result
    )
    return $result
}

function Get-AdltSqlVmResourceReadinessCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource,

        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $CheckId
    )

    $read = Get-AdltAzureResourceRead `
        -Resource $Resource `
        -ResourceId $ResourceId
    if ($read.status -cne 'present') {
        $status = if ($read.status -in @(
            'unauthenticated'
            'denied'
        )) {
            'denied'
        }
        elseif ($read.status -ceq 'absent') {
            'fail'
        }
        else {
            'unverified'
        }
        return [ordered]@{
            checkId = $CheckId
            status = $status
            failureKind = [string] $read.failureKind
            retryable = $status -in @('denied', 'unverified')
            resourceId = $ResourceId
            provisioningState = $null
            powerState = $null
        }
    }

    $observedId = Get-AdltObservedResourceId `
        -Observed $read.observed
    $observedType = Get-AdltObservedResourceType `
        -Observed $read.observed
    if (
        -not [string]::Equals(
            $observedId,
            $ResourceId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            $observedType,
            [string] $Resource.type,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return [ordered]@{
            checkId = $CheckId
            status = 'fail'
            failureKind = 'resource-identity-mismatch'
            retryable = $false
            resourceId = $ResourceId
            provisioningState = $null
            powerState = $null
        }
    }

    $provisioningState = [string] (
        Get-AdltObservedNestedValue `
            -Observed $read.observed `
            -CandidatePaths @(
                'Properties.ProvisioningState'
                'ProvisioningState'
            )
    )
    $status = if (
        [string]::Equals(
            $provisioningState,
            'Succeeded',
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        'pass'
    }
    elseif ($provisioningState -in @('Failed', 'Canceled')) {
        'fail'
    }
    else {
        'unverified'
    }
    $failureKind = if ($status -ceq 'pass') {
        $null
    }
    elseif ([string]::IsNullOrWhiteSpace($provisioningState)) {
        'resource-provisioning-unverified'
    }
    elseif ($status -ceq 'fail') {
        'resource-provisioning-failed'
    }
    else {
        'resource-provisioning-unverified'
    }
    return [ordered]@{
        checkId = $CheckId
        status = $status
        failureKind = $failureKind
        retryable = $status -ceq 'unverified'
        resourceId = $ResourceId
        provisioningState = if (
            [string]::IsNullOrWhiteSpace($provisioningState)
        ) {
            $null
        }
        else {
            $provisioningState
        }
        powerState = $null
    }
}

function Get-AdltSqlVmControlPlaneReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation
    )

    $resourceMap = Get-AdltSqlVmArmResourceMap -Plan $Plan
    $checks = [System.Collections.Generic.List[object]]::new()
    $resourceContracts = @(
        [ordered]@{
            stableId = 'azure.compute.virtual-machine.primary'
            checkId = 'vm-control-plane'
        }
        [ordered]@{
            stableId = 'azure.sql.virtual-machine.primary'
            checkId = 'sql-iaas-registration'
        }
    )
    foreach ($contract in $resourceContracts) {
        $bindings = @(
            $Compilation.resourceBindings |
                Where-Object {
                    $_.stableId -ceq $contract.stableId -and
                    $_.disposition -ceq 'deploy'
                }
        )
        if ($bindings.Count -ne 1) {
            throw (
                "Readiness contract '$($contract.stableId)' requires one " +
                'deployed resource binding.'
            )
        }
        $resource = $resourceMap[[string] $contract.stableId]
        $check = Get-AdltSqlVmResourceReadinessCheck `
            -Resource $resource `
            -ResourceId ([string] $bindings[0].resourceId) `
            -CheckId ([string] $contract.checkId)
        $checks.Add($check)
        if ($check.status -cne 'pass') {
            return New-AdltSqlVmReadinessResult `
                -Status ([string] $check.status) `
                -FailureKind ([string] $check.failureKind) `
                -Retryable ([bool] $check.retryable) `
                -Checks @($checks.ToArray())
        }
    }

    $extensionContracts = @(
        $Compilation.expectedGeneratedResources |
            Where-Object {
                $_.relationship -ceq 'sql-iaas-agent-extension'
            }
    )
    if ($extensionContracts.Count -ne 1) {
        throw 'Readiness requires one SQL IaaS Agent extension contract.'
    }
    $extension = ConvertTo-AdltDictionary `
        -InputObject $extensionContracts[0]
    $extensionResource = [ordered]@{
        type = [string] $extension.resourceType
        apiVersion = Get-AdltGeneratedResourceApiVersion `
            -ResourceType ([string] $extension.resourceType)
        logicalName = Get-AdltResourceNameFromId `
            -ResourceId ([string] $extension.resourceId)
    }
    $extensionCheck = Get-AdltSqlVmResourceReadinessCheck `
        -Resource $extensionResource `
        -ResourceId ([string] $extension.resourceId) `
        -CheckId 'sql-iaas-extension'
    $checks.Add($extensionCheck)
    if ($extensionCheck.status -cne 'pass') {
        return New-AdltSqlVmReadinessResult `
            -Status ([string] $extensionCheck.status) `
            -FailureKind ([string] $extensionCheck.failureKind) `
            -Retryable ([bool] $extensionCheck.retryable) `
            -Checks @($checks.ToArray())
    }

    $vmBinding = @(
        $Compilation.resourceBindings |
            Where-Object {
                $_.stableId -ceq
                    'azure.compute.virtual-machine.primary'
            }
    )[0]
    $vmResource = $resourceMap[
        'azure.compute.virtual-machine.primary'
    ]
    $instanceView = Invoke-AdltAzCommand `
        -ModuleName Az.Compute `
        -CommandName Get-AzVM `
        -Parameters @{
            ResourceGroupName =
                [string] $Plan.configuration.azure.resourceGroup.name
            Name = [string] $vmResource.logicalName
            Status = $true
            ErrorAction = 'Stop'
        }
    if ($null -eq $instanceView) {
        return New-AdltSqlVmReadinessResult `
            -Status unverified `
            -FailureKind empty-vm-instance-view `
            -Retryable $true `
            -Checks @($checks.ToArray())
    }
    $instanceViewId = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $instanceView `
            -Name Id
    )
    if (
        -not [string]::Equals(
            $instanceViewId,
            [string] $vmBinding.resourceId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return New-AdltSqlVmReadinessResult `
            -Status fail `
            -FailureKind vm-instance-identity-mismatch `
            -Retryable $false `
            -Checks @($checks.ToArray())
    }
    $statusCodes = @(
        @(
            Get-AdltObjectPropertyValue `
                -InputObject $instanceView `
                -Name Statuses
        ) |
            ForEach-Object {
                [string] (
                    Get-AdltObjectPropertyValue `
                        -InputObject $_ `
                        -Name Code
                )
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )
    $provisioningCode = @(
        $statusCodes |
            Where-Object {
                $_ -like 'ProvisioningState/*'
            }
    )
    $powerCode = @(
        $statusCodes |
            Where-Object {
                $_ -like 'PowerState/*'
            }
    )
    $instanceStatus = if (
        $provisioningCode.Count -eq 1 -and
        $powerCode.Count -eq 1 -and
        [string]::Equals(
            $provisioningCode[0],
            'ProvisioningState/succeeded',
            [System.StringComparison]::OrdinalIgnoreCase
        ) -and
        [string]::Equals(
            $powerCode[0],
            'PowerState/running',
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        'pass'
    }
    elseif (
        $provisioningCode.Count -eq 1 -and
        $powerCode.Count -eq 1
    ) {
        'fail'
    }
    else {
        'unverified'
    }
    $instanceCheck = [ordered]@{
        checkId = 'vm-instance-view'
        status = $instanceStatus
        failureKind = if ($instanceStatus -ceq 'pass') {
            $null
        }
        else {
            'vm-instance-not-running'
        }
        retryable = $instanceStatus -ceq 'unverified'
        resourceId = [string] $vmBinding.resourceId
        provisioningState = if ($provisioningCode.Count -eq 1) {
            [string] $provisioningCode[0]
        }
        else {
            $null
        }
        powerState = if ($powerCode.Count -eq 1) {
            [string] $powerCode[0]
        }
        else {
            $null
        }
    }
    $checks.Add($instanceCheck)
    return New-AdltSqlVmReadinessResult `
        -Status $instanceStatus `
        -FailureKind ([string] $instanceCheck.failureKind) `
        -Retryable ([bool] $instanceCheck.retryable) `
        -Checks @($checks.ToArray())
}

function Get-AdltPostDeploymentProbeEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DeploymentEvidence,

        [Parameter(Mandatory)]
        [ValidateRange(1, 256)]
        [int] $RequiredResourceCount,

        [AllowNull()]
        [System.Collections.IDictionary] $Inventory,

        [AllowNull()]
        [System.Collections.IDictionary] $Readiness,

        [Parameter(Mandatory)]
        [ValidateSet('pass', 'fail', 'denied', 'unverified')]
        [string] $Status,

        [AllowNull()]
        [string] $FailureKind,

        [Parameter(Mandatory)]
        [bool] $Retryable,

        [datetimeoffset] $StartedAt = [datetimeoffset]::UtcNow,

        [datetimeoffset] $CompletedAt = [datetimeoffset]::UtcNow
    )

    $normalizedFailureKind = if (
        [string]::IsNullOrWhiteSpace($FailureKind)
    ) {
        $null
    }
    else {
        $FailureKind
    }
    if (
        $Status -ceq 'pass' -and
        (
            $null -eq $Inventory -or
            $null -eq $Readiness -or
            $Readiness.status -cne 'pass'
        )
    ) {
        throw 'Passing deployment probe evidence requires passing readiness.'
    }
    $probeResults = [System.Collections.Generic.List[object]]::new()
    if ($Status -ceq 'pass') {
        $probeResults.Add([ordered]@{
            probeId       = 'probe.deployment.resource-group'
            status        = 'pass'
            correlationIds = @()
            observedAt    = ConvertTo-AdltUtcTimestamp -Value $CompletedAt
            message       = 'The resource group has the exact toolkit ownership proof.'
            payload       = [ordered]@{
                resourceId = [string] $Inventory.resourceGroupId
                proofHash = [string] $Inventory.resourceGroupProofHash
            }
        })
        foreach ($resource in @($Inventory.resources)) {
            $probeResults.Add([ordered]@{
                probeId = 'probe.deployment.{0}' -f
                    ([string] $resource.stableId)
                status = 'pass'
                correlationIds = @()
                observedAt = ConvertTo-AdltUtcTimestamp `
                    -Value $CompletedAt
                message = 'The exact deployed resource and ownership proof were verified.'
                payload = [ordered]@{
                    resourceId = [string] $resource.resourceId
                    resourceType = [string] $resource.resourceType
                    relationship = [string] $resource.relationship
                    proofHash = [string] $resource.proofHash
                }
            })
        }
        foreach ($check in @($Readiness.checks)) {
            $probeResults.Add([ordered]@{
                probeId = 'probe.deployment.readiness.{0}' -f
                    ([string] $check.checkId)
                status = 'pass'
                correlationIds = @()
                observedAt = ConvertTo-AdltUtcTimestamp `
                    -Value $CompletedAt
                message = (
                    'The exact control-plane readiness condition was ' +
                    'verified.'
                )
                payload = [ordered]@{
                    resourceId = [string] $check.resourceId
                    provisioningState =
                        [string] $check.provisioningState
                    powerState = [string] $check.powerState
                }
            })
        }
    }
    else {
        $probeResults.Add([ordered]@{
            probeId       = 'probe.deployment.inventory'
            status        = $Status
            correlationIds = @()
            observedAt    = ConvertTo-AdltUtcTimestamp -Value $CompletedAt
            message       = (
                'The exact post-deployment inventory could not be proven; ' +
                "failure classification: $FailureKind."
            )
            payload       = [ordered]@{
                failureKind = $FailureKind
                retryable = $Retryable
                readinessHash = if ($null -eq $Readiness) {
                    $null
                }
                else {
                    [string] $Readiness.readinessHash
                }
            }
        })
    }

    $approvedResourceSetHash = if ($null -eq $Inventory) {
        $null
    }
    else {
        Get-AdltSha256Identifier -Value (
            ConvertTo-AdltCanonicalJson -InputObject @(
                $Inventory.resources |
                    Sort-Object resourceId |
                    ForEach-Object {
                        [ordered]@{
                            resourceId = [string] $_.resourceId
                            apiVersion = [string] $_.apiVersion
                        }
                    }
            )
        )
    }
    $outcome = switch ($Status) {
        'pass' { 'succeeded' }
        'fail' { 'failed' }
        'denied' { 'denied' }
        'unverified' { 'unverified' }
    }
    return New-AdltEvidence `
        -RunId $Context.State.runId `
        -PlanHash $Context.Plan.planHash `
        -IntentHash $Context.Plan.intentHash `
        -Stage probe `
        -Status $Status `
        -CorrelationIds @(
            [string] $DeploymentEvidence.payload.correlationId |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                }
        ) `
        -Probes @($probeResults.ToArray()) `
        -Payload ([ordered]@{
            operationId = $ExecutionRecord.operationId
            executionRecordHash =
                $ExecutionRecord.executionRecordHash
            deploymentEvidenceHash =
                $DeploymentEvidence.evidenceHash
            executionArtifactDigest =
                $ExecutionRecord.deployment.executionArtifactDigest
            inventoryHash = if ($null -eq $Inventory) {
                $null
            }
            else {
                [string] $Inventory.inventoryHash
            }
            approvedResourceSetHash = $approvedResourceSetHash
            readinessHash = if ($null -eq $Readiness) {
                $null
            }
            else {
                [string] $Readiness.readinessHash
            }
            sqlReadinessProxy = if (
                $null -ne $Readiness -and
                $Readiness.status -ceq 'pass'
            ) {
                'sql-iaas-registration-and-extension-succeeded'
            }
            else {
                $null
            }
            requiredResourceCount = $RequiredResourceCount
            observedResourceCount = if ($null -eq $Inventory) {
                0
            }
            else {
                [int] $Inventory.resourceCount
            }
            outcome = $outcome
            failureKind = $normalizedFailureKind
            retryable = $Retryable
            checkedAt = ConvertTo-AdltUtcTimestamp -Value $CompletedAt
        }) `
        -StartedAt $StartedAt `
        -CompletedAt $CompletedAt
}

function Invoke-AdltPostDeploymentProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath
    )

    $context = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
    if ($context.Plan.target.type -cne 'sqlVm') {
        throw 'Only SQL VM post-deployment probes are implemented.'
    }
    $record = Get-AdltDeploymentExecutionRecordFromContext `
        -Context $context
    [void] (Assert-AdltAzureMutationPrincipal `
        -Plan $context.Plan `
        -ExpectedPrincipalId (
            [string] $record.authorization.approval.approver.id
        ))
    $deploymentEvidence = @(
        $context.Evidence |
            Where-Object {
                $_.stage -ceq 'deploy' -and
                $_.status -ceq 'pass' -and
                $_.payload.operationId -ceq $record.operationId
            }
    )
    if ($deploymentEvidence.Count -ne 1) {
        throw 'Post-deployment probing requires one passing deployment evidence record.'
    }
    $successfulProbe = @(
        $context.Evidence |
            Where-Object {
                $_.stage -ceq 'probe' -and
                $_.status -ceq 'pass' -and
                $_.payload.operationId -ceq $record.operationId
            }
    )
    if ($successfulProbe.Count -gt 1) {
        throw 'The deployment has duplicate successful probe evidence.'
    }
    if ($context.State.status -ceq 'running') {
        if ($successfulProbe.Count -ne 1) {
            throw 'A running deployment is missing successful probe evidence.'
        }
        return [pscustomobject][ordered]@{
            PSTypeName = 'AzureDataLabToolkit.DeploymentProbeResult'
            RunId = $context.State.runId
            RunPath = [System.IO.Path]::GetFullPath($RunPath)
            OperationId = $record.operationId
            Status = 'running'
            EvidenceStatus = 'pass'
            EvidenceHash = $successfulProbe[0].evidenceHash
            RequiresReconciliation = $false
        }
    }
    if (
        $context.State.status -cne 'probing' -or
        $successfulProbe.Count -ne 0
    ) {
        throw "Run status '$($context.State.status)' cannot execute deployment probes."
    }

    $liveResolution = Get-AdltRunEvidenceByStage `
        -Evidence $context.Evidence `
        -Stage live-resolution
    $compilation = New-AdltSqlVmArmCompilation `
        -Plan $context.Plan `
        -LiveResolutionEvidence $liveResolution
    if (
        $compilation.executionArtifactDigest -cne
            $record.deployment.executionArtifactDigest
    ) {
        throw 'Post-deployment compiler identity does not match the execution record.'
    }
    $expectedResources = @(
        Get-AdltSqlVmTeardownExpectedResourceSet `
            -Plan $context.Plan `
            -Compilation $compilation
    )
    $requiredResourceCount = @(
        $expectedResources |
            Where-Object { [bool] $_.required }
    ).Count

    $startedAt = [datetimeoffset]::UtcNow
    $inventory = $null
    $readiness = $null
    $failureKind = $null
    $evidenceStatus = 'pass'
    $retryable = $false
    try {
        $inventory = Get-AdltSqlVmTeardownInventory `
            -Plan $context.Plan `
            -State $context.State `
            -Compilation $compilation `
            -RequireCompleteDeployment
        $readiness = Get-AdltSqlVmControlPlaneReadiness `
            -Plan $context.Plan `
            -Compilation $compilation
        if ($readiness.status -cne 'pass') {
            $failureKind = [string] $readiness.failureKind
            $evidenceStatus = [string] $readiness.status
            $retryable = [bool] $readiness.retryable
        }
    }
    catch {
        $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
        $evidenceStatus = switch ($failureKind) {
            'unauthenticated' { 'denied' }
            'denied' { 'denied' }
            'absent' { 'fail' }
            'conflict' { 'fail' }
            default { 'unverified' }
        }
        $retryable = $evidenceStatus -in @('denied', 'unverified')
    }
    $completedAt = [datetimeoffset]::UtcNow
    $candidate = Get-AdltPostDeploymentProbeEvidence `
        -Context $context `
        -ExecutionRecord $record `
        -DeploymentEvidence (
            ConvertTo-AdltDictionary `
                -InputObject $deploymentEvidence[0]
        ) `
        -RequiredResourceCount $requiredResourceCount `
        -Inventory $inventory `
        -Readiness $readiness `
        -Status $evidenceStatus `
        -FailureKind $failureKind `
        -Retryable $retryable `
        -StartedAt $startedAt `
        -CompletedAt $completedAt
    $attached = Add-AdltGeneratedRunEvidence `
        -RunPath $RunPath `
        -Evidence $candidate `
        -ActorId AzureDataLabToolkit `
        -OccurredAt $completedAt

    $finalStatus = [string] $context.State.status
    if ($evidenceStatus -ceq 'pass') {
        $transition = Add-AdltLocalRunStatusTransition `
            -RunPath $RunPath `
            -Status running `
            -ActorType toolkit `
            -ActorId AzureDataLabToolkit `
            -OccurredAt $completedAt
        $finalStatus = $transition.State.status
    }
    elseif ($evidenceStatus -ceq 'fail') {
        $transition = Add-AdltLocalRunStatusTransition `
            -RunPath $RunPath `
            -Status failed `
            -ActorType toolkit `
            -ActorId AzureDataLabToolkit `
            -OccurredAt $completedAt
        $finalStatus = $transition.State.status
    }

    return [pscustomobject][ordered]@{
        PSTypeName = 'AzureDataLabToolkit.DeploymentProbeResult'
        RunId = $context.State.runId
        RunPath = [System.IO.Path]::GetFullPath($RunPath)
        OperationId = $record.operationId
        Status = $finalStatus
        EvidenceStatus = $evidenceStatus
        EvidenceHash = $attached.evidenceHash
        RequiresReconciliation = $retryable
    }
}
