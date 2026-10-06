function New-AdltRunEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $PlanHash,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $IntentHash,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Sequence,

        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Generation,

        [AllowNull()]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $PreviousEventHash,

        [Parameter(Mandatory)]
        [ValidateSet(
            'run-created',
            'status-changed',
            'preflight-blocked',
            'resource-observed',
            'evidence-attached',
            'authorization-recorded',
            'operation-started',
            'operation-resumed',
            'operation-uncertain',
            'operation-finished',
            'teardown-authorization-recorded',
            'teardown-authorization-refreshed',
            'teardown-operation-started',
            'teardown-operation-resumed',
            'teardown-operation-uncertain',
            'teardown-operation-finished',
            'failure-recorded',
            'cleanup-status-changed',
            'lock-generation-changed'
        )]
        [string] $EventType,

        [Parameter(Mandatory)]
        [ValidateSet('interactive-user', 'oidc', 'managed-identity', 'toolkit')]
        [string] $ActorType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Data,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $runEvent = [ordered]@{
        schemaVersion     = '1.0'
        kind              = 'AzureDataLabRunEvent'
        canonicalization  = 'rfc8785'
        runId             = $RunId
        planHash           = $PlanHash
        intentHash         = $IntentHash
        sequence          = $Sequence
        generation        = $Generation
        previousEventHash = if ([string]::IsNullOrWhiteSpace($PreviousEventHash)) {
            $null
        }
        else {
            $PreviousEventHash
        }
        eventType         = $EventType
        occurredAt        = ConvertTo-AdltUtcTimestamp -Value $OccurredAt
        actor             = [ordered]@{
            type = $ActorType
            id   = $ActorId
        }
        data              = Copy-AdltValue -InputObject $Data
    }

    $forbiddenFields = @(Get-AdltForbiddenField -InputObject $runEvent)
    if ($forbiddenFields.Count -gt 0) {
        throw "Secret values are forbidden in run events. Remove field '$($forbiddenFields[0])'."
    }

    [void] (ConvertTo-AdltCanonicalJson -InputObject $runEvent)
    $runEvent.eventHash = Get-AdltArtifactHash `
        -Artifact $runEvent `
        -HashProperty 'eventHash'
    Assert-AdltRunEvent -RunEvent $runEvent
    return $runEvent
}

function Assert-AdltRunEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $RunEvent
    )

    Assert-AdltArtifactContract `
        -Artifact $RunEvent `
        -ExpectedKind 'AzureDataLabRunEvent' `
        -HashProperty 'eventHash' `
        -SchemaFileName 'run-event.schema.json'
}

function Assert-AdltRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    Assert-AdltArtifactContract `
        -Artifact $State `
        -ExpectedKind 'AzureDataLabRunState' `
        -HashProperty 'stateHash' `
        -SchemaFileName 'run-state.schema.json'

    $createdAt = [datetimeoffset]::Parse(
        [string] $State.createdAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $updatedAt = [datetimeoffset]::Parse(
        [string] $State.updatedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $expiresAt = [datetimeoffset]::Parse(
        [string] $State.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if ($updatedAt -lt $createdAt) {
        throw 'Run state updatedAt cannot be earlier than createdAt.'
    }
    if ($expiresAt -le $createdAt) {
        throw 'Run state expiresAt must be later than createdAt.'
    }
}

function Test-AdltCleanupRunStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Status
    )

    return $Status -in @(
        'teardown-pending',
        'tearing-down',
        'completed',
        'cleanup-unknown'
    )
}

