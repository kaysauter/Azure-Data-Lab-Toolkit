function Get-AdltPlanScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    return [ordered]@{
        cloud             = $Plan.context.cloud
        tenantId          = $Plan.context.tenantId
        subscriptionId    = $Plan.context.subscriptionId
        resourceGroupName = $Plan.configuration.azure.resourceGroup.name
        location          = $Plan.context.location
    }
}

function Assert-AdltExactValueSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Actual,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Expected,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $actualSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($value in $Actual) {
        if (-not $actualSet.Add([string] $value)) {
            throw "$Name contains duplicate value '$value'."
        }
    }

    $expectedSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($value in $Expected) {
        if (-not $expectedSet.Add([string] $value)) {
            throw "The expected $Name set contains duplicate value '$value'."
        }
    }

    if (-not $actualSet.SetEquals($expectedSet)) {
        throw "$Name does not exactly match the verified artifact set."
    }
}

function Assert-AdltScopeBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Actual,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Expected,

        [Parameter(Mandatory)]
        [string] $ArtifactName
    )

    if (
        (ConvertTo-AdltCanonicalJson -InputObject $Actual) -cne
        (ConvertTo-AdltCanonicalJson -InputObject $Expected)
    ) {
        throw "$ArtifactName scope does not exactly match the approved plan scope."
    }
}

function Assert-AdltResourceIdInScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Scope,

        [Parameter(Mandatory)]
        [string] $ArtifactName
    )

    $match = [regex]::Match(
        $ResourceId,
        '^/subscriptions/(?<subscription>[^/]+)/resourceGroups/(?<resourceGroup>[^/]+)(?:/|$)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (
        -not $match.Success -or
        -not [string]::Equals(
            $match.Groups['subscription'].Value,
            [string] $Scope.subscriptionId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            $match.Groups['resourceGroup'].Value,
            [string] $Scope.resourceGroupName,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "$ArtifactName resource '$ResourceId' is outside the approved scope."
    }
}

function Assert-AdltBoundRunArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Artifact,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [string] $ArtifactName
    )

    if ($Artifact.runId -cne $State.runId) {
        throw "$ArtifactName run ID does not match the verified run state."
    }
    if ($Artifact.planHash -cne $State.planHash) {
        throw "$ArtifactName plan hash does not match the verified run state."
    }
    if ($Artifact.intentHash -cne $State.intentHash) {
        throw "$ArtifactName intent hash does not match the verified run state."
    }
}

function Assert-AdltStateEvidenceReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [string] $ExpectedStage
    )

    $stageReferences = @(
        $State.evidenceReferences |
            Where-Object { $_.stage -ceq $ExpectedStage }
    )
    if (
        $stageReferences.Count -ne 1 -or
        $stageReferences[0].evidenceHash -cne $Evidence.evidenceHash
    ) {
        throw "'$ExpectedStage' evidence is not committed exactly once in the verified run state."
    }
}

