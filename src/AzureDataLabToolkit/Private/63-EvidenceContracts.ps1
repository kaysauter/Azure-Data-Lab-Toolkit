function Assert-AdltEvidencePayloadSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Stage,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Payload
    )

    $schemaFileName = switch ($Stage) {
        'live-resolution' { 'evidence-live-resolution-payload.schema.json' }
        'what-if' { 'evidence-what-if-payload.schema.json' }
        'cost' { 'evidence-cost-payload.schema.json' }
        'teardown-preview' { 'evidence-teardown-preview-payload.schema.json' }
        'deploy' { 'evidence-deploy-payload.schema.json' }
        'probe' { 'evidence-probe-payload.schema.json' }
        'cleanup-proof' { 'evidence-cleanup-proof-payload.schema.json' }
        default { $null }
    }
    if ($null -eq $schemaFileName) {
        return
    }

    $validation = Test-AdltObjectAgainstSchema `
        -InputObject $Payload `
        -SchemaPath (Get-AdltDataPath -ChildPath "Schemas/$schemaFileName")
    if (-not $validation.Valid) {
        throw (
            "Evidence stage '$Stage' payload validation failed: {0}" -f
            ($validation.Errors -join ' ')
        )
    }
}

function Assert-AdltEvidencePayloadContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence
    )

    if ($Evidence.payload -isnot [System.Collections.IDictionary]) {
        throw "Evidence stage '$($Evidence.stage)' requires a dictionary payload."
    }
    Assert-AdltEvidencePayloadSchema `
        -Stage ([string] $Evidence.stage) `
        -Payload $Evidence.payload

    switch ([string] $Evidence.stage) {
        'live-resolution' {
            $stableIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )
            $resourceIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            foreach ($resource in @($Evidence.payload.resources)) {
                if (-not $stableIds.Add([string] $resource.stableId)) {
                    throw "Live-resolution evidence contains duplicate stable ID '$($resource.stableId)'."
                }
                if (-not $resourceIds.Add([string] $resource.resourceId)) {
                    throw "Live-resolution evidence contains duplicate resource ID '$($resource.resourceId)'."
                }
            }
        }
        'what-if' {
            $stableIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )
            $resourceIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            foreach ($result in @($Evidence.payload.results)) {
                if (-not $stableIds.Add([string] $result.stableId)) {
                    throw "WhatIf evidence contains duplicate stable ID '$($result.stableId)'."
                }
                if (-not $resourceIds.Add([string] $result.resourceId)) {
                    throw "WhatIf evidence contains duplicate resource ID '$($result.resourceId)'."
                }
            }
            if ([int64] $Evidence.payload.mutationCount -ne 0) {
                throw 'WhatIf evidence must describe a read-only operation with mutationCount zero.'
            }
        }
        'cost' {
            $componentIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )
            foreach ($component in @($Evidence.payload.components)) {
                if (-not $componentIds.Add([string] $component.componentId)) {
                    throw "Cost evidence contains duplicate component ID '$($component.componentId)'."
                }
            }
        }
        'teardown-preview' {
            $stableIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )
            $resourceIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            foreach ($resource in @($Evidence.payload.resources)) {
                if (-not $stableIds.Add([string] $resource.stableId)) {
                    throw "Teardown-preview evidence contains duplicate stable ID '$($resource.stableId)'."
                }
                if (-not $resourceIds.Add([string] $resource.resourceId)) {
                    throw "Teardown-preview evidence contains duplicate resource ID '$($resource.resourceId)'."
                }
            }
        }
        'deploy' {
            if (
                $Evidence.status -eq 'pass' -and
                $Evidence.payload.outcome -cne 'succeeded'
            ) {
                throw 'Passing deployment evidence requires a succeeded outcome.'
            }
            if (
                $Evidence.status -eq 'fail' -and
                $Evidence.payload.outcome -cne 'failed'
            ) {
                throw 'Failed deployment evidence requires a failed outcome.'
            }
        }
        'probe' {
            $expectedOutcome = switch ([string] $Evidence.status) {
                'pass' { 'succeeded' }
                'fail' { 'failed' }
                'denied' { 'denied' }
                'unverified' { 'unverified' }
                default { $null }
            }
            if (
                $null -eq $expectedOutcome -or
                $Evidence.payload.outcome -cne $expectedOutcome -or
                (
                    $Evidence.status -ceq 'pass' -and
                    (
                        $null -ne $Evidence.payload.failureKind -or
                        [bool] $Evidence.payload.retryable
                    )
                ) -or
                (
                    $Evidence.status -cne 'pass' -and
                    $null -eq $Evidence.payload.failureKind
                )
            ) {
                throw 'Probe evidence status, outcome, and retry policy are inconsistent.'
            }
        }
        'cleanup-proof' {
            if (
                $Evidence.status -cne 'pass' -or
                $Evidence.payload.observedState -cne
                    'approved-resources-absent' -or
                [int] $Evidence.payload.remainingApprovedResourceCount -ne 0
            ) {
                throw (
                    'Cleanup-proof evidence must pass and prove the ' +
                    'exact approved resource set is absent.'
                )
            }
        }
    }
}
