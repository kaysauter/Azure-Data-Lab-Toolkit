function Get-AdltPlanResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [string] $StableId
    )

    $resource = @($Plan.resources | Where-Object id -CEQ $StableId)
    if ($resource.Count -ne 1) {
        throw "Plan resource '$StableId' must resolve exactly once."
    }

    return ConvertTo-AdltDictionary -InputObject $resource[0]
}

function Resolve-AdltPlanResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [string] $StableId,

        [hashtable] $Cache = @{},

        [string[]] $ResolutionStack = @()
    )

    if ($Cache.ContainsKey($StableId)) {
        return [string] $Cache[$StableId]
    }
    if ($StableId -in $ResolutionStack) {
        throw "Plan resource ID dependency cycle detected at '$StableId'."
    }

    $resource = Get-AdltPlanResource -Plan $Plan -StableId $StableId
    if (-not [string]::IsNullOrWhiteSpace([string] $resource.externalResourceId)) {
        $Cache[$StableId] = [string] $resource.externalResourceId
        return [string] $Cache[$StableId]
    }

    $subscriptionId = [string] $Plan.context.subscriptionId
    $resourceGroupName = [string] $Plan.configuration.azure.resourceGroup.name
    $resourceGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f
        $subscriptionId,
        $resourceGroupName
    if ($resource.type -eq 'Microsoft.Resources/resourceGroups') {
        $Cache[$StableId] = $resourceGroupId
        return $resourceGroupId
    }

    $nextStack = @($ResolutionStack) + $StableId
    $parentMappings = @{
        'Microsoft.KeyVault/vaults/secrets' = @{
            Property = 'parentResourceId'
            Suffix   = 'secrets'
        }
        'Microsoft.Network/virtualNetworks/subnets' = @{
            Property = 'virtualNetworkResourceId'
            Suffix   = 'subnets'
        }
        'Microsoft.Network/privateDnsZones/virtualNetworkLinks' = @{
            Property = 'privateDnsZoneResourceId'
            Suffix   = 'virtualNetworkLinks'
        }
        'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' = @{
            Property = 'privateEndpointResourceId'
            Suffix   = 'privateDnsZoneGroups'
        }
        'Microsoft.Storage/storageAccounts/fileServices/shares' = @{
            Property = 'storageAccountResourceId'
            Suffix   = 'fileServices/default/shares'
        }
    }

    if ($resource.type -eq 'Microsoft.Authorization/roleAssignments') {
        $scopeStableId = [string] $resource.desiredProperties.scopeResourceId
        $scopeId = Resolve-AdltPlanResourceId `
            -Plan $Plan `
            -StableId $scopeStableId `
            -Cache $Cache `
            -ResolutionStack $nextStack
        $resolvedId = '{0}/providers/Microsoft.Authorization/roleAssignments/{1}' -f
            $scopeId.TrimEnd('/'),
            $resource.logicalName
    }
    elseif ($parentMappings.ContainsKey([string] $resource.type)) {
        $mapping = $parentMappings[[string] $resource.type]
        $parentStableId = [string] $resource.desiredProperties[$mapping.Property]
        $parentId = Resolve-AdltPlanResourceId `
            -Plan $Plan `
            -StableId $parentStableId `
            -Cache $Cache `
            -ResolutionStack $nextStack
        $resolvedId = '{0}/{1}/{2}' -f
            $parentId.TrimEnd('/'),
            $mapping.Suffix,
            $resource.logicalName
    }
    else {
        $resolvedId = '{0}/providers/{1}/{2}' -f
            $resourceGroupId,
            $resource.type,
            $resource.logicalName
    }

    $Cache[$StableId] = $resolvedId
    return $resolvedId
}

function Get-AdltResolvedResourceIdSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    Assert-AdltPlanContract -Plan $Plan
    $cache = @{}
    return @(
        foreach ($resource in @($Plan.resources | Sort-Object id)) {
            [ordered]@{
                stableId         = [string] $resource.id
                resourceId       = Resolve-AdltPlanResourceId `
                    -Plan $Plan `
                    -StableId ([string] $resource.id) `
                    -Cache $cache
                resourceType     = [string] $resource.type
                plannedOwnership = [string] $resource.ownership.expectedClassification
            }
        }
    )
}

function Get-AdltDesiredResourceHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource
    )

    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            type              = $Resource.type
            apiVersion        = $Resource.apiVersion
            logicalName       = $Resource.logicalName
            desiredProperties = $Resource.desiredProperties
        })
    )
}
