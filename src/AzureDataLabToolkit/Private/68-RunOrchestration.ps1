function New-AdltChainedEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Sequence,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $PreviousEvidenceHash
    )

    Assert-AdltEvidence -Evidence $Evidence
    $parameters = @{
        RunId             = [string] $Evidence.runId
        PlanHash          = [string] $Evidence.planHash
        IntentHash        = [string] $Evidence.intentHash
        Stage             = [string] $Evidence.stage
        Status            = [string] $Evidence.status
        Sequence          = $Sequence
        PreviousEventHash = $PreviousEvidenceHash
        CorrelationIds     = @($Evidence.correlationIds)
        Probes             = @($Evidence.probes)
        Redactions         = @($Evidence.redactions)
        Payload            = Copy-AdltValue -InputObject $Evidence.payload
        StartedAt          = [datetimeoffset]::Parse(
            [string] $Evidence.startedAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        CompletedAt        = [datetimeoffset]::Parse(
            [string] $Evidence.completedAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    return New-AdltEvidence @parameters
}

function Get-AdltRunEvidenceByStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Evidence,

        [Parameter(Mandatory)]
        [string] $Stage
    )

    $stageEvidence = @($Evidence | Where-Object stage -CEQ $Stage)
    if ($stageEvidence.Count -ne 1) {
        throw "The protected run must contain exactly one '$Stage' evidence artifact."
    }
    return ConvertTo-AdltDictionary -InputObject $stageEvidence[0]
}

function Add-AdltGeneratedRunEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $attachment = Add-AdltLocalRunEvidence `
        -RunPath $RunPath `
        -Evidence $Evidence `
        -ActorType toolkit `
        -ActorId $ActorId `
        -RebindGeneratedEvidence `
        -OccurredAt $OccurredAt

    return $attachment.Evidence
}

function Add-AdltValidatedPreflightEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [AllowNull()]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [AllowNull()]
        [System.Collections.IDictionary] $WhatIfEvidence,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $context = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
    $chained = New-AdltChainedEvidence `
        -Evidence $Evidence `
        -Sequence @($context.Evidence).Count `
        -PreviousEvidenceHash $context.Evidence[-1].evidenceHash
    switch ([string] $chained.stage) {
        'live-resolution' {
            Assert-AdltLiveResolutionEvidenceForPlan `
                -Evidence $chained `
                -Plan $Plan
        }
        'what-if' {
            if ($null -eq $LiveResolutionEvidence) {
                throw 'WhatIf validation requires live-resolution evidence.'
            }
            Assert-AdltWhatIfEvidenceForPlan `
                -Evidence $chained `
                -Plan $Plan `
                -LiveResolutionEvidence $LiveResolutionEvidence
        }
        'cost' {
            if ($null -eq $LiveResolutionEvidence) {
                throw 'Cost validation requires live-resolution evidence.'
            }
            $maximumRunCost = $Plan.configuration.cost.maximumRunCost
            Assert-AdltCostEvidenceForPlan `
                -Evidence $chained `
                -Plan $Plan `
                -LiveResolutionEvidence $LiveResolutionEvidence `
                -AuthorizedMaximumMinorUnits (
                    [int64] $maximumRunCost.amountMinorUnits
                ) `
                -AuthorizedCurrency ([string] $maximumRunCost.currency)
        }
        'teardown-preview' {
            if (
                $null -eq $LiveResolutionEvidence -or
                $null -eq $WhatIfEvidence
            ) {
                throw (
                    'Teardown-preview validation requires live-resolution ' +
                    'and WhatIf evidence.'
                )
            }
            Assert-AdltTeardownPreviewEvidenceForPlan `
                -Evidence $chained `
                -Plan $Plan `
                -LiveResolutionEvidence $LiveResolutionEvidence `
                -WhatIfEvidence $WhatIfEvidence
        }
        default {
            throw "Unsupported preflight evidence stage '$($chained.stage)'."
        }
    }

    $attachment = Add-AdltLocalRunEvidence `
        -RunPath $RunPath `
        -Evidence $chained `
        -ActorType toolkit `
        -ActorId $ActorId `
        -OccurredAt $OccurredAt
    return $attachment.Evidence
}

