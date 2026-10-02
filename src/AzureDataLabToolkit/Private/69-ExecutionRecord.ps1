function Get-AdltLiveFactsGateHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence
    )

    $payload = $Evidence.payload
    $normalized = [ordered]@{
        context = [ordered]@{
            cloud          = $payload.context.cloud
            tenantId       = $payload.context.tenantId
            subscriptionId = $payload.context.subscriptionId
            accountType    = $payload.context.accountType
            contextScope   = $payload.context.contextScope
        }
        providerStates = @(
            $payload.providerStates |
                Sort-Object namespace |
                ForEach-Object {
                    Copy-AdltValue -InputObject $_
                }
        )
        imageResolution = Copy-AdltValue `
            -InputObject $payload.imageResolution
        skuResolution = Copy-AdltValue `
            -InputObject $payload.skuResolution
        keyVaultResolution = Copy-AdltValue `
            -InputObject $payload.keyVaultResolution
        secretMetadata = Copy-AdltValue `
            -InputObject $payload.secretMetadata
        diagnosticResolution = Copy-AdltValue `
            -InputObject $payload.diagnosticResolution
        principalObjectId = $payload.principalObjectId
        principalType = $payload.principalType
        requiredAuthorizations = @(
            $payload.requiredAuthorizations |
                ForEach-Object {
                    Copy-AdltValue -InputObject $_
                }
        )
        resources = @(
            $payload.resources |
                Sort-Object stableId |
                ForEach-Object {
                    Copy-AdltValue -InputObject $_
                }
        )
        resolvedPolicyFindingIds = @(
            $payload.resolvedPolicyFindingIds | Sort-Object
        )
    }
    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $normalized
    )
}

function Get-AdltWhatIfGateHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence
    )

    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $Evidence.payload
    )
}

function New-AdltFinalDeploymentGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $WhatIfEvidence,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId
    )

    $freshLive = Resolve-AzureDataLabPlan `
        -Plan $Plan `
        -RunId $RunId `
        -ErrorAction Stop
    $freshLive = ConvertTo-AdltDictionary -InputObject $freshLive
    Assert-AdltLiveResolutionEvidenceForPlan `
        -Evidence $freshLive `
        -Plan $Plan
    $approvedLiveFactsHash = Get-AdltLiveFactsGateHash `
        -Evidence $LiveResolutionEvidence
    $freshLiveFactsHash = Get-AdltLiveFactsGateHash `
        -Evidence $freshLive
    if ($freshLiveFactsHash -cne $approvedLiveFactsHash) {
        throw 'Final deployment gate detected drift in resolved Azure facts.'
    }

    $freshWhatIf = Test-AzureDataLabWhatIf `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -RunId $RunId `
        -ErrorAction Stop
    $freshWhatIf = ConvertTo-AdltDictionary -InputObject $freshWhatIf
    Assert-AdltWhatIfEvidenceForPlan `
        -Evidence $freshWhatIf `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    $approvedWhatIfHash = Get-AdltWhatIfGateHash `
        -Evidence $WhatIfEvidence
    $freshWhatIfHash = Get-AdltWhatIfGateHash `
        -Evidence $freshWhatIf
    if ($freshWhatIfHash -cne $approvedWhatIfHash) {
        throw 'Final deployment gate detected drift in provider What-If.'
    }

    $completedAt = [datetimeoffset]::UtcNow
    $finalGateHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            liveFactsHash = $freshLiveFactsHash
            whatIfHash    = $freshWhatIfHash
        })
    )
    return [ordered]@{
        liveFactsHash = $freshLiveFactsHash
        whatIfHash    = $freshWhatIfHash
        finalGateHash = $finalGateHash
        completedAt   = ConvertTo-AdltUtcTimestamp -Value $completedAt
    }
}

