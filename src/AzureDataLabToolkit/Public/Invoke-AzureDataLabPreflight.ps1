function Invoke-AzureDataLabPreflight {
    <#
    .SYNOPSIS
    Runs the protected, read-only Azure preflight for a local SQL VM run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('StatePath')]
        [string] $RunPath,

        [switch] $RetryBlocked
    )

    process {
        $actorId = 'AzureDataLabToolkit'
        $stage = $null
        $preflightActive = $false
        $operationLock = Open-AdltLocalRunOperationLock `
            -RunPath $RunPath
        try {
            $context = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
            if (
                $context.Plan.target.type -cne 'sqlVm' -or
                @($context.Evidence).Count -lt 1 -or
                $context.Evidence[0].stage -cne 'plan'
            ) {
                throw 'Preflight requires a protected SQL VM run with plan evidence.'
            }
            $evidenceSet = $null
            switch ([string] $context.State.status) {
                'planned' {
                    if ($RetryBlocked.IsPresent) {
                        throw '-RetryBlocked is valid only for a typed blocked preflight.'
                    }
                    [void] (Add-AdltLocalRunStatusTransition `
                        -RunPath $RunPath `
                        -Status authorizing `
                        -ActorType toolkit `
                        -ActorId $actorId)
                    $context = Get-AdltVerifiedLocalRunContext `
                        -RunPath $RunPath
                }
                'authorizing' {
                    if ($RetryBlocked.IsPresent) {
                        throw '-RetryBlocked is valid only for a typed blocked preflight.'
                    }
                }
                'blocked' {
                    if (-not $RetryBlocked.IsPresent) {
                        throw (
                            'A blocked preflight requires explicit ' +
                            '-RetryBlocked after the failure is corrected.'
                        )
                    }
                    $evidenceSet = Assert-AdltPreflightRetryEligibility `
                        -Context $context
                    [void] (Add-AdltLocalRunStatusTransition `
                        -RunPath $RunPath `
                        -Status authorizing `
                        -ActorType toolkit `
                        -ActorId $actorId)
                    $context = Get-AdltVerifiedLocalRunContext `
                        -RunPath $RunPath
                }
                default {
                    throw (
                        'Preflight requires a planned, interrupted-authorizing, ' +
                        'or typed blocked preflight run.'
                    )
                }
            }
            if ($null -eq $evidenceSet) {
                $evidenceSet = Get-AdltVerifiedPreflightEvidenceSet `
                    -Context $context
            }

            $stage = 'live-resolution'
            $preflightActive = $true
            $liveResolution = $evidenceSet.LiveResolution
            if ($null -eq $liveResolution) {
                $candidate = Resolve-AzureDataLabPlan `
                    -Plan $context.Plan `
                    -RunId $context.State.runId `
                    -ErrorAction Stop
                if ($candidate.status -cne 'pass') {
                    throw 'Live Azure facts did not pass verification.'
                }
                $liveResolution = Add-AdltValidatedPreflightEvidence `
                    -RunPath $RunPath `
                    -Evidence (
                        ConvertTo-AdltDictionary -InputObject $candidate
                    ) `
                    -Plan $context.Plan `
                    -ActorId $actorId
            }

            $stage = 'what-if'
            $whatIf = $evidenceSet.WhatIf
            if ($null -eq $whatIf) {
                $candidate = Test-AzureDataLabWhatIf `
                    -Plan $context.Plan `
                    -LiveResolutionEvidence $liveResolution `
                    -RunId $context.State.runId `
                    -ErrorAction Stop
                if ($candidate.status -cne 'pass') {
                    throw 'Provider-level ARM What-If did not pass verification.'
                }
                $whatIf = Add-AdltValidatedPreflightEvidence `
                    -RunPath $RunPath `
                    -Evidence (
                        ConvertTo-AdltDictionary -InputObject $candidate
                    ) `
                    -Plan $context.Plan `
                    -ActorId $actorId `
                    -LiveResolutionEvidence $liveResolution
            }

            $stage = 'cost'
            $cost = $evidenceSet.Cost
            if ($null -eq $cost) {
                $priceProvider = {
                    param($Request)

                    Invoke-AdltAzureRetailPriceCommand -Request $Request
                }
                $candidate = New-AdltSqlVmCostEstimateEvidence `
                    -Plan $context.Plan `
                    -LiveResolutionEvidence $liveResolution `
                    -RunId $context.State.runId `
                    -PriceProvider $priceProvider `
                    -RetrievedAt ([datetimeoffset]::UtcNow)
                if ($candidate.status -cne 'pass') {
                    throw (
                        'The cost estimate is incomplete or exceeds the ' +
                        'configured estimate admission limit.'
                    )
                }
                $cost = Add-AdltValidatedPreflightEvidence `
                    -RunPath $RunPath `
                    -Evidence $candidate `
                    -Plan $context.Plan `
                    -ActorId $actorId `
                    -LiveResolutionEvidence $liveResolution
            }

            $stage = 'teardown-preview'
            $teardownPreview = $evidenceSet.TeardownPreview
            if ($null -eq $teardownPreview) {
                $previewStartedAt = [datetimeoffset]::UtcNow
                $candidate = New-AdltPreDeploymentTeardownPreviewEvidence `
                    -Plan $context.Plan `
                    -LiveResolutionEvidence $liveResolution `
                    -WhatIfEvidence $whatIf `
                    -RunId $context.State.runId `
                    -StartedAt $previewStartedAt `
                    -CompletedAt ([datetimeoffset]::UtcNow)
                if ($candidate.status -cne 'pass') {
                    throw (
                        'The preauthorized teardown preview did not pass ' +
                        'verification.'
                    )
                }
                $teardownPreview = Add-AdltValidatedPreflightEvidence `
                    -RunPath $RunPath `
                    -Evidence $candidate `
                    -Plan $context.Plan `
                    -ActorId $actorId `
                    -LiveResolutionEvidence $liveResolution `
                    -WhatIfEvidence $whatIf
            }

            $preflightActive = $false
            $verified = Get-AdltVerifiedLocalRunContext -RunPath $RunPath
            return [pscustomobject][ordered]@{
                PSTypeName               =
                    'AzureDataLabToolkit.PreflightResult'
                RunId                    = $verified.State.runId
                RunPath                  =
                    [System.IO.Path]::GetFullPath($RunPath)
                PlanHash                 = $verified.Plan.planHash
                IntentHash               = $verified.Plan.intentHash
                Status                   = 'ready-for-approval'
                LiveResolutionEvidenceHash =
                    $liveResolution.evidenceHash
                WhatIfEvidenceHash       = $whatIf.evidenceHash
                CostEvidenceHash         = $cost.evidenceHash
                TeardownPreviewEvidenceHash =
                    $teardownPreview.evidenceHash
                EstimatedCostMinorUnits  =
                    $cost.payload.totalAmountMinorUnits
                MaximumCostMinorUnits    =
                    $cost.payload.maximumRunCost.amountMinorUnits
                Currency                 = $cost.payload.currency
                MaximumRuntimeMinutes    =
                    $verified.Plan.configuration.lifecycle.maximumRuntimeMinutes
                RequiredAcknowledgementIds = @(
                    $verified.Plan.approval.requiredAcknowledgementIds
                )
                ExpiresAt                = $verified.State.expiresAt
            }
        }
        catch {
            $preflightFailure = $_.Exception
            if (-not $preflightActive) {
                throw
            }
            try {
                [void] (Set-AdltPreflightRunBlocked `
                    -RunPath $RunPath `
                    -Stage $stage `
                    -ActorId $actorId)
            }
            catch {
                Write-Verbose -Message (
                    'Could not persist the blocked preflight state; ' +
                    'preserving the original preflight failure. {0}' -f
                    $_.Exception.Message
                )
            }
            throw [System.InvalidOperationException]::new(
                "Azure Data Lab preflight failed at stage '$stage'.",
                $preflightFailure
            )
        }
        finally {
            $operationLock.Dispose()
        }
    }
}
