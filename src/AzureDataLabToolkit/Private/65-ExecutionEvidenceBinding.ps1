function Get-AdltEvidenceCompletedAt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence
    )

    return [datetimeoffset]::Parse(
        [string] $Evidence.completedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Assert-AdltNormalizedPayloadHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Value,

        [Parameter(Mandatory)]
        [string] $HashProperty,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not $Value.Contains($HashProperty)) {
        throw "$Name lacks $HashProperty."
    }
    $candidate = Copy-AdltValue -InputObject $Value
    $actualHash = [string] $candidate[$HashProperty]
    $candidate.Remove($HashProperty)
    $expectedHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $candidate
    )
    if ($actualHash -cne $expectedHash) {
        throw "$Name $HashProperty does not match its normalized payload."
    }
}

function Test-AdltResourceIdContainedBy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $ContainmentRootResourceId
    )

    $root = $ContainmentRootResourceId.TrimEnd('/')
    return (
        [string]::Equals(
            $ResourceId,
            $root,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $ResourceId.StartsWith(
            "$root/",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Get-AdltDictionaryByProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Items,

        [Parameter(Mandatory)]
        [string] $PropertyName,

        [Parameter(Mandatory)]
        [string] $ArtifactName,

        [switch] $CaseInsensitive
    )

    $comparer = if ($CaseInsensitive) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparer]::Ordinal
    }
    $result = [System.Collections.Generic.Dictionary[string, object]]::new(
        $comparer
    )
    foreach ($item in $Items) {
        $dictionary = ConvertTo-AdltDictionary -InputObject $item
        $value = [string] $dictionary[$PropertyName]
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "$ArtifactName contains an empty $PropertyName."
        }
        if (-not $result.TryAdd($value, $dictionary)) {
            throw "$ArtifactName contains duplicate $PropertyName '$value'."
        }
    }
    return $result
}