function Set-AdltRunBlocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $context = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
    if ($context.State.status -eq 'blocked') {
        return $context.State
    }
    $transition = Add-AdltLocalRunStatusTransition `
        -RunPath $RunPath `
        -Status blocked `
        -ActorType toolkit `
        -ActorId $ActorId `
        -OccurredAt $OccurredAt
    return $transition.State
}

function Set-AdltPreflightRunBlocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [ValidateSet(
            'live-resolution',
            'what-if',
            'cost',
            'teardown-preview'
        )]
        [string] $Stage,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $result = Add-AdltLocalPreflightBlockedEvent `
        -RunPath $RunPath `
        -Stage $Stage `
        -ActorId $ActorId `
        -OccurredAt $OccurredAt
    return $result.State
}

function Get-AdltVerifiedPreflightEvidenceSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $expectedStages = @(
        'live-resolution'
        'what-if'
        'cost'
        'teardown-preview'
    )
    $attached = @($Context.Evidence | Select-Object -Skip 1)
    if ($attached.Count -gt $expectedStages.Count) {
        throw 'The protected run contains evidence beyond the preflight contract.'
    }
    for ($index = 0; $index -lt $attached.Count; $index++) {
        if (
            $attached[$index].stage -cne $expectedStages[$index] -or
            $attached[$index].status -cne 'pass'
        ) {
            throw (
                'The protected run contains a non-passing, duplicate, or ' +
                'out-of-order preflight artifact.'
            )
        }
    }

    $result = [ordered]@{
        LiveResolution  = $null
        WhatIf          = $null
        Cost            = $null
        TeardownPreview = $null
    }
    if ($attached.Count -ge 1) {
        $result.LiveResolution = ConvertTo-AdltDictionary `
            -InputObject $attached[0]
        Assert-AdltLiveResolutionEvidenceForPlan `
            -Evidence $result.LiveResolution `
            -Plan $Context.Plan
    }
    if ($attached.Count -ge 2) {
        $result.WhatIf = ConvertTo-AdltDictionary `
            -InputObject $attached[1]
        Assert-AdltWhatIfEvidenceForPlan `
            -Evidence $result.WhatIf `
            -Plan $Context.Plan `
            -LiveResolutionEvidence $result.LiveResolution
    }
    if ($attached.Count -ge 3) {
        $result.Cost = ConvertTo-AdltDictionary `
            -InputObject $attached[2]
        $maximumRunCost = $Context.Plan.configuration.cost.maximumRunCost
        Assert-AdltCostEvidenceForPlan `
            -Evidence $result.Cost `
            -Plan $Context.Plan `
            -LiveResolutionEvidence $result.LiveResolution `
            -AuthorizedMaximumMinorUnits (
                [int64] $maximumRunCost.amountMinorUnits
            ) `
            -AuthorizedCurrency ([string] $maximumRunCost.currency)
    }
    if ($attached.Count -ge 4) {
        $result.TeardownPreview = ConvertTo-AdltDictionary `
            -InputObject $attached[3]
        Assert-AdltTeardownPreviewEvidenceForPlan `
            -Evidence $result.TeardownPreview `
            -Plan $Context.Plan `
            -LiveResolutionEvidence $result.LiveResolution `
            -WhatIfEvidence $result.WhatIf
    }

    return $result
}

function Assert-AdltPreflightRetryEligibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    if ([string] $Context.State.status -cne 'blocked') {
        throw 'Preflight retry requires a blocked run.'
    }
    if (@($Context.Artifacts).Count -ne 0) {
        throw 'Preflight retry is forbidden after execution artifacts exist.'
    }
    $allowedEventTypes = @(
        'run-created'
        'status-changed'
        'evidence-attached'
        'preflight-blocked'
    )
    foreach ($runEvent in @($Context.Events)) {
        if ([string] $runEvent.eventType -cnotin $allowedEventTypes) {
            throw (
                'Preflight retry requires a preflight-only event history; ' +
                "found '$($runEvent.eventType)'."
            )
        }
        if (
            [string] $runEvent.eventType -ceq 'status-changed' -and
            [string] $runEvent.data.status -cne 'authorizing'
        ) {
            throw 'Preflight retry found a non-preflight status transition.'
        }
    }
    if (
        [string] $Context.TailEvent.eventType -cne
            'preflight-blocked'
    ) {
        throw 'Preflight retry requires a typed preflight-blocked tail event.'
    }

    $evidenceSet = Get-AdltVerifiedPreflightEvidenceSet -Context $Context
    $expectedStages = @(
        'live-resolution'
        'what-if'
        'cost'
        'teardown-preview'
    )
    $completedCount = @($Context.Evidence | Select-Object -Skip 1).Count
    if ($completedCount -ge $expectedStages.Count) {
        throw 'Completed preflight evidence cannot be retried; create a new run.'
    }
    $expectedBlockedStage = $expectedStages[$completedCount]
    if (
        [string] $Context.TailEvent.data.stage -cne
            $expectedBlockedStage
    ) {
        throw (
            'The preflight block stage does not match the next missing ' +
            'evidence stage.'
        )
    }
    return $evidenceSet
}