function Assert-AdltExecutionRecordArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    Assert-AdltArtifactContract `
        -Artifact $ExecutionRecord `
        -ExpectedKind 'AzureDataLabExecutionRecord' `
        -HashProperty 'executionRecordHash' `
        -SchemaFileName 'execution-record.schema.json'
    Assert-AdltArtifactContract `
        -Artifact $ExecutionRecord.authorization `
        -ExpectedKind 'AzureDataLabExecutionAuthorization' `
        -HashProperty 'authorizationHash' `
        -SchemaFileName 'execution-authorization.schema.json'
    Assert-AdltArtifactContract `
        -Artifact $ExecutionRecord.teardownPlan `
        -ExpectedKind 'AzureDataLabTeardownPlan' `
        -HashProperty 'teardownPlanHash' `
        -SchemaFileName 'teardown-plan.schema.json'

    if (
        $ExecutionRecord.runId -cne $State.runId -or
        $ExecutionRecord.planHash -cne $State.planHash -or
        $ExecutionRecord.intentHash -cne $State.intentHash -or
        $ExecutionRecord.authorization.runId -cne $State.runId -or
        $ExecutionRecord.authorization.authorizationHash -cne
            $ExecutionRecord.authorizationHash
    ) {
        throw 'Execution record does not match the protected run binding.'
    }
    if (
        $ExecutionRecord.teardownPlan.runId -cne $State.runId -or
        $ExecutionRecord.authorization.teardownPlanHash -cne
            $ExecutionRecord.teardownPlan.teardownPlanHash
    ) {
        throw 'Execution record teardown binding is invalid.'
    }
    Assert-AdltScopeBinding `
        -Actual $ExecutionRecord.scope `
        -Expected $State.scope `
        -ArtifactName 'Execution record'
    $expectedDeploymentName = 'adlt-deploy-{0}-{1}' -f
        $State.runId.Replace(
            '-',
            ''
        ).Substring(0, 8).ToLowerInvariant(),
        $ExecutionRecord.authorization.authorizationHash.Substring(7, 12)
    if (
        $ExecutionRecord.deployment.name -cne $expectedDeploymentName -or
        $ExecutionRecord.deployment.scope -cne (
            '/subscriptions/{0}' -f $State.scope.subscriptionId
        ) -or
        $ExecutionRecord.deployment.location -cne $State.scope.location
    ) {
        throw 'Execution record deployment identity is invalid.'
    }

    $forbiddenFields = @(
        Get-AdltForbiddenField -InputObject $ExecutionRecord
    )
    if ($forbiddenFields.Count -gt 0) {
        throw "Execution record contains forbidden field '$($forbiddenFields[0])'."
    }
    $sensitiveValues = @(
        Get-AdltSensitiveValueFinding -InputObject $ExecutionRecord
    )
    if ($sensitiveValues.Count -gt 0) {
        throw 'Execution record contains a sensitive value pattern.'
    }
}

function Assert-AdltDeploymentExecutionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $WhatIfEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $CostEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $TeardownPreviewEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow
    )

    Assert-AdltExecutionRecordArtifact `
        -ExecutionRecord $ExecutionRecord `
        -State $State
    Assert-AdltExecutionAuthorization `
        -Authorization $ExecutionRecord.authorization `
        -Plan $Plan `
        -State $State `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -WhatIfEvidence $WhatIfEvidence `
        -CostEvidence $CostEvidence `
        -TeardownPlan $ExecutionRecord.teardownPlan `
        -ObservedStateEvidence $TeardownPreviewEvidence `
        -Compilation $Compilation `
        -AsOf $AsOf

    $expectedPreflight = [ordered]@{
        liveResolutionEvidenceHash =
            $LiveResolutionEvidence.evidenceHash
        whatIfEvidenceHash = $WhatIfEvidence.evidenceHash
        costEvidenceHash = $CostEvidence.evidenceHash
        teardownPreviewEvidenceHash =
            $TeardownPreviewEvidence.evidenceHash
    }
    if (
        (ConvertTo-AdltCanonicalJson `
            -InputObject $ExecutionRecord.preflight) -cne
        (ConvertTo-AdltCanonicalJson -InputObject $expectedPreflight)
    ) {
        throw 'Execution record preflight hashes are not exact.'
    }

    $expectedFinalGateHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            liveFactsHash = $ExecutionRecord.finalGate.liveFactsHash
            whatIfHash    = $ExecutionRecord.finalGate.whatIfHash
        })
    )
    if (
        $ExecutionRecord.finalGate.finalGateHash -cne
            $expectedFinalGateHash -or
        $ExecutionRecord.finalGate.liveFactsHash -cne
            (Get-AdltLiveFactsGateHash `
                -Evidence $LiveResolutionEvidence) -or
        $ExecutionRecord.finalGate.whatIfHash -cne
            (Get-AdltWhatIfGateHash -Evidence $WhatIfEvidence)
    ) {
        throw 'Execution record final gate is not bound to approved preflight.'
    }

    $parameterDocument = New-AdltSqlVmArmParameterDocument `
        -Compilation $Compilation
    $parameterFileHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $parameterDocument
    )
    $parameterReferenceHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson `
            -InputObject $Compilation.parameterReference
    )
    $expectedDeployment = [ordered]@{
        scope = '/subscriptions/{0}' -f $Plan.context.subscriptionId
        name = 'adlt-deploy-{0}-{1}' -f
            $State.runId.Replace(
                '-',
                ''
            ).Substring(0, 8).ToLowerInvariant(),
            $ExecutionRecord.authorization.authorizationHash.Substring(7, 12)
        location = $Plan.context.location
        templateHash = $Compilation.templateHash
        parameterReferenceHash = $parameterReferenceHash
        parameterFileHash = $parameterFileHash
        executionArtifactDigest =
            $Compilation.executionArtifactDigest
        expectedGeneratedResourceSetHash =
            Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson `
                    -InputObject $Compilation.expectedGeneratedResources
            )
    }
    if (
        (ConvertTo-AdltCanonicalJson `
            -InputObject $ExecutionRecord.deployment) -cne
        (ConvertTo-AdltCanonicalJson -InputObject $expectedDeployment)
    ) {
        throw 'Execution record deployment binding is not deterministic.'
    }

    $finalGateCompletedAt = [datetimeoffset]::Parse(
        [string] $ExecutionRecord.finalGate.completedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $createdAt = [datetimeoffset]::Parse(
        [string] $ExecutionRecord.createdAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if (
        $createdAt -lt $finalGateCompletedAt -or
        $AsOf -lt $createdAt
    ) {
        throw 'Execution record timestamps are invalid.'
    }
}

function New-AdltDeploymentExecutionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $WhatIfEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $CostEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $TeardownPreviewEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Authorization,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $TeardownPlan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $FinalGate,

        [datetimeoffset] $CreatedAt = [datetimeoffset]::UtcNow
    )

    $parameterDocument = New-AdltSqlVmArmParameterDocument `
        -Compilation $Compilation
    $record = [ordered]@{
        schemaVersion = '1.0'
        kind = 'AzureDataLabExecutionRecord'
        canonicalization = 'rfc8785'
        operation = 'deploy'
        operationId = [guid]::NewGuid().ToString()
        runId = $State.runId
        planHash = $Plan.planHash
        intentHash = $Plan.intentHash
        scope = Get-AdltPlanScope -Plan $Plan
        preflight = [ordered]@{
            liveResolutionEvidenceHash =
                $LiveResolutionEvidence.evidenceHash
            whatIfEvidenceHash = $WhatIfEvidence.evidenceHash
            costEvidenceHash = $CostEvidence.evidenceHash
            teardownPreviewEvidenceHash =
                $TeardownPreviewEvidence.evidenceHash
        }
        authorization = Copy-AdltValue -InputObject $Authorization
        authorizationHash = $Authorization.authorizationHash
        teardownPlan = Copy-AdltValue -InputObject $TeardownPlan
        finalGate = Copy-AdltValue -InputObject $FinalGate
        deployment = [ordered]@{
            scope = '/subscriptions/{0}' -f $Plan.context.subscriptionId
            name = 'adlt-deploy-{0}-{1}' -f
                $State.runId.Replace(
                    '-',
                    ''
                ).Substring(0, 8).ToLowerInvariant(),
                $Authorization.authorizationHash.Substring(7, 12)
            location = $Plan.context.location
            templateHash = $Compilation.templateHash
            parameterReferenceHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson `
                    -InputObject $Compilation.parameterReference
            )
            parameterFileHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson `
                    -InputObject $parameterDocument
            )
            executionArtifactDigest =
                $Compilation.executionArtifactDigest
            expectedGeneratedResourceSetHash =
                Get-AdltSha256Identifier -Value (
                    ConvertTo-AdltCanonicalJson `
                        -InputObject $Compilation.expectedGeneratedResources
                )
        }
        createdAt = ConvertTo-AdltUtcTimestamp -Value $CreatedAt
    }
    $record.executionRecordHash = Get-AdltArtifactHash `
        -Artifact $record `
        -HashProperty executionRecordHash
    Assert-AdltDeploymentExecutionRecord `
        -ExecutionRecord $record `
        -Plan $Plan `
        -State $State `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -WhatIfEvidence $WhatIfEvidence `
        -CostEvidence $CostEvidence `
        -TeardownPreviewEvidence $TeardownPreviewEvidence `
        -Compilation $Compilation `
        -AsOf $CreatedAt
    return $record
}

