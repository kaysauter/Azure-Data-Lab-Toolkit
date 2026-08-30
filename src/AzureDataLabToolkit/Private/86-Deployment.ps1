function ConvertTo-AdltDeploymentResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    $name = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $Result `
            -Name DeploymentName
    )
    $location = [string] (
        Get-AdltObjectPropertyValue -InputObject $Result -Name Location
    )
    $provisioningState = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $Result `
            -Name ProvisioningState
    )
    if (
        $name -cne $ExecutionRecord.deployment.name -or
        $location -cne $ExecutionRecord.deployment.location -or
        $provisioningState -notin @(
            'Accepted'
            'Running'
            'Creating'
            'Validating'
            'Succeeded'
            'Failed'
            'Canceled'
        )
    ) {
        throw 'Azure returned a deployment result outside the execution record.'
    }

    $deploymentId = [string] (
        Get-AdltObjectPropertyValue -InputObject $Result -Name Id
    )
    if (
        -not [string]::IsNullOrWhiteSpace($deploymentId) -and
        $deploymentId -cne (
            '{0}/providers/Microsoft.Resources/deployments/{1}' -f
                $ExecutionRecord.deployment.scope,
                $ExecutionRecord.deployment.name
        )
    ) {
        throw 'Azure returned an unexpected deployment resource ID.'
    }
    $correlationId = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $Result `
            -Name CorrelationId
    )
    if (
        -not [string]::IsNullOrWhiteSpace($correlationId) -and
        $correlationId -notmatch '^[0-9a-fA-F-]{36}$'
    ) {
        throw 'Azure returned an invalid deployment correlation ID.'
    }
    $outputs = Get-AdltObjectPropertyValue `
        -InputObject $Result `
        -Name Outputs
    if (
        $null -ne $outputs -and
        @(
            if ($outputs -is [System.Collections.IDictionary]) {
                $outputs.Keys
            }
            else {
                $outputs.PSObject.Properties
            }
        ).Count -gt 0
    ) {
        throw 'The SQL VM deployment returned unexpected outputs.'
    }

    $terminal = $provisioningState -in @(
        'Succeeded'
        'Failed'
        'Canceled'
    )
    return [ordered]@{
        deploymentName = $name
        deploymentId = if (
            [string]::IsNullOrWhiteSpace($deploymentId)
        ) {
            $null
        }
        else {
            $deploymentId
        }
        correlationId = if (
            [string]::IsNullOrWhiteSpace($correlationId)
        ) {
            $null
        }
        else {
            $correlationId.ToLowerInvariant()
        }
        provisioningState = $provisioningState
        terminal = $terminal
        outcome = if ($provisioningState -eq 'Succeeded') {
            'succeeded'
        }
        elseif ($terminal) {
            'failed'
        }
        else {
            $null
        }
    }
}

function Get-AdltGeneratedResourceApiVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceType
    )

    $versions = @{
        'Microsoft.Compute/disks' =
            '2024-03-02'
        'Microsoft.Compute/virtualMachines/extensions' =
            '2024-03-01'
        'Microsoft.Resources/deployments' =
            '2022-09-01'
    }
    if (-not $versions.ContainsKey($ResourceType)) {
        throw "No generated-resource API version is pinned for '$ResourceType'."
    }
    return [string] $versions[$ResourceType]
}

function Assert-AdltSqlVmDeploymentTargetAbsence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation
    )

    $planResources = Get-AdltSqlVmArmResourceMap -Plan $Plan
    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($bindingObject in @(
        $Compilation.resourceBindings |
            Where-Object disposition -CEQ deploy
    )) {
        $binding = ConvertTo-AdltDictionary `
            -InputObject $bindingObject
        $resource = $planResources[[string] $binding.stableId]
        $targets.Add([ordered]@{
            stableId  = [string] $binding.stableId
            resourceId = [string] $binding.resourceId
            resource = $resource
        })
    }
    foreach ($generatedObject in @(
        $Compilation.expectedGeneratedResources
    )) {
        $generated = ConvertTo-AdltDictionary `
            -InputObject $generatedObject
        $targets.Add([ordered]@{
            stableId  = [string] $generated.stableId
            resourceId = [string] $generated.resourceId
            resource = [ordered]@{
                type = [string] $generated.resourceType
                apiVersion = Get-AdltGeneratedResourceApiVersion `
                    -ResourceType ([string] $generated.resourceType)
                logicalName = Get-AdltResourceNameFromId `
                    -ResourceId ([string] $generated.resourceId)
            }
        })
    }

    foreach ($target in @(
        $targets |
            Sort-Object resourceId
    )) {
        $read = Get-AdltAzureResourceRead `
            -Resource $target.resource `
            -ResourceId $target.resourceId
        if ($read.status -cne 'absent') {
            throw (
                "Deployment target '$($target.stableId)' is no longer " +
                'provably absent. No Azure mutation was submitted.'
            )
        }
    }
}

function New-AdltDeploymentMutationLease {
    [CmdletBinding(DefaultParameterSetName = 'Original')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory, ParameterSetName = 'Resume')]
        [System.Collections.IDictionary] $ResumeEvent
    )

    if ($PSCmdlet.ParameterSetName -ceq 'Original') {
        return [ordered]@{
            sourceType = 'execution-authorization'
            sourceHash =
                [string] $ExecutionRecord.authorization.authorizationHash
            approverId = [string] (
                $ExecutionRecord.authorization.approval.approver.id
            )
            approvedAt = [string] (
                $ExecutionRecord.authorization.approval.approvedAt
            )
            expiresAt = [string] $ExecutionRecord.authorization.expiresAt
        }
    }
    if (
        $ResumeEvent.eventType -cne 'operation-resumed' -or
        $ResumeEvent.actor.type -cne 'interactive-user' -or
        $ResumeEvent.data.operationId -cne $ExecutionRecord.operationId -or
        $ResumeEvent.data.executionRecordHash -cne
            $ExecutionRecord.executionRecordHash
    ) {
        throw 'Deployment resume event cannot grant a mutation lease.'
    }
    return [ordered]@{
        sourceType = 'resume-event'
        sourceHash = [string] $ResumeEvent.eventHash
        approverId = [string] $ResumeEvent.actor.id
        approvedAt = [string] $ResumeEvent.data.approvedAt
        expiresAt = [string] $ResumeEvent.data.expiresAt
    }
}

function Assert-AdltDeploymentMutationLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Lease,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow
    )

    Assert-AdltExactValueSet `
        -Actual @($Lease.Keys) `
        -Expected @(
            'sourceType'
            'sourceHash'
            'approverId'
            'approvedAt'
            'expiresAt'
        ) `
        -Name 'Deployment mutation lease fields'
    if (
        $Lease.sourceType -notin @(
            'execution-authorization'
            'resume-event'
        ) -or
        [string] $Lease.sourceHash -notmatch
            '^sha256:[a-f0-9]{64}$' -or
        [string] $Lease.approverId -cne
            [string] $ExecutionRecord.authorization.approval.approver.id
    ) {
        throw 'Deployment mutation lease identity is invalid.'
    }
    if (
        $Lease.sourceType -ceq 'execution-authorization' -and
        (
            $Lease.sourceHash -cne
                $ExecutionRecord.authorization.authorizationHash -or
            $Lease.approvedAt -cne
                $ExecutionRecord.authorization.approval.approvedAt -or
            $Lease.expiresAt -cne
                $ExecutionRecord.authorization.expiresAt
        )
    ) {
        throw 'Deployment mutation lease does not match its authorization.'
    }
    $approvedAt = [datetimeoffset]::Parse(
        [string] $Lease.approvedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $expiresAt = [datetimeoffset]::Parse(
        [string] $Lease.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if (
        $expiresAt -le $approvedAt -or
        $expiresAt -gt $approvedAt.AddMinutes(10) -or
        $AsOf -lt $approvedAt -or
        $AsOf -ge $expiresAt
    ) {
        throw 'Deployment mutation lease is not currently valid.'
    }
    Assert-AdltRuntimeAuthorizationBinding `
        -Authorization $ExecutionRecord.authorization
}

function Invoke-AdltSqlVmDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $MutationLease
    )

    Assert-AdltDeploymentMutationLease `
        -Lease $MutationLease `
        -ExecutionRecord $ExecutionRecord
    [void] (Assert-AdltAzureMutationPrincipal `
        -Plan $Plan `
        -ExpectedPrincipalId (
            [string] $ExecutionRecord.authorization.approval.approver.id
        ))
    $parameterDocument = New-AdltSqlVmArmParameterDocument `
        -Compilation $Compilation
    $parameterJson = ConvertTo-AdltCanonicalJson `
        -InputObject $parameterDocument
    $temporaryDirectory = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ('adlt-deploy-{0}' -f $ExecutionRecord.operationId.Replace('-', ''))
    $parameterPath = Join-Path $temporaryDirectory 'parameters.json'

    try {
        [void] (New-AdltPrivateDirectory -Path $temporaryDirectory)
        [void] (Write-AdltPrivateAtomicText `
            -Path $parameterPath `
            -Content $parameterJson)
        Assert-AdltPrivatePathMode -Path $parameterPath -Type File
        if (
            (Get-AdltFileSha256Identifier -Path $parameterPath) -cne
            $ExecutionRecord.deployment.parameterFileHash
        ) {
            throw 'Protected deployment parameter file hash drifted.'
        }
        Assert-AdltSqlVmDeploymentTargetAbsence `
            -Plan $Plan `
            -Compilation $Compilation
        Assert-AdltDeploymentMutationLease `
            -Lease $MutationLease `
            -ExecutionRecord $ExecutionRecord
        $templateObject = $Compilation.template |
            ConvertTo-Json -Depth 100 -Compress |
            ConvertFrom-Json -AsHashtable -Depth 100
        $result = Invoke-AdltAzCommand `
            -ModuleName Az.Resources `
            -CommandName New-AzDeployment `
            -Parameters @{
                Name = $ExecutionRecord.deployment.name
                Location = $ExecutionRecord.deployment.location
                TemplateObject = $templateObject
                TemplateParameterFile = $parameterPath
                ValidationLevel = 'Provider'
                SkipTemplateParameterPrompt = $true
                DeploymentDebugLogLevel = 'None'
                Confirm = $false
                ErrorAction = 'Stop'
            }
        return ConvertTo-AdltDeploymentResult `
            -Result $result `
            -ExecutionRecord $ExecutionRecord
    }
    finally {
        if ([System.IO.File]::Exists($parameterPath)) {
            [System.IO.File]::Delete($parameterPath)
        }
        if ([System.IO.Directory]::Exists($temporaryDirectory)) {
            [System.IO.Directory]::Delete($temporaryDirectory, $false)
        }
    }
}

function Get-AdltSqlVmDeploymentStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    [void] (Assert-AdltAzureContextReady -Plan $Plan)
    $result = Invoke-AdltAzCommand `
        -ModuleName Az.Resources `
        -CommandName Get-AzDeployment `
        -Parameters @{
            Name = $ExecutionRecord.deployment.name
            ErrorAction = 'Stop'
        }
    return ConvertTo-AdltDeploymentResult `
        -Result $result `
        -ExecutionRecord $ExecutionRecord
}

function Assert-AdltSqlVmDeploymentRecordAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    try {
        $result = Get-AdltSqlVmDeploymentStatus `
            -Plan $Plan `
            -ExecutionRecord $ExecutionRecord
    }
    catch {
        if ((Get-AdltAzureFailureKind -ErrorRecord $_) -eq 'absent') {
            return
        }
        throw
    }

    throw (
        "Subscription deployment '$($result.deploymentName)' exists " +
        "with provisioning state '$($result.provisioningState)'. " +
        'Reconcile it instead of resubmitting.'
    )
}

function Get-AdltDeploymentResumeApprovalPhrase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    return 'RESUBMIT {0} {1} {2}' -f
        $State.scope.resourceGroupName,
        $State.runId.Replace(
            '-',
            ''
        ).Substring(0, 8).ToLowerInvariant(),
        $ExecutionRecord.executionRecordHash.Substring(7, 12)
}

function New-AdltDeploymentEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DeploymentResult,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId,

        [datetimeoffset] $StartedAt = [datetimeoffset]::UtcNow,

        [datetimeoffset] $CompletedAt = [datetimeoffset]::UtcNow
    )

    if (
        -not [bool] $DeploymentResult.terminal -or
        $DeploymentResult.outcome -notin @('succeeded', 'failed')
    ) {
        throw 'Deployment evidence requires a terminal Azure result.'
    }
    $status = if ($DeploymentResult.outcome -eq 'succeeded') {
        'pass'
    }
    else {
        'fail'
    }
    $failureKind = if ($status -eq 'pass') {
        $null
    }
    else {
        'unknown'
    }
    return New-AdltEvidence `
        -RunId $RunId `
        -PlanHash $Plan.planHash `
        -IntentHash $Plan.intentHash `
        -Stage deploy `
        -Status $status `
        -Payload ([ordered]@{
            operationId = $ExecutionRecord.operationId
            executionRecordHash =
                $ExecutionRecord.executionRecordHash
            authorizationHash =
                $ExecutionRecord.authorization.authorizationHash
            scope = $ExecutionRecord.deployment.scope
            deploymentName = $DeploymentResult.deploymentName
            deploymentId = $DeploymentResult.deploymentId
            correlationId = $DeploymentResult.correlationId
            provisioningState =
                $DeploymentResult.provisioningState
            outcome = $DeploymentResult.outcome
            failureKind = $failureKind
            templateHash = $ExecutionRecord.deployment.templateHash
            parameterFileHash =
                $ExecutionRecord.deployment.parameterFileHash
            executionArtifactDigest =
                $ExecutionRecord.deployment.executionArtifactDigest
        }) `
        -StartedAt $StartedAt `
        -CompletedAt $CompletedAt
}

function Complete-AdltDeploymentOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DeploymentResult,

        [datetimeoffset] $StartedAt = [datetimeoffset]::UtcNow,

        [datetimeoffset] $CompletedAt = [datetimeoffset]::UtcNow
    )

    $context = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
    $existingEvidence = @(
        $context.Evidence |
            Where-Object {
                $_.stage -ceq 'deploy' -and
                $_.payload.operationId -ceq
                    $ExecutionRecord.operationId
            }
    )
    if ($existingEvidence.Count -gt 1) {
        throw 'The deployment operation has duplicate terminal evidence.'
    }
    if ($existingEvidence.Count -eq 1) {
        $evidence = ConvertTo-AdltDictionary `
            -InputObject $existingEvidence[0]
    }
    else {
        $candidate = New-AdltDeploymentEvidence `
            -Plan $Plan `
            -ExecutionRecord $ExecutionRecord `
            -DeploymentResult $DeploymentResult `
            -RunId $context.State.runId `
            -StartedAt $StartedAt `
            -CompletedAt $CompletedAt
        $evidence = Add-AdltGeneratedRunEvidence `
            -RunPath $RunPath `
            -Evidence $candidate `
            -ActorId AzureDataLabToolkit `
            -OccurredAt $CompletedAt
    }

    $refreshed = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
    $finishedEvents = @(
        $refreshed.Events |
            Where-Object {
                $_.eventType -ceq 'operation-finished' -and
                $_.data.operationId -ceq
                    $ExecutionRecord.operationId
            }
    )
    if ($finishedEvents.Count -gt 1) {
        throw 'The deployment operation has duplicate finish events.'
    }
    if ($finishedEvents.Count -eq 0) {
        $finish = Add-AdltLocalOperationEvent `
            -RunPath $RunPath `
            -EventType operation-finished `
            -Data ([ordered]@{
                operation = 'deploy'
                operationId = $ExecutionRecord.operationId
                outcome = $DeploymentResult.outcome
                evidenceHash = $evidence.evidenceHash
            }) `
            -ActorId AzureDataLabToolkit `
            -OccurredAt $CompletedAt
        $state = $finish.State
    }
    else {
        $state = $refreshed.State
    }

    return [pscustomobject][ordered]@{
        PSTypeName = 'AzureDataLabToolkit.DeploymentResult'
        RunId = $state.runId
        RunPath = [System.IO.Path]::GetFullPath($RunPath)
        OperationId = $ExecutionRecord.operationId
        DeploymentName = $DeploymentResult.deploymentName
        ProvisioningState = $DeploymentResult.provisioningState
        Status = $state.status
        EvidenceHash = $evidence.evidenceHash
        RequiresReconciliation = $false
    }
}
