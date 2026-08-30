function Get-AdltDeploymentExecutionRecordFromContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $records = @(
        $Context.Artifacts |
            Where-Object {
                $_.kind -ceq 'AzureDataLabExecutionRecord'
            }
    )
    if ($records.Count -ne 1) {
        throw 'Teardown requires one committed deployment execution record.'
    }
    return ConvertTo-AdltDictionary -InputObject $records[0]
}

function Get-AdltTeardownExecutionRecordFromContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $records = @(
        $Context.Artifacts |
            Where-Object {
                $_.kind -ceq
                    'AzureDataLabTeardownExecutionRecord'
            }
    )
    if ($records.Count -ne 1) {
        throw 'The run does not contain one teardown execution record.'
    }
    return ConvertTo-AdltDictionary -InputObject $records[0]
}

function Get-AdltEffectiveTeardownCleanupLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    Assert-AdltTeardownExecutionRecordArtifact `
        -ExecutionRecord $ExecutionRecord `
        -State $Context.State
    $effectiveLease = Copy-AdltValue `
        -InputObject $ExecutionRecord.cleanupLease
    $previousExpiresAt = [datetimeoffset]::Parse(
        [string] $effectiveLease.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $refreshEvents = @(
        $Context.Events |
            Where-Object {
                $_.eventType -ceq
                    'teardown-authorization-refreshed' -and
                $_.data.operationId -ceq
                    $ExecutionRecord.operationId
            } |
            Sort-Object sequence
    )
    foreach ($eventValue in $refreshEvents) {
        $refreshEvent = ConvertTo-AdltDictionary -InputObject $eventValue
        if (
            $refreshEvent.actor.type -cne 'interactive-user' -or
            $refreshEvent.actor.id -cne
                $ExecutionRecord.cleanupLease.approver.id -or
            $refreshEvent.data.operation -cne 'teardown' -or
            $refreshEvent.data.teardownExecutionRecordHash -cne
                $ExecutionRecord.teardownExecutionRecordHash -or
            $refreshEvent.data.inventoryHash -cne
                $ExecutionRecord.inventory.inventoryHash -or
            $refreshEvent.data.confirmationPhraseHash -cne
                $ExecutionRecord.cleanupLease.confirmationPhraseHash
        ) {
            throw 'Teardown authorization refresh is not bound to its record.'
        }
        $approvedAt = [datetimeoffset]::Parse(
            [string] $refreshEvent.data.approvedAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $occurredAt = [datetimeoffset]::Parse(
            [string] $refreshEvent.occurredAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        if (
            $approvedAt -ne $occurredAt -or
            $approvedAt -lt $previousExpiresAt
        ) {
            throw 'Teardown authorization refresh is out of sequence.'
        }
        $effectiveLease = [ordered]@{
            inventoryHash = [string] $refreshEvent.data.inventoryHash
            confirmationPhraseHash =
                [string] $refreshEvent.data.confirmationPhraseHash
            approver = [ordered]@{
                type = 'user'
                id   = [string] $refreshEvent.actor.id
            }
            mechanism = 'interactive'
            approvedAt = [string] $refreshEvent.data.approvedAt
            expiresAt  = [string] $refreshEvent.data.expiresAt
        }
        Assert-AdltTeardownCleanupLease `
            -CleanupLease $effectiveLease `
            -ExecutionRecord $ExecutionRecord `
            -AsOf $approvedAt
        $previousExpiresAt = [datetimeoffset]::Parse(
            [string] $effectiveLease.expiresAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    return $effectiveLease
}

function Add-AdltLocalTeardownAuthorizationRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $ActorId,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $InventoryHash,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $fullRunPath = Assert-AdltLocalStorePath -Path $RunPath
    $lock = Open-AdltLocalRunLock -RunPath $fullRunPath
    try {
        $context = Get-AdltVerifiedLocalRunContext `
            -RunPath $fullRunPath
        Assert-AdltLocalMutationNotExpired `
            -State $context.State `
            -OccurredAt $OccurredAt `
            -Cleanup
        if ($context.State.status -cne 'teardown-pending') {
            throw 'Only a pending teardown authorization can be refreshed.'
        }
        $record = Get-AdltTeardownExecutionRecordFromContext `
            -Context $context
        if (
            $ActorId -cne $record.cleanupLease.approver.id -or
            $InventoryHash -cne $record.inventory.inventoryHash
        ) {
            throw 'Teardown refresh principal or inventory does not match.'
        }
        $deploymentRecord = Get-AdltDeploymentExecutionRecordFromContext `
            -Context $context
        if (
            $record.deploymentExecutionRecordHash -cne
                $deploymentRecord.executionRecordHash
        ) {
            throw 'Teardown refresh is not bound to the deployment record.'
        }
        if (
            @(
                $context.Events |
                    Where-Object {
                        $_.eventType -ceq
                            'teardown-operation-started' -and
                        $_.data.operationId -ceq $record.operationId
                    }
            ).Count -ne 0
        ) {
            throw 'A consumed teardown authorization cannot be refreshed.'
        }
        $currentLease = Get-AdltEffectiveTeardownCleanupLease `
            -Context $context `
            -ExecutionRecord $record
        $currentExpiresAt = [datetimeoffset]::Parse(
            [string] $currentLease.expiresAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        if ($OccurredAt -lt $currentExpiresAt) {
            throw 'The current cleanup lease is still valid.'
        }

        $data = [ordered]@{
            operation = 'teardown'
            operationId = $record.operationId
            teardownExecutionRecordHash =
                $record.teardownExecutionRecordHash
            inventoryHash = $record.inventory.inventoryHash
            confirmationPhraseHash =
                $record.cleanupLease.confirmationPhraseHash
            approvedAt = ConvertTo-AdltUtcTimestamp -Value $OccurredAt
            expiresAt = ConvertTo-AdltUtcTimestamp `
                -Value $OccurredAt.AddMinutes(10)
        }
        $refreshEvent = New-AdltRunEvent `
            -RunId $context.State.runId `
            -PlanHash $context.State.planHash `
            -IntentHash $context.State.intentHash `
            -Sequence ($context.Events.Count + 1) `
            -Generation ([int] $context.State.generation) `
            -PreviousEventHash $context.TailEvent.eventHash `
            -EventType teardown-authorization-refreshed `
            -ActorType interactive-user `
            -ActorId $ActorId `
            -Data $data `
            -OccurredAt $OccurredAt
        Write-AdltRunEventLog `
            -Path (Join-Path $fullRunPath 'events.ndjson') `
            -RunEvent $refreshEvent
        $state = Invoke-AdltRunEventProjection `
            -State $context.Replayed `
            -RunEvent $refreshEvent
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $fullRunPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
            -Force)
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath
        return [pscustomobject]@{
            State        = $state
            RunEvent     = $refreshEvent
            CleanupLease = [ordered]@{
                inventoryHash = $data.inventoryHash
                confirmationPhraseHash =
                    $data.confirmationPhraseHash
                approver = [ordered]@{
                    type = 'user'
                    id   = $ActorId
                }
                mechanism = 'interactive'
                approvedAt = $data.approvedAt
                expiresAt  = $data.expiresAt
            }
        }
    }
    finally {
        $lock.Dispose()
    }
}

function Add-AdltLocalTeardownExecutionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
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
            -OccurredAt $OccurredAt `
            -Cleanup
        $deploymentRecord = Get-AdltDeploymentExecutionRecordFromContext `
            -Context $context
        if (
            @(
                $context.Artifacts |
                    Where-Object {
                        $_.kind -ceq
                            'AzureDataLabTeardownExecutionRecord'
                    }
            ).Count -ne 0
        ) {
            throw 'A teardown execution record already exists.'
        }
        Assert-AdltTeardownExecutionRecordForExecution `
            -ExecutionRecord $ExecutionRecord `
            -State $context.State `
            -DeploymentExecutionRecord $deploymentRecord `
            -AsOf $OccurredAt

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
            throw 'A teardown execution record already exists.'
        }
        [void] (Write-AdltPrivateAtomicText `
            -Path $pendingPath `
            -Content (
                ConvertTo-AdltCanonicalJson -InputObject $ExecutionRecord
            ))

        $authorizationEvent = New-AdltRunEvent `
            -RunId $context.State.runId `
            -PlanHash $context.State.planHash `
            -IntentHash $context.State.intentHash `
            -Sequence ($context.Events.Count + 1) `
            -Generation ([int] $context.State.generation) `
            -PreviousEventHash $context.TailEvent.eventHash `
            -EventType teardown-authorization-recorded `
            -ActorType interactive-user `
            -ActorId $ActorId `
            -Data ([ordered]@{
                operation = 'teardown'
                operationId = $ExecutionRecord.operationId
                teardownExecutionRecordHash =
                    $ExecutionRecord.teardownExecutionRecordHash
            }) `
            -OccurredAt $OccurredAt
        Write-AdltRunEventLog `
            -Path (Join-Path $fullRunPath 'events.ndjson') `
            -RunEvent $authorizationEvent
        $eventAppended = $true
        [System.IO.File]::Move($pendingPath, $finalPath, $false)
        $pendingPath = $null
        Set-AdltPrivatePathMode -Path $finalPath -Type File

        $state = Invoke-AdltRunEventProjection `
            -State $context.Replayed `
            -RunEvent $authorizationEvent
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $fullRunPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
            -Force)
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath
        return [pscustomobject]@{
            State = $state
            RunEvent = $authorizationEvent
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

function Add-AdltLocalTeardownOperationEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [ValidateSet(
            'teardown-operation-started',
            'teardown-operation-resumed',
            'teardown-operation-uncertain',
            'teardown-operation-finished'
        )]
        [string] $EventType,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Data,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $fullRunPath = Assert-AdltLocalStorePath -Path $RunPath
    $lock = Open-AdltLocalRunLock -RunPath $fullRunPath
    try {
        $context = Get-AdltVerifiedLocalRunContext `
            -RunPath $fullRunPath
        Assert-AdltLocalMutationNotExpired `
            -State $context.State `
            -OccurredAt $OccurredAt `
            -Cleanup
        $record = Get-AdltTeardownExecutionRecordFromContext `
            -Context $context
        $deploymentRecord = Get-AdltDeploymentExecutionRecordFromContext `
            -Context $context
        if (
            $Data.operation -cne 'teardown' -or
            $Data.operationId -cne $record.operationId
        ) {
            throw 'Teardown event does not match its execution record.'
        }
        if ($EventType -eq 'teardown-operation-started') {
            if (
                $Data.teardownExecutionRecordHash -cne
                    $record.teardownExecutionRecordHash
            ) {
                throw 'Teardown start does not match its record hash.'
            }
            $effectiveLease = Get-AdltEffectiveTeardownCleanupLease `
                -Context $context `
                -ExecutionRecord $record
            Assert-AdltTeardownExecutionRecordForExecution `
                -ExecutionRecord $record `
                -State $context.State `
                -DeploymentExecutionRecord $deploymentRecord `
                -CleanupLease $effectiveLease `
                -AsOf $OccurredAt
        }
        elseif ($EventType -eq 'teardown-operation-resumed') {
            if (
                $context.State.status -cne 'cleanup-unknown' -or
                $Data.teardownExecutionRecordHash -cne
                    $record.teardownExecutionRecordHash -or
                $ActorId -cne $record.cleanupLease.approver.id -or
                [string] $Data.approvedAt -cne
                    (ConvertTo-AdltUtcTimestamp -Value $OccurredAt)
            ) {
                throw 'Teardown resume is not bound to its record and approver.'
            }
            if (
                @(
                    $context.Events |
                        Where-Object {
                            $_.eventType -ceq
                                'teardown-operation-finished' -and
                            $_.data.operationId -ceq
                                $record.operationId
                        }
                ).Count -ne 0
            ) {
                throw 'A completed teardown cannot be resumed.'
            }
        }
        else {
            Assert-AdltTeardownExecutionRecordArtifact `
                -ExecutionRecord $record `
                -State $context.State
        }

        $existingStarts = @(
            $context.Events |
                Where-Object {
                    $_.eventType -ceq
                        'teardown-operation-started' -and
                    $_.data.operationId -ceq $record.operationId
                }
        )
        if (
            $EventType -eq 'teardown-operation-started' -and
            $existingStarts.Count -ne 0
        ) {
            throw 'The teardown execution record has already been consumed.'
        }
        if (
            $EventType -ne 'teardown-operation-started' -and
            $existingStarts.Count -ne 1
        ) {
            throw 'Teardown completion requires one prior start event.'
        }
        if ($EventType -eq 'teardown-operation-finished') {
            $matchingEvidence = @(
                $context.Evidence |
                    Where-Object {
                        $_.evidenceHash -ceq $Data.evidenceHash -and
                        $_.stage -ceq 'cleanup-proof' -and
                        $_.payload.teardownExecutionRecordHash -ceq
                            $record.teardownExecutionRecordHash
                    }
            )
            if ($matchingEvidence.Count -ne 1) {
                throw 'Teardown finish requires committed cleanup-proof evidence.'
            }
        }

        $operationEvent = New-AdltRunEvent `
            -RunId $context.State.runId `
            -PlanHash $context.State.planHash `
            -IntentHash $context.State.intentHash `
            -Sequence ($context.Events.Count + 1) `
            -Generation ([int] $context.State.generation) `
            -PreviousEventHash $context.TailEvent.eventHash `
            -EventType $EventType `
            -ActorType $(if (
                $EventType -eq 'teardown-operation-resumed'
            ) {
                'interactive-user'
            }
            else {
                'toolkit'
            }) `
            -ActorId $ActorId `
            -Data $Data `
            -OccurredAt $OccurredAt
        Write-AdltRunEventLog `
            -Path (Join-Path $fullRunPath 'events.ndjson') `
            -RunEvent $operationEvent
        $state = Invoke-AdltRunEventProjection `
            -State $context.Replayed `
            -RunEvent $operationEvent
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $fullRunPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
            -Force)
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath
        return [pscustomobject]@{
            State = $state
            RunEvent = $operationEvent
        }
    }
    finally {
        $lock.Dispose()
    }
}

function Get-AdltApprovedResourceSetHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject @(
            $ExecutionRecord.inventory.resources |
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

function Get-AdltTeardownDeletionOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    $inventoryByStableId =
        [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::Ordinal
        )
    foreach ($resource in @($ExecutionRecord.inventory.resources)) {
        $inventoryByStableId.Add([string] $resource.stableId, $resource)
    }

    $ordered = [System.Collections.Generic.List[object]]::new()
    $scheduled = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($resource in @(
        $ExecutionRecord.inventory.resources |
            Where-Object {
                $_.relationship -ceq 'sql-iaas-agent-extension'
            } |
            Sort-Object resourceId
    )) {
        [void] $scheduled.Add([string] $resource.resourceId)
        $ordered.Add($resource)
    }

    $reverseBindings = @($Compilation.actionBindings)
    [array]::Reverse($reverseBindings)
    foreach ($binding in $reverseBindings) {
        $stableId = [string] $binding.resourceStableId
        if (
            $binding.disposition -ceq 'deploy' -and
            $stableId -cne 'azure.resource-group.primary' -and
            $inventoryByStableId.ContainsKey($stableId)
        ) {
            $resource = $inventoryByStableId[$stableId]
            if ($scheduled.Add([string] $resource.resourceId)) {
                $ordered.Add($resource)
            }
        }
        if ($stableId -ceq 'azure.compute.virtual-machine.primary') {
            foreach ($resource in @(
                $ExecutionRecord.inventory.resources |
                    Where-Object {
                        $_.relationship -ceq 'vm-managed-disk'
                    } |
                    Sort-Object resourceId
            )) {
                if ($scheduled.Add([string] $resource.resourceId)) {
                    $ordered.Add($resource)
                }
            }
        }
    }

    if ($ordered.Count -ne [int] $ExecutionRecord.inventory.resourceCount) {
        $missing = @(
            $ExecutionRecord.inventory.resources |
                Where-Object {
                    -not $scheduled.Contains([string] $_.resourceId)
                } |
                ForEach-Object { [string] $_.resourceId }
        )
        throw (
            'The exact-resource deletion order is incomplete: {0}' -f
            ($missing -join ', ')
        )
    }
    return @($ordered.ToArray())
}

function Test-AdltApprovedResourceUnchanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation
    )

    $approvedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($approved in @($ExecutionRecord.inventory.resources)) {
        [void] $approvedIds.Add([string] $approved.resourceId)
    }
    $retainedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($expected in @(
        Get-AdltSqlVmTeardownExpectedResourceSet `
            -Plan $Plan `
            -Compilation $Compilation |
            Where-Object relationship -CEQ 'nested-deployment'
    )) {
        [void] $retainedIds.Add([string] $expected.resourceId)
    }
    $listedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    try {
        $listed = @(
            Invoke-AdltAzCommand `
                -ModuleName 'Az.Resources' `
                -CommandName 'Get-AzResource' `
                -Parameters @{
                    ResourceGroupName = [string] $ExecutionRecord.
                        deleteAction.resourceGroupName
                    ExpandProperties = $true
                    ErrorAction      = 'Stop'
                }
        )
    }
    catch {
        if ((Get-AdltAzureFailureKind -ErrorRecord $_) -eq 'absent') {
            return $false
        }
        throw
    }
    foreach ($observed in $listed) {
        if ($null -eq $observed) {
            continue
        }
        $resourceId = Get-AdltObservedResourceId -Observed $observed
        if ($retainedIds.Contains($resourceId)) {
            continue
        }
        if (-not $approvedIds.Contains($resourceId)) {
            throw (
                "Exact-resource deletion is blocked by unapproved resource " +
                "'$resourceId'."
            )
        }
        [void] $listedIds.Add($resourceId)
    }

    try {
        $observed = Invoke-AdltAzCommand `
            -ModuleName 'Az.Resources' `
            -CommandName 'Get-AzResource' `
            -Parameters @{
                ResourceId       = [string] $Resource.resourceId
                ApiVersion       = [string] $Resource.apiVersion
                ExpandProperties = $true
                ErrorAction      = 'Stop'
            }
    }
    catch {
        if ((Get-AdltAzureFailureKind -ErrorRecord $_) -eq 'absent') {
            return $false
        }
        throw
    }
    if (
        $null -eq $observed -or
        -not $listedIds.Contains([string] $Resource.resourceId)
    ) {
        throw 'Exact-resource deletion received inconsistent Azure inventory.'
    }
    $observedId = Get-AdltObservedResourceId -Observed $observed
    $observedType = Get-AdltObservedResourceType -Observed $observed
    $observedEtag = Get-AdltObservedResourceEtag -Observed $observed
    $observedFingerprint = Get-AdltObservedResourceFingerprint `
        -Observed $observed
    if (
        -not [string]::Equals(
            $observedId,
            [string] $Resource.resourceId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            $observedType,
            [string] $Resource.resourceType,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        (
            $null -ne $Resource.etag -and
            [string] $observedEtag -cne [string] $Resource.etag
        ) -or
        $observedFingerprint -cne
            [string] $Resource.observationFingerprint
    ) {
        throw (
            "Approved resource '$($Resource.resourceId)' changed after " +
            'teardown approval.'
        )
    }
    if (
        $Resource.relationship -in @(
            'planned-taggable'
            'planned-descendant'
        )
    ) {
        $expectedMatches = @(
            Get-AdltSqlVmTeardownExpectedResourceSet `
                -Plan $Plan `
                -Compilation $Compilation |
                Where-Object {
                    [string]::Equals(
                        [string] $_.resourceId,
                        [string] $Resource.resourceId,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
        if ($expectedMatches.Count -ne 1) {
            throw 'Approved resource no longer has one compiler proof contract.'
        }
        $expected = ConvertTo-AdltDictionary `
            -InputObject $expectedMatches[0]
        $planResources = Get-AdltSqlVmArmResourceMap -Plan $Plan
        $compiledResources =
            Get-AdltSqlVmCompiledNestedResourceMap `
                -Plan $Plan `
                -Compilation $Compilation
        $freshProof = Get-AdltSqlVmPlannedResourceProof `
            -Observed $observed `
            -Plan $Plan `
            -State $ExecutionRecord `
            -Expected $expected `
            -PlanResource $planResources[
                [string] $expected.stableId
            ] `
            -CompiledResource $compiledResources[
                [string] $expected.stableId
            ]
        if ($freshProof -cne [string] $Resource.proofHash) {
            throw (
                "Approved resource '$($Resource.resourceId)' ownership or " +
                'material-state proof changed before deletion.'
            )
        }
    }
    return $true
}

function Get-AdltTeardownMutationTime {
    [CmdletBinding()]
    param()

    return [datetimeoffset]::UtcNow
}

function New-AdltTeardownMutationLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $CleanupLease,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [ValidateSet('start', 'resume')]
        [string] $AuthorizationKind,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $AuthorizationEventHash
    )

    $lease = Copy-AdltValue -InputObject $CleanupLease
    $lease.operationId = [string] $ExecutionRecord.operationId
    $lease.teardownExecutionRecordHash =
        [string] $ExecutionRecord.teardownExecutionRecordHash
    $lease.authorizationKind = $AuthorizationKind
    $lease.authorizationEventHash = $AuthorizationEventHash
    $lease.mutationLeaseHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $lease
    )
    Assert-AdltTeardownMutationLease `
        -MutationLease $lease `
        -ExecutionRecord $ExecutionRecord `
        -AsOf ([datetimeoffset]::Parse(
            [string] $lease.approvedAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        ))
    return $lease
}

function Assert-AdltTeardownMutationLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $MutationLease,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [datetimeoffset] $AsOf
    )

    Assert-AdltTeardownCleanupLease `
        -CleanupLease $MutationLease `
        -ExecutionRecord $ExecutionRecord `
        -AsOf $AsOf
    if (
        $MutationLease.operationId -cne $ExecutionRecord.operationId -or
        $MutationLease.teardownExecutionRecordHash -cne
            $ExecutionRecord.teardownExecutionRecordHash -or
        $MutationLease.authorizationKind -notin @('start', 'resume') -or
        [string] $MutationLease.authorizationEventHash -notmatch
            '^sha256:[a-f0-9]{64}$' -or
        [string] $MutationLease.mutationLeaseHash -notmatch
            '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'The teardown mutation lease is not bound to its operation.'
    }
    $hashInput = Copy-AdltValue -InputObject $MutationLease
    [void] $hashInput.Remove('mutationLeaseHash')
    $expectedHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $hashInput
    )
    if ($MutationLease.mutationLeaseHash -cne $expectedHash) {
        throw 'The teardown mutation lease hash is invalid.'
    }
}

function Invoke-AdltApprovedResourceDeletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $CleanupLease
    )

    if (-not [bool] $ExecutionRecord.deleteAction.operationRequired) {
        return @()
    }
    $deleted = [System.Collections.Generic.List[string]]::new()
    foreach ($resource in @(
        Get-AdltTeardownDeletionOrder `
            -Compilation $Compilation `
            -ExecutionRecord $ExecutionRecord
    )) {
        if (
            -not (Test-AdltApprovedResourceUnchanged `
                -Resource $resource `
                -ExecutionRecord $ExecutionRecord `
                -Plan $Plan `
                -Compilation $Compilation)
        ) {
            $deleted.Add([string] $resource.resourceId)
            continue
        }
        try {
            [void] (Assert-AdltAzureMutationPrincipal `
                -Plan $Plan `
                -ExpectedPrincipalId (
                    [string] $CleanupLease.approver.id
                ))
            Assert-AdltTeardownMutationLease `
                -MutationLease $CleanupLease `
                -ExecutionRecord $ExecutionRecord `
                -AsOf (Get-AdltTeardownMutationTime)
            [void] (Invoke-AdltAzCommand `
                -ModuleName 'Az.Resources' `
                -CommandName 'Remove-AzResource' `
                -Parameters @{
                    ResourceId = [string] $resource.resourceId
                    ApiVersion = [string] $resource.apiVersion
                    Force       = $true
                    Confirm     = $false
                    ErrorAction = 'Stop'
                })
            $deleted.Add([string] $resource.resourceId)
        }
        catch {
            if ((Get-AdltAzureFailureKind -ErrorRecord $_) -eq 'absent') {
                $deleted.Add([string] $resource.resourceId)
                continue
            }
            throw
        }
    }
    return @($deleted.ToArray())
}

function Get-AdltApprovedResourceDeletionObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord
    )

    $approvedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $remainingIds = [System.Collections.Generic.List[string]]::new()
    foreach ($resource in @($ExecutionRecord.inventory.resources)) {
        [void] $approvedIds.Add([string] $resource.resourceId)
        try {
            $observed = Invoke-AdltAzCommand `
                -ModuleName 'Az.Resources' `
                -CommandName 'Get-AzResource' `
                -Parameters @{
                    ResourceId       = [string] $resource.resourceId
                    ApiVersion       = [string] $resource.apiVersion
                    ExpandProperties = $true
                    ErrorAction      = 'Stop'
                }
            if ($null -eq $observed) {
                return [ordered]@{
                    state                          = 'unknown'
                    failureKind                    = 'empty-response'
                    remainingApprovedResourceCount = $null
                    resourceGroupState             = 'unknown'
                    retainedUnapprovedResourceCount = $null
                }
            }
            $resourceId = Get-AdltObservedResourceId `
                -Observed $observed
            if (
                -not [string]::Equals(
                    $resourceId,
                    [string] $resource.resourceId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                return [ordered]@{
                    state                          = 'unknown'
                    failureKind                    = 'conflict'
                    remainingApprovedResourceCount = $null
                    resourceGroupState             = 'unknown'
                    retainedUnapprovedResourceCount = $null
                }
            }
            $remainingIds.Add([string] $resourceId)
        }
        catch {
            $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
            if ($failureKind -ne 'absent') {
                return [ordered]@{
                    state                          = 'unknown'
                    failureKind                    = $failureKind
                    remainingApprovedResourceCount = $null
                    resourceGroupState             = 'unknown'
                    retainedUnapprovedResourceCount = $null
                }
            }
        }
    }
    if ($remainingIds.Count -gt 0) {
        return [ordered]@{
            state                          = 'approved-resources-present'
            failureKind                    = $null
            remainingApprovedResourceCount = $remainingIds.Count
            resourceGroupState             = 'present'
            retainedUnapprovedResourceCount = $null
        }
    }

    try {
        $observedGroup = Invoke-AdltAzCommand `
            -ModuleName 'Az.Resources' `
            -CommandName 'Get-AzResourceGroup' `
            -Parameters @{
                Name        = [string] $ExecutionRecord.deleteAction.
                    resourceGroupName
                ErrorAction = 'Stop'
            }
        if ($null -eq $observedGroup) {
            return [ordered]@{
                state                          = 'unknown'
                failureKind                    = 'empty-response'
                remainingApprovedResourceCount = $null
                resourceGroupState             = 'unknown'
                retainedUnapprovedResourceCount = $null
            }
        }
        $resourceGroupId = Get-AdltObservedResourceId `
            -Observed $observedGroup
        if (
            -not [string]::Equals(
                $resourceGroupId,
                [string] $ExecutionRecord.deleteAction.resourceId,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return [ordered]@{
                state                          = 'unknown'
                failureKind                    = 'conflict'
                remainingApprovedResourceCount = $null
                resourceGroupState             = 'unknown'
                retainedUnapprovedResourceCount = $null
            }
        }

        $retained = @(
            Invoke-AdltAzCommand `
                -ModuleName 'Az.Resources' `
                -CommandName 'Get-AzResource' `
                -Parameters @{
                    ResourceGroupName = [string] $ExecutionRecord.
                        deleteAction.resourceGroupName
                    ExpandProperties = $true
                    ErrorAction      = 'Stop'
                }
        )
        foreach ($resource in $retained) {
            if (
                $null -ne $resource -and
                $approvedIds.Contains(
                    (Get-AdltObservedResourceId -Observed $resource)
                )
            ) {
                return [ordered]@{
                    state                          = 'approved-resources-present'
                    failureKind                    = 'conflict'
                    remainingApprovedResourceCount = 1
                    resourceGroupState             = 'present'
                    retainedUnapprovedResourceCount = $null
                }
            }
        }
        return [ordered]@{
            state                          = 'approved-resources-absent'
            failureKind                    = $null
            remainingApprovedResourceCount = 0
            resourceGroupState             = 'present'
            retainedUnapprovedResourceCount = @(
                $retained |
                    Where-Object { $null -ne $_ }
            ).Count
        }
    }
    catch {
        $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
        return [ordered]@{
            state = if ($failureKind -eq 'absent') {
                'approved-resources-absent'
            }
            else {
                'unknown'
            }
            failureKind = $failureKind
            remainingApprovedResourceCount = if (
                $failureKind -eq 'absent'
            ) {
                0
            }
            else {
                $null
            }
            resourceGroupState = if ($failureKind -eq 'absent') {
                'absent'
            }
            else {
                'unknown'
            }
            retainedUnapprovedResourceCount = if (
                $failureKind -eq 'absent'
            ) {
                0
            }
            else {
                $null
            }
        }
    }
}

function Get-AdltRemainingApprovedResourceSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation
    )

    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($resource in @(
        $ExecutionRecord.inventory.resources |
            Sort-Object resourceId
    )) {
        if (
            Test-AdltApprovedResourceUnchanged `
                -Resource $resource `
                -ExecutionRecord $ExecutionRecord `
                -Plan $Plan `
                -Compilation $Compilation
        ) {
            $remaining.Add((
                Copy-AdltValue -InputObject $resource
            ))
        }
    }
    $resources = @($remaining.ToArray())
    return [ordered]@{
        resourceCount = $resources.Count
        resources = $resources
        resourceSetHash = Get-AdltSha256Identifier -Value (
            ConvertTo-AdltCanonicalJson -InputObject @(
                $resources |
                    ForEach-Object {
                        [ordered]@{
                            resourceId = [string] $_.resourceId
                            apiVersion = [string] $_.apiVersion
                            observationFingerprint =
                                [string] $_.observationFingerprint
                        }
                    }
            )
        )
    }
}

