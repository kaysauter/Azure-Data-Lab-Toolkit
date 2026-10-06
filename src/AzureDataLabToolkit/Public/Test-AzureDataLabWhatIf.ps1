function Test-AzureDataLabWhatIf {
    <#
    .SYNOPSIS
    Compares a resolved plan with live Azure state without making changes.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $Plan,

        [Parameter(Mandatory)]
        [object] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId
    )

    process {
        $startedAt = [datetimeoffset]::UtcNow
        $planDictionary = ConvertTo-AdltDictionary -InputObject $Plan
        $resolution = ConvertTo-AdltDictionary -InputObject $LiveResolutionEvidence
        Assert-AdltPlanContract -Plan $planDictionary
        Assert-AdltEvidence -Evidence $resolution
        if (
            $resolution.stage -ne 'live-resolution' -or
            $resolution.status -ne 'pass' -or
            $resolution.runId -cne $RunId -or
            $resolution.planHash -cne $planDictionary.planHash -or
            $resolution.intentHash -cne $planDictionary.intentHash
        ) {
            throw 'WhatIf requires passing live-resolution evidence bound to this run and plan.'
        }
        [void] (Assert-AdltAzureContextReady -Plan $planDictionary)

        $results = [System.Collections.Generic.List[object]]::new()
        $probes = [System.Collections.Generic.List[object]]::new()
        $resourceIds = @{}
        foreach ($item in @($resolution.payload.resources)) {
            $resourceIds[[string] $item.stableId] = [string] $item.resourceId
        }
        $observedAt = ConvertTo-AdltUtcTimestamp -Value ([datetimeoffset]::UtcNow)

        foreach ($resourceObject in @($planDictionary.resources | Sort-Object id)) {
            $resource = ConvertTo-AdltDictionary -InputObject $resourceObject
            if (-not $resourceIds.ContainsKey([string] $resource.id)) {
                throw "Live-resolution evidence is missing resource '$($resource.id)'."
            }
            $resourceId = $resourceIds[[string] $resource.id]
            $read = Get-AdltAzureResourceRead `
                -Resource $resource `
                -ResourceId $resourceId
            $classification = Get-AdltWhatIfClassification `
                -Resource $resource `
                -ReadResult $read `
                -RunId $RunId
            $results.Add([ordered]@{
                stableId           = [string] $resource.id
                resourceId         = $resourceId
                resourceType       = [string] $resource.type
                plannedOwnership   = [string] $resource.ownership.expectedClassification
                observedState      = [string] $read.status
                classification     = $classification
                desiredHash        = Get-AdltDesiredResourceHash -Resource $resource
            })
            $probeStatus = switch ($classification) {
                'conflict'   { 'fail' }
                'denied'     { 'denied' }
                'unverified' { 'unverified' }
                'update'     { 'warning' }
                default      { 'pass' }
            }
            $probes.Add([ordered]@{
                probeId       = 'probe.what-if.{0}' -f (
                    ([string] $resource.id) -replace '^azure\.', ''
                )
                status        = $probeStatus
                correlationIds = @()
                observedAt    = $observedAt
                message       = 'Live state was classified without changing the resource.'
                payload       = [ordered]@{
                    classification = $classification
                    observedState  = [string] $read.status
                    failureKind    = $read.failureKind
                }
            })
        }

        $status = Get-AdltWhatIfStatus `
            -Classifications @($results.ToArray().classification)
        $compilation = New-AdltSqlVmArmCompilation `
            -Plan $planDictionary `
            -LiveResolutionEvidence $resolution
        $scope = '/subscriptions/{0}' -f
            [string] $planDictionary.context.subscriptionId
        $deploymentName = 'adlt-whatif-{0}-{1}' -f
            $RunId.Replace('-', '').Substring(0, 8).ToLowerInvariant(),
            ([string] $planDictionary.planHash).Substring(7, 12)
        $parameterReferenceHash = Get-AdltSha256Identifier -Value (
            ConvertTo-AdltCanonicalJson `
                -InputObject $compilation.parameterReference
        )
        $native = [ordered]@{
            scope                    = $scope
            deploymentName           = $deploymentName
            validationLevel          = 'Provider'
            resultFormat             = 'ResourceIdOnly'
            executionArtifactDigest  =
                [string] $compilation.executionArtifactDigest
            templateHash             = [string] $compilation.templateHash
            parameterReferenceHash   = $parameterReferenceHash
            parameterFileHash        = $null
            invocationHash           = $null
            nativeStatus             = 'NotRun'
            nativeChanges            = @()
            nativeDiagnostics        = @()
            nativePotentialChangeCount = 0
            nativeChangesHash        = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject @()
            )
            nativeFailureKind        = 'unsafe-custom-preflight'
        }
        $native.nativeWhatIfResultHash =
            Get-AdltNativeWhatIfResultHash `
                -Status $native.nativeStatus `
                -Changes @($native.nativeChanges) `
                -Diagnostics @($native.nativeDiagnostics) `
                -PotentialChangeCount $native.nativePotentialChangeCount `
                -ChangesHash $native.nativeChangesHash `
                -FailureKind $native.nativeFailureKind

        if ($status -ceq 'pass') {
            try {
                $native = Invoke-AdltSqlVmNativeWhatIf `
                    -Plan $planDictionary `
                    -Compilation $compilation `
                    -RunId $RunId `
                    -CustomResults $results.ToArray()
                $native.nativeFailureKind = $null
                $probes.Add([ordered]@{
                    probeId        = 'probe.what-if.native-provider'
                    status         = 'pass'
                    correlationIds = @()
                    observedAt     = ConvertTo-AdltUtcTimestamp `
                        -Value ([datetimeoffset]::UtcNow)
                    message        = 'Native provider-level ARM WhatIf matched the compiled deployment.'
                    payload        = [ordered]@{
                        deploymentName = $native.deploymentName
                        validationLevel = $native.validationLevel
                        resultFormat = $native.resultFormat
                        nativeStatus = $native.nativeStatus
                    }
                })
            }
            catch {
                $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
                $status = if ($failureKind -in @(
                    'denied'
                    'unauthenticated'
                )) {
                    'denied'
                }
                else {
                    'unverified'
                }
                $native.nativeStatus = 'Unavailable'
                $native.nativeFailureKind = $failureKind
                $native.nativeWhatIfResultHash =
                    Get-AdltNativeWhatIfResultHash `
                        -Status $native.nativeStatus `
                        -Changes @($native.nativeChanges) `
                        -Diagnostics @($native.nativeDiagnostics) `
                        -PotentialChangeCount (
                            $native.nativePotentialChangeCount
                        ) `
                        -ChangesHash $native.nativeChangesHash `
                        -FailureKind $native.nativeFailureKind
                $probes.Add([ordered]@{
                    probeId        = 'probe.what-if.native-provider'
                    status         = $status
                    correlationIds = @()
                    observedAt     = ConvertTo-AdltUtcTimestamp `
                        -Value ([datetimeoffset]::UtcNow)
                    message        = 'Native provider-level ARM WhatIf did not produce an executable result.'
                    payload        = [ordered]@{
                        failureKind = $failureKind
                    }
                })
            }
        }
        return New-AdltEvidence `
            -RunId $RunId `
            -PlanHash $planDictionary.planHash `
            -IntentHash $planDictionary.intentHash `
            -Stage what-if `
            -Status $status `
            -Probes @($probes.ToArray()) `
            -Payload ([ordered]@{
                liveResolutionEvidenceHash = $resolution.evidenceHash
                results                    = $results.ToArray()
                mutationCount              = 0
                scope                      = $native.scope
                deploymentName             = $native.deploymentName
                validationLevel            = $native.validationLevel
                resultFormat               = $native.resultFormat
                executionArtifactDigest    =
                    $native.executionArtifactDigest
                templateHash               = $native.templateHash
                parameterReferenceHash     =
                    $native.parameterReferenceHash
                parameterFileHash          = $native.parameterFileHash
                invocationHash             = $native.invocationHash
                nativeStatus               = $native.nativeStatus
                nativeChanges              = @($native.nativeChanges)
                nativeDiagnostics          = @($native.nativeDiagnostics)
                nativePotentialChangeCount =
                    $native.nativePotentialChangeCount
                nativeChangesHash          = $native.nativeChangesHash
                nativeWhatIfResultHash     =
                    $native.nativeWhatIfResultHash
                nativeFailureKind          = $native.nativeFailureKind
            }) `
            -StartedAt $startedAt `
            -CompletedAt ([datetimeoffset]::UtcNow)
    }
}
