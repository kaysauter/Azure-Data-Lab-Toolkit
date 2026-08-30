function Get-AdltObservedResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed
    )

    foreach ($name in @('ResourceId', 'Id')) {
        $value = [string] (
            Get-AdltObjectPropertyValue `
                -InputObject $Observed `
                -Name $name
        )
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    throw 'An Azure inventory resource did not expose a resource ID.'
}

function Get-AdltObservedResourceType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed
    )

    $resourceType = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $Observed `
            -Name 'ResourceType'
    )
    if ([string]::IsNullOrWhiteSpace($resourceType)) {
        $resourceType = [string] (
            Get-AdltObjectPropertyValue `
                -InputObject $Observed `
                -Name 'Type'
        )
    }
    if ([string]::IsNullOrWhiteSpace($resourceType)) {
        throw 'An Azure inventory resource did not expose a resource type.'
    }
    return $resourceType
}

function Get-AdltObservedNestedValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed,

        [Parameter(Mandatory)]
        [string[]] $CandidatePaths
    )

    foreach ($path in $CandidatePaths) {
        $value = Get-AdltNestedPropertyValue `
            -InputObject $Observed `
            -Path ([string[]] $path.Split('.'))
        if ($null -ne $value) {
            return $value
        }
    }
    return $null
}

function Get-AdltObservedResourceEtag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed
    )

    $etag = [string] (
        Get-AdltObservedNestedValue `
            -Observed $Observed `
            -CandidatePaths @(
                'ETag'
                'Etag'
                'Properties.ETag'
                'Properties.Etag'
            )
    )
    if ([string]::IsNullOrWhiteSpace($etag)) {
        return $null
    }
    return $etag
}

function Get-AdltObservedResourceFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed
    )

    $tags = Get-AdltObservedTagSet -Observed $Observed
    $orderedTags = [ordered]@{}
    foreach ($key in @($tags.Keys | Sort-Object)) {
        $orderedTags[[string] $key] = [string] $tags[$key]
    }
    $provisioningState = [string] (
        Get-AdltObservedNestedValue `
            -Observed $Observed `
            -CandidatePaths @(
                'ProvisioningState'
                'Properties.ProvisioningState'
            )
    )
    $location = [string] (
        Get-AdltObservedNestedValue `
            -Observed $Observed `
            -CandidatePaths @(
                'Location'
                'Properties.Location'
            )
    )
    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            resourceId = Get-AdltObservedResourceId -Observed $Observed
            resourceType = Get-AdltObservedResourceType -Observed $Observed
            etag = Get-AdltObservedResourceEtag -Observed $Observed
            location = if ([string]::IsNullOrWhiteSpace($location)) {
                $null
            }
            else {
                $location
            }
            provisioningState = if (
                [string]::IsNullOrWhiteSpace($provisioningState)
            ) {
                $null
            }
            else {
                $provisioningState
            }
            tags = $orderedTags
        })
    )
}

function Get-AdltTeardownInventoryHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Inventory
    )

    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            resourceGroupId        = $Inventory.resourceGroupId
            resourceGroupStatus    = $Inventory.resourceGroupStatus
            resourceGroupProofHash = $Inventory.resourceGroupProofHash
            resourceCount          = [int] $Inventory.resourceCount
            resources              = @($Inventory.resources)
        })
    )
}

function Assert-AdltTeardownInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Inventory,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    Assert-AdltExactValueSet `
        -Actual @($Inventory.Keys) `
        -Expected @(
            'capturedAt'
            'resourceGroupId'
            'resourceGroupStatus'
            'resourceGroupProofHash'
            'resourceCount'
            'resources'
            'inventoryHash'
        ) `
        -Name 'Teardown inventory fields'
    $expectedResourceGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f
        $State.scope.subscriptionId,
        $State.scope.resourceGroupName
    if (
        -not [string]::Equals(
            [string] $Inventory.resourceGroupId,
            $expectedResourceGroupId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $Inventory.resourceGroupStatus -notin @('present', 'absent') -or
        [string] $Inventory.resourceGroupProofHash -notmatch
            '^sha256:[a-f0-9]{64}$' -or
        [string] $Inventory.inventoryHash -notmatch
            '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'Teardown inventory resource-group binding is invalid.'
    }
    if ([int] $Inventory.resourceCount -ne @($Inventory.resources).Count) {
        throw 'Teardown inventory resource count is invalid.'
    }
    if (
        $Inventory.resourceGroupStatus -eq 'absent' -and
        [int] $Inventory.resourceCount -ne 0
    ) {
        throw 'An absent resource group cannot contain inventory resources.'
    }

    $resourceIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $stableIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $previousResourceId = $null
    foreach ($resource in @($Inventory.resources)) {
        Assert-AdltExactValueSet `
            -Actual @($resource.Keys) `
            -Expected @(
                'stableId'
                'resourceId'
                'resourceType'
                'apiVersion'
                'etag'
                'observationFingerprint'
                'relationship'
                'required'
                'proofHash'
            ) `
            -Name 'Teardown inventory resource fields'
        if (
            -not $resourceIds.Add([string] $resource.resourceId) -or
            -not $stableIds.Add([string] $resource.stableId)
        ) {
            throw 'Teardown inventory contains duplicate resource identities.'
        }
        if (
            -not (
                Test-AdltResourceIdContainedBy `
                    -ResourceId $resource.resourceId `
                    -ContainmentRootResourceId $expectedResourceGroupId
            ) -or
            [string] $resource.apiVersion -notmatch
                '^\d{4}-\d{2}-\d{2}(?:-preview)?$' -or
            (
                $null -ne $resource.etag -and
                (
                    $resource.etag -isnot [string] -or
                    [string]::IsNullOrWhiteSpace(
                        [string] $resource.etag
                    )
                )
            ) -or
            [string] $resource.observationFingerprint -notmatch
                '^sha256:[a-f0-9]{64}$' -or
            [string] $resource.proofHash -notmatch
                '^sha256:[a-f0-9]{64}$'
        ) {
            throw "Teardown inventory resource '$($resource.resourceId)' is invalid."
        }
        if (
            $null -ne $previousResourceId -and
            [string]::Compare(
                $previousResourceId,
                [string] $resource.resourceId,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        ) {
            throw 'Teardown inventory resources must be in strict resource-ID order.'
        }
        $previousResourceId = [string] $resource.resourceId
    }
    if (
        $Inventory.inventoryHash -cne
            (Get-AdltTeardownInventoryHash -Inventory $Inventory)
    ) {
        throw 'Teardown inventory hash is invalid.'
    }
}

function Get-AdltSqlVmTeardownExpectedResourceSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation
    )

    $resources = Get-AdltSqlVmArmResourceMap -Plan $Plan
    $contract = Get-AdltSqlVmArmResourceContract
    $expected = [System.Collections.Generic.List[object]]::new()
    foreach ($binding in @($Compilation.resourceBindings)) {
        if (
            $binding.disposition -cne 'deploy' -or
            $binding.stableId -ceq 'azure.resource-group.primary'
        ) {
            continue
        }
        $definition = $contract[[string] $binding.stableId]
        $resource = $resources[[string] $binding.stableId]
        $parentResourceId = $null
        if ($binding.resourceType -ceq
            'Microsoft.Network/virtualNetworks/subnets') {
            $parentResourceId = [string] $binding.resourceId.Substring(
                0,
                [string] $binding.resourceId.IndexOf(
                    '/subnets/',
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            )
        }
        $expected.Add([ordered]@{
            stableId          = [string] $binding.stableId
            resourceId        = [string] $binding.resourceId
            resourceType      = [string] $binding.resourceType
            relationship      = if ([bool] $definition.taggable) {
                'planned-taggable'
            }
            else {
                'planned-descendant'
            }
            required          = $true
            apiVersion        = [string] $resource.apiVersion
            producerResourceId = $parentResourceId
            expectedProperties = [ordered]@{}
        })
    }

    $generatedApiVersions = @{
        'Microsoft.Compute/disks' = '2024-03-02'
        'Microsoft.Resources/deployments' = '2022-09-01'
        'Microsoft.Compute/virtualMachines/extensions' = '2024-03-01'
    }
    foreach ($generated in @($Compilation.expectedGeneratedResources)) {
        $apiVersion = $generatedApiVersions[
            [string] $generated.resourceType
        ]
        if ([string]::IsNullOrWhiteSpace([string] $apiVersion)) {
            throw (
                "Generated resource type '$($generated.resourceType)' " +
                'does not have a teardown read contract.'
            )
        }
        $expected.Add([ordered]@{
            stableId          = [string] $generated.stableId
            resourceId        = [string] $generated.resourceId
            resourceType      = [string] $generated.resourceType
            relationship      = [string] $generated.relationship
            required          = [bool] $generated.required
            apiVersion        = [string] $apiVersion
            producerResourceId = [string] $generated.producerResourceId
            expectedProperties = Copy-AdltValue `
                -InputObject $generated.expectedProperties
        })
    }

    $resourceIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $stableIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in @($expected.ToArray())) {
        if (
            -not $resourceIds.Add([string] $entry.resourceId) -or
            -not $stableIds.Add([string] $entry.stableId)
        ) {
            throw 'The SQL VM teardown contract contains duplicate identities.'
        }
    }
    return @($expected.ToArray())
}