function Assert-AdltLiveResolutionEvidenceForPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    Assert-AdltEvidence -Evidence $Evidence
    if (
        $Evidence.stage -cne 'live-resolution' -or
        $Evidence.status -cne 'pass'
    ) {
        throw 'Execution requires passing live-resolution evidence.'
    }
    if (
        $Evidence.planHash -cne $Plan.planHash -or
        $Evidence.intentHash -cne $Plan.intentHash
    ) {
        throw 'Live-resolution evidence is not bound to the supplied plan.'
    }
    $completedAt = Get-AdltEvidenceCompletedAt -Evidence $Evidence
    $now = [datetimeoffset]::UtcNow
    if (
        $completedAt -lt $now.AddMinutes(-15) -or
        $completedAt -gt $now.AddMinutes(2)
    ) {
        throw 'Live-resolution evidence is outside the 15-minute execution freshness window.'
    }

    $expectedContext = [ordered]@{
        cloud          = [string] $Plan.context.cloud
        tenantId       = [string] $Plan.context.tenantId
        subscriptionId = [string] $Plan.context.subscriptionId
    }
    foreach ($property in $expectedContext.Keys) {
        if (
            [string] $Evidence.payload.context[$property] -cne
            [string] $expectedContext[$property]
        ) {
            throw "Live-resolution context.$property does not match the plan."
        }
    }

    $expectedResources = Get-AdltDictionaryByProperty `
        -Items @(Get-AdltResolvedResourceIdSet -Plan $Plan) `
        -PropertyName stableId `
        -ArtifactName 'Expected resolved resource set'
    $actualResources = Get-AdltDictionaryByProperty `
        -Items @($Evidence.payload.resources) `
        -PropertyName stableId `
        -ArtifactName 'Live-resolution resource set'
    if ($actualResources.Count -ne $expectedResources.Count) {
        throw 'Live-resolution resource set does not exactly match the plan.'
    }
    foreach ($stableId in $expectedResources.Keys) {
        if (-not $actualResources.ContainsKey($stableId)) {
            throw "Live-resolution evidence is missing resource '$stableId'."
        }
        if (
            (ConvertTo-AdltCanonicalJson -InputObject $actualResources[$stableId]) -cne
            (ConvertTo-AdltCanonicalJson -InputObject $expectedResources[$stableId])
        ) {
            throw "Live-resolution resource '$stableId' does not match independent ID resolution."
        }
    }

    $expectedProviders = @(Get-AdltProviderNamespaceSet -Plan $Plan)
    $providerStates = Get-AdltDictionaryByProperty `
        -Items @($Evidence.payload.providerStates) `
        -PropertyName namespace `
        -ArtifactName 'Live-resolution provider set' `
        -CaseInsensitive
    Assert-AdltExactValueSet `
        -Actual @($providerStates.Keys) `
        -Expected $expectedProviders `
        -Name 'Live-resolution provider namespaces'
    foreach ($provider in $providerStates.Values) {
        if ($provider.registrationState -cne 'Registered') {
            throw "Azure provider '$($provider.namespace)' is not registered."
        }
    }

    $vm = Get-AdltPlanResource `
        -Plan $Plan `
        -StableId 'azure.compute.virtual-machine.primary'
    $expectedImage = $vm.desiredProperties.imageReference
    $resolvedImage = $Evidence.payload.imageResolution
    if ($resolvedImage -isnot [System.Collections.IDictionary]) {
        throw 'Live-resolution evidence lacks an immutable VM image resolution.'
    }
    foreach ($property in @('publisher', 'offer', 'sku')) {
        if (
            [string] $resolvedImage[$property] -cne
            [string] $expectedImage[$property]
        ) {
            throw "Resolved VM image $property does not match the plan."
        }
    }
    if (
        [string]::IsNullOrWhiteSpace([string] $resolvedImage.version) -or
        [string] $resolvedImage.version -ceq 'latest'
    ) {
        throw 'Resolved VM image version must be immutable.'
    }
    if (
        [string] $resolvedImage.hyperVGeneration -cne 'V2' -or
        -not [bool] $resolvedImage.trustedLaunchSupported
    ) {
        throw 'Resolved VM image does not prove Trusted Launch support.'
    }
    Assert-AdltNormalizedPayloadHash `
        -Value $resolvedImage `
        -HashProperty imageMetadataHash `
        -Name 'Live-resolution image'

    $resolvedSku = $Evidence.payload.skuResolution
    if (
        $resolvedSku -isnot [System.Collections.IDictionary] -or
        [string] $resolvedSku.name -cne
            [string] $vm.desiredProperties.hardwareProfile.vmSize -or
        [string] $resolvedSku.location -cne [string] $Plan.context.location -or
        -not [bool] $resolvedSku.available -or
        -not [bool] $resolvedSku.encryptionAtHostSupported -or
        -not [bool] $resolvedSku.trustedLaunchSupported -or
        -not [bool] $resolvedSku.hyperVGenerationV2
    ) {
        throw 'Live-resolution VM SKU does not satisfy the secure first-canary profile.'
    }
    Assert-AdltNormalizedPayloadHash `
        -Value $resolvedSku `
        -HashProperty resourceSkuHash `
        -Name 'Live-resolution VM SKU'
    if (
        [string] $Evidence.payload.principalObjectId -notmatch
        '^[0-9a-fA-F-]{36}$' -or
        [string] $Evidence.payload.principalType -cne 'user'
    ) {
        throw 'Live-resolution evidence lacks a verified user deployment principal.'
    }

    $vaultId = [string] $Plan.configuration.security.secretStore.resourceId
    $vaultResolution = $Evidence.payload.keyVaultResolution
    if (
        $vaultResolution -isnot [System.Collections.IDictionary] -or
        [string] $vaultResolution.resourceId -cne $vaultId -or
        [string] $vaultResolution.apiVersion -cne '2026-02-01' -or
        [string] $vaultResolution.tenantId -cne
            [string] $Plan.context.tenantId -or
        [string] $vaultResolution.provisioningState -cne 'Succeeded' -or
        -not [bool] $vaultResolution.enableRbacAuthorization -or
        -not [bool] $vaultResolution.enabledForTemplateDeployment -or
        -not [bool] $vaultResolution.purgeProtectionEnabled -or
        [int] $vaultResolution.softDeleteRetentionDays -lt 7 -or
        [int] $vaultResolution.softDeleteRetentionDays -gt 90 -or
        [string] $vaultResolution.publicNetworkAccess -cne 'Disabled' -or
        [string] $vaultResolution.networkDefaultAction -cne 'Deny' -or
        [int] $vaultResolution.approvedPrivateEndpointCount -lt 1
    ) {
        throw 'Live-resolution Key Vault evidence does not satisfy the plan.'
    }
    Assert-AdltNormalizedPayloadHash `
        -Value $vaultResolution `
        -HashProperty resourceStateHash `
        -Name 'Live-resolution Key Vault'

    $credential = $Plan.configuration.security.vmAdministratorCredential
    $secretMetadata = $Evidence.payload.secretMetadata
    if (
        $secretMetadata -isnot [System.Collections.IDictionary] -or
        [string] $secretMetadata.vaultResourceId -cne $vaultId -or
        [string] $secretMetadata.secretName -cne
            [string] $credential.secretName -or
        [string] $secretMetadata.version -cne
            [string] $credential.secretVersion -or
        -not [bool] $secretMetadata.enabled -or
        -not [bool] $secretMetadata.notBeforeSatisfied -or
        -not [bool] $secretMetadata.expiresAfterMinimumWindow
    ) {
        throw 'Live-resolution secret metadata is not bound to the pinned credential.'
    }
    Assert-AdltNormalizedPayloadHash `
        -Value $secretMetadata `
        -HashProperty metadataHash `
        -Name 'Live-resolution secret metadata'

    $diagnosticResolution = $Evidence.payload.diagnosticResolution
    $expectedDiagnosticDestination = [string] (
        Get-AdltPathValue `
            -InputObject $Plan.configuration `
            -Path 'security.secretStore.diagnosticDestinationResourceId'
    )
    if (
        $diagnosticResolution -isnot [System.Collections.IDictionary] -or
        [string] $diagnosticResolution.destinationResourceId -cne
            $expectedDiagnosticDestination -or
        -not [bool] $diagnosticResolution.auditEnabled
    ) {
        throw 'Live-resolution Key Vault diagnostics do not match the approved destination.'
    }
    Assert-AdltNormalizedPayloadHash `
        -Value $diagnosticResolution `
        -HashProperty settingsHash `
        -Name 'Live-resolution Key Vault diagnostics'

    Assert-AdltExactValueSet `
        -Actual @(
            $Evidence.payload.requiredAuthorizations |
                ForEach-Object {
                    '{0}|{1}' -f $_.action, $_.validationStage
                }
        ) `
        -Expected @(
            'Microsoft.KeyVault/vaults/deploy/action|native-provider-what-if'
        ) `
        -Name 'Live-resolution required authorization declarations'
}

function Assert-AdltWhatIfEvidenceForPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence
    )

    Assert-AdltEvidence -Evidence $Evidence
    if ($Evidence.stage -cne 'what-if' -or $Evidence.status -cne 'pass') {
        throw 'Execution requires passing WhatIf evidence.'
    }
    if (
        $Evidence.planHash -cne $Plan.planHash -or
        $Evidence.intentHash -cne $Plan.intentHash -or
        $Evidence.payload.liveResolutionEvidenceHash -cne
            $LiveResolutionEvidence.evidenceHash
    ) {
        throw 'WhatIf evidence lineage does not match the plan and live resolution.'
    }
    if (
        (Get-AdltEvidenceCompletedAt -Evidence $Evidence) -lt
        (Get-AdltEvidenceCompletedAt -Evidence $LiveResolutionEvidence)
    ) {
        throw 'WhatIf evidence cannot predate live-resolution evidence.'
    }
    $whatIfCompletedAt = Get-AdltEvidenceCompletedAt -Evidence $Evidence
    $now = [datetimeoffset]::UtcNow
    if (
        $whatIfCompletedAt -lt $now.AddMinutes(-15) -or
        $whatIfCompletedAt -gt $now.AddMinutes(2)
    ) {
        throw 'WhatIf evidence is outside the 15-minute execution freshness window.'
    }

    $resolvedResources = Get-AdltDictionaryByProperty `
        -Items @($LiveResolutionEvidence.payload.resources) `
        -PropertyName stableId `
        -ArtifactName 'Live-resolution resource set'
    $results = Get-AdltDictionaryByProperty `
        -Items @($Evidence.payload.results) `
        -PropertyName stableId `
        -ArtifactName 'WhatIf result set'
    if ($results.Count -ne @($Plan.resources).Count) {
        throw 'WhatIf result set does not exactly match the plan resources.'
    }

    foreach ($resourceObject in @($Plan.resources)) {
        $resource = ConvertTo-AdltDictionary -InputObject $resourceObject
        $stableId = [string] $resource.id
        if (
            -not $results.ContainsKey($stableId) -or
            -not $resolvedResources.ContainsKey($stableId)
        ) {
            throw "WhatIf evidence is missing resource '$stableId'."
        }
        $result = $results[$stableId]
        if (
            [string] $result.resourceId -cne
                [string] $resolvedResources[$stableId].resourceId -or
            [string] $result.resourceType -cne [string] $resource.type -or
            [string] $result.plannedOwnership -cne
                [string] $resource.ownership.expectedClassification -or
            [string] $result.desiredHash -cne
                (Get-AdltDesiredResourceHash -Resource $resource)
        ) {
            throw "WhatIf resource '$stableId' is not exactly bound to the plan."
        }

        $allowedClassifications = if (
            $resource.ownership.expectedClassification -in @('reused', 'external')
        ) {
            @('reuse')
        }
        else {
            @('create', 'no-change')
        }
        if ([string] $result.classification -notin $allowedClassifications) {
            throw "WhatIf resource '$stableId' is not safe to execute."
        }
    }

    $compilation = New-AdltSqlVmArmCompilation `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    if (
        [string] $Evidence.payload.executionArtifactDigest -cne
            [string] $compilation.executionArtifactDigest -or
        [string] $Evidence.payload.templateHash -cne
            [string] $compilation.templateHash
    ) {
        throw 'WhatIf evidence is not bound to deterministic ARM compilation.'
    }
    $parameterReferenceHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson `
            -InputObject $compilation.parameterReference
    )
    $parameterDocument = New-AdltSqlVmArmParameterDocument `
        -Compilation $compilation
    $parameterFileHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $parameterDocument
    )
    $scope = '/subscriptions/{0}' -f [string] $Plan.context.subscriptionId
    $deploymentName = 'adlt-whatif-{0}-{1}' -f
        ([string] $Evidence.runId).Replace(
            '-',
            ''
        ).Substring(0, 8).ToLowerInvariant(),
        ([string] $Plan.planHash).Substring(7, 12)
    if (
        [string] $Evidence.payload.scope -cne $scope -or
        [string] $Evidence.payload.deploymentName -cne $deploymentName -or
        [string] $Evidence.payload.validationLevel -cne 'Provider' -or
        [string] $Evidence.payload.resultFormat -cne 'ResourceIdOnly' -or
        [string] $Evidence.payload.parameterReferenceHash -cne
            $parameterReferenceHash -or
        [string] $Evidence.payload.parameterFileHash -cne
            $parameterFileHash -or
        [string] $Evidence.payload.nativeStatus -cne 'Succeeded' -or
        $null -ne $Evidence.payload.nativeFailureKind -or
        [int] $Evidence.payload.nativePotentialChangeCount -ne 0 -or
        @($Evidence.payload.nativeDiagnostics).Count -ne 0
    ) {
        throw 'WhatIf native provider evidence does not satisfy the execution contract.'
    }
    $invocation = [ordered]@{
        scope                  = $scope
        deploymentName         = $deploymentName
        location               = [string] $Plan.context.location
        validationLevel        = 'Provider'
        resultFormat           = 'ResourceIdOnly'
        templateHash           = [string] $compilation.templateHash
        executionArtifactDigest =
            [string] $compilation.executionArtifactDigest
        parameterReferenceHash = $parameterReferenceHash
        parameterFileHash      = $parameterFileHash
    }
    $expectedInvocationHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $invocation
    )
    if (
        [string] $Evidence.payload.invocationHash -cne
            $expectedInvocationHash
    ) {
        throw 'WhatIf invocation hash does not match the authorized provider call.'
    }
    $nativeChangesHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson `
            -InputObject @($Evidence.payload.nativeChanges)
    )
    if (
        [string] $Evidence.payload.nativeChangesHash -cne
            $nativeChangesHash
    ) {
        throw 'WhatIf native change hash does not match its normalized changes.'
    }
    $nativeResultHash = Get-AdltNativeWhatIfResultHash `
        -Status ([string] $Evidence.payload.nativeStatus) `
        -Changes @($Evidence.payload.nativeChanges) `
        -Diagnostics @($Evidence.payload.nativeDiagnostics) `
        -PotentialChangeCount (
            [int] $Evidence.payload.nativePotentialChangeCount
        ) `
        -ChangesHash ([string] $Evidence.payload.nativeChangesHash) `
        -FailureKind $Evidence.payload.nativeFailureKind
    if (
        [string] $Evidence.payload.nativeWhatIfResultHash -cne
            $nativeResultHash
    ) {
        throw 'WhatIf native result hash does not match its normalized result.'
    }
    $expectedNativeChanges = Get-AdltSqlVmNativeWhatIfExpectedChange `
        -Compilation $compilation `
        -CustomResults @($Evidence.payload.results)
    $nativeResult = [ordered]@{
        status               = [string] $Evidence.payload.nativeStatus
        changes              = @($Evidence.payload.nativeChanges)
        diagnostics          = @($Evidence.payload.nativeDiagnostics)
        potentialChangeCount =
            [int] $Evidence.payload.nativePotentialChangeCount
    }
    Assert-AdltNativeWhatIfChangeSet `
        -NativeResult $nativeResult `
        -ExpectedChanges $expectedNativeChanges
}

function Assert-AdltCostEvidenceForPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [ValidateRange(0, 1000000000000)]
        [int64] $AuthorizedMaximumMinorUnits,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z]{3}$')]
        [string] $AuthorizedCurrency
    )

    Assert-AdltEvidence -Evidence $Evidence
    if ($Evidence.stage -cne 'cost' -or $Evidence.status -cne 'pass') {
        throw 'Execution requires a complete passing cost estimate.'
    }
    if (
        $Evidence.planHash -cne $Plan.planHash -or
        $Evidence.intentHash -cne $Plan.intentHash -or
        $Evidence.payload.liveResolutionEvidenceHash -cne
            $LiveResolutionEvidence.evidenceHash
    ) {
        throw 'Cost evidence lineage does not match the plan and live resolution.'
    }
    if (
        (Get-AdltEvidenceCompletedAt -Evidence $Evidence) -lt
        (Get-AdltEvidenceCompletedAt -Evidence $LiveResolutionEvidence)
    ) {
        throw 'Cost evidence cannot predate live-resolution evidence.'
    }
    if (
        -not [bool] $Evidence.payload.pricingComplete -or
        $Evidence.payload.guardrail.status -cne 'within-limit' -or
        $null -eq $Evidence.payload.totalAmountMinorUnits
    ) {
        throw 'Cost evidence is incomplete or exceeds its configured guardrail.'
    }
    if (
        [string] $Evidence.payload.currency -cne $AuthorizedCurrency -or
        [int64] $Evidence.payload.totalAmountMinorUnits -gt
            $AuthorizedMaximumMinorUnits
    ) {
        throw 'Verified cost exceeds the authorized amount or uses another currency.'
    }
}

function Assert-AdltTeardownPreviewEvidenceForPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $WhatIfEvidence
    )

    Assert-AdltEvidence -Evidence $Evidence
    if (
        $Evidence.stage -cne 'teardown-preview' -or
        $Evidence.status -cne 'pass'
    ) {
        throw 'Execution requires a passing teardown preview.'
    }
    if (
        $Evidence.planHash -cne $Plan.planHash -or
        $Evidence.intentHash -cne $Plan.intentHash -or
        $Evidence.payload.liveResolutionEvidenceHash -cne
            $LiveResolutionEvidence.evidenceHash -or
        $Evidence.payload.whatIfEvidenceHash -cne $WhatIfEvidence.evidenceHash
    ) {
        throw 'Teardown-preview evidence lineage does not match the verified plan.'
    }
    if (
        (Get-AdltEvidenceCompletedAt -Evidence $Evidence) -lt
        (Get-AdltEvidenceCompletedAt -Evidence $WhatIfEvidence)
    ) {
        throw 'Teardown-preview evidence cannot predate WhatIf evidence.'
    }
    if (@($Evidence.payload.blockers).Count -gt 0) {
        throw 'A passing teardown preview cannot contain blockers.'
    }

    $resourceGroupId = Resolve-AdltPlanResourceId `
        -Plan $Plan `
        -StableId 'azure.resource-group.primary'
    if (
        [string] $Evidence.payload.resourceGroupId -cne
        [string] $resourceGroupId
    ) {
        throw 'Teardown-preview resource group is not the planned resource group.'
    }

    $planResources = Get-AdltDictionaryByProperty `
        -Items @($Plan.resources) `
        -PropertyName id `
        -ArtifactName 'Plan resource set'
    $liveResources = Get-AdltDictionaryByProperty `
        -Items @($LiveResolutionEvidence.payload.resources) `
        -PropertyName stableId `
        -ArtifactName 'Live-resolution resource set'
    $whatIfResults = Get-AdltDictionaryByProperty `
        -Items @($WhatIfEvidence.payload.results) `
        -PropertyName stableId `
        -ArtifactName 'WhatIf result set'
    $previewResources = Get-AdltDictionaryByProperty `
        -Items @($Evidence.payload.resources) `
        -PropertyName stableId `
        -ArtifactName 'Teardown-preview resource set'
    if ($previewResources.Count -ne $planResources.Count) {
        throw 'Teardown-preview resource set does not exactly match the plan.'
    }

    foreach ($stableId in $planResources.Keys) {
        if (
            -not $liveResources.ContainsKey($stableId) -or
            -not $whatIfResults.ContainsKey($stableId) -or
            -not $previewResources.ContainsKey($stableId)
        ) {
            throw "Teardown-preview evidence is missing resource '$stableId'."
        }
        $planResource = $planResources[$stableId]
        $liveResource = $liveResources[$stableId]
        $whatIfResult = $whatIfResults[$stableId]
        $preview = $previewResources[$stableId]
        if (
            [string] $preview.resourceId -cne [string] $liveResource.resourceId -or
            [string] $preview.observedState -cne [string] $whatIfResult.observedState
        ) {
            throw "Teardown-preview resource '$stableId' is not bound to observed state."
        }

        $isResourceGroup = $stableId -ceq
            'azure.resource-group.primary'
        $isRetained = $planResource.ownership.teardownIntent -ne
            'delete-after-proof-and-approval'
        if ($isResourceGroup) {
            $expectedOwnership = if (
                $whatIfResult.observedState -eq 'absent'
            ) {
                'future-owned'
            }
            else {
                'owned'
            }
            if (
                $preview.teardownDisposition -cne
                    'retain-resource-group' -or
                -not [bool] $preview.ownershipProofRequired -or
                $preview.observedOwnership -cne $expectedOwnership -or
                [string] $preview.resourceId -cne $resourceGroupId
            ) {
                throw 'The planned resource group must be retained with ownership proof.'
            }
        }
        elseif ($isRetained) {
            if (
                $preview.teardownDisposition -cne 'retain' -or
                [bool] $preview.ownershipProofRequired -or
                $preview.observedOwnership -notin @('reused', 'external') -or
                (Test-AdltResourceIdContainedBy `
                    -ResourceId ([string] $preview.resourceId) `
                    -ContainmentRootResourceId $resourceGroupId)
            ) {
                throw "Retained resource '$stableId' is not safely outside the deletion boundary."
            }
        }
        else {
            $expectedOwnership = if ($whatIfResult.observedState -eq 'absent') {
                'future-owned'
            }
            else {
                'owned'
            }
            if (
                $preview.teardownDisposition -cne
                    'inventory-before-exact-delete' -or
                -not [bool] $preview.ownershipProofRequired -or
                $preview.observedOwnership -cne $expectedOwnership -or
                -not (Test-AdltResourceIdContainedBy `
                    -ResourceId ([string] $preview.resourceId) `
                    -ContainmentRootResourceId $resourceGroupId)
            ) {
                throw "Owned resource '$stableId' is not safely covered by teardown."
            }
        }
    }
}

function Assert-AdltBlockingFindingsResolved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence
    )

    $blockingIds = @($Plan.approval.blockingFindingIds)
    $resolvedIds = @($LiveResolutionEvidence.payload.resolvedPolicyFindingIds)
    Assert-AdltExactValueSet `
        -Actual $resolvedIds `
        -Expected $blockingIds `
        -Name 'Resolved blocking policy finding IDs'
}

