BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:ConfigurationPath = Join-Path `
        $script:RepositoryRoot `
        'examples/sqlvm-minimal.yaml'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:Module = Get-Module AzureDataLabToolkit

    function New-TestEvidence {
        param(
            [Parameter(Mandatory)]
            [object] $Run,

            [int] $Sequence = 1,

            [string] $PreviousEventHash,

            [string] $RunId = $Run.RunId,

            [string] $PlanHash = $Run.State.planHash,

            [string] $IntentHash = $Run.State.intentHash,

            [string] $Stage = 'validate'
        )

        return & $script:Module {
            param(
                $RunId,
                $PlanHash,
                $IntentHash,
                $Sequence,
                $PreviousEventHash,
                $Stage
            )
            $payload = if ($Stage -ceq 'cleanup-proof') {
                [ordered]@{
                    teardownExecutionRecordHash = $PlanHash
                    operationId =
                        '99999999-9999-4999-8999-999999999999'
                    resourceGroupId = (
                        '/subscriptions/00000000-0000-0000-0000-000000000001/' +
                        'resourceGroups/test'
                    )
                    approvedResourceSetHash =
                        "sha256:$('a' * 64)"
                    approvedResourceCount = 1
                    remainingApprovedResourceCount = 0
                    resourceGroupState = 'present'
                    retainedUnapprovedResourceCount = 0
                    observedState = 'approved-resources-absent'
                    observationSource = 'Get-AzResource'
                    checkedAt = ConvertTo-AdltUtcTimestamp `
                        -Value ([datetimeoffset]::UtcNow)
                }
            }
            else {
                [ordered]@{
                    liveResolutionEvidenceHash = $PlanHash
                    results = @(
                        [ordered]@{
                            stableId        = 'azure.test.resource'
                            resourceId      = (
                                '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Test/resources/test'
                            )
                            resourceType    = 'Microsoft.Test/resources'
                            plannedOwnership = 'owned'
                            observedState   = 'absent'
                            classification  = 'create'
                            desiredHash     = $PlanHash
                        }
                    )
                    mutationCount = 0
                }
            }
            New-AdltEvidence `
                -RunId $RunId `
                -PlanHash $PlanHash `
                -IntentHash $IntentHash `
                -Stage $Stage `
                -Status pass `
                -Sequence $Sequence `
                -PreviousEventHash $PreviousEventHash `
                -Payload $payload
        } `
            $RunId `
            $PlanHash `
            $IntentHash `
            $Sequence `
            $PreviousEventHash `
            $Stage
    }

    function Add-TestEvidence {
        param(
            [Parameter(Mandatory)]
            [object] $Run,

            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Evidence,

            [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
        )

        return & $script:Module {
            param($RunPath, $Evidence, $OccurredAt)
            Add-AdltLocalRunEvidence `
                -RunPath $RunPath `
                -Evidence $Evidence `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $OccurredAt
        } $Run.StatePath $Evidence $OccurredAt
    }

    function Set-TestRunStatus {
        param(
            [Parameter(Mandatory)]
            [object] $Run,

            [Parameter(Mandatory)]
            [string] $Status,

            [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow,

            [AllowNull()]
            [Nullable[int]] $Generation
        )

        return & $script:Module {
            param($RunPath, $Status, $OccurredAt, $Generation)
            Add-AdltLocalRunStatusTransition `
                -RunPath $RunPath `
                -Status $Status `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit `
                -Generation $Generation `
                -OccurredAt $OccurredAt
        } $Run.StatePath $Status $OccurredAt $Generation
    }
}

Describe 'Protected local run state' {
    BeforeEach {
        $script:Plan = New-AzureDataLabPlan $script:ConfigurationPath
        $script:StateRoot = Join-Path $TestDrive 'state'
    }

    It 'accepts the complete generated plan contract before creating state' {
        {
            & $script:Module {
                param($Plan)
                $copy = ConvertTo-AdltDictionary -InputObject $Plan
                Assert-AdltPlanContract -Plan $copy
            } $script:Plan
        } | Should -Not -Throw
    }

    It 'creates an immutable plan, hash-chained event log, evidence, and snapshot' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot

        $run.RunId | Should -Match '^[0-9a-f-]{36}$'
        Test-Path (Join-Path $run.StatePath 'plan.json') | Should -BeTrue
        Test-Path (Join-Path $run.StatePath 'events.ndjson') | Should -BeTrue
        Test-Path (Join-Path $run.StatePath 'snapshot.json') | Should -BeTrue
        @(Get-ChildItem (Join-Path $run.StatePath 'evidence') -File).Count |
            Should -Be 1
        $run.State.planHash | Should -BeExactly $script:Plan.planHash
        $run.State.stateHash | Should -Match '^sha256:[a-f0-9]{64}$'
        $run.State.status | Should -Be 'planned'
        $run.State.eventReferences.Count | Should -Be 1
        $run.State.evidenceReferences.Count | Should -Be 1
    }

    It 'round-trips only after replaying and comparing authoritative events' {
        $created = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $loaded = Get-AzureDataLabRun `
            -RunId $created.RunId `
            -StateRoot $script:StateRoot

        $loaded.State.stateHash | Should -BeExactly $created.State.stateHash
        $loaded.State.eventReferences[0].eventHash |
            Should -BeExactly $created.State.eventReferences[0].eventHash
    }

    It 'commits bound evidence with its event and updates the snapshot' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash

        $result = Add-TestEvidence -Run $run -Evidence $evidence
        $loaded = Get-AzureDataLabRun `
            -RunId $run.RunId `
            -StateRoot $script:StateRoot

        $result.RunEvent.eventType | Should -Be 'evidence-attached'
        $result.RunEvent.sequence | Should -Be 2
        $loaded.State.evidenceReferences.Count | Should -Be 2
        $loaded.State.evidenceReferences[-1].evidenceHash |
            Should -BeExactly $evidence.evidenceHash
        $loaded.State.eventReferences.Count | Should -Be 2
        @(Get-ChildItem (Join-Path $run.StatePath 'evidence') -File).Count |
            Should -Be 2
    }

    It 'requires exact run, plan, and intent evidence binding' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -RunId ([guid]::NewGuid().ToString()) `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash

        {
            Add-TestEvidence -Run $run -Evidence $evidence
        } | Should -Throw -ExpectedMessage '*exact run, plan, and intent binding*'
        @(Get-ChildItem (Join-Path $run.StatePath 'evidence') -File).Count |
            Should -Be 1
    }

    It 'requires evidence sequence and previous hash continuity' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $wrongSequence = New-TestEvidence `
            -Run $run `
            -Sequence 2 `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        $wrongPreviousHash = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $script:Plan.planHash

        {
            Add-TestEvidence -Run $run -Evidence $wrongSequence
        } | Should -Throw -ExpectedMessage '*sequence must continue*'
        {
            Add-TestEvidence -Run $run -Evidence $wrongPreviousHash
        } | Should -Throw -ExpectedMessage '*does not continue the evidence chain*'
    }

    It 'rejects duplicate evidence without creating another artifact' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        [void] (Add-TestEvidence -Run $run -Evidence $evidence)

        {
            Add-TestEvidence -Run $run -Evidence $evidence
        } | Should -Throw -ExpectedMessage '*already attached*'
        @(Get-ChildItem (Join-Path $run.StatePath 'evidence') -File).Count |
            Should -Be 2
    }

    It 'refuses an orphan evidence artifact instead of adopting it' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        $orphanPath = Join-Path $run.StatePath 'evidence/orphan.json'
        Set-Content `
            -LiteralPath $orphanPath `
            -Value ($evidence | ConvertTo-Json -Depth 100 -Compress) `
            -Encoding utf8NoBOM
        & $script:Module {
            param($Path)
            Set-AdltPrivatePathMode -Path $Path -Type File
        } $orphanPath

        {
            Get-AzureDataLabRun `
                -RunId $run.RunId `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*files and authoritative evidence references*'
    }

    It 'removes an unreferenced pending evidence write after interruption' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        $pendingPath = & $script:Module {
            param($RunPath, $Evidence)
            $finalPath = Join-Path `
                (Join-Path $RunPath 'evidence') `
                (Get-AdltEvidenceFileName -Evidence $Evidence)
            $pendingPath = '{0}.pending' -f $finalPath
            [void] (Write-AdltPrivateAtomicText `
                -Path $pendingPath `
                -Content (ConvertTo-AdltCanonicalJson -InputObject $Evidence))
            return $pendingPath
        } $run.StatePath $evidence

        $loaded = Get-AzureDataLabRun `
            -RunId $run.RunId `
            -StateRoot $script:StateRoot

        Test-Path $pendingPath | Should -BeFalse
        $loaded.State.evidenceReferences.Count | Should -Be 1
    }

    It 'recovers referenced pending evidence after an interrupted commit' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        $result = Add-TestEvidence -Run $run -Evidence $evidence
        $pendingPath = '{0}.pending' -f $result.EvidencePath
        Move-Item -LiteralPath $result.EvidencePath -Destination $pendingPath

        $loaded = Get-AzureDataLabRun `
            -RunId $run.RunId `
            -StateRoot $script:StateRoot

        Test-Path $pendingPath | Should -BeFalse
        Test-Path $result.EvidencePath | Should -BeTrue
        $loaded.State.evidenceReferences[-1].evidenceHash |
            Should -BeExactly $evidence.evidenceHash
    }

    It 'refuses an event whose evidence artifact is absent' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        $result = Add-TestEvidence -Run $run -Evidence $evidence
        Remove-Item -LiteralPath $result.EvidencePath -Force

        {
            Get-AzureDataLabRun `
                -RunId $run.RunId `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*files and authoritative evidence references*'
    }

    It 'applies only allowlisted status transitions' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot

        $result = Set-TestRunStatus -Run $run -Status authorizing
        $result.State.status | Should -Be 'authorizing'
        $result.RunEvent.eventType | Should -Be 'status-changed'

        {
            Set-TestRunStatus -Run $run -Status running
        } | Should -Throw -ExpectedMessage "*'authorizing' to 'running'*not allowed*"
    }

    It 'allows only cleanup transitions after expiry' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $afterExpiry = [datetimeoffset]::Parse($run.State.expiresAt).AddSeconds(1)

        {
            Set-TestRunStatus `
                -Run $run `
                -Status authorizing `
                -OccurredAt $afterExpiry
        } | Should -Throw -ExpectedMessage '*expired; only cleanup transitions*'

        $result = Set-TestRunStatus `
            -Run $run `
            -Status teardown-pending `
            -OccurredAt $afterExpiry
        $result.State.status | Should -Be 'teardown-pending'
        $result.RunEvent.eventType | Should -Be 'cleanup-status-changed'
    }

    It 'rejects evidence mutation after expiry' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        $afterExpiry = [datetimeoffset]::Parse($run.State.expiresAt).AddSeconds(1)

        {
            Add-TestEvidence `
                -Run $run `
                -Evidence $evidence `
                -OccurredAt $afterExpiry
        } | Should -Throw -ExpectedMessage '*expired; only cleanup transitions*'
    }

    It 'allows cleanup-proof evidence to be committed after expiry' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -Stage cleanup-proof `
            -PreviousEventHash (
                $run.State.evidenceReferences[-1].evidenceHash
            )
        $afterExpiry = [datetimeoffset]::Parse(
            $run.State.expiresAt
        ).AddSeconds(1)

        $result = Add-TestEvidence `
            -Run $run `
            -Evidence $evidence `
            -OccurredAt $afterExpiry

        $result.Evidence.stage | Should -BeExactly 'cleanup-proof'
        $result.State.evidenceReferences[-1].evidenceHash |
            Should -BeExactly $evidence.evidenceHash
    }

    It 'rejects generation regressions' {
        {
            & $script:Module {
                Assert-AdltLocalMutationGeneration `
                    -CurrentGeneration 2 `
                    -RequestedGeneration 1
            }
        } | Should -Throw -ExpectedMessage '*generation regression*'
    }

    It 'binds the run-created envelope to the embedded state' {
        {
            & $script:Module {
                param($Plan)
                $runId = [guid]::NewGuid().ToString()
                $createdAt = [datetimeoffset]::UtcNow
                $planEvidence = New-AdltEvidence `
                    -RunId $runId `
                    -PlanHash $Plan.planHash `
                    -IntentHash $Plan.intentHash `
                    -Stage plan `
                    -Status pass
                $seed = New-AdltInitialRunStateSeed `
                    -Plan $Plan `
                    -RunId $runId `
                    -PlanEvidence $planEvidence `
                    -CreatedAt $createdAt
                $seed.runId = [guid]::NewGuid().ToString()
                $runEvent = New-AdltRunEvent `
                    -RunId $runId `
                    -PlanHash $Plan.planHash `
                    -IntentHash $Plan.intentHash `
                    -Sequence 1 `
                    -Generation 0 `
                    -EventType run-created `
                    -ActorType toolkit `
                    -ActorId AzureDataLabToolkit `
                    -Data ([ordered]@{ state = $seed }) `
                    -OccurredAt $createdAt
                Invoke-AdltRunEventProjection -State $null -RunEvent $runEvent
            } $script:Plan
        } | Should -Throw -ExpectedMessage '*envelope does not match*'
    }

    It 'binds the complete initial resource ledger to the immutable plan' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        & $script:Module {
            param($RunPath)
            $eventLogPath = Join-Path $RunPath 'events.ndjson'
            $events = @(Read-AdltRunEventLog -Path $eventLogPath)
            $runEvent = $events[0]
            $runEvent.data.state.resourceLedger[0].plannedOwnership = 'external'
            $runEvent.eventHash = Get-AdltArtifactHash `
                -Artifact $runEvent `
                -HashProperty eventHash
            [void] (Write-AdltPrivateAtomicText `
                -Path $eventLogPath `
                -Content (
                    (ConvertTo-AdltCanonicalJson -InputObject $runEvent) +
                    "`n"
                ) `
                -Force)
        } $run.StatePath

        {
            Get-AzureDataLabRun `
                -RunId $run.RunId `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*resource ledger entry*immutable plan*'
    }

    It 'rejects undeclared event data and local lock generations' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        {
            & $script:Module {
                param($State)
                $runEvent = New-AdltRunEvent `
                    -RunId $State.runId `
                    -PlanHash $State.planHash `
                    -IntentHash $State.intentHash `
                    -Sequence 2 `
                    -Generation 0 `
                    -PreviousEventHash $State.eventReferences[-1].eventHash `
                    -EventType status-changed `
                    -ActorType toolkit `
                    -ActorId AzureDataLabToolkit `
                    -Data ([ordered]@{
                        status = 'authorizing'
                        note   = 'not part of the event contract'
                    })
                Invoke-AdltRunEventProjection -State $State -RunEvent $runEvent
            } $run.State
        } | Should -Throw -ExpectedMessage '*does not allow data.note*'

        {
            & $script:Module {
                param($State)
                $runEvent = New-AdltRunEvent `
                    -RunId $State.runId `
                    -PlanHash $State.planHash `
                    -IntentHash $State.intentHash `
                    -Sequence 2 `
                    -Generation 1 `
                    -PreviousEventHash $State.eventReferences[-1].eventHash `
                    -EventType lock-generation-changed `
                    -ActorType toolkit `
                    -ActorId AzureDataLabToolkit `
                    -Data ([ordered]@{ generation = 1 })
                Invoke-AdltRunEventProjection -State $State -RunEvent $runEvent
            } $run.State
        } | Should -Throw -ExpectedMessage '*not allowed for local run state*'
    }

    It 'projects declared resource and failure event types' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot

        $resourceState = & $script:Module {
            param($State)
            $resource = $State.resourceLedger[0]
            $runEvent = New-AdltRunEvent `
                -RunId $State.runId `
                -PlanHash $State.planHash `
                -IntentHash $State.intentHash `
                -Sequence 2 `
                -Generation 0 `
                -PreviousEventHash $State.eventReferences[-1].eventHash `
                -EventType resource-observed `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit `
                -Data ([ordered]@{
                    resource = [ordered]@{
                        stableId          = $resource.stableId
                        resourceId        = $resource.resourceId
                        observedOwnership = 'owned'
                        status            = 'present'
                    }
                })
            Invoke-AdltRunEventProjection -State $State -RunEvent $runEvent
        } $run.State
        $resourceState.resourceLedger[0].observedOwnership |
            Should -Be 'owned'
        $resourceState.resourceLedger[0].status | Should -Be 'present'

        $failedState = & $script:Module {
            param($State)
            $runEvent = New-AdltRunEvent `
                -RunId $State.runId `
                -PlanHash $State.planHash `
                -IntentHash $State.intentHash `
                -Sequence 3 `
                -Generation 0 `
                -PreviousEventHash $State.eventReferences[-1].eventHash `
                -EventType failure-recorded `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit `
                -Data ([ordered]@{
                    failureId = 'failure.test'
                    message   = 'A test failure without secret data.'
                })
            Invoke-AdltRunEventProjection -State $State -RunEvent $runEvent
        } $run.State
        $failedState.status | Should -Be 'failed'
    }

    It 'rejects coherent remote state in the protected local store' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        & $script:Module {
            param($RunPath)
            $eventLogPath = Join-Path $RunPath 'events.ndjson'
            $snapshotPath = Join-Path $RunPath 'snapshot.json'
            $events = @(Read-AdltRunEventLog -Path $eventLogPath)
            $runEvent = $events[0]
            $runEvent.data.state.mode = 'remote'
            $runEvent.eventHash = Get-AdltArtifactHash `
                -Artifact $runEvent `
                -HashProperty eventHash
            Assert-AdltRunEvent -RunEvent $runEvent
            $state = Invoke-AdltRunEventProjection `
                -State $null `
                -RunEvent $runEvent
            [void] (Write-AdltPrivateAtomicText `
                -Path $eventLogPath `
                -Content (
                    (ConvertTo-AdltCanonicalJson -InputObject $runEvent) +
                    [Environment]::NewLine
                ) `
                -Force)
            [void] (Write-AdltPrivateAtomicText `
                -Path $snapshotPath `
                -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
                -Force)
        } $run.StatePath

        {
            Get-AzureDataLabRun `
                -RunId $run.RunId `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*invalid initial state contract*'
    }

    It 'rejects event timestamps that move backwards' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $beforeCreation = [datetimeoffset]::Parse(
            $run.State.createdAt
        ).AddSeconds(-1)

        {
            Set-TestRunStatus `
                -Run $run `
                -Status authorizing `
                -OccurredAt $beforeCreation
        } | Should -Throw -ExpectedMessage '*timestamps must not move backwards*'
    }

    It 'recovers a missing snapshot from the complete authoritative log' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $snapshotPath = Join-Path $run.StatePath 'snapshot.json'
        Remove-Item -LiteralPath $snapshotPath -Force

        $loaded = Get-AzureDataLabRun `
            -RunId $run.RunId `
            -StateRoot $script:StateRoot

        Test-Path $snapshotPath | Should -BeTrue
        $loaded.State.stateHash | Should -BeExactly $run.State.stateHash
    }

    It 'recovers a valid stale snapshot from the authoritative log' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $snapshotPath = Join-Path $run.StatePath 'snapshot.json'
        $staleSnapshot = Get-Content -LiteralPath $snapshotPath -Raw
        [void] (Set-TestRunStatus -Run $run -Status authorizing)
        Set-Content `
            -LiteralPath $snapshotPath `
            -Value $staleSnapshot `
            -Encoding utf8NoBOM

        $loaded = Get-AzureDataLabRun `
            -RunId $run.RunId `
            -StateRoot $script:StateRoot

        $loaded.State.status | Should -Be 'authorizing'
        (Get-Content -LiteralPath $snapshotPath -Raw |
            ConvertFrom-Json -DateKind String).stateHash |
            Should -BeExactly $loaded.State.stateHash
    }

    It 'rejects snapshot tampering' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $snapshotPath = Join-Path $run.StatePath 'snapshot.json'
        $snapshot = Get-Content $snapshotPath -Raw |
            ConvertFrom-Json -AsHashtable -DateKind String
        $snapshot.status = 'running'
        Set-Content `
            -LiteralPath $snapshotPath `
            -Value ($snapshot | ConvertTo-Json -Depth 100 -Compress) `
            -Encoding utf8NoBOM

        {
            Get-AzureDataLabRun `
                -RunId $run.RunId `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*hash verification failed*'
    }

    It 'rejects a truncated event log' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        Add-Content `
            -LiteralPath (Join-Path $run.StatePath 'events.ndjson') `
            -Value '{"truncated":'

        {
            Get-AzureDataLabRun `
                -RunId $run.RunId `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*invalid or truncated JSON*'
    }

    It 'rejects an oversized event log before replay' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $eventLogPath = Join-Path $run.StatePath 'events.ndjson'
        $stream = [System.IO.File]::OpenWrite($eventLogPath)
        try {
            $stream.SetLength(64MB + 1)
        }
        finally {
            $stream.Dispose()
        }

        {
            Get-AzureDataLabRun `
                -RunId $run.RunId `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*maximum protected size*'
    }

    It 'rejects a complete-looking event record without its append terminator' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $eventLogPath = Join-Path $run.StatePath 'events.ndjson'
        $content = (Get-Content -LiteralPath $eventLogPath -Raw).TrimEnd(
            [char] 10,
            [char] 13
        )
        Set-Content `
            -LiteralPath $eventLogPath `
            -Value $content `
            -Encoding utf8NoBOM `
            -NoNewline

        {
            Get-AzureDataLabRun `
                -RunId $run.RunId `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*incomplete or truncated record*'
    }

    It 'refuses concurrent access to the same run store' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $lockPath = Join-Path $run.StatePath '.lock'
        $lock = [System.IO.FileStream]::new(
            $lockPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            {
                Get-AzureDataLabRun `
                    -RunId $run.RunId `
                    -StateRoot $script:StateRoot
            } | Should -Throw -ExpectedMessage '*locked by another process*'
        }
        finally {
            $lock.Dispose()
        }
    }

    It 'refuses evidence mutation while another process holds the run lock' {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        $lock = [System.IO.FileStream]::new(
            (Join-Path $run.StatePath '.lock'),
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            {
                Add-TestEvidence -Run $run -Evidence $evidence
            } | Should -Throw -ExpectedMessage '*locked by another process*'
        }
        finally {
            $lock.Dispose()
        }
    }

    It 'rejects nested secret fields in run events' {
        $module = Get-Module AzureDataLabToolkit
        {
            & $module {
                param($Plan)
                New-AdltRunEvent `
                    -RunId ([guid]::NewGuid().ToString()) `
                    -PlanHash $Plan.planHash `
                    -IntentHash $Plan.intentHash `
                    -Sequence 1 `
                    -Generation 0 `
                    -EventType failure-recorded `
                    -ActorType toolkit `
                    -ActorId AzureDataLabToolkit `
                    -Data ([ordered]@{
                        nested = [ordered]@{
                            accessToken = 'must-not-be-stored'
                        }
                    })
            } $script:Plan
        } | Should -Throw -ExpectedMessage '*Secret values are forbidden*'
    }

    It 'uses owner-only filesystem modes on Unix' -Skip:$IsWindows {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $directoryMode = [System.IO.File]::GetUnixFileMode($run.StatePath)
        $snapshotMode = [System.IO.File]::GetUnixFileMode(
            (Join-Path $run.StatePath 'snapshot.json')
        )
        $nonOwnerMask =
            [System.IO.UnixFileMode]::GroupRead -bor
            [System.IO.UnixFileMode]::GroupWrite -bor
            [System.IO.UnixFileMode]::GroupExecute -bor
            [System.IO.UnixFileMode]::OtherRead -bor
            [System.IO.UnixFileMode]::OtherWrite -bor
            [System.IO.UnixFileMode]::OtherExecute

        ($directoryMode -band $nonOwnerMask) | Should -Be 0
        ($snapshotMode -band $nonOwnerMask) | Should -Be 0
    }

    It 'creates a missing state root with the current Unix owner and private mode' -Skip:$IsWindows {
        $nestedStateRoot = Join-Path $script:StateRoot 'nested/private'

        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $nestedStateRoot

        $ownerIds = & $script:Module {
            param($StateRoot, $RunPath)
            return @(
                Get-AdltUnixPathOwnerId -Path $StateRoot
                Get-AdltUnixPathOwnerId -Path $RunPath
                Get-AdltCurrentUnixUserId
            )
        } $nestedStateRoot $run.StatePath
        $mode = [System.IO.File]::GetUnixFileMode($nestedStateRoot)
        $nonOwnerMask =
            [System.IO.UnixFileMode]::GroupRead -bor
            [System.IO.UnixFileMode]::GroupWrite -bor
            [System.IO.UnixFileMode]::GroupExecute -bor
            [System.IO.UnixFileMode]::OtherRead -bor
            [System.IO.UnixFileMode]::OtherWrite -bor
            [System.IO.UnixFileMode]::OtherExecute

        $ownerIds[0] | Should -Be $ownerIds[2]
        $ownerIds[1] | Should -Be $ownerIds[2]
        ($mode -band $nonOwnerMask) | Should -Be 0
    }

    It 'rejects an unsafe existing custom root without changing its mode' -Skip:$IsWindows {
        [void] [System.IO.Directory]::CreateDirectory($script:StateRoot)
        $unsafeMode =
            [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite -bor
            [System.IO.UnixFileMode]::UserExecute -bor
            [System.IO.UnixFileMode]::GroupRead -bor
            [System.IO.UnixFileMode]::GroupExecute
        try {
            [System.IO.File]::SetUnixFileMode($script:StateRoot, $unsafeMode)

            {
                New-AzureDataLabRun `
                    -Plan $script:Plan `
                    -StateRoot $script:StateRoot
            } | Should -Throw -ExpectedMessage '*accessible by non-owner identities*'

            [System.IO.File]::GetUnixFileMode($script:StateRoot) |
                Should -Be $unsafeMode
        }
        finally {
            [System.IO.File]::SetUnixFileMode(
                $script:StateRoot,
                (
                    [System.IO.UnixFileMode]::UserRead -bor
                    [System.IO.UnixFileMode]::UserWrite -bor
                    [System.IO.UnixFileMode]::UserExecute
                )
            )
        }
    }

    It 'rejects an unsafe ancestor before creating a nested state root' -Skip:$IsWindows {
        $unsafeParent = Join-Path $TestDrive 'unsafe-parent'
        [void] [System.IO.Directory]::CreateDirectory($unsafeParent)
        $unsafeMode =
            [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite -bor
            [System.IO.UnixFileMode]::UserExecute -bor
            [System.IO.UnixFileMode]::GroupRead -bor
            [System.IO.UnixFileMode]::GroupWrite -bor
            [System.IO.UnixFileMode]::GroupExecute
        [System.IO.File]::SetUnixFileMode($unsafeParent, $unsafeMode)
        $nestedStateRoot = Join-Path $unsafeParent 'state'

        {
            New-AzureDataLabRun `
                -Plan $script:Plan `
                -StateRoot $nestedStateRoot
        } | Should -Throw -ExpectedMessage '*writable by non-owner identities*'

        Test-Path $nestedStateRoot | Should -BeFalse
        [System.IO.File]::GetUnixFileMode($unsafeParent) |
            Should -Be $unsafeMode
    }

    It 'rejects a state root with a mocked unexpected Unix owner' -Skip:$IsWindows {
        [void] [System.IO.Directory]::CreateDirectory(
            $script:StateRoot,
            (
                [System.IO.UnixFileMode]::UserRead -bor
                [System.IO.UnixFileMode]::UserWrite -bor
                [System.IO.UnixFileMode]::UserExecute
            )
        )
        $script:WrongOwnerStateRoot = [System.IO.Path]::GetFullPath(
            $script:StateRoot
        )
        $script:CurrentOwnerId = & $script:Module {
            Get-AdltCurrentUnixUserId
        }
        Mock `
            -CommandName Get-AdltUnixPathOwnerId `
            -ModuleName AzureDataLabToolkit `
            -MockWith {
                param($Path)
                if (
                    [System.IO.Path]::GetFullPath($Path) -ceq
                        $script:WrongOwnerStateRoot
                ) {
                    return [uint32] ($script:CurrentOwnerId + 1)
                }
                return [uint32] $script:CurrentOwnerId
            }

        {
            New-AzureDataLabRun `
                -Plan $script:Plan `
                -StateRoot $script:StateRoot
        } | Should -Throw -ExpectedMessage '*unexpected owner UID*'
    }

    It 'rejects a symbolic-link component in the state path' -Skip:$IsWindows {
        $realRoot = Join-Path $TestDrive 'real-state'
        [void] [System.IO.Directory]::CreateDirectory($realRoot)
        $linkRoot = Join-Path $TestDrive 'linked-state'
        [void] (New-Item `
            -ItemType SymbolicLink `
            -Path $linkRoot `
            -Target $realRoot)

        {
            New-AzureDataLabRun `
                -Plan $script:Plan `
                -StateRoot (Join-Path $linkRoot 'nested')
        } | Should -Throw -ExpectedMessage '*symbolic link or reparse point*'
    }

    It 'rejects a store whose state root became accessible to others' -Skip:$IsWindows {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        try {
            [System.IO.File]::SetUnixFileMode(
                $script:StateRoot,
                (
                    [System.IO.UnixFileMode]::UserRead -bor
                    [System.IO.UnixFileMode]::UserWrite -bor
                    [System.IO.UnixFileMode]::UserExecute -bor
                    [System.IO.UnixFileMode]::GroupRead -bor
                    [System.IO.UnixFileMode]::GroupExecute
                )
            )

            {
                Get-AzureDataLabRun `
                    -RunId $run.RunId `
                    -StateRoot $script:StateRoot
            } | Should -Throw -ExpectedMessage '*accessible by non-owner identities*'
        }
        finally {
            [System.IO.File]::SetUnixFileMode(
                $script:StateRoot,
                (
                    [System.IO.UnixFileMode]::UserRead -bor
                    [System.IO.UnixFileMode]::UserWrite -bor
                    [System.IO.UnixFileMode]::UserExecute
                )
            )
        }
    }

    It 'uses a protected owner-only ACL on Windows' -Skip:(-not $IsWindows) {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot

        {
            & $script:Module {
                param($RunPath)
                Assert-AdltPrivatePathMode -Path $RunPath -Type Directory
                Assert-AdltPrivatePathMode `
                    -Path (Join-Path $RunPath 'snapshot.json') `
                    -Type File
            } $run.StatePath
        } | Should -Not -Throw
    }

    It 'retains owner-only modes after evidence and status mutations' -Skip:$IsWindows {
        $run = New-AzureDataLabRun `
            -Plan $script:Plan `
            -StateRoot $script:StateRoot
        $evidence = New-TestEvidence `
            -Run $run `
            -PreviousEventHash $run.State.evidenceReferences[-1].evidenceHash
        $result = Add-TestEvidence -Run $run -Evidence $evidence
        [void] (Set-TestRunStatus -Run $run -Status authorizing)
        $nonOwnerMask =
            [System.IO.UnixFileMode]::GroupRead -bor
            [System.IO.UnixFileMode]::GroupWrite -bor
            [System.IO.UnixFileMode]::GroupExecute -bor
            [System.IO.UnixFileMode]::OtherRead -bor
            [System.IO.UnixFileMode]::OtherWrite -bor
            [System.IO.UnixFileMode]::OtherExecute

        foreach ($path in @(
            (Join-Path $run.StatePath 'events.ndjson'),
            (Join-Path $run.StatePath 'snapshot.json'),
            $result.EvidencePath
        )) {
            $mode = [System.IO.File]::GetUnixFileMode($path)
            ($mode -band $nonOwnerMask) | Should -Be 0
        }
    }
}