function Assert-AdltRunStatusTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CurrentStatus,

        [Parameter(Mandatory)]
        [string] $NextStatus
    )

    $allowedTransitions = @{
        planned = @(
            'authorizing',
            'blocked',
            'failed',
            'teardown-pending'
        )
        authorizing = @(
            'ready',
            'blocked',
            'failed',
            'teardown-pending'
        )
        ready = @(
            'deploying',
            'blocked',
            'failed',
            'teardown-pending'
        )
        deploying = @(
            'probing',
            'running',
            'deployment-unknown',
            'blocked',
            'failed',
            'teardown-pending'
        )
        'deployment-unknown' = @(
            'deploying',
            'probing',
            'failed',
            'teardown-pending',
            'cleanup-unknown'
        )
        probing = @(
            'running',
            'blocked',
            'failed',
            'teardown-pending'
        )
        running = @(
            'stopping',
            'blocked',
            'failed',
            'teardown-pending'
        )
        stopping = @(
            'stopped',
            'failed',
            'teardown-pending',
            'cleanup-unknown'
        )
        stopped = @(
            'resuming',
            'teardown-pending'
        )
        resuming = @(
            'probing',
            'running',
            'blocked',
            'failed',
            'teardown-pending'
        )
        'teardown-pending' = @(
            'tearing-down',
            'blocked',
            'cleanup-unknown'
        )
        'tearing-down' = @(
            'completed',
            'failed',
            'cleanup-unknown'
        )
        failed = @(
            'teardown-pending',
            'tearing-down',
            'cleanup-unknown'
        )
        blocked = @(
            'authorizing',
            'teardown-pending',
            'failed',
            'cleanup-unknown'
        )
        'cleanup-unknown' = @(
            'teardown-pending',
            'tearing-down',
            'completed',
            'failed'
        )
        completed = @()
    }

    if (
        -not $allowedTransitions.ContainsKey($CurrentStatus) -or
        $NextStatus -notin @($allowedTransitions[$CurrentStatus])
    ) {
        throw "Run status transition '$CurrentStatus' to '$NextStatus' is not allowed."
    }
}

function Assert-AdltRunEventDataShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Data,

        [Parameter(Mandatory)]
        [string[]] $RequiredKeys,

        [Parameter(Mandatory)]
        [string[]] $AllowedKeys,

        [Parameter(Mandatory)]
        [string] $EventType
    )

    foreach ($key in $RequiredKeys) {
        if (-not $Data.Contains($key)) {
            throw "Run event '$EventType' requires data.$key."
        }
    }
    foreach ($key in @($Data.Keys)) {
        if ([string] $key -notin $AllowedKeys) {
            throw "Run event '$EventType' does not allow data.$key."
        }
    }
}

function Assert-AdltOperationEventData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Data,

        [switch] $RequireExecutionRecordHash,

        [switch] $RequireEvidenceHash,

        [switch] $RequireOutcome,

        [switch] $RequireReason
    )

    if (
        $Data.operation -cne 'deploy' -or
        [string] $Data.operationId -notmatch
            '^[0-9a-fA-F-]{36}$'
    ) {
        throw 'Operation event has an invalid operation identity.'
    }
    if (
        $RequireExecutionRecordHash.IsPresent -and
        [string] $Data.executionRecordHash -notmatch
            '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'Operation event has an invalid execution record hash.'
    }
    if (
        $RequireEvidenceHash.IsPresent -and
        [string] $Data.evidenceHash -notmatch
            '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'Operation event has an invalid evidence hash.'
    }
    if (
        $RequireOutcome.IsPresent -and
        $Data.outcome -notin @('succeeded', 'failed')
    ) {
        throw 'Operation event has an invalid terminal outcome.'
    }
    if (
        $RequireReason.IsPresent -and
        $Data.reason -notin @(
            'unauthenticated'
            'denied'
            'absent'
            'conflict'
            'throttled'
            'unknown'
        )
    ) {
        throw 'Operation event has an invalid uncertainty reason.'
    }
}

function Assert-AdltTeardownOperationEventData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Data,

        [switch] $RequireExecutionRecordHash,

        [switch] $RequireEvidenceHash,

        [switch] $RequireOutcome,

        [switch] $RequireReason
    )

    if (
        $Data.operation -cne 'teardown' -or
        [string] $Data.operationId -notmatch
            '^[0-9a-fA-F-]{36}$'
    ) {
        throw 'Teardown event has an invalid operation identity.'
    }
    if (
        $RequireExecutionRecordHash.IsPresent -and
        [string] $Data.teardownExecutionRecordHash -notmatch
            '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'Teardown event has an invalid execution record hash.'
    }
    if (
        $RequireEvidenceHash.IsPresent -and
        [string] $Data.evidenceHash -notmatch
            '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'Teardown event has an invalid evidence hash.'
    }
    if (
        $RequireOutcome.IsPresent -and
        $Data.outcome -notin @('succeeded', 'failed')
    ) {
        throw 'Teardown event has an invalid terminal outcome.'
    }
    if (
        $RequireReason.IsPresent -and
        $Data.reason -notin @(
            'unauthenticated'
            'denied'
            'absent'
            'conflict'
            'throttled'
            'unknown'
        )
    ) {
        throw 'Teardown event has an invalid uncertainty reason.'
    }
}