function Get-AdltExecutionRecordFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    switch ([string] $ExecutionRecord.kind) {
        'AzureDataLabExecutionRecord' {
            if ($ExecutionRecord.operation -cne 'deploy') {
                throw "Execution record operation '$($ExecutionRecord.operation)' is unsupported."
            }
            return 'deploy-execution-record.json'
        }
        'AzureDataLabTeardownExecutionRecord' {
            if ($ExecutionRecord.operation -cne 'teardown') {
                throw "Execution record operation '$($ExecutionRecord.operation)' is unsupported."
            }
            return 'teardown-execution-record.json'
        }
        default {
            throw "Run artifact kind '$($ExecutionRecord.kind)' is unsupported."
        }
    }
}

function Assert-AdltRunExecutionRecordArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    switch ([string] $ExecutionRecord.kind) {
        'AzureDataLabExecutionRecord' {
            Assert-AdltExecutionRecordArtifact `
                -ExecutionRecord $ExecutionRecord `
                -State $State
        }
        'AzureDataLabTeardownExecutionRecord' {
            Assert-AdltTeardownExecutionRecordArtifact `
                -ExecutionRecord $ExecutionRecord `
                -State $State
        }
        default {
            throw "Run artifact kind '$($ExecutionRecord.kind)' is unsupported."
        }
    }
}

function Get-AdltExecutionRecordEventBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    switch ([string] $ExecutionRecord.kind) {
        'AzureDataLabExecutionRecord' {
            return [ordered]@{
                eventType    = 'authorization-recorded'
                hashProperty = 'executionRecordHash'
            }
        }
        'AzureDataLabTeardownExecutionRecord' {
            return [ordered]@{
                eventType    = 'teardown-authorization-recorded'
                hashProperty = 'teardownExecutionRecordHash'
            }
        }
        default {
            throw "Run artifact kind '$($ExecutionRecord.kind)' is unsupported."
        }
    }
}

function Get-AdltVerifiedRunArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ArtifactPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [object[]] $Events
    )

    Assert-AdltLocalStoreEntry -Path $ArtifactPath -Type Directory
    $artifactFiles = @(
        Get-ChildItem -LiteralPath $ArtifactPath -File -Force
    )
    if (
        $artifactFiles.Count -gt
            $script:AzureDataLabToolkitMaximumArtifactFiles
    ) {
        throw 'Run artifact directory exceeds its protected file limit.'
    }
    foreach ($pendingFile in @(
        $artifactFiles |
            Where-Object Name -Like '*.json.pending'
    )) {
        Assert-AdltLocalStoreEntry -Path $pendingFile.FullName -Type File
        $record = Read-AdltJsonFile -Path $pendingFile.FullName
        Assert-AdltRunExecutionRecordArtifact `
            -ExecutionRecord $record `
            -State $State
        $binding = Get-AdltExecutionRecordEventBinding `
            -ExecutionRecord $record
        $recordHash = [string] $record[$binding.hashProperty]
        $references = @(
            $Events |
                Where-Object {
                    $_.eventType -ceq $binding.eventType -and
                    $_.data[$binding.hashProperty] -ceq $recordHash
                }
        )
        if ($references.Count -eq 0) {
            [System.IO.File]::Delete($pendingFile.FullName)
            continue
        }
        if ($references.Count -ne 1) {
            throw 'Pending execution record has ambiguous event references.'
        }
        $finalPath = Join-Path `
            $ArtifactPath `
            (Get-AdltExecutionRecordFileName -ExecutionRecord $record)
        if ([System.IO.File]::Exists($finalPath)) {
            throw 'Pending execution record collides with a committed record.'
        }
        [System.IO.File]::Move($pendingFile.FullName, $finalPath, $false)
        Set-AdltPrivatePathMode -Path $finalPath -Type File
    }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(
        Get-ChildItem -LiteralPath $ArtifactPath -File -Force
    )) {
        Assert-AdltLocalStoreEntry -Path $file.FullName -Type File
        if ($file.Name -notin @(
            'deploy-execution-record.json'
            'teardown-execution-record.json'
        )) {
            throw "Unrecognized run artifact '$($file.Name)' is not allowed."
        }
        $record = Read-AdltJsonFile -Path $file.FullName
        Assert-AdltRunExecutionRecordArtifact `
            -ExecutionRecord $record `
            -State $State
        $expectedName = Get-AdltExecutionRecordFileName `
            -ExecutionRecord $record
        if ($file.Name -cne $expectedName) {
            throw 'Execution record filename does not match its operation.'
        }
        $binding = Get-AdltExecutionRecordEventBinding `
            -ExecutionRecord $record
        $recordHash = [string] $record[$binding.hashProperty]
        $references = @(
            $Events |
                Where-Object {
                    $_.eventType -ceq $binding.eventType -and
                    $_.data[$binding.hashProperty] -ceq $recordHash
                }
        )
        if ($references.Count -ne 1) {
            throw 'Execution record must have one authorization event.'
        }
        $records.Add($record)
    }

    $authorizationEvents = @(
        $Events |
            Where-Object {
                $_.eventType -in @(
                    'authorization-recorded'
                    'teardown-authorization-recorded'
                )
            }
    )
    if ($authorizationEvents.Count -ne $records.Count) {
        throw 'Authorization events and execution records do not match.'
    }
    $deploymentRecords = @(
        $records.ToArray() |
            Where-Object {
                $_.kind -ceq 'AzureDataLabExecutionRecord'
            }
    )
    $teardownRecords = @(
        $records.ToArray() |
            Where-Object {
                $_.kind -ceq
                    'AzureDataLabTeardownExecutionRecord'
            }
    )
    if (
        $deploymentRecords.Count -gt 1 -or
        $teardownRecords.Count -gt 1
    ) {
        throw 'A protected run cannot contain duplicate operation records.'
    }
    if (
        $teardownRecords.Count -eq 1 -and
        (
            $deploymentRecords.Count -ne 1 -or
            $teardownRecords[0].deploymentExecutionRecordHash -cne
                $deploymentRecords[0].executionRecordHash
        )
    ) {
        throw 'Teardown and deployment execution records are not bound.'
    }
    return @($records.ToArray())
}

function Add-AdltLocalExecutionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $fullRunPath = Assert-AdltLocalStorePath -Path $RunPath
    $lock = Open-AdltLocalRunLock -RunPath $fullRunPath
    $pendingPath = $null
    $eventAppended = $false
    try {
        $context = Get-AdltVerifiedLocalRunContext `
            -RunPath $fullRunPath
        Assert-AdltLocalMutationNotExpired `
            -State $context.State `
            -OccurredAt $OccurredAt
        if (
            $context.State.status -cne 'authorizing' -or
            @($context.Artifacts).Count -ne 0
        ) {
            throw 'Execution record can only consume an authorizing run once.'
        }
        Assert-AdltExecutionRecordArtifact `
            -ExecutionRecord $ExecutionRecord `
            -State $context.State
        if (
            $ExecutionRecord.authorization.stateBinding.stateHash -cne
                $context.State.stateHash -or
            $ExecutionRecord.authorization.stateBinding.eventHash -cne
                $context.TailEvent.eventHash
        ) {
            throw 'Execution record authorization does not bind the current run tail.'
        }

        $artifactPath = Join-Path $fullRunPath 'artifacts'
        $finalPath = Join-Path `
            $artifactPath `
            (Get-AdltExecutionRecordFileName `
                -ExecutionRecord $ExecutionRecord)
        $pendingPath = '{0}.pending' -f $finalPath
        if (
            [System.IO.File]::Exists($finalPath) -or
            [System.IO.File]::Exists($pendingPath)
        ) {
            throw 'A deployment execution record already exists.'
        }
        [void] (Write-AdltPrivateAtomicText `
            -Path $pendingPath `
            -Content (
                ConvertTo-AdltCanonicalJson -InputObject $ExecutionRecord
            ))

        $runEvent = New-AdltRunEvent `
            -RunId $context.State.runId `
            -PlanHash $context.State.planHash `
            -IntentHash $context.State.intentHash `
            -Sequence ($context.Events.Count + 1) `
            -Generation ([int] $context.State.generation) `
            -PreviousEventHash $context.TailEvent.eventHash `
            -EventType authorization-recorded `
            -ActorType interactive-user `
            -ActorId $ActorId `
            -Data ([ordered]@{
                operation = 'deploy'
                operationId = $ExecutionRecord.operationId
                executionRecordHash =
                    $ExecutionRecord.executionRecordHash
            }) `
            -OccurredAt $OccurredAt
        Write-AdltRunEventLog `
            -Path (Join-Path $fullRunPath 'events.ndjson') `
            -RunEvent $runEvent
        $eventAppended = $true
        [System.IO.File]::Move($pendingPath, $finalPath, $false)
        $pendingPath = $null
        Set-AdltPrivatePathMode -Path $finalPath -Type File

        $state = Invoke-AdltRunEventProjection `
            -State $context.Replayed `
            -RunEvent $runEvent
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $fullRunPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
            -Force)
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath
        return [pscustomobject]@{
            State = $state
            RunEvent = $runEvent
            ExecutionRecordPath = $finalPath
        }
    }
    catch {
        if (
            -not $eventAppended -and
            -not [string]::IsNullOrWhiteSpace($pendingPath) -and
            [System.IO.File]::Exists($pendingPath)
        ) {
            [System.IO.File]::Delete($pendingPath)
        }
        throw
    }
    finally {
        $lock.Dispose()
    }
}