function Get-AdltTeardownResumeApprovalPhrase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $RemainingResourceSet
    )

    return 'RESUME DELETE {0} {1} {2} {3}' -f
        $ExecutionRecord.deleteAction.resourceGroupName,
        $ExecutionRecord.runId.Replace(
            '-',
            ''
        ).Substring(0, 8).ToLowerInvariant(),
        [int] $RemainingResourceSet.resourceCount,
        $RemainingResourceSet.resourceSetHash.Substring(7, 12)
}

function New-AdltCleanupProofEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Observation,

        [datetimeoffset] $StartedAt = [datetimeoffset]::UtcNow,

        [datetimeoffset] $CompletedAt = [datetimeoffset]::UtcNow
    )

    if (
        $Observation.state -cne 'approved-resources-absent' -or
        [int] $Observation.remainingApprovedResourceCount -ne 0 -or
        $Observation.resourceGroupState -notin @('present', 'absent') -or
        $null -eq $Observation.retainedUnapprovedResourceCount
    ) {
        throw 'Cleanup proof requires a complete exact-resource absence observation.'
    }
    return New-AdltEvidence `
        -RunId $ExecutionRecord.runId `
        -PlanHash $Plan.planHash `
        -IntentHash $Plan.intentHash `
        -Stage cleanup-proof `
        -Status pass `
        -Payload ([ordered]@{
            teardownExecutionRecordHash =
                $ExecutionRecord.teardownExecutionRecordHash
            operationId = $ExecutionRecord.operationId
            resourceGroupId =
                $ExecutionRecord.deleteAction.resourceId
            approvedResourceSetHash =
                Get-AdltApprovedResourceSetHash `
                    -ExecutionRecord $ExecutionRecord
            approvedResourceCount =
                [int] $ExecutionRecord.inventory.resourceCount
            remainingApprovedResourceCount = 0
            resourceGroupState =
                [string] $Observation.resourceGroupState
            retainedUnapprovedResourceCount =
                [int] $Observation.retainedUnapprovedResourceCount
            observedState = 'approved-resources-absent'
            observationSource = 'Get-AzResource'
            checkedAt = ConvertTo-AdltUtcTimestamp `
                -Value $CompletedAt
        }) `
        -StartedAt $StartedAt `
        -CompletedAt $CompletedAt
}