function Assert-AdltTeardownAuthorizationRefreshData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Data
    )

    Assert-AdltTeardownOperationEventData `
        -Data $Data `
        -RequireExecutionRecordHash
    foreach ($hashName in @(
        'inventoryHash',
        'confirmationPhraseHash'
    )) {
        if (
            [string] $Data[$hashName] -notmatch
                '^sha256:[a-f0-9]{64}$'
        ) {
            throw "Teardown authorization refresh has an invalid $hashName."
        }
    }
    $approvedAt = [datetimeoffset]::Parse(
        [string] $Data.approvedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $expiresAt = [datetimeoffset]::Parse(
        [string] $Data.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if (
        $expiresAt -le $approvedAt -or
        $expiresAt -gt $approvedAt.AddMinutes(10)
    ) {
        throw 'Teardown authorization refresh has an invalid lease window.'
    }
}

function Assert-AdltRunEventDataContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $RunEvent
    )

    switch ([string] $RunEvent.eventType) {
        'run-created' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @('state') `
                -AllowedKeys @('state') `
                -EventType $RunEvent.eventType
            if (
                $RunEvent.data.state -isnot
                    [System.Collections.IDictionary]
            ) {
                throw 'A run-created event requires a dictionary state projection.'
            }
        }
        'status-changed' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @('status') `
                -AllowedKeys @('status') `
                -EventType $RunEvent.eventType
        }
        'preflight-blocked' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @('status', 'stage') `
                -AllowedKeys @('status', 'stage') `
                -EventType $RunEvent.eventType
            if (
                [string] $RunEvent.data.status -cne 'blocked' -or
                [string] $RunEvent.data.stage -cnotin @(
                    'live-resolution'
                    'what-if'
                    'cost'
                    'teardown-preview'
                ) -or
                [string] $RunEvent.actor.type -cne 'toolkit'
            ) {
                throw 'A preflight-blocked event has invalid provenance.'
            }
        }
        'cleanup-status-changed' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @('status') `
                -AllowedKeys @('status') `
                -EventType $RunEvent.eventType
        }
        'resource-observed' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @('resource') `
                -AllowedKeys @('resource') `
                -EventType $RunEvent.eventType
            if (
                $RunEvent.data.resource -isnot
                    [System.Collections.IDictionary]
            ) {
                throw 'A resource-observed event requires data.resource.'
            }
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data.resource `
                -RequiredKeys @(
                    'stableId',
                    'resourceId',
                    'observedOwnership',
                    'status'
                ) `
                -AllowedKeys @(
                    'stableId',
                    'resourceId',
                    'observedOwnership',
                    'status'
                ) `
                -EventType 'resource-observed.resource'
        }
        'evidence-attached' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @('evidence') `
                -AllowedKeys @('evidence') `
                -EventType $RunEvent.eventType
            if (
                $RunEvent.data.evidence -isnot
                    [System.Collections.IDictionary]
            ) {
                throw 'An evidence-attached event requires data.evidence.'
            }
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data.evidence `
                -RequiredKeys @('stage', 'evidenceHash') `
                -AllowedKeys @('stage', 'evidenceHash') `
                -EventType 'evidence-attached.evidence'
        }
        'authorization-recorded' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'executionRecordHash'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'executionRecordHash'
                ) `
                -EventType $RunEvent.eventType
            Assert-AdltOperationEventData `
                -Data $RunEvent.data `
                -RequireExecutionRecordHash
        }
        'operation-started' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'executionRecordHash'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'executionRecordHash'
                ) `
                -EventType $RunEvent.eventType
            Assert-AdltOperationEventData `
                -Data $RunEvent.data `
                -RequireExecutionRecordHash
        }
        'operation-resumed' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'executionRecordHash'
                    'confirmationPhraseHash'
                    'approvedAt'
                    'expiresAt'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'executionRecordHash'
                    'confirmationPhraseHash'
                    'approvedAt'
                    'expiresAt'
                ) `
                -EventType $RunEvent.eventType
            if ($RunEvent.actor.type -cne 'interactive-user') {
                throw 'Deployment resume requires an interactive user.'
            }
            Assert-AdltOperationEventData `
                -Data $RunEvent.data `
                -RequireExecutionRecordHash
            if (
                [string] $RunEvent.data.confirmationPhraseHash -notmatch
                    '^sha256:[a-f0-9]{64}$'
            ) {
                throw 'Deployment resume has an invalid confirmation phrase hash.'
            }
            $approvedAt = [datetimeoffset]::Parse(
                [string] $RunEvent.data.approvedAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            $expiresAt = [datetimeoffset]::Parse(
                [string] $RunEvent.data.expiresAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            if (
                $expiresAt -le $approvedAt -or
                $expiresAt -gt $approvedAt.AddMinutes(10) -or
                $approvedAt -ne [datetimeoffset]::Parse(
                    [string] $RunEvent.occurredAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            ) {
                throw 'Deployment resume approval timestamps are invalid.'
            }
        }
        'operation-uncertain' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'reason'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'reason'
                ) `
                -EventType $RunEvent.eventType
            Assert-AdltOperationEventData `
                -Data $RunEvent.data `
                -RequireReason
        }
        'operation-finished' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'outcome'
                    'evidenceHash'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'outcome'
                    'evidenceHash'
                ) `
                -EventType $RunEvent.eventType
            Assert-AdltOperationEventData `
                -Data $RunEvent.data `
                -RequireEvidenceHash `
                -RequireOutcome
        }
        'teardown-authorization-recorded' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'teardownExecutionRecordHash'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'teardownExecutionRecordHash'
                ) `
                -EventType $RunEvent.eventType
            Assert-AdltTeardownOperationEventData `
                -Data $RunEvent.data `
                -RequireExecutionRecordHash
        }
        'teardown-authorization-refreshed' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'teardownExecutionRecordHash'
                    'inventoryHash'
                    'confirmationPhraseHash'
                    'approvedAt'
                    'expiresAt'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'teardownExecutionRecordHash'
                    'inventoryHash'
                    'confirmationPhraseHash'
                    'approvedAt'
                    'expiresAt'
                ) `
                -EventType $RunEvent.eventType
            if ($RunEvent.actor.type -cne 'interactive-user') {
                throw 'Teardown authorization refresh requires an interactive user.'
            }
            Assert-AdltTeardownAuthorizationRefreshData `
                -Data $RunEvent.data
        }
        'teardown-operation-started' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'teardownExecutionRecordHash'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'teardownExecutionRecordHash'
                ) `
                -EventType $RunEvent.eventType
            Assert-AdltTeardownOperationEventData `
                -Data $RunEvent.data `
                -RequireExecutionRecordHash
        }
        'teardown-operation-resumed' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'teardownExecutionRecordHash'
                    'remainingResourceSetHash'
                    'confirmationPhraseHash'
                    'approvedAt'
                    'expiresAt'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'teardownExecutionRecordHash'
                    'remainingResourceSetHash'
                    'confirmationPhraseHash'
                    'approvedAt'
                    'expiresAt'
                ) `
                -EventType $RunEvent.eventType
            if ($RunEvent.actor.type -cne 'interactive-user') {
                throw 'Teardown resume requires an interactive user.'
            }
            Assert-AdltTeardownOperationEventData `
                -Data $RunEvent.data `
                -RequireExecutionRecordHash
            foreach ($hashName in @(
                'remainingResourceSetHash'
                'confirmationPhraseHash'
            )) {
                if (
                    [string] $RunEvent.data[$hashName] -notmatch
                        '^sha256:[a-f0-9]{64}$'
                ) {
                    throw "Teardown resume has an invalid $hashName."
                }
            }
            $approvedAt = [datetimeoffset]::Parse(
                [string] $RunEvent.data.approvedAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            $expiresAt = [datetimeoffset]::Parse(
                [string] $RunEvent.data.expiresAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            if (
                $approvedAt -ne [datetimeoffset]::Parse(
                    [string] $RunEvent.occurredAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                ) -or
                $expiresAt -le $approvedAt -or
                $expiresAt -gt $approvedAt.AddMinutes(10)
            ) {
                throw 'Teardown resume has an invalid approval window.'
            }
        }
        'teardown-operation-uncertain' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'reason'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'reason'
                ) `
                -EventType $RunEvent.eventType
            Assert-AdltTeardownOperationEventData `
                -Data $RunEvent.data `
                -RequireReason
        }
        'teardown-operation-finished' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @(
                    'operation'
                    'operationId'
                    'outcome'
                    'evidenceHash'
                ) `
                -AllowedKeys @(
                    'operation'
                    'operationId'
                    'outcome'
                    'evidenceHash'
                ) `
                -EventType $RunEvent.eventType
            Assert-AdltTeardownOperationEventData `
                -Data $RunEvent.data `
                -RequireEvidenceHash `
                -RequireOutcome
        }
        'failure-recorded' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @('failureId', 'message') `
                -AllowedKeys @('failureId', 'message') `
                -EventType $RunEvent.eventType
        }
        'lock-generation-changed' {
            Assert-AdltRunEventDataShape `
                -Data $RunEvent.data `
                -RequiredKeys @('generation') `
                -AllowedKeys @('generation') `
                -EventType $RunEvent.eventType
        }
        default {
            throw "Run event type '$($RunEvent.eventType)' is not implemented."
        }
    }
}

function New-AdltInitialRunStateSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $PlanEvidence,

        [Parameter(Mandatory)]
        [datetimeoffset] $CreatedAt
    )

    $scope = [ordered]@{
        cloud             = $Plan.context.cloud
        tenantId          = $Plan.context.tenantId
        subscriptionId    = $Plan.context.subscriptionId
        resourceGroupName = $Plan.configuration.azure.resourceGroup.name
        location          = $Plan.context.location
    }
    $resourceGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f
        $scope.subscriptionId,
        $scope.resourceGroupName
    $ledger = @(
        foreach ($resource in @($Plan.resources)) {
            $resourceId = if (
                -not [string]::IsNullOrWhiteSpace(
                    [string] $resource.externalResourceId
                )
            ) {
                [string] $resource.externalResourceId
            }
            elseif ($resource.type -eq 'Microsoft.Resources/resourceGroups') {
                $resourceGroupId
            }
            else {
                $null
            }

            [ordered]@{
                stableId          = $resource.id
                resourceId        = $resourceId
                plannedOwnership  = $resource.ownership.expectedClassification
                observedOwnership = 'unverified'
                status            = 'pending'
            }
        }
    )
    $expiresAt = $CreatedAt.AddMinutes(
        [int] $Plan.configuration.lifecycle.timeToLiveMinutes
    )
    $timestamp = ConvertTo-AdltUtcTimestamp -Value $CreatedAt

    return [ordered]@{
        schemaVersion      = '1.0'
        kind               = 'AzureDataLabRunState'
        canonicalization   = 'rfc8785'
        runId              = $RunId
        planHash           = $Plan.planHash
        intentHash         = $Plan.intentHash
        mode               = 'local'
        generation         = 0
        status             = 'planned'
        scope              = $scope
        resourceLedger     = $ledger
        evidenceReferences = @(
            [ordered]@{
                stage        = $PlanEvidence.stage
                evidenceHash = $PlanEvidence.evidenceHash
            }
        )
        createdAt          = $timestamp
        updatedAt          = $timestamp
        expiresAt          = ConvertTo-AdltUtcTimestamp -Value $expiresAt
    }
}

function Assert-AdltInitialRunStateSeedBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Seed,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $RunEvent
    )

    Assert-AdltRunEventDataShape `
        -Data $Seed `
        -RequiredKeys @(
            'schemaVersion',
            'kind',
            'canonicalization',
            'runId',
            'planHash',
            'intentHash',
            'mode',
            'generation',
            'status',
            'scope',
            'resourceLedger',
            'evidenceReferences',
            'createdAt',
            'updatedAt',
            'expiresAt'
        ) `
        -AllowedKeys @(
            'schemaVersion',
            'kind',
            'canonicalization',
            'runId',
            'planHash',
            'intentHash',
            'mode',
            'generation',
            'status',
            'scope',
            'resourceLedger',
            'evidenceReferences',
            'createdAt',
            'updatedAt',
            'expiresAt'
        ) `
        -EventType 'run-created.state'

    if (
        $Seed.schemaVersion -cne '1.0' -or
        $Seed.kind -cne 'AzureDataLabRunState' -or
        $Seed.canonicalization -cne 'rfc8785' -or
        $Seed.mode -cne 'local' -or
        [int] $Seed.generation -ne 0 -or
        $Seed.status -cne 'planned'
    ) {
        throw 'The run-created state has an invalid initial state contract.'
    }
    if (
        $Seed.runId -cne $RunEvent.runId -or
        $Seed.planHash -cne $Plan.planHash -or
        $Seed.intentHash -cne $Plan.intentHash
    ) {
        throw 'The run-created state does not match the immutable plan binding.'
    }

    $expectedScope = [ordered]@{
        cloud             = $Plan.context.cloud
        tenantId          = $Plan.context.tenantId
        subscriptionId    = $Plan.context.subscriptionId
        resourceGroupName = $Plan.configuration.azure.resourceGroup.name
        location          = $Plan.context.location
    }
    if (
        (ConvertTo-AdltCanonicalJson -InputObject $Seed.scope) -cne
        (ConvertTo-AdltCanonicalJson -InputObject $expectedScope)
    ) {
        throw 'The run-created state scope does not match the immutable plan.'
    }

    $planResources = @($Plan.resources)
    $ledger = @($Seed.resourceLedger)
    if ($ledger.Count -ne $planResources.Count) {
        throw 'The run-created resource ledger does not match the immutable plan.'
    }
    $resourceGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f
        $expectedScope.subscriptionId,
        $expectedScope.resourceGroupName
    for ($index = 0; $index -lt $planResources.Count; $index++) {
        $resource = $planResources[$index]
        $entry = $ledger[$index]
        Assert-AdltRunEventDataShape `
            -Data $entry `
            -RequiredKeys @(
                'stableId',
                'resourceId',
                'plannedOwnership',
                'observedOwnership',
                'status'
            ) `
            -AllowedKeys @(
                'stableId',
                'resourceId',
                'plannedOwnership',
                'observedOwnership',
                'status'
            ) `
            -EventType 'run-created.state.resourceLedger'

        $expectedResourceId = if (
            -not [string]::IsNullOrWhiteSpace(
                [string] $resource.externalResourceId
            )
        ) {
            [string] $resource.externalResourceId
        }
        elseif ($resource.type -eq 'Microsoft.Resources/resourceGroups') {
            $resourceGroupId
        }
        else {
            $null
        }
        if (
            $entry.stableId -cne $resource.id -or
            $entry.resourceId -cne $expectedResourceId -or
            $entry.plannedOwnership -cne
                $resource.ownership.expectedClassification -or
            $entry.observedOwnership -cne 'unverified' -or
            $entry.status -cne 'pending'
        ) {
            throw "The run-created resource ledger entry '$index' does not match the immutable plan."
        }
    }

    $evidenceReferences = @($Seed.evidenceReferences)
    if (
        $evidenceReferences.Count -ne 1 -or
        $evidenceReferences[0].stage -cne 'plan' -or
        [string] $evidenceReferences[0].evidenceHash -notmatch
            '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'The run-created state must contain exactly one plan evidence reference.'
    }

    if (
        $Seed.createdAt -cne $RunEvent.occurredAt -or
        $Seed.updatedAt -cne $RunEvent.occurredAt
    ) {
        throw 'The run-created state timestamps do not match its event.'
    }
    $createdAt = [datetimeoffset]::Parse(
        [string] $Seed.createdAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $expectedExpiry = ConvertTo-AdltUtcTimestamp -Value (
        $createdAt.AddMinutes(
            [int] $Plan.configuration.lifecycle.timeToLiveMinutes
        )
    )
    if ($Seed.expiresAt -cne $expectedExpiry) {
        throw 'The run-created state expiry does not match the plan lifecycle.'
    }
}

function Add-AdltEventReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $RunEvent
    )

    $references = [System.Collections.Generic.List[object]]::new()
    foreach ($reference in @($State.eventReferences)) {
        $references.Add((Copy-AdltValue -InputObject $reference))
    }
    $references.Add([ordered]@{
        sequence  = $RunEvent.sequence
        eventHash = $RunEvent.eventHash
    })
    $State.eventReferences = @($references.ToArray())
}

function Update-AdltRunStateHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    $State.stateHash = Get-AdltArtifactHash `
        -Artifact $State `
        -HashProperty 'stateHash'
    Assert-AdltRunState -State $State
    return $State
}

function Invoke-AdltRunEventProjection {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $RunEvent
    )

    Assert-AdltRunEvent -RunEvent $RunEvent
    Assert-AdltRunEventDataContract -RunEvent $RunEvent

    if ($RunEvent.eventType -eq 'run-created') {
        if ($null -ne $State) {
            throw 'A run-created event cannot be applied to an existing state.'
        }
        if (
            [int] $RunEvent.sequence -ne 1 -or
            $null -ne $RunEvent.previousEventHash
        ) {
            throw 'A run-created event must start a new event chain.'
        }
        if ([int] $RunEvent.generation -ne 0) {
            throw 'A run-created event must use generation zero.'
        }
        $embeddedState = $RunEvent.data.state
        if (
            $embeddedState.runId -cne $RunEvent.runId -or
            $embeddedState.planHash -cne $RunEvent.planHash -or
            $embeddedState.intentHash -cne $RunEvent.intentHash -or
            [int] $embeddedState.generation -ne [int] $RunEvent.generation
        ) {
            throw 'A run-created event envelope does not match its embedded state.'
        }
        $State = Copy-AdltValue -InputObject $embeddedState
        $State.eventReferences = @()
    }
    elseif ($null -eq $State) {
        throw 'The first run event must be run-created.'
    }
    else {
        if ($RunEvent.runId -cne $State.runId) {
            throw 'Run event ID does not match the state projection.'
        }
        if ($RunEvent.planHash -cne $State.planHash) {
            throw 'Run event plan hash does not match the state projection.'
        }
        if ($RunEvent.intentHash -cne $State.intentHash) {
            throw 'Run event intent hash does not match the state projection.'
        }
        $expectedSequence = @($State.eventReferences).Count + 1
        if ([int] $RunEvent.sequence -ne $expectedSequence) {
            throw "Run event sequence must continue at '$expectedSequence'."
        }
        if (
            $RunEvent.previousEventHash -cne
                $State.eventReferences[-1].eventHash
        ) {
            throw 'Run event previousEventHash does not continue the event chain.'
        }
        $occurredAt = [datetimeoffset]::Parse(
            [string] $RunEvent.occurredAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $updatedAt = [datetimeoffset]::Parse(
            [string] $State.updatedAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        if ($occurredAt -lt $updatedAt) {
            throw 'Run event timestamps must not move backwards.'
        }

        if ($RunEvent.eventType -eq 'lock-generation-changed') {
            if ($State.mode -cne 'remote') {
                throw 'Lock generation changes are not allowed for local run state.'
            }
            if (-not $RunEvent.data.Contains('generation')) {
                throw 'A lock-generation-changed event requires data.generation.'
            }
            $nextGeneration = [int] $RunEvent.data.generation
            if (
                $nextGeneration -le [int] $State.generation -or
                [int] $RunEvent.generation -ne $nextGeneration
            ) {
                throw 'A lock generation must increase monotonically.'
            }
        }
        elseif ([int] $RunEvent.generation -ne [int] $State.generation) {
            throw 'Run event generation does not match the current state generation.'
        }

        switch ($RunEvent.eventType) {
            'status-changed' {
                $nextStatus = [string] $RunEvent.data.status
                if (Test-AdltCleanupRunStatus -Status $nextStatus) {
                    throw 'Cleanup statuses require a cleanup-status-changed event.'
                }
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus $nextStatus
                $State.status = $nextStatus
            }
            'preflight-blocked' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus blocked
                $State.status = 'blocked'
            }
            'cleanup-status-changed' {
                $nextStatus = [string] $RunEvent.data.status
                if (-not (Test-AdltCleanupRunStatus -Status $nextStatus)) {
                    throw 'A cleanup status event requires a cleanup status.'
                }
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus $nextStatus
                $State.status = $nextStatus
            }
            'resource-observed' {
                $observed = $RunEvent.data.resource
                $matchingResources = @(
                    $State.resourceLedger |
                        Where-Object {
                            $_.stableId -ceq $observed.stableId
                        }
                )
                if ($matchingResources.Count -ne 1) {
                    throw "Observed resource '$($observed.stableId)' must match exactly one ledger entry."
                }
                $matchingResources[0].resourceId = $observed.resourceId
                $matchingResources[0].observedOwnership =
                    [string] $observed.observedOwnership
                $matchingResources[0].status = [string] $observed.status
            }
            'evidence-attached' {
                $reference = Copy-AdltValue -InputObject $RunEvent.data.evidence
                if (
                    @($State.evidenceReferences).evidenceHash -contains
                        $reference.evidenceHash
                ) {
                    throw "Evidence '$($reference.evidenceHash)' is already attached."
                }
                $State.evidenceReferences = @(
                    @($State.evidenceReferences) + @($reference)
                )
            }
            'failure-recorded' {
                if ($State.status -cne 'failed') {
                    Assert-AdltRunStatusTransition `
                        -CurrentStatus ([string] $State.status) `
                        -NextStatus failed
                    $State.status = 'failed'
                }
            }
            'authorization-recorded' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus ready
                $State.status = 'ready'
            }
            'operation-started' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus deploying
                $State.status = 'deploying'
            }
            'operation-resumed' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus deploying
                $State.status = 'deploying'
            }
            'operation-uncertain' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus deployment-unknown
                $State.status = 'deployment-unknown'
            }
            'operation-finished' {
                $nextStatus = if (
                    $RunEvent.data.outcome -ceq 'succeeded'
                ) {
                    'probing'
                }
                elseif ($RunEvent.data.outcome -ceq 'failed') {
                    'failed'
                }
                else {
                    throw (
                        'An operation-finished event requires a succeeded ' +
                        'or failed outcome.'
                    )
                }
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus $nextStatus
                $State.status = $nextStatus
            }
            'teardown-authorization-recorded' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus teardown-pending
                $State.status = 'teardown-pending'
            }
            'teardown-authorization-refreshed' {
                if ($State.status -cne 'teardown-pending') {
                    throw (
                        'Teardown authorization can only be refreshed while ' +
                        'teardown is pending.'
                    )
                }
            }
            'teardown-operation-started' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus tearing-down
                $State.status = 'tearing-down'
            }
            'teardown-operation-resumed' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus tearing-down
                $State.status = 'tearing-down'
            }
            'teardown-operation-uncertain' {
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus cleanup-unknown
                $State.status = 'cleanup-unknown'
            }
            'teardown-operation-finished' {
                $nextStatus = if (
                    $RunEvent.data.outcome -ceq 'succeeded'
                ) {
                    'completed'
                }
                elseif ($RunEvent.data.outcome -ceq 'failed') {
                    'cleanup-unknown'
                }
                else {
                    throw (
                        'A teardown-operation-finished event requires a ' +
                        'succeeded or failed outcome.'
                    )
                }
                Assert-AdltRunStatusTransition `
                    -CurrentStatus ([string] $State.status) `
                    -NextStatus $nextStatus
                $State.status = $nextStatus
            }
        }
    }

    $State.generation = [int] $RunEvent.generation
    $State.updatedAt = [string] $RunEvent.occurredAt
    Add-AdltEventReference -State $State -RunEvent $RunEvent
    return Update-AdltRunStateHash -State $State
}