function Assert-AdltObservedOwnershipTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    $expectedTags = Get-AdltSqlVmArmOwnershipTag `
        -Plan $Plan `
        -Resource $Resource `
        -RunId $RunId
    $observedTags = Get-AdltObservedTagSet -Observed $Observed
    foreach ($key in @($expectedTags.Keys)) {
        if (
            -not $observedTags.ContainsKey([string] $key) -or
            [string] $observedTags[[string] $key] -cne
                [string] $expectedTags[[string] $key]
        ) {
            throw (
                "Azure resource '$($Resource.id)' does not have the " +
                "exact toolkit ownership tag '$key'."
            )
        }
    }
    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            resourceId   = Get-AdltObservedResourceId -Observed $Observed
            expectedTags = $expectedTags
        })
    )
}

function Get-AdltSqlVmObservedResourceSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [object[]] $ExpectedResources
    )

    $resourceGroupName = [string] $Plan.configuration.azure.resourceGroup.name
    $observedById =
        [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    $listed = @(
        Invoke-AdltAzCommand `
            -ModuleName 'Az.Resources' `
            -CommandName 'Get-AzResource' `
            -Parameters @{
                ResourceGroupName = $resourceGroupName
                ExpandProperties  = $true
                ErrorAction       = 'Stop'
            }
    )
    foreach ($observed in $listed) {
        if ($null -eq $observed) {
            continue
        }
        $resourceId = Get-AdltObservedResourceId -Observed $observed
        if ($observedById.ContainsKey($resourceId)) {
            throw "Azure inventory returned duplicate resource '$resourceId'."
        }
        $observedById.Add($resourceId, $observed)
    }

    foreach ($expected in $ExpectedResources) {
        if ($observedById.ContainsKey([string] $expected.resourceId)) {
            continue
        }
        try {
            $observed = Invoke-AdltAzCommand `
                -ModuleName 'Az.Resources' `
                -CommandName 'Get-AzResource' `
                -Parameters @{
                    ResourceId       = [string] $expected.resourceId
                    ApiVersion       = [string] $expected.apiVersion
                    ExpandProperties = $true
                    ErrorAction      = 'Stop'
                }
            if ($null -ne $observed) {
                $resourceId = Get-AdltObservedResourceId `
                    -Observed $observed
                if (-not $observedById.ContainsKey($resourceId)) {
                    $observedById.Add($resourceId, $observed)
                }
            }
        }
        catch {
            if ((Get-AdltAzureFailureKind -ErrorRecord $_) -ne 'absent') {
                throw
            }
        }
    }
    return $observedById
}