function Complete-AdltTeardownOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Observation,

        [datetimeoffset] $StartedAt = [datetimeoffset]::UtcNow,

        [datetimeoffset] $CompletedAt = [datetimeoffset]::UtcNow
    )

    $context = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
    $proofs = @(
        $context.Evidence |
            Where-Object {
                $_.stage -ceq 'cleanup-proof' -and
                $_.payload.teardownExecutionRecordHash -ceq
                    $ExecutionRecord.teardownExecutionRecordHash
            }
    )
    if ($proofs.Count -gt 1) {
        throw 'The teardown operation has duplicate cleanup proof.'
    }
    $proof = if ($proofs.Count -eq 1) {
        ConvertTo-AdltDictionary -InputObject $proofs[0]
    }
    else {
        $candidate = New-AdltCleanupProofEvidence `
            -Plan $Plan `
            -ExecutionRecord $ExecutionRecord `
            -Observation $Observation `
            -StartedAt $StartedAt `
            -CompletedAt $CompletedAt
        Add-AdltGeneratedRunEvidence `
            -RunPath $RunPath `
            -Evidence $candidate `
            -ActorId AzureDataLabToolkit `
            -OccurredAt $CompletedAt
    }

    $context = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
    $finished = @(
        $context.Events |
            Where-Object {
                $_.eventType -ceq
                    'teardown-operation-finished' -and
                $_.data.operationId -ceq
                    $ExecutionRecord.operationId
            }
    )
    if ($finished.Count -gt 1) {
        throw 'The teardown operation has duplicate terminal events.'
    }
    if ($finished.Count -eq 0) {
        [void] (Add-AdltLocalTeardownOperationEvent `
            -RunPath $RunPath `
            -EventType teardown-operation-finished `
            -Data ([ordered]@{
                operation = 'teardown'
                operationId = $ExecutionRecord.operationId
                outcome = 'succeeded'
                evidenceHash = $proof.evidenceHash
            }) `
            -ActorId AzureDataLabToolkit `
            -OccurredAt $CompletedAt)
    }

    return [pscustomobject][ordered]@{
        PSTypeName = 'AzureDataLabToolkit.TeardownResult'
        RunId = $ExecutionRecord.runId
        RunPath = [System.IO.Path]::GetFullPath($RunPath)
        OperationId = $ExecutionRecord.operationId
        ResourceGroupName =
            $ExecutionRecord.deleteAction.resourceGroupName
        Status = 'completed'
        EvidenceHash = $proof.evidenceHash
        ResourceGroupRetained =
            $proof.payload.resourceGroupState -ceq 'present'
        RetainedUnapprovedResourceCount =
            [int] $proof.payload.retainedUnapprovedResourceCount
        RequiresReconciliation = $false
    }
}