function New-AdltPreDeploymentTeardownPreviewEvidence {
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
        [string] $RunId,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Sequence = 0,

        [AllowNull()]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $PreviousEventHash,

        [datetimeoffset] $StartedAt = [datetimeoffset]::UtcNow,

        [datetimeoffset] $CompletedAt = [datetimeoffset]::UtcNow
    )

    Assert-AdltPlanContract -Plan $Plan
    Assert-AdltLiveResolutionEvidenceForPlan `
        -Evidence $LiveResolutionEvidence `
        -Plan $Plan
    Assert-AdltWhatIfEvidenceForPlan `
        -Evidence $WhatIfEvidence `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    if (
        $RunId -cne $LiveResolutionEvidence.runId -or
        $RunId -cne $WhatIfEvidence.runId
    ) {
        throw 'Teardown preview run ID does not match its evidence lineage.'
    }

    $resourceGroupId = Resolve-AdltPlanResourceId `
        -Plan $Plan `
        -StableId 'azure.resource-group.primary'
    $liveResources = Get-AdltDictionaryByProperty `
        -Items @($LiveResolutionEvidence.payload.resources) `
        -PropertyName stableId `
        -ArtifactName 'Live-resolution resource set'
    $whatIfResults = Get-AdltDictionaryByProperty `
        -Items @($WhatIfEvidence.payload.results) `
        -PropertyName stableId `
        -ArtifactName 'WhatIf result set'

    $resources = foreach ($resourceObject in @($Plan.resources | Sort-Object id)) {
        $resource = ConvertTo-AdltDictionary -InputObject $resourceObject
        $stableId = [string] $resource.id
        $resolved = $liveResources[$stableId]
        $whatIf = $whatIfResults[$stableId]
        $retained = $resource.ownership.teardownIntent -ne
            'delete-after-proof-and-approval'

        [ordered]@{
            stableId               = $stableId
            resourceId             = [string] $resolved.resourceId
            observedState          = [string] $whatIf.observedState
            observedOwnership      = if ($retained) {
                [string] $resource.ownership.expectedClassification
            }
            elseif ($whatIf.observedState -eq 'absent') {
                'future-owned'
            }
            else {
                'owned'
            }
            teardownDisposition    = if (
                $stableId -ceq 'azure.resource-group.primary'
            ) {
                'retain-resource-group'
            }
            elseif ($retained) {
                'retain'
            }
            else {
                'inventory-before-exact-delete'
            }
            ownershipProofRequired = (
                -not $retained -or
                $stableId -ceq 'azure.resource-group.primary'
            )
        }
    }

    $evidenceParameters = @{
        RunId       = $RunId
        PlanHash    = $Plan.planHash
        IntentHash  = $Plan.intentHash
        Stage       = 'teardown-preview'
        Status      = 'pass'
        Sequence    = $Sequence
        Payload     = [ordered]@{
            liveResolutionEvidenceHash = $LiveResolutionEvidence.evidenceHash
            whatIfEvidenceHash         = $WhatIfEvidence.evidenceHash
            resourceGroupId            = $resourceGroupId
            resources                  = @($resources)
            blockers                   = @()
        }
        StartedAt   = $StartedAt
        CompletedAt = $CompletedAt
    }
    if (-not [string]::IsNullOrWhiteSpace($PreviousEventHash)) {
        $evidenceParameters.PreviousEventHash = $PreviousEventHash
    }
    $preview = New-AdltEvidence @evidenceParameters
    Assert-AdltTeardownPreviewEvidenceForPlan `
        -Evidence $preview `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -WhatIfEvidence $WhatIfEvidence
    return $preview
}