function Assert-AdltSqlVmDiskOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $ObservedDisk,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Expected,

        [Parameter(Mandatory)]
        [object] $ObservedVirtualMachine
    )

    $managedBy = [string] (
        Get-AdltObservedNestedValue `
            -Observed $ObservedDisk `
            -CandidatePaths @(
                'ManagedBy'
                'Properties.ManagedBy'
            )
    )
    if (
        -not [string]::Equals(
            $managedBy,
            [string] $Expected.producerResourceId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Managed disk '$($Expected.resourceId)' is not managed by the planned VM."
    }
    $diskSize = Get-AdltObservedNestedValue `
        -Observed $ObservedDisk `
        -CandidatePaths @(
            'DiskSizeGB'
            'Properties.DiskSizeGB'
        )
    if (
        $null -eq $diskSize -or
        [int] $diskSize -ne
            [int] $Expected.expectedProperties.sizeGiB
    ) {
        throw "Managed disk '$($Expected.resourceId)' has an unexpected size."
    }
    $storageType = [string] (
        Get-AdltObservedNestedValue `
            -Observed $ObservedDisk `
            -CandidatePaths @(
                'Sku.Name'
                'Properties.AccountType'
            )
    )
    if (
        -not [string]::Equals(
            $storageType,
            [string] $Expected.expectedProperties.storageType,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Managed disk '$($Expected.resourceId)' has an unexpected storage type."
    }

    $storageProfile = Get-AdltObservedNestedValue `
        -Observed $ObservedVirtualMachine `
        -CandidatePaths @(
            'Properties.StorageProfile'
            'StorageProfile'
        )
    if ($null -eq $storageProfile) {
        throw 'The planned VM did not expose its storage profile.'
    }
    $vmDisk = if ($Expected.expectedProperties.purpose -ceq 'os') {
        Get-AdltNestedPropertyValue `
            -InputObject $storageProfile `
            -Path @('OsDisk')
    }
    else {
        @(
            Get-AdltNestedPropertyValue `
                -InputObject $storageProfile `
                -Path @('DataDisks')
        ) |
            Where-Object {
                [int] (
                    Get-AdltObjectPropertyValue `
                        -InputObject $_ `
                        -Name 'Lun'
                ) -eq [int] $Expected.expectedProperties.lun
            } |
            Select-Object -First 1
    }
    if ($null -eq $vmDisk) {
        throw "Managed disk '$($Expected.resourceId)' is absent from the VM storage profile."
    }
    $attachedDiskId = [string] (
        Get-AdltNestedPropertyValue `
            -InputObject $vmDisk `
            -Path @('ManagedDisk', 'Id')
    )
    $deleteOption = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $vmDisk `
            -Name 'DeleteOption'
    )
    if (
        -not [string]::Equals(
            $attachedDiskId,
            [string] $Expected.resourceId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $deleteOption -cne 'Delete'
    ) {
        throw "Managed disk '$($Expected.resourceId)' lacks the exact VM deletion coupling."
    }

    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            resourceId   = [string] $Expected.resourceId
            managedBy    = $managedBy
            attachedId   = $attachedDiskId
            deleteOption = $deleteOption
            sizeGiB      = [int] $diskSize
            storageType  = $storageType
        })
    )
}

function Get-AdltSqlVmCompiledNestedResourceMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation
    )

    $deploymentResources = @(
        $Compilation.template.resources |
            Where-Object {
                $_.type -ceq 'Microsoft.Resources/deployments'
            }
    )
    if ($deploymentResources.Count -ne 1) {
        throw 'SQL VM compilation requires one nested resource-group deployment.'
    }
    $nestedResources = @(
        $deploymentResources[0].properties.template.resources
    )
    $planResources = Get-AdltSqlVmArmResourceMap -Plan $Plan
    $map = [ordered]@{}
    foreach ($binding in @(
        $Compilation.resourceBindings |
            Where-Object {
                $_.disposition -ceq 'deploy' -and
                $_.stableId -cne 'azure.resource-group.primary'
            }
    )) {
        $planResource = $planResources[[string] $binding.stableId]
        $expectedName = if (
            $planResource.type -ceq
                'Microsoft.Network/virtualNetworks/subnets'
        ) {
            $virtualNetwork = $planResources[
                'azure.network.virtual-network.primary'
            ]
            '{0}/{1}' -f
                [string] $virtualNetwork.logicalName,
                [string] $planResource.logicalName
        }
        else {
            [string] $planResource.logicalName
        }
        $resourceMatches = @(
            $nestedResources |
                Where-Object {
                    $_.type -ceq $planResource.type -and
                    $_.name -ceq $expectedName
                }
        )
        if ($resourceMatches.Count -ne 1) {
            throw (
                "Compiled material-state resource '$($binding.stableId)' " +
                'did not resolve uniquely.'
            )
        }
        $map[[string] $binding.stableId] =
            ConvertTo-AdltDictionary -InputObject $resourceMatches[0]
    }
    return $map
}

function New-AdltAzureConflictErrorRecord {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Message
    )

    return [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new($Message),
        'Conflict',
        [System.Management.Automation.ErrorCategory]::ResourceExists,
        $null
    )
}

function ConvertTo-AdltMaterialStateValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Expected,

        [AllowNull()]
        [object] $Observed,

        [string] $Path = ''
    )

    if ($null -eq $Expected) {
        if ($null -ne $Observed) {
            throw (New-AdltAzureConflictErrorRecord -Message (
                    "Material state '$Path' must be null."
                ))
        }
        return $null
    }
    if ($Expected -is [System.Collections.IDictionary]) {
        if ($null -eq $Observed) {
            throw (New-AdltAzureConflictErrorRecord -Message (
                    "Material state '$Path' is missing."
                ))
        }
        $keys = [string[]] @(
            $Expected.Keys |
                Where-Object {
                    [string] $_ -cnotin @(
                        'adminPassword'
                        'dependsOn'
                        'tags'
                    ) -and
                    -not (
                        [string] $_ -ceq 'location' -and
                        $Path -ceq 'properties'
                    )
                }
        )
        [System.Array]::Sort(
            $keys,
            [System.StringComparer]::Ordinal
        )
        $result = [ordered]@{}
        foreach ($key in $keys) {
            $childPath = if ([string]::IsNullOrEmpty($Path)) {
                $key
            }
            else {
                '{0}.{1}' -f $Path, $key
            }
            $observedValue = Get-AdltObjectPropertyValue `
                -InputObject $Observed `
                -Name $key
            $result[$key] = ConvertTo-AdltMaterialStateValue `
                -Expected $Expected[$key] `
                -Observed $observedValue `
                -Path $childPath
        }
        return $result
    }
    if (
        $Expected -is [System.Collections.IList] -and
        $Expected -isnot [string]
    ) {
        if ($null -eq $Observed) {
            throw (New-AdltAzureConflictErrorRecord -Message (
                    "Material state '$Path' is not an array."
                ))
        }
        $expectedItems = @($Expected)
        $observedItems = @($Observed)
        if ($expectedItems.Count -ne $observedItems.Count) {
            throw (New-AdltAzureConflictErrorRecord -Message (
                    "Material state '$Path' has an unexpected item count."
                ))
        }
        if ($expectedItems.Count -eq 0) {
            return @()
        }
        $keyName = if (
            @(
                $expectedItems |
                    Where-Object {
                        $null -eq (
                            Get-AdltObjectPropertyValue `
                                -InputObject $_ `
                                -Name name
                        )
                    }
            ).Count -eq 0
        ) {
            'name'
        }
        elseif (
            @(
                $expectedItems |
                    Where-Object {
                        $null -eq (
                            Get-AdltObjectPropertyValue `
                                -InputObject $_ `
                                -Name lun
                        )
                    }
            ).Count -eq 0
        ) {
            'lun'
        }
        else {
            $null
        }
        $result = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $keyName) {
            foreach ($expectedItem in $expectedItems) {
                $expectedKey = [string] (
                    Get-AdltObjectPropertyValue `
                        -InputObject $expectedItem `
                        -Name $keyName
                )
                $itemMatches = @(
                    $observedItems |
                        Where-Object {
                            [string]::Equals(
                                [string] (
                                    Get-AdltObjectPropertyValue `
                                        -InputObject $_ `
                                        -Name $keyName
                                ),
                                $expectedKey,
                                [System.StringComparison]::OrdinalIgnoreCase
                            )
                        }
                )
                if ($itemMatches.Count -ne 1) {
                    throw (New-AdltAzureConflictErrorRecord -Message (
                            "Material state '$Path' item '$expectedKey' did " +
                            'not resolve uniquely.'
                        ))
                }
                $result.Add(
                    (ConvertTo-AdltMaterialStateValue `
                        -Expected $expectedItem `
                        -Observed $itemMatches[0] `
                        -Path ('{0}[{1}]' -f $Path, $expectedKey))
                )
            }
            return @($result.ToArray())
        }
        if (
            $expectedItems[0] -is
                [System.Collections.IDictionary]
        ) {
            for ($index = 0; $index -lt $expectedItems.Count; $index++) {
                $result.Add(
                    (ConvertTo-AdltMaterialStateValue `
                        -Expected $expectedItems[$index] `
                        -Observed $observedItems[$index] `
                        -Path ('{0}[{1}]' -f $Path, $index))
                )
            }
            return @($result.ToArray())
        }
        $expectedScalars = @(
            $expectedItems |
                ForEach-Object {
                    ConvertTo-AdltMaterialStateValue `
                        -Expected $_ `
                        -Observed $_ `
                        -Path $Path
                } |
                Sort-Object
        )
        $observedScalars = @(
            $observedItems |
                ForEach-Object {
                    ConvertTo-AdltMaterialStateValue `
                        -Expected $expectedItems[0] `
                        -Observed $_ `
                        -Path $Path
                } |
                Sort-Object
        )
        if (
            (ConvertTo-AdltCanonicalJson `
                -InputObject $observedScalars) -cne
            (ConvertTo-AdltCanonicalJson `
                -InputObject $expectedScalars)
        ) {
            throw (New-AdltAzureConflictErrorRecord -Message (
                    "Material state '$Path' has unexpected values."
                ))
        }
        return $observedScalars
    }
    if ($Expected -is [bool]) {
        if ($Observed -isnot [bool]) {
            throw (New-AdltAzureConflictErrorRecord -Message (
                    "Material state '$Path' is not Boolean."
                ))
        }
        return [bool] $Observed
    }
    if (
        $Expected -is [byte] -or
        $Expected -is [sbyte] -or
        $Expected -is [int16] -or
        $Expected -is [uint16] -or
        $Expected -is [int32] -or
        $Expected -is [uint32] -or
        $Expected -is [int64]
    ) {
        try {
            $integer = [int64] $Observed
        }
        catch {
            throw (New-AdltAzureConflictErrorRecord -Message (
                    "Material state '$Path' is not an integer."
                ))
        }
        if ($integer -ne [int64] $Expected) {
            throw (New-AdltAzureConflictErrorRecord -Message (
                    "Material state '$Path' has an unexpected integer."
                ))
        }
        return $integer
    }

    $expectedString = [string] $Expected
    $observedString = [string] $Observed
    if (
        [string]::IsNullOrWhiteSpace($observedString) -or
        -not [string]::Equals(
            $observedString,
            $expectedString,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw (New-AdltAzureConflictErrorRecord -Message (
                "Material state '$Path' has an unexpected value."
            ))
    }
    return $observedString.ToLowerInvariant()
}

function Get-AdltSqlVmMaterialStateProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExpectedResource
    )

    $expectedMaterial = [ordered]@{}
    foreach ($key in @('location', 'sku', 'identity', 'properties')) {
        if ($ExpectedResource.Contains($key)) {
            $expectedMaterial[$key] = $ExpectedResource[$key]
        }
    }
    $actualMaterial = ConvertTo-AdltMaterialStateValue `
        -Expected $expectedMaterial `
        -Observed $Observed
    $expectedNormalized = ConvertTo-AdltMaterialStateValue `
        -Expected $expectedMaterial `
        -Observed $expectedMaterial
    if (
        (ConvertTo-AdltCanonicalJson `
            -InputObject $actualMaterial) -cne
        (ConvertTo-AdltCanonicalJson `
            -InputObject $expectedNormalized)
    ) {
        throw (New-AdltAzureConflictErrorRecord -Message (
                'Observed Azure material state differs from the compiled ' +
                'deployment.'
            ))
    }
    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $actualMaterial
    )
}

function Get-AdltSqlVmPlannedResourceProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Expected,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $PlanResource,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $CompiledResource
    )

    $relationshipProof = if (
        $Expected.relationship -ceq 'planned-taggable'
    ) {
        Assert-AdltObservedOwnershipTag `
            -Observed $Observed `
            -Plan $Plan `
            -Resource $PlanResource `
            -RunId $State.runId
    }
    else {
        if (
            [string]::IsNullOrWhiteSpace(
                [string] $Expected.producerResourceId
            )
        ) {
            throw "Resource '$($Expected.resourceId)' lacks its owned parent."
        }
        Get-AdltSha256Identifier -Value (
            ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                resourceId = [string] $Expected.resourceId
                parentResourceId =
                    [string] $Expected.producerResourceId
                relationship = 'planned-descendant'
            })
        )
    }
    $materialProof = Get-AdltSqlVmMaterialStateProof `
        -Observed $Observed `
        -ExpectedResource $CompiledResource
    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            relationshipProof = $relationshipProof
            materialProof = $materialProof
        })
    )
}

function Get-AdltSqlVmTeardownInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [switch] $RequireCompleteDeployment,

        [datetimeoffset] $CapturedAt = [datetimeoffset]::UtcNow
    )

    $resourceGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f
        $State.scope.subscriptionId,
        $State.scope.resourceGroupName
    $resourceGroup = Get-AdltPlanResource `
        -Plan $Plan `
        -StableId 'azure.resource-group.primary'
    try {
        $observedResourceGroup = Invoke-AdltAzCommand `
            -ModuleName 'Az.Resources' `
            -CommandName 'Get-AzResourceGroup' `
            -Parameters @{
                Name        = [string] $State.scope.resourceGroupName
                ErrorAction = 'Stop'
            }
    }
    catch {
        if ((Get-AdltAzureFailureKind -ErrorRecord $_) -ne 'absent') {
            throw
        }
        $absenceProofHash = Get-AdltSha256Identifier -Value (
            ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                resourceGroupId = $resourceGroupId
                observedState   = 'absent'
            })
        )
        $inventory = [ordered]@{
            capturedAt            = ConvertTo-AdltUtcTimestamp `
                -Value $CapturedAt
            resourceGroupId       = $resourceGroupId
            resourceGroupStatus   = 'absent'
            resourceGroupProofHash = $absenceProofHash
            resourceCount         = 0
            resources             = @()
        }
        $inventory.inventoryHash = Get-AdltTeardownInventoryHash `
            -Inventory $inventory
        Assert-AdltTeardownInventory `
            -Inventory $inventory `
            -State $State
        return $inventory
    }
    if ($null -eq $observedResourceGroup) {
        throw 'The resource-group inventory query returned an empty response.'
    }
    $observedResourceGroupId = Get-AdltObservedResourceId `
        -Observed $observedResourceGroup
    if (
        -not [string]::Equals(
            $observedResourceGroupId,
            $resourceGroupId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'The resource-group inventory query returned another scope.'
    }
    $resourceGroupProofHash = Assert-AdltObservedOwnershipTag `
        -Observed $observedResourceGroup `
        -Plan $Plan `
        -Resource $resourceGroup `
        -RunId $State.runId

    $expectedResources = @(
        Get-AdltSqlVmTeardownExpectedResourceSet `
            -Plan $Plan `
            -Compilation $Compilation
    )
    $retainedResources = @(
        $expectedResources |
            Where-Object {
                $_.relationship -ceq 'nested-deployment'
            }
    )
    $deletableExpectedResources = @(
        $expectedResources |
            Where-Object {
                $_.relationship -cne 'nested-deployment'
            }
    )
    $expectedById =
        [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    foreach ($expected in $deletableExpectedResources) {
        $expectedById.Add([string] $expected.resourceId, $expected)
    }
    $retainedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($retained in $retainedResources) {
        [void] $retainedIds.Add([string] $retained.resourceId)
    }
    $observedById = Get-AdltSqlVmObservedResourceSet `
        -Plan $Plan `
        -ExpectedResources $expectedResources

    foreach ($resourceId in @($observedById.Keys)) {
        if (
            -not $expectedById.ContainsKey([string] $resourceId) -and
            -not $retainedIds.Contains([string] $resourceId)
        ) {
            throw (
                "Teardown is blocked by unknown contained resource " +
                "'$resourceId'."
            )
        }
    }
    if ($RequireCompleteDeployment.IsPresent) {
        foreach ($expected in $deletableExpectedResources) {
            if (
                [bool] $expected.required -and
                -not $observedById.ContainsKey(
                    [string] $expected.resourceId
                )
            ) {
                throw (
                    "Completed deployment resource '$($expected.resourceId)' " +
                    'is missing from fresh teardown inventory.'
                )
            }
        }
    }

    $planResources = Get-AdltSqlVmArmResourceMap -Plan $Plan
    $compiledResources = Get-AdltSqlVmCompiledNestedResourceMap `
        -Plan $Plan `
        -Compilation $Compilation
    $virtualMachineId = [string] (
        $Compilation.resourceBindings |
            Where-Object {
                $_.stableId -ceq
                    'azure.compute.virtual-machine.primary'
            } |
            Select-Object -First 1
    ).resourceId
    $observedVirtualMachine = if (
        $observedById.ContainsKey($virtualMachineId)
    ) {
        $observedById[$virtualMachineId]
    }
    else {
        $null
    }
    $inventoryResources = [System.Collections.Generic.List[object]]::new()
    foreach ($resourceId in @($observedById.Keys | Sort-Object)) {
        if ($retainedIds.Contains([string] $resourceId)) {
            continue
        }
        $expected = ConvertTo-AdltDictionary `
            -InputObject $expectedById[[string] $resourceId]
        $observed = $observedById[[string] $resourceId]
        $observedType = Get-AdltObservedResourceType `
            -Observed $observed
        if (
            -not [string]::Equals(
                $observedType,
                [string] $expected.resourceType,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw "Resource '$resourceId' has an unexpected Azure type."
        }

        $proofHash = switch ([string] $expected.relationship) {
            'planned-taggable' {
                $planResource = $planResources[
                    [string] $expected.stableId
                ]
                Get-AdltSqlVmPlannedResourceProof `
                    -Observed $observed `
                    -Plan $Plan `
                    -State $State `
                    -Expected $expected `
                    -PlanResource $planResource `
                    -CompiledResource $compiledResources[
                        [string] $expected.stableId
                    ]
                break
            }
            'planned-descendant' {
                if (
                    [string]::IsNullOrWhiteSpace(
                        [string] $expected.producerResourceId
                    ) -or
                    -not $observedById.ContainsKey(
                        [string] $expected.producerResourceId
                    )
                ) {
                    throw "Resource '$resourceId' lacks its owned parent."
                }
                $planResource = $planResources[
                    [string] $expected.stableId
                ]
                Get-AdltSqlVmPlannedResourceProof `
                    -Observed $observed `
                    -Plan $Plan `
                    -State $State `
                    -Expected $expected `
                    -PlanResource $planResource `
                    -CompiledResource $compiledResources[
                        [string] $expected.stableId
                    ]
                break
            }
            'vm-managed-disk' {
                if ($null -eq $observedVirtualMachine) {
                    throw "Managed disk '$resourceId' lacks its owned VM."
                }
                Assert-AdltSqlVmDiskOwnership `
                    -ObservedDisk $observed `
                    -Expected $expected `
                    -ObservedVirtualMachine $observedVirtualMachine
                break
            }
            'sql-iaas-agent-extension' {
                $parentResourceId = [string] $expected.
                    expectedProperties.parentResourceId
                if (-not $observedById.ContainsKey($parentResourceId)) {
                    throw "SQL IaaS extension '$resourceId' lacks its owned VM."
                }
                $publisher = [string] (
                    Get-AdltObservedNestedValue `
                        -Observed $observed `
                        -CandidatePaths @(
                            'Properties.Publisher'
                            'Publisher'
                        )
                )
                $extensionType = [string] (
                    Get-AdltObservedNestedValue `
                        -Observed $observed `
                        -CandidatePaths @(
                            'Properties.Type'
                            'Properties.ExtensionType'
                        )
                )
                if (
                    -not [string]::Equals(
                        $publisher,
                        [string] $expected.expectedProperties.publisher,
                        [System.StringComparison]::Ordinal
                    ) -or
                    -not [string]::Equals(
                        $extensionType,
                        [string] $expected.expectedProperties.type,
                        [System.StringComparison]::Ordinal
                    )
                ) {
                    throw "SQL IaaS extension '$resourceId' is outside the pinned provider profile."
                }
                Get-AdltSha256Identifier -Value (
                    ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                        resourceId = $resourceId
                        parentResourceId = $parentResourceId
                        producerResourceId = [string] $expected.
                            producerResourceId
                        publisher = $publisher
                        type = $extensionType
                        profileVersion = 'sql-iaas-windows-2023-10-01-v1'
                    })
                )
                break
            }
            default {
                throw (
                    "Teardown relationship '$($expected.relationship)' " +
                    'is unsupported.'
                )
            }
        }
        $inventoryResources.Add([ordered]@{
            stableId     = [string] $expected.stableId
            resourceId   = [string] $resourceId
            resourceType = [string] $expected.resourceType
            apiVersion   = [string] $expected.apiVersion
            etag         = Get-AdltObservedResourceEtag `
                -Observed $observed
            observationFingerprint =
                Get-AdltObservedResourceFingerprint `
                    -Observed $observed
            relationship = [string] $expected.relationship
            required     = [bool] $expected.required
            proofHash    = [string] $proofHash
        })
    }

    $inventory = [ordered]@{
        capturedAt             = ConvertTo-AdltUtcTimestamp `
            -Value $CapturedAt
        resourceGroupId        = $resourceGroupId
        resourceGroupStatus    = 'present'
        resourceGroupProofHash = $resourceGroupProofHash
        resourceCount          = $inventoryResources.Count
        resources              = @(
            $inventoryResources.ToArray() |
                Sort-Object resourceId
        )
    }
    $inventory.inventoryHash = Get-AdltTeardownInventoryHash `
        -Inventory $inventory
    Assert-AdltTeardownInventory `
        -Inventory $inventory `
        -State $State
    return $inventory
}

function Get-AdltTeardownApprovalPhrase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Inventory
    )

    Assert-AdltTeardownInventory `
        -Inventory $Inventory `
        -State $State
    return 'DELETE {0} {1} {2} {3}' -f
        $State.scope.resourceGroupName,
        $State.runId.Replace(
            '-',
            ''
        ).Substring(0, 8).ToLowerInvariant(),
        [int] $Inventory.resourceCount,
        $Inventory.inventoryHash.Substring(7, 12)
}

function Assert-AdltTeardownExecutionRecordArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    Assert-AdltArtifactContract `
        -Artifact $ExecutionRecord `
        -ExpectedKind 'AzureDataLabTeardownExecutionRecord' `
        -HashProperty 'teardownExecutionRecordHash' `
        -SchemaFileName 'teardown-execution-record.schema.json'
    if (
        $ExecutionRecord.runId -cne $State.runId -or
        $ExecutionRecord.planHash -cne $State.planHash -or
        $ExecutionRecord.intentHash -cne $State.intentHash
    ) {
        throw 'Teardown execution record does not match the protected run.'
    }
    Assert-AdltScopeBinding `
        -Actual $ExecutionRecord.scope `
        -Expected $State.scope `
        -ArtifactName 'Teardown execution record'
    Assert-AdltTeardownInventory `
        -Inventory $ExecutionRecord.inventory `
        -State $State
    if (
        $ExecutionRecord.cleanupLease.inventoryHash -cne
            $ExecutionRecord.inventory.inventoryHash -or
        $ExecutionRecord.deleteAction.resourceId -cne
            $ExecutionRecord.inventory.resourceGroupId -or
        $ExecutionRecord.deleteAction.resourceGroupName -cne
            $State.scope.resourceGroupName -or
        $ExecutionRecord.deleteAction.strategy -cne
            'exact-resource-ids' -or
        -not [bool] $ExecutionRecord.deleteAction.retainResourceGroup -or
        [bool] $ExecutionRecord.deleteAction.operationRequired -ne
            ([int] $ExecutionRecord.inventory.resourceCount -gt 0)
    ) {
        throw 'Teardown execution record cleanup binding is invalid.'
    }
    $expectedPhrase = Get-AdltTeardownApprovalPhrase `
        -State $State `
        -Inventory $ExecutionRecord.inventory
    if (
        $ExecutionRecord.cleanupLease.confirmationPhraseHash -cne
            (Get-AdltSha256Identifier -Value $expectedPhrase)
    ) {
        throw 'Teardown execution record approval phrase hash is invalid.'
    }
    $createdAt = [datetimeoffset]::Parse(
        [string] $ExecutionRecord.createdAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $approvedAt = [datetimeoffset]::Parse(
        [string] $ExecutionRecord.cleanupLease.approvedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $expiresAt = [datetimeoffset]::Parse(
        [string] $ExecutionRecord.cleanupLease.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $capturedAt = [datetimeoffset]::Parse(
        [string] $ExecutionRecord.inventory.capturedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if (
        $createdAt -lt $capturedAt -or
        $approvedAt -ne $createdAt -or
        $expiresAt -le $approvedAt -or
        $expiresAt -gt $approvedAt.AddMinutes(10)
    ) {
        throw 'Teardown execution record timestamps are invalid.'
    }
    if (
        $ExecutionRecord.cleanupLease.approver.type -cne 'user' -or
        $ExecutionRecord.cleanupLease.mechanism -cne 'interactive'
    ) {
        throw 'Teardown execution record requires interactive user approval.'
    }
}

function Assert-AdltTeardownCleanupLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $CleanupLease,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow
    )

    if (
        $CleanupLease.inventoryHash -cne
            $ExecutionRecord.inventory.inventoryHash -or
        $CleanupLease.confirmationPhraseHash -cne
            $ExecutionRecord.cleanupLease.confirmationPhraseHash -or
        $CleanupLease.approver.type -cne 'user' -or
        [string] $CleanupLease.approver.id -notmatch
            '^[0-9a-fA-F-]{36}$' -or
        $CleanupLease.mechanism -cne 'interactive'
    ) {
        throw 'The effective cleanup lease is not bound to its approval.'
    }
    $approvedAt = [datetimeoffset]::Parse(
        [string] $CleanupLease.approvedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $expiresAt = [datetimeoffset]::Parse(
        [string] $CleanupLease.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if (
        $expiresAt -le $approvedAt -or
        $expiresAt -gt $approvedAt.AddMinutes(10)
    ) {
        throw 'The effective cleanup lease window is invalid.'
    }
    if ($AsOf -lt $approvedAt -or $AsOf -ge $expiresAt) {
        throw 'The cleanup lease is not currently valid.'
    }
}

function Assert-AdltTeardownExecutionRecordForExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DeploymentExecutionRecord,

        [System.Collections.IDictionary] $CleanupLease,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow
    )

    Assert-AdltTeardownExecutionRecordArtifact `
        -ExecutionRecord $ExecutionRecord `
        -State $State
    if (
        $ExecutionRecord.deploymentExecutionRecordHash -cne
            $DeploymentExecutionRecord.executionRecordHash
    ) {
        throw 'Teardown record is not bound to the deployment execution record.'
    }
    $effectiveLease = if ($PSBoundParameters.ContainsKey('CleanupLease')) {
        $CleanupLease
    }
    else {
        $ExecutionRecord.cleanupLease
    }
    Assert-AdltTeardownCleanupLease `
        -CleanupLease $effectiveLease `
        -ExecutionRecord $ExecutionRecord `
        -AsOf $AsOf
}

function New-AdltTeardownExecutionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DeploymentExecutionRecord,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Inventory,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $ApproverId,

        [datetimeoffset] $CreatedAt = [datetimeoffset]::UtcNow
    )

    Assert-AdltTeardownInventory `
        -Inventory $Inventory `
        -State $State
    $approvalPhrase = Get-AdltTeardownApprovalPhrase `
        -State $State `
        -Inventory $Inventory
    $record = [ordered]@{
        schemaVersion = '1.0'
        kind = 'AzureDataLabTeardownExecutionRecord'
        canonicalization = 'rfc8785'
        operation = 'teardown'
        operationId = [guid]::NewGuid().ToString()
        runId = $State.runId
        planHash = $Plan.planHash
        intentHash = $Plan.intentHash
        scope = Get-AdltPlanScope -Plan $Plan
        deploymentExecutionRecordHash =
            $DeploymentExecutionRecord.executionRecordHash
        inventory = Copy-AdltValue -InputObject $Inventory
        cleanupLease = [ordered]@{
            inventoryHash = $Inventory.inventoryHash
            confirmationPhraseHash =
                Get-AdltSha256Identifier -Value $approvalPhrase
            approver = [ordered]@{
                type = 'user'
                id   = $ApproverId
            }
            mechanism = 'interactive'
            recordId = 'interactive:{0}' -f
                [guid]::NewGuid().ToString()
            approvedAt = ConvertTo-AdltUtcTimestamp `
                -Value $CreatedAt
            expiresAt = ConvertTo-AdltUtcTimestamp `
                -Value $CreatedAt.AddMinutes(10)
        }
        deleteAction = [ordered]@{
            resourceGroupName = [string] $State.scope.resourceGroupName
            resourceId = [string] $Inventory.resourceGroupId
            strategy = 'exact-resource-ids'
            retainResourceGroup = $true
            operationRequired =
                [int] $Inventory.resourceCount -gt 0
        }
        createdAt = ConvertTo-AdltUtcTimestamp -Value $CreatedAt
    }
    $record.teardownExecutionRecordHash = Get-AdltArtifactHash `
        -Artifact $record `
        -HashProperty 'teardownExecutionRecordHash'
    Assert-AdltTeardownExecutionRecordForExecution `
        -ExecutionRecord $record `
        -State $State `
        -DeploymentExecutionRecord $DeploymentExecutionRecord `
        -AsOf $CreatedAt
    return $record
}