function Assert-AdltAuthorizationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [string] $ExpectedStage,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9]*Hash$')]
        [string] $AuthorizationHashProperty
    )

    Assert-AdltEvidence -Evidence $Evidence
    Assert-AdltBoundRunArtifact `
        -Artifact $Evidence `
        -State $State `
        -ArtifactName "$ExpectedStage evidence"

    if ($Evidence.stage -cne $ExpectedStage) {
        throw "Expected '$ExpectedStage' evidence, but received '$($Evidence.stage)'."
    }
    if ($Evidence.status -cne 'pass') {
        throw "'$ExpectedStage' evidence must have pass status before authorization."
    }
    Assert-AdltStateEvidenceReference `
        -State $State `
        -Evidence $Evidence `
        -ExpectedStage $ExpectedStage

    return [ordered]@{
        HashProperty = $AuthorizationHashProperty
        Hash         = [string] $Evidence.evidenceHash
        CompletedAt  = [datetimeoffset]::Parse(
            [string] $Evidence.completedAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
}

function Get-AdltAuthorizationActionBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('deploy')]
        [string] $Operation,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [string[]] $ActionIds
    )

    $actionsById = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal
    )
    $resourceIdByStableId =
        [System.Collections.Generic.Dictionary[string, string]]::new(
            [System.StringComparer]::Ordinal
        )
    $expectedActionIds = [System.Collections.Generic.List[string]]::new()

    foreach ($action in @($Plan.actions)) {
        $actionsById.Add([string] $action.id, $action)
        if ([bool] $action.mutation) {
            $expectedActionIds.Add([string] $action.id)
        }
    }
    foreach ($entry in @($LiveResolutionEvidence.payload.resources)) {
        $resourceIdByStableId.Add(
            [string] $entry.stableId,
            [string] $entry.resourceId
        )
    }

    Assert-AdltExactValueSet `
        -Actual $ActionIds `
        -Expected @($expectedActionIds.ToArray()) `
        -Name "Execution authorization $Operation action IDs"

    $seenActionIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $resourceIds = [System.Collections.Generic.List[string]]::new()
    foreach ($actionId in $ActionIds) {
        if (-not $seenActionIds.Add([string] $actionId)) {
            throw "Execution authorization contains duplicate action ID '$actionId'."
        }
        if (-not $actionsById.ContainsKey([string] $actionId)) {
            throw "Execution authorization contains unknown $Operation action '$actionId'."
        }

        $action = $actionsById[[string] $actionId]
        if (-not [bool] $action.mutation) {
            throw "Deploy action '$actionId' is non-mutating and cannot be authorized for execution."
        }
        if (
            -not $resourceIdByStableId.ContainsKey(
                [string] $action.resourceId
            )
        ) {
            throw "Deploy action '$actionId' lacks an exact observed resource ID binding."
        }
        $resourceIds.Add(
            $resourceIdByStableId[[string] $action.resourceId]
        )
        foreach ($dependencyId in @($action.dependsOn)) {
            if (-not $actionsById.ContainsKey([string] $dependencyId)) {
                throw "Deploy action '$actionId' depends on unknown action '$dependencyId'."
            }
            $dependency = $actionsById[[string] $dependencyId]
            if (
                [bool] $dependency.mutation -and
                [string] $dependencyId -notin $ActionIds
            ) {
                throw "Deploy action '$actionId' lacks mutating dependency '$dependencyId'."
            }
        }
    }

    return [ordered]@{
        ActionIds   = @($seenActionIds | Sort-Object)
        ResourceIds = @($resourceIds.ToArray() | Sort-Object -Unique)
    }
}

function Get-AdltTeardownOwnershipClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ObservedStateEvidence
    )

    $containmentRoot = Resolve-AdltPlanResourceId `
        -Plan $Plan `
        -StableId 'azure.resource-group.primary'
    $plannedOwned = [System.Collections.Generic.List[string]]::new()
    $futureOwned = [System.Collections.Generic.List[string]]::new()
    $ownershipProof = [System.Collections.Generic.List[string]]::new()
    $retained = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($ObservedStateEvidence.payload.resources)) {
        if (
            $entry.teardownDisposition -eq
                'inventory-before-exact-delete'
        ) {
            $plannedOwned.Add([string] $entry.resourceId)
            $ownershipProof.Add([string] $entry.resourceId)
            if ($entry.observedOwnership -eq 'future-owned') {
                $futureOwned.Add([string] $entry.resourceId)
            }
        }
        elseif (
            $entry.teardownDisposition -eq 'retain-resource-group'
        ) {
            if ([string] $entry.resourceId -cne $containmentRoot) {
                throw 'Cleanup intent retains an unexpected resource group.'
            }
            $retained.Add([string] $entry.resourceId)
            $ownershipProof.Add([string] $entry.resourceId)
        }
        else {
            $retained.Add([string] $entry.resourceId)
        }
    }

    if (
        $plannedOwned.Count -eq 0 -or
        $containmentRoot -notin @($retained.ToArray())
    ) {
        throw 'Cleanup intent must retain its resource group and own resources.'
    }

    return [ordered]@{
        ResourceGroupId = $containmentRoot
        PlannedOwnedResourceIds = @(
            $plannedOwned.ToArray() | Sort-Object
        )
        FutureOwnedResourceIds = @($futureOwned.ToArray() | Sort-Object)
        OwnershipProofRequiredResourceIds = @(
            $ownershipProof.ToArray() | Sort-Object
        )
        RetainedResourceIds = @($retained.ToArray() | Sort-Object)
    }
}

function Assert-AdltTeardownPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $TeardownPlan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ObservedStateEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $WhatIfEvidence,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow
    )

    Assert-AdltPlanContract -Plan $Plan
    Assert-AdltRunState -State $State
    Assert-AdltArtifactContract `
        -Artifact $TeardownPlan `
        -ExpectedKind 'AzureDataLabTeardownPlan' `
        -HashProperty 'teardownPlanHash' `
        -SchemaFileName 'teardown-plan.schema.json'

    if ($State.planHash -cne $Plan.planHash) {
        throw 'Run state plan hash does not match the supplied plan.'
    }
    if ($State.intentHash -cne $Plan.intentHash) {
        throw 'Run state intent hash does not match the supplied plan.'
    }

    $expectedScope = Get-AdltPlanScope -Plan $Plan
    Assert-AdltScopeBinding `
        -Actual $State.scope `
        -Expected $expectedScope `
        -ArtifactName 'Run state'
    Assert-AdltScopeBinding `
        -Actual $TeardownPlan.scope `
        -Expected $expectedScope `
        -ArtifactName 'Teardown plan'

    if ($TeardownPlan.runId -cne $State.runId) {
        throw 'Teardown plan run ID does not match the verified run state.'
    }
    if ($TeardownPlan.sourcePlanHash -cne $Plan.planHash) {
        throw 'Teardown plan source plan hash does not match the supplied plan.'
    }
    if ($TeardownPlan.intentHash -cne $Plan.intentHash) {
        throw 'Teardown plan intent hash does not match the supplied plan.'
    }

    Assert-AdltTeardownPreviewEvidenceForPlan `
        -Evidence $ObservedStateEvidence `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -WhatIfEvidence $WhatIfEvidence
    Assert-AdltBoundRunArtifact `
        -Artifact $ObservedStateEvidence `
        -State $State `
        -ArtifactName 'Teardown preview evidence'
    if ($ObservedStateEvidence.stage -cne 'teardown-preview') {
        throw 'Observed state evidence must use the teardown-preview stage.'
    }
    Assert-AdltStateEvidenceReference `
        -State $State `
        -Evidence $ObservedStateEvidence `
        -ExpectedStage 'teardown-preview'
    if (
        $TeardownPlan.observedStateEvidenceHash -cne
        $ObservedStateEvidence.evidenceHash
    ) {
        throw 'Teardown plan observed state evidence hash does not match the supplied evidence.'
    }

    $hasBlockers = @($TeardownPlan.blockers).Count -gt 0
    if (-not $hasBlockers -and $ObservedStateEvidence.status -cne 'pass') {
        throw 'A cleanup intent requires passing teardown-preview evidence.'
    }
    if ($hasBlockers -and $ObservedStateEvidence.status -eq 'pass') {
        throw 'A blocked teardown plan cannot claim passing teardown-preview evidence.'
    }

    $ownership = Get-AdltTeardownOwnershipClassification `
        -Plan $Plan `
        -ObservedStateEvidence $ObservedStateEvidence
    if (
        $TeardownPlan.resourceGroupId -cne
            $ownership.ResourceGroupId -or
        $TeardownPlan.strategy -cne 'exact-resource-ids' -or
        -not [bool] $TeardownPlan.retainResourceGroup -or
        -not [bool] $TeardownPlan.freshInventoryRequired
    ) {
        throw 'Cleanup intent does not match the exact-resource safety profile.'
    }
    Assert-AdltExactValueSet `
        -Actual @($TeardownPlan.plannedOwnedResourceIds) `
        -Expected @($ownership.PlannedOwnedResourceIds) `
        -Name 'Cleanup-intent planned owned resource IDs'
    Assert-AdltExactValueSet `
        -Actual @($TeardownPlan.futureOwnedResourceIds) `
        -Expected @($ownership.FutureOwnedResourceIds) `
        -Name 'Cleanup-intent future-owned resource IDs'
    Assert-AdltExactValueSet `
        -Actual @($TeardownPlan.ownershipProofRequiredResourceIds) `
        -Expected @($ownership.OwnershipProofRequiredResourceIds) `
        -Name 'Cleanup-intent ownership-proof resource IDs'
    Assert-AdltExactValueSet `
        -Actual @($TeardownPlan.retainedResourceIds) `
        -Expected @($ownership.RetainedResourceIds) `
        -Name 'Cleanup-intent retained resource IDs'

    $allClassified = @(
        @($TeardownPlan.plannedOwnedResourceIds) +
        @($TeardownPlan.retainedResourceIds)
    )
    $classifiedSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($resourceId in $allClassified) {
        if (-not $classifiedSet.Add([string] $resourceId)) {
            throw "Cleanup-intent resource sets overlap at '$resourceId'."
        }
    }
    Assert-AdltResourceIdInScope `
        -ResourceId $TeardownPlan.resourceGroupId `
        -Scope $expectedScope `
        -ArtifactName 'Cleanup intent'
    foreach ($resourceId in @($TeardownPlan.plannedOwnedResourceIds)) {
        Assert-AdltResourceIdInScope `
            -ResourceId $resourceId `
            -Scope $expectedScope `
            -ArtifactName 'Cleanup intent'
        if (
            -not (Test-AdltResourceIdContainedBy `
                -ResourceId $resourceId `
                -ContainmentRootResourceId $TeardownPlan.resourceGroupId)
        ) {
            throw "Planned cleanup resource '$resourceId' is outside its resource group."
        }
    }
    if (
        $TeardownPlan.resourceGroupId -notin
            @($TeardownPlan.retainedResourceIds)
    ) {
        throw 'Cleanup intent must retain the resource group.'
    }

    $createdAt = [datetimeoffset]::Parse(
        [string] $TeardownPlan.createdAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $expiresAt = [datetimeoffset]::Parse(
        [string] $TeardownPlan.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $evidenceCompletedAt = [datetimeoffset]::Parse(
        [string] $ObservedStateEvidence.completedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $stateExpiresAt = [datetimeoffset]::Parse(
        [string] $State.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if ($createdAt -lt $evidenceCompletedAt) {
        throw 'Teardown plan cannot predate its observed state evidence.'
    }
    if ($expiresAt -le $createdAt) {
        throw 'Teardown plan expiresAt must be later than createdAt.'
    }
    if ($expiresAt -gt $stateExpiresAt) {
        throw 'Teardown plan cannot outlive the verified run state.'
    }
    if ($AsOf -lt $createdAt) {
        throw 'Teardown plan is not valid before its creation time.'
    }
    if ($AsOf -ge $expiresAt) {
        throw 'Teardown plan has expired.'
    }
}

function New-AdltTeardownPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ObservedStateEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $WhatIfEvidence,

        [object[]] $Blockers = @(),

        [datetimeoffset] $CreatedAt = [datetimeoffset]::UtcNow,

        [Parameter(Mandatory)]
        [datetimeoffset] $ExpiresAt
    )

    $ownership = Get-AdltTeardownOwnershipClassification `
        -Plan $Plan `
        -ObservedStateEvidence $ObservedStateEvidence
    $teardownPlan = [ordered]@{
        schemaVersion             = '1.0'
        kind                      = 'AzureDataLabTeardownPlan'
        canonicalization          = 'rfc8785'
        runId                     = $State.runId
        scope                     = Get-AdltPlanScope -Plan $Plan
        sourcePlanHash            = $Plan.planHash
        intentHash                = $Plan.intentHash
        observedStateEvidenceHash = $ObservedStateEvidence.evidenceHash
        resourceGroupId           = $ownership.ResourceGroupId
        strategy                  = 'exact-resource-ids'
        retainResourceGroup       = $true
        freshInventoryRequired    = $true
        plannedOwnedResourceIds   = @(
            $ownership.PlannedOwnedResourceIds
        )
        futureOwnedResourceIds    = @($ownership.FutureOwnedResourceIds)
        ownershipProofRequiredResourceIds = @(
            $ownership.OwnershipProofRequiredResourceIds
        )
        retainedResourceIds       = @($ownership.RetainedResourceIds)
        blockers                  = @(
            $Blockers |
                ForEach-Object { ConvertTo-AdltDictionary -InputObject $_ }
        )
        createdAt                 = ConvertTo-AdltUtcTimestamp -Value $CreatedAt
        expiresAt                 = ConvertTo-AdltUtcTimestamp -Value $ExpiresAt
    }
    $teardownPlan.teardownPlanHash = Get-AdltArtifactHash `
        -Artifact $teardownPlan `
        -HashProperty 'teardownPlanHash'

    Assert-AdltTeardownPlan `
        -TeardownPlan $teardownPlan `
        -Plan $Plan `
        -State $State `
        -ObservedStateEvidence $ObservedStateEvidence `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -WhatIfEvidence $WhatIfEvidence `
        -AsOf $CreatedAt
    return $teardownPlan
}

function Assert-AdltExecutionAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Authorization,

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
        [System.Collections.IDictionary] $TeardownPlan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ObservedStateEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow
    )

    Assert-AdltPlanContract -Plan $Plan
    Assert-AdltRunState -State $State
    Assert-AdltArtifactContract `
        -Artifact $Authorization `
        -ExpectedKind 'AzureDataLabExecutionAuthorization' `
        -HashProperty 'authorizationHash' `
        -SchemaFileName 'execution-authorization.schema.json'
    Assert-AdltSqlVmArmCompilation `
        -Compilation $Compilation `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    Assert-AdltRuntimeAuthorizationBinding -Authorization $Authorization
    $requiredStateStatus = if ($Authorization.operation -eq 'deploy') {
        'authorizing'
    }
    else {
        $null
    }
    if (
        $State.mode -cne 'local' -or
        $null -eq $requiredStateStatus -or
        $State.status -cne $requiredStateStatus
    ) {
        throw "Operation '$($Authorization.operation)' is not valid for the verified run-state mode and status."
    }
    Assert-AdltTeardownPlan `
        -TeardownPlan $TeardownPlan `
        -Plan $Plan `
        -State $State `
        -ObservedStateEvidence $ObservedStateEvidence `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -WhatIfEvidence $WhatIfEvidence `
        -AsOf $AsOf

    if (@($TeardownPlan.blockers).Count -gt 0) {
        throw 'Execution cannot be authorized while the teardown plan has blockers.'
    }
    if ($Authorization.runId -cne $State.runId) {
        throw 'Execution authorization run ID does not match the verified run state.'
    }
    if ($Authorization.planHash -cne $Plan.planHash) {
        throw 'Execution authorization plan hash does not match the supplied plan.'
    }
    if ($Authorization.intentHash -cne $Plan.intentHash) {
        throw 'Execution authorization intent hash does not match the supplied plan.'
    }
    if ($Authorization.teardownPlanHash -cne $TeardownPlan.teardownPlanHash) {
        throw 'Execution authorization teardown plan hash does not match the supplied teardown plan.'
    }
    if (
        $Authorization.executionArtifactDigest -cne
            $Compilation.executionArtifactDigest -or
        (ConvertTo-AdltCanonicalJson -InputObject $Authorization.engine) -cne
            (ConvertTo-AdltCanonicalJson -InputObject $Compilation.engine)
    ) {
        throw 'Execution authorization is not bound to the verified compiler artifact and engine.'
    }

    $expectedScope = Get-AdltPlanScope -Plan $Plan
    Assert-AdltScopeBinding `
        -Actual $State.scope `
        -Expected $expectedScope `
        -ArtifactName 'Run state'
    Assert-AdltScopeBinding `
        -Actual $Authorization.scope `
        -Expected $expectedScope `
        -ArtifactName 'Execution authorization'

    $tailEventReference = @(
        $State.eventReferences |
            Sort-Object { [int] $_.sequence }
    )[-1]
    if (
        [string] $Authorization.stateBinding.stateHash -cne
            [string] $State.stateHash -or
        [int] $Authorization.stateBinding.generation -ne
            [int] $State.generation -or
        [int] $Authorization.stateBinding.eventSequence -ne
            [int] $tailEventReference.sequence -or
        [string] $Authorization.stateBinding.eventHash -cne
            [string] $tailEventReference.eventHash
    ) {
        throw 'Execution authorization is not bound to the current verified run-state tail.'
    }

    Assert-AdltLiveResolutionEvidenceForPlan `
        -Evidence $LiveResolutionEvidence `
        -Plan $Plan
    Assert-AdltBlockingFindingsResolved `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    Assert-AdltWhatIfEvidenceForPlan `
        -Evidence $WhatIfEvidence `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    Assert-AdltCostEvidenceForPlan `
        -Evidence $CostEvidence `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -AuthorizedMaximumMinorUnits (
            [int64] $Authorization.maximumCost.amountMinorUnits
        ) `
        -AuthorizedCurrency ([string] $Authorization.maximumCost.currency)

    $evidenceResults = @(
        Assert-AdltAuthorizationEvidence `
            -Evidence $LiveResolutionEvidence `
            -State $State `
            -ExpectedStage 'live-resolution' `
            -AuthorizationHashProperty 'liveResolutionEvidenceHash'
        Assert-AdltAuthorizationEvidence `
            -Evidence $WhatIfEvidence `
            -State $State `
            -ExpectedStage 'what-if' `
            -AuthorizationHashProperty 'whatIfEvidenceHash'
        Assert-AdltAuthorizationEvidence `
            -Evidence $CostEvidence `
            -State $State `
            -ExpectedStage 'cost' `
            -AuthorizationHashProperty 'costEvidenceHash'
    )
    foreach ($result in $evidenceResults) {
        if (
            [string] $Authorization[$result.HashProperty] -cne
            [string] $result.Hash
        ) {
            throw "Execution authorization $($result.HashProperty) does not match the supplied evidence."
        }
    }

    $actionBinding = Get-AdltAuthorizationActionBinding `
        -Operation $Authorization.operation `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -ActionIds @($Authorization.permittedActionIds)
    Assert-AdltExactValueSet `
        -Actual @($Authorization.permittedActionIds) `
        -Expected @($actionBinding.ActionIds) `
        -Name 'Execution authorization action IDs'
    Assert-AdltExactValueSet `
        -Actual @($Authorization.permittedResourceIds) `
        -Expected @($actionBinding.ResourceIds) `
        -Name 'Execution authorization action resource IDs'

    foreach ($resourceId in @($actionBinding.ResourceIds)) {
        Assert-AdltResourceIdInScope `
            -ResourceId $resourceId `
            -Scope $expectedScope `
            -ArtifactName 'Execution authorization'
    }

    $maximumRunCost = $Plan.configuration.cost.maximumRunCost
    if ($null -eq $maximumRunCost) {
        throw 'The plan must define cost.maximumRunCost before execution can be authorized.'
    }
    if (
        $Authorization.maximumCost.currency -cne
        $maximumRunCost.currency
    ) {
        throw 'Execution authorization currency does not match the plan maximum run cost.'
    }
    if (
        [int64] $Authorization.maximumCost.amountMinorUnits -gt
        [int64] $maximumRunCost.amountMinorUnits
    ) {
        throw 'Execution authorization maximum cost exceeds the plan maximum run cost.'
    }
    if (
        [int] $Authorization.maximumRuntimeMinutes -gt
        [int] $Plan.configuration.lifecycle.maximumRuntimeMinutes
    ) {
        throw 'Execution authorization maximum runtime exceeds the plan limit.'
    }

    if (
        -not $WhatIfEvidence.payload.Contains('executionArtifactDigest') -or
        [string] $WhatIfEvidence.payload.executionArtifactDigest -cne
            [string] $Authorization.executionArtifactDigest
    ) {
        throw 'Execution authorization is not bound to the exact artifact used by native WhatIf.'
    }
    if (
        [string] $Authorization.approval.approver.id -cne
        [string] $LiveResolutionEvidence.payload.principalObjectId
    ) {
        throw 'Execution approval identity does not match the verified Azure principal.'
    }
    if (
        $Authorization.operation -eq 'deploy' -and
        (
            $Authorization.approval.approver.type -cne 'user' -or
            $Authorization.approval.mechanism -cne 'interactive' -or
            $LiveResolutionEvidence.payload.principalType -cne 'user'
        )
    ) {
        throw 'Deployment approval requires the verified interactive Azure user.'
    }

    Assert-AdltExactValueSet `
        -Actual @($Authorization.acknowledgementIds) `
        -Expected @($Plan.approval.requiredAcknowledgementIds) `
        -Name 'Execution authorization acknowledgement IDs'

    $approvedAt = [datetimeoffset]::Parse(
        [string] $Authorization.approval.approvedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $createdAt = [datetimeoffset]::Parse(
        [string] $Authorization.createdAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $expiresAt = [datetimeoffset]::Parse(
        [string] $Authorization.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $teardownCreatedAt = [datetimeoffset]::Parse(
        [string] $TeardownPlan.createdAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $teardownExpiresAt = [datetimeoffset]::Parse(
        [string] $TeardownPlan.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $stateExpiresAt = [datetimeoffset]::Parse(
        [string] $State.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    foreach ($evidenceResult in $evidenceResults) {
        if ($approvedAt -lt $evidenceResult.CompletedAt) {
            throw 'Execution approval cannot predate required evidence.'
        }
    }
    if ($approvedAt -lt $teardownCreatedAt) {
        throw 'Execution approval cannot predate the teardown plan.'
    }
    if ($createdAt -lt $approvedAt) {
        throw 'Execution authorization cannot predate its approval.'
    }
    if ($expiresAt -le $createdAt) {
        throw 'Execution authorization expiresAt must be later than createdAt.'
    }
    if ($expiresAt -gt $teardownExpiresAt -or $expiresAt -gt $stateExpiresAt) {
        throw 'Execution authorization cannot outlive its teardown plan or run state.'
    }
    if ($AsOf -lt $createdAt) {
        throw 'Execution authorization is not valid before its creation time.'
    }
    if ($AsOf -ge $expiresAt) {
        throw 'Execution authorization has expired.'
    }
}

function New-AdltExecutionAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('deploy')]
        [string] $Operation,

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
        [System.Collections.IDictionary] $TeardownPlan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ObservedStateEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Approval,

        [Parameter(Mandatory)]
        [ValidateRange(0, 1000000000000)]
        [int64] $MaximumCostMinorUnits,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z]{3}$')]
        [string] $MaximumCostCurrency,

        [Parameter(Mandatory)]
        [ValidateRange(30, 720)]
        [int] $MaximumRuntimeMinutes,

        [string[]] $AcknowledgementIds = @(),

        [datetimeoffset] $CreatedAt = [datetimeoffset]::UtcNow,

        [Parameter(Mandatory)]
        [datetimeoffset] $ExpiresAt
    )

    Assert-AdltSqlVmArmCompilation `
        -Compilation $Compilation `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    $runtimeIdentity = Get-AdltRuntimeIdentity
    $candidateActionIds = @(
        $Plan.actions |
            Where-Object mutation |
            ForEach-Object id
    )
    $actionBinding = Get-AdltAuthorizationActionBinding `
        -Operation $Operation `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -ActionIds $candidateActionIds
    $tailEventReference = @(
        $State.eventReferences |
            Sort-Object { [int] $_.sequence }
    )[-1]
    $authorization = [ordered]@{
        schemaVersion              = '1.0'
        kind                       = 'AzureDataLabExecutionAuthorization'
        canonicalization           = 'rfc8785'
        operation                  = $Operation
        runId                      = $State.runId
        planHash                   = $Plan.planHash
        intentHash                 = $Plan.intentHash
        liveResolutionEvidenceHash = $LiveResolutionEvidence.evidenceHash
        whatIfEvidenceHash         = $WhatIfEvidence.evidenceHash
        costEvidenceHash           = $CostEvidence.evidenceHash
        teardownPlanHash           = $TeardownPlan.teardownPlanHash
        executionArtifactDigest    = $Compilation.executionArtifactDigest
        module                     = Copy-AdltValue -InputObject $runtimeIdentity.module
        commit                     = $runtimeIdentity.commit
        engine                     = Copy-AdltValue -InputObject $Compilation.engine
        runtime                    = [ordered]@{
            powershell   = Copy-AdltValue -InputObject $runtimeIdentity.powershell
            dependencies = @(
                $runtimeIdentity.dependencies |
                    ForEach-Object {
                        Copy-AdltValue -InputObject $_
                    }
            )
        }
        scope                      = Get-AdltPlanScope -Plan $Plan
        stateBinding               = [ordered]@{
            stateHash     = $State.stateHash
            generation    = [int] $State.generation
            eventSequence = [int] $tailEventReference.sequence
            eventHash     = [string] $tailEventReference.eventHash
        }
        permittedActionIds         = @(
            $actionBinding.ActionIds
        )
        permittedResourceIds       = @(
            $actionBinding.ResourceIds
        )
        approval                   = Copy-AdltValue -InputObject $Approval
        createdAt                  = ConvertTo-AdltUtcTimestamp -Value $CreatedAt
        expiresAt                  = ConvertTo-AdltUtcTimestamp -Value $ExpiresAt
        maximumCost                = [ordered]@{
            amountMinorUnits = $MaximumCostMinorUnits
            currency         = $MaximumCostCurrency
        }
        maximumRuntimeMinutes      = $MaximumRuntimeMinutes
        acknowledgementIds         = @(
            $AcknowledgementIds | Sort-Object -Unique
        )
    }
    $authorization.authorizationHash = Get-AdltArtifactHash `
        -Artifact $authorization `
        -HashProperty 'authorizationHash'

    Assert-AdltExecutionAuthorization `
        -Authorization $authorization `
        -Plan $Plan `
        -State $State `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -WhatIfEvidence $WhatIfEvidence `
        -CostEvidence $CostEvidence `
        -TeardownPlan $TeardownPlan `
        -ObservedStateEvidence $ObservedStateEvidence `
        -Compilation $Compilation `
        -AsOf $CreatedAt
    return $authorization
}
