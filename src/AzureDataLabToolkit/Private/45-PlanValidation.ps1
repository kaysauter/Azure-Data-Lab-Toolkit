function Assert-AdltPlanStructure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $resourceIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($resource in @($Plan.resources)) {
        if (-not $resourceIds.Add([string] $resource.id)) {
            throw "Plan contains duplicate resource ID '$($resource.id)'."
        }

        if (
            $resource.ownership.intent -eq 'create' -and
            $resource.ownership.expectedClassification -ne 'owned'
        ) {
            throw "Resource '$($resource.id)' has contradictory create ownership intent."
        }

        if (
            $resource.ownership.intent -eq 'reuse' -and
            $resource.ownership.expectedClassification -ne 'reused'
        ) {
            throw "Resource '$($resource.id)' has contradictory reuse ownership intent."
        }

        if (
            $resource.ownership.expectedClassification -in @('reused', 'external') -and
            $resource.ownership.teardownIntent -ne 'retain'
        ) {
            throw "Reused or external resource '$($resource.id)' must be retained."
        }

        if ($resource.ownership.observedClassification -ne 'unverified') {
            throw "Offline plan resource '$($resource.id)' cannot claim observed ownership."
        }
        if (
            $resource.ownership.intent -eq 'reuse' -and
            [string]::IsNullOrWhiteSpace([string] $resource.externalResourceId)
        ) {
            throw "Reused resource '$($resource.id)' must identify the external resource."
        }
        if (
            $resource.ownership.intent -eq 'create' -and
            $null -ne $resource.externalResourceId
        ) {
            throw "Created resource '$($resource.id)' cannot identify an external resource."
        }
        if ($resource.desiredProperties.Count -eq 0) {
            throw "Resource '$($resource.id)' has no desired properties."
        }
    }

    $actionIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $idempotencyKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($action in @($Plan.actions)) {
        if (-not $actionIds.Add([string] $action.id)) {
            throw "Plan contains duplicate action ID '$($action.id)'."
        }
        if (-not $idempotencyKeys.Add([string] $action.idempotencyKey)) {
            throw "Plan contains duplicate idempotency key '$($action.idempotencyKey)'."
        }
        if (
            [string] $action.resourceId -like 'azure.*' -and
            -not $resourceIds.Contains([string] $action.resourceId)
        ) {
            throw "Action '$($action.id)' references unknown resource '$($action.resourceId)'."
        }
        if ($action.operation -eq 'reference' -and $action.mutation) {
            throw "Reference action '$($action.id)' cannot be mutating."
        }

        $executionContract = switch ($action.executionScope) {
            'offline' {
                [ordered]@{
                    stateSource = 'local-artifact-state'
                    required = @(
                        'approved-plan-hash-matches'
                        'local-input-contract-valid'
                    )
                    forbidden = @(
                        'live-state-observed'
                        'ownership-established'
                        'collision-check-passed'
                        'target-ready'
                        'guest-execution-authorized'
                    )
                    mutationForbidden = $true
                }
            }
            'azure' {
                [ordered]@{
                    stateSource = 'azure-control-plane'
                    required = @(
                        'approved-plan-hash-matches'
                        'live-state-observed'
                        'ownership-established'
                        'collision-check-passed'
                    )
                    forbidden = @(
                        'local-input-contract-valid'
                        'target-ready'
                        'guest-execution-authorized'
                    )
                    mutationForbidden = $false
                }
            }
            'guest' {
                [ordered]@{
                    stateSource = 'guest-probe'
                    required = @(
                        'approved-plan-hash-matches'
                        'live-state-observed'
                        'target-ready'
                        'guest-execution-authorized'
                        'collision-check-passed'
                    )
                    forbidden = @(
                        'local-input-contract-valid'
                        'ownership-established'
                    )
                    mutationForbidden = $false
                }
            }
        }

        if (
            $executionContract.mutationForbidden -and
            $action.mutation
        ) {
            throw "Action '$($action.id)' cannot mutate in '$($action.executionScope)' scope."
        }
        if (
            $action.reconciliation.stateSource -ne
            $executionContract.stateSource
        ) {
            throw "Action '$($action.id)' has the wrong reconciliation state source for '$($action.executionScope)' scope."
        }
        foreach ($requiredPrecondition in $executionContract.required) {
            if ($action.preconditions -notcontains $requiredPrecondition) {
                throw "Action '$($action.id)' lacks required '$($action.executionScope)' precondition '$requiredPrecondition'."
            }
        }
        foreach ($forbiddenPrecondition in $executionContract.forbidden) {
            if ($action.preconditions -contains $forbiddenPrecondition) {
                throw "Action '$($action.id)' contains invalid '$($action.executionScope)' precondition '$forbiddenPrecondition'."
            }
        }
    }

    $remainingDependencies = [ordered]@{}
    foreach ($action in @($Plan.actions)) {
        $dependencies = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        foreach ($dependency in @($action.dependsOn)) {
            if (-not $actionIds.Contains([string] $dependency)) {
                throw "Action '$($action.id)' depends on unknown action '$dependency'."
            }
            if ([string] $dependency -ceq [string] $action.id) {
                throw "Action '$($action.id)' cannot depend on itself."
            }
            if (-not $dependencies.Add([string] $dependency)) {
                throw "Action '$($action.id)' declares duplicate dependency '$dependency'."
            }
        }
        $remainingDependencies[[string] $action.id] = $dependencies
    }

    while ($remainingDependencies.Count -gt 0) {
        $ready = [string[]] @(
            $remainingDependencies.Keys |
                Where-Object { $remainingDependencies[$_].Count -eq 0 }
        )
        if ($ready.Count -eq 0) {
            throw 'Plan action dependencies contain a cycle.'
        }

        foreach ($readyId in $ready) {
            $remainingDependencies.Remove($readyId)
        }
        foreach ($dependencies in $remainingDependencies.Values) {
            foreach ($readyId in $ready) {
                [void] $dependencies.Remove($readyId)
            }
        }
    }

    $policyFindingIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $expectedAcknowledgements = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $expectedBlockers = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($finding in @($Plan.policyFindings)) {
        if (-not $policyFindingIds.Add([string] $finding.id)) {
            throw "Plan contains duplicate policy finding '$($finding.id)'."
        }
        if ($finding.acknowledgementRequired -ne ($finding.effect -eq 'acknowledge')) {
            throw "Policy finding '$($finding.id)' has inconsistent acknowledgement semantics."
        }
        if ($finding.blocksDeployment -ne ($finding.effect -eq 'resolve-before-deploy')) {
            throw "Policy finding '$($finding.id)' has inconsistent blocking semantics."
        }
        if ($finding.acknowledgementRequired) {
            [void] $expectedAcknowledgements.Add([string] $finding.id)
        }
        if ($finding.blocksDeployment) {
            [void] $expectedBlockers.Add([string] $finding.id)
        }
    }

    foreach ($acknowledgementId in @($Plan.approval.requiredAcknowledgementIds)) {
        if (-not $expectedAcknowledgements.Remove([string] $acknowledgementId)) {
            throw "Approval references unexpected acknowledgement '$acknowledgementId'."
        }
    }
    if ($expectedAcknowledgements.Count -gt 0) {
        throw 'Approval omits one or more required policy acknowledgements.'
    }

    foreach ($blockingId in @($Plan.approval.blockingFindingIds)) {
        if (-not $expectedBlockers.Remove([string] $blockingId)) {
            throw "Approval references unexpected blocking finding '$blockingId'."
        }
    }
    if ($expectedBlockers.Count -gt 0) {
        throw 'Approval omits one or more blocking policy findings.'
    }
}