function Add-AdltLocalOperationEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [ValidateSet(
            'operation-started',
            'operation-resumed',
            'operation-uncertain',
            'operation-finished'
        )]
        [string] $EventType,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Data,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [ValidateSet('interactive-user', 'toolkit')]
        [string] $ActorType = 'toolkit',

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $fullRunPath = Assert-AdltLocalStorePath -Path $RunPath
    $lock = Open-AdltLocalRunLock -RunPath $fullRunPath
    try {
        $context = Get-AdltVerifiedLocalRunContext `
            -RunPath $fullRunPath
        $cleanup = $EventType -in @(
            'operation-uncertain'
            'operation-finished'
        )
        Assert-AdltLocalMutationNotExpired `
            -State $context.State `
            -OccurredAt $OccurredAt `
            -Cleanup:$cleanup
        if (@($context.Artifacts).Count -ne 1) {
            throw 'Operation event requires one committed execution record.'
        }
        $record = $context.Artifacts[0]
        if (
            $Data.operation -cne $record.operation -or
            $Data.operationId -cne $record.operationId
        ) {
            throw 'Operation event does not match its execution record.'
        }
        if (
            $EventType -in @(
                'operation-started'
                'operation-resumed'
            ) -and
            $Data.executionRecordHash -cne $record.executionRecordHash
        ) {
            throw 'Operation event does not match its execution record hash.'
        }
        $existingStarts = @(
            $context.Events |
                Where-Object {
                    $_.eventType -ceq 'operation-started' -and
                    $_.data.operationId -ceq $record.operationId
                }
        )
        if (
            $EventType -eq 'operation-started' -and
            $existingStarts.Count -ne 0
        ) {
            throw 'The execution record has already been consumed.'
        }
        if (
            $EventType -ne 'operation-started' -and
            $existingStarts.Count -ne 1
        ) {
            throw 'Operation completion requires one prior start event.'
        }
        if ($EventType -eq 'operation-resumed') {
            if ($ActorType -cne 'interactive-user') {
                throw 'Deployment resume requires an interactive user.'
            }
            $existingResumes = @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq 'operation-resumed' -and
                        $_.data.operationId -ceq $record.operationId
                    }
            )
            $existingUncertain = @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq 'operation-uncertain' -and
                        $_.data.operationId -ceq $record.operationId
                    }
            )
            if (
                $context.State.status -cne 'deployment-unknown' -or
                $existingUncertain.Count -ne
                    ($existingResumes.Count + 1)
            ) {
                throw (
                    'Deployment resume requires one fresh uncertain ' +
                    'operation outcome.'
                )
            }
        }
        if ($EventType -eq 'operation-finished') {
            $matchingEvidence = @(
                $context.Evidence |
                    Where-Object evidenceHash -CEQ $Data.evidenceHash
            )
            if (
                $matchingEvidence.Count -ne 1 -or
                $matchingEvidence[0].stage -cne 'deploy'
            ) {
                throw 'Operation finish requires committed deployment evidence.'
            }
        }

        $runEvent = New-AdltRunEvent `
            -RunId $context.State.runId `
            -PlanHash $context.State.planHash `
            -IntentHash $context.State.intentHash `
            -Sequence ($context.Events.Count + 1) `
            -Generation ([int] $context.State.generation) `
            -PreviousEventHash $context.TailEvent.eventHash `
            -EventType $EventType `
            -ActorType $ActorType `
            -ActorId $ActorId `
            -Data $Data `
            -OccurredAt $OccurredAt
        Write-AdltRunEventLog `
            -Path (Join-Path $fullRunPath 'events.ndjson') `
            -RunEvent $runEvent
        $state = Invoke-AdltRunEventProjection `
            -State $context.Replayed `
            -RunEvent $runEvent
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $fullRunPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
            -Force)
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath
        return [pscustomobject]@{
            State = $state
            RunEvent = $runEvent
        }
    }
    finally {
        $lock.Dispose()
    }
}

function Get-AdltRunStateBeforeEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Events,

        [Parameter(Mandatory)]
        [ValidateRange(2, [int]::MaxValue)]
        [int] $EventSequence
    )

    $state = $null
    foreach ($runEventItem in @(
        $Events |
            Where-Object { [int] $_.sequence -lt $EventSequence } |
            Sort-Object { [int] $_.sequence }
    )) {
        $state = Invoke-AdltRunEventProjection `
            -State $state `
            -RunEvent (
                ConvertTo-AdltDictionary -InputObject $runEventItem
            )
    }
    if ($null -eq $state) {
        throw 'Execution record does not have a reconstructable predecessor state.'
    }
    return $state
}

function Assert-AdltPersistedDeploymentExecutionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow
    )

    if (@($Context.Artifacts).Count -ne 1) {
        throw 'The protected run must contain one deployment execution record.'
    }
    $record = ConvertTo-AdltDictionary `
        -InputObject $Context.Artifacts[0]
    $authorizationEvents = @(
        $Context.Events |
            Where-Object {
                $_.eventType -ceq 'authorization-recorded' -and
                $_.data.executionRecordHash -ceq
                    $record.executionRecordHash
            }
    )
    if ($authorizationEvents.Count -ne 1) {
        throw 'The deployment execution record lacks one authorization event.'
    }
    $authorizationEvent = ConvertTo-AdltDictionary `
        -InputObject $authorizationEvents[0]
    if (
        $authorizationEvent.actor.type -cne 'interactive-user' -or
        $authorizationEvent.actor.id -cne
            $record.authorization.approval.approver.id -or
        $authorizationEvent.data.operationId -cne $record.operationId
    ) {
        throw 'The persisted authorization event identity is invalid.'
    }

    $authorizationState = Get-AdltRunStateBeforeEvent `
        -Events $Context.Events `
        -EventSequence ([int] $authorizationEvent.sequence)
    $liveResolution = Get-AdltRunEvidenceByStage `
        -Evidence $Context.Evidence `
        -Stage live-resolution
    $whatIf = Get-AdltRunEvidenceByStage `
        -Evidence $Context.Evidence `
        -Stage what-if
    $cost = Get-AdltRunEvidenceByStage `
        -Evidence $Context.Evidence `
        -Stage cost
    $teardownPreview = Get-AdltRunEvidenceByStage `
        -Evidence $Context.Evidence `
        -Stage teardown-preview
    $compilation = New-AdltSqlVmArmCompilation `
        -Plan $Context.Plan `
        -LiveResolutionEvidence $liveResolution
    Assert-AdltDeploymentExecutionRecord `
        -ExecutionRecord $record `
        -Plan $Context.Plan `
        -State $authorizationState `
        -LiveResolutionEvidence $liveResolution `
        -WhatIfEvidence $whatIf `
        -CostEvidence $cost `
        -TeardownPreviewEvidence $teardownPreview `
        -Compilation $compilation `
        -AsOf $AsOf

    return [ordered]@{
        ExecutionRecord = $record
        AuthorizationState = $authorizationState
        AuthorizationEvent = $authorizationEvent
        LiveResolution = $liveResolution
        WhatIf = $whatIf
        Cost = $cost
        TeardownPreview = $teardownPreview
        Compilation = $compilation
    }
}
