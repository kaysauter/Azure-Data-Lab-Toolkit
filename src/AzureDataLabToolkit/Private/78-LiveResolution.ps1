function Get-AdltProviderNamespaceSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    return @(
        $Plan.resources.type |
            ForEach-Object { ([string] $_).Split('/')[0] } |
            Where-Object { $_ -ne 'Microsoft.Resources' } |
            Sort-Object -Unique
    )
}

function Get-AdltSqlVmImageResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $vm = Get-AdltPlanResource `
        -Plan $Plan `
        -StableId 'azure.compute.virtual-machine.primary'
    $image = $vm.desiredProperties.imageReference
    $versions = @(
        Invoke-AdltAzCommand `
            -ModuleName 'Az.Compute' `
            -CommandName 'Get-AzVMImage' `
            -Parameters @{
                Location    = [string] $Plan.context.location
                PublisherName = [string] $image.publisher
                Offer       = [string] $image.offer
                Skus        = [string] $image.sku
                ErrorAction = 'Stop'
            }
    )
    if ($versions.Count -eq 0) {
        throw 'No marketplace image version matched the SQL VM profile.'
    }

    $resolved = $versions |
        Sort-Object {
            try {
                [version] ([string] $_.Version)
            }
            catch {
                [version] '0.0'
            }
        } -Descending |
        Select-Object -First 1

    $version = [string] $resolved.Version
    if ($version -notmatch '^[0-9]+(?:\.[0-9]+){2,3}$') {
        throw 'The resolved SQL VM marketplace image version is not immutable.'
    }
    $imageDetails = @(
        Invoke-AdltAzCommand `
            -ModuleName 'Az.Compute' `
            -CommandName 'Get-AzVMImage' `
            -Parameters @{
                Location      = [string] $Plan.context.location
                PublisherName = [string] $image.publisher
                Offer         = [string] $image.offer
                Skus          = [string] $image.sku
                Version       = $version
                ErrorAction   = 'Stop'
            }
    )
    if ($imageDetails.Count -ne 1) {
        throw 'The immutable SQL VM marketplace image did not resolve exactly once.'
    }
    $imageDetail = $imageDetails[0]
    $hyperVGeneration = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $imageDetail `
            -Name 'HyperVGeneration'
    )
    $features = @(
        Get-AdltObjectPropertyValue `
            -InputObject $imageDetail `
            -Name 'Features'
    )
    $trustedLaunchSupported = $false
    foreach ($feature in $features) {
        $featureName = [string] (
            Get-AdltObjectPropertyValue -InputObject $feature -Name 'Name'
        )
        $featureValue = [string] (
            Get-AdltObjectPropertyValue -InputObject $feature -Name 'Value'
        )
        if (
            $featureName -ieq 'SecurityType' -and
            (
                $featureValue -match
                    '(?i)(TrustedLaunch|TrustedLaunchSupported)'
            )
        ) {
            $trustedLaunchSupported = $true
        }
    }
    if (
        $hyperVGeneration -cne 'V2' -or
        -not $trustedLaunchSupported
    ) {
        throw 'The immutable SQL VM image does not prove Trusted Launch compatibility.'
    }

    $normalized = [ordered]@{
        publisher = [string] $image.publisher
        offer     = [string] $image.offer
        sku       = [string] $image.sku
        version   = $version
        hyperVGeneration      = $hyperVGeneration
        trustedLaunchSupported = $trustedLaunchSupported
    }
    $normalized.imageMetadataHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $normalized
    )
    return $normalized
}

function Get-AdltSqlVmSkuResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $vm = Get-AdltPlanResource `
        -Plan $Plan `
        -StableId 'azure.compute.virtual-machine.primary'
    $vmSize = [string] $vm.desiredProperties.hardwareProfile.vmSize
    $location = [string] $Plan.context.location
    $matchingSkus = @(
        Invoke-AdltAzCommand `
            -ModuleName 'Az.Compute' `
            -CommandName 'Get-AzComputeResourceSku' `
            -Parameters @{
                Location    = $location
                ErrorAction = 'Stop'
            } |
            Where-Object {
                $_.ResourceType -eq 'virtualMachines' -and
                $_.Name -eq $vmSize -and
                $location -in @($_.Locations)
            }
    )
    if ($matchingSkus.Count -ne 1) {
        throw (
            "VM size '$vmSize' did not resolve exactly once in '$location'."
        )
    }
    $sku = $matchingSkus[0]

    $restrictions = @(
        foreach ($restriction in @($sku.Restrictions)) {
            $restrictionLocations = @(
                Get-AdltObjectPathValue `
                    -InputObject $restriction `
                    -Path 'RestrictionInfo.Locations'
            )
            $restrictionZones = @(
                Get-AdltObjectPathValue `
                    -InputObject $restriction `
                    -Path 'RestrictionInfo.Zones'
            )
            [ordered]@{
                reasonCode = [string] (
                    Get-AdltObjectPropertyValue `
                        -InputObject $restriction `
                        -Name 'ReasonCode'
                )
                type = [string] (
                    Get-AdltObjectPropertyValue `
                        -InputObject $restriction `
                        -Name 'Type'
                )
                locations = @($restrictionLocations | Sort-Object -Unique)
                zones     = @($restrictionZones | Sort-Object -Unique)
            }
        }
    )
    $blocked = @(
        $restrictions |
            Where-Object {
                $_.reasonCode -eq 'NotAvailableForSubscription' -and
                (
                    @($_.locations).Count -eq 0 -or
                    $location -in @($_.locations)
                )
            }
    ).Count -gt 0

    $capabilitiesByName =
        [System.Collections.Generic.Dictionary[string, string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    foreach ($capability in @($sku.Capabilities)) {
        $name = [string] (
            Get-AdltObjectPropertyValue `
                -InputObject $capability `
                -Name 'Name'
        )
        $value = [string] (
            Get-AdltObjectPropertyValue `
                -InputObject $capability `
                -Name 'Value'
        )
        if (
            [string]::IsNullOrWhiteSpace($name) -or
            -not $capabilitiesByName.TryAdd($name, $value)
        ) {
            throw "VM size '$vmSize' returned ambiguous capabilities."
        }
    }
    $capabilities = @(
        $capabilityNames = [string[]] @($capabilitiesByName.Keys)
        [System.Array]::Sort(
            $capabilityNames,
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($name in $capabilityNames) {
            [ordered]@{
                name  = $name
                value = $capabilitiesByName[$name]
            }
        }
    )
    $encryptionAtHostSupported = (
        $capabilitiesByName.ContainsKey('EncryptionAtHostSupported') -and
        $capabilitiesByName['EncryptionAtHostSupported'] -ieq 'True'
    )
    $trustedLaunchSupported = (
        -not $capabilitiesByName.ContainsKey('TrustedLaunchDisabled') -or
        $capabilitiesByName['TrustedLaunchDisabled'] -ine 'True'
    )
    $hyperVGenerationV2 = (
        $capabilitiesByName.ContainsKey('HyperVGenerations') -and
        'V2' -in @(
            $capabilitiesByName['HyperVGenerations'] -split '[,\s]+' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    )

    $normalized = [ordered]@{
        name                      = $vmSize
        location                  = $location
        available                 = (
            -not $blocked -and
            $encryptionAtHostSupported -and
            $trustedLaunchSupported -and
            $hyperVGenerationV2
        )
        encryptionAtHostSupported = $encryptionAtHostSupported
        trustedLaunchSupported    = $trustedLaunchSupported
        hyperVGenerationV2        = $hyperVGenerationV2
        capabilities              = $capabilities
        restrictions              = $restrictions
    }
    $normalized.resourceSkuHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $normalized
    )
    return $normalized
}

function Get-AdltKeyVaultCompatibilityResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    if ($Plan.configuration.security.secretStore.mode -cne 'reuse-key-vault') {
        throw 'The first canary requires a reused Key Vault.'
    }
    $vault = Get-AdltPlanResource `
        -Plan $Plan `
        -StableId 'azure.security.key-vault.primary'
    $vaultId = [string] $vault.externalResourceId
    $observed = Invoke-AdltAzCommand `
        -ModuleName 'Az.Resources' `
        -CommandName 'Get-AzResource' `
        -Parameters @{
            ResourceId       = $vaultId
            ApiVersion       = '2026-02-01'
            ExpandProperties = $true
            ErrorAction      = 'Stop'
        }
    if ($null -eq $observed) {
        throw 'The reused Key Vault returned no control-plane response.'
    }

    $observedId = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $observed `
            -Name 'ResourceId'
    )
    if ([string]::IsNullOrWhiteSpace($observedId)) {
        $observedId = [string] (
            Get-AdltObjectPropertyValue -InputObject $observed -Name 'Id'
        )
    }
    $observedType = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $observed `
            -Name 'ResourceType'
    )
    if ([string]::IsNullOrWhiteSpace($observedType)) {
        $observedType = [string] (
            Get-AdltObjectPropertyValue -InputObject $observed -Name 'Type'
        )
    }
    if (
        -not [string]::Equals(
            $observedId,
            $vaultId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            $observedType,
            'Microsoft.KeyVault/vaults',
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'The Key Vault control-plane response does not match the planned resource.'
    }

    $properties = Get-AdltObjectPropertyValue `
        -InputObject $observed `
        -Name 'Properties'
    $tenantId = [string] (
        Get-AdltObjectPropertyValue -InputObject $properties -Name 'TenantId'
    )
    $provisioningState = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $properties `
            -Name 'ProvisioningState'
    )
    $rbacEnabled = [bool] (
        Get-AdltObjectPropertyValue `
            -InputObject $properties `
            -Name 'EnableRbacAuthorization'
    )
    $templateDeploymentEnabled = [bool] (
        Get-AdltObjectPropertyValue `
            -InputObject $properties `
            -Name 'EnabledForTemplateDeployment'
    )
    $purgeProtectionEnabled = [bool] (
        Get-AdltObjectPropertyValue `
            -InputObject $properties `
            -Name 'EnablePurgeProtection'
    )
    $softDeleteRetentionDays = [int] (
        Get-AdltObjectPropertyValue `
            -InputObject $properties `
            -Name 'SoftDeleteRetentionInDays'
    )
    $publicNetworkAccess = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $properties `
            -Name 'PublicNetworkAccess'
    )
    $networkAcls = Get-AdltObjectPropertyValue `
        -InputObject $properties `
        -Name 'NetworkAcls'
    $networkDefaultAction = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $networkAcls `
            -Name 'DefaultAction'
    )
    $approvedPrivateEndpointCount = @(
        foreach ($connection in @(
            Get-AdltObjectPropertyValue `
                -InputObject $properties `
                -Name 'PrivateEndpointConnections'
        )) {
            $status = [string] (
                Get-AdltObjectPathValue `
                    -InputObject $connection `
                    -Path 'Properties.PrivateLinkServiceConnectionState.Status'
            )
            $state = [string] (
                Get-AdltObjectPathValue `
                    -InputObject $connection `
                    -Path 'Properties.ProvisioningState'
            )
            if ($status -ieq 'Approved' -and $state -ieq 'Succeeded') {
                $connection
            }
        }
    ).Count

    if (
        -not [string]::Equals(
            $tenantId,
            [string] $Plan.context.tenantId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $provisioningState -ine 'Succeeded' -or
        -not $rbacEnabled -or
        -not $templateDeploymentEnabled -or
        -not $purgeProtectionEnabled -or
        $softDeleteRetentionDays -lt 7 -or
        $softDeleteRetentionDays -gt 90 -or
        $publicNetworkAccess -ine 'Disabled' -or
        $networkDefaultAction -ine 'Deny' -or
        $approvedPrivateEndpointCount -lt 1
    ) {
        throw 'The reused Key Vault does not satisfy the first-canary security profile.'
    }

    $normalized = [ordered]@{
        resourceId                   = $vaultId
        apiVersion                   = '2026-02-01'
        tenantId                     = $tenantId
        provisioningState            = $provisioningState
        enableRbacAuthorization      = $rbacEnabled
        enabledForTemplateDeployment = $templateDeploymentEnabled
        purgeProtectionEnabled       = $purgeProtectionEnabled
        softDeleteRetentionDays      = $softDeleteRetentionDays
        publicNetworkAccess          = $publicNetworkAccess
        networkDefaultAction         = $networkDefaultAction
        approvedPrivateEndpointCount = $approvedPrivateEndpointCount
    }
    $normalized.resourceStateHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $normalized
    )
    return $normalized
}

function Get-AdltSecretVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Metadata
    )

    $version = [string] (
        Get-AdltObjectPropertyValue -InputObject $Metadata -Name 'Version'
    )
    if (-not [string]::IsNullOrWhiteSpace($version)) {
        return $version
    }
    $id = [string] (
        Get-AdltObjectPropertyValue -InputObject $Metadata -Name 'Id'
    )
    $match = [regex]::Match(
        $id,
        '/secrets/[^/]+/(?<version>[0-9a-fA-F]{32})/?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($match.Success) {
        return $match.Groups['version'].Value
    }
    return ''
}

function Get-AdltKeyVaultSecretMetadataResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [datetimeoffset] $ObservedAt = [datetimeoffset]::UtcNow
    )

    $vaultId = [string] (
        $Plan.configuration.security.secretStore.resourceId
    )
    $credential = $Plan.configuration.security.vmAdministratorCredential
    $vaultName = Get-AdltResourceNameFromId -ResourceId $vaultId
    $secretName = [string] $credential.secretName
    $secretVersion = [string] $credential.secretVersion
    $secretResourceId = '{0}/secrets/{1}' -f
        $vaultId.TrimEnd('/'),
        $secretName
    $metadata = Invoke-AdltAzCommand `
        -ModuleName 'Az.Resources' `
        -CommandName 'Get-AzResource' `
        -Parameters @{
            ResourceId       = $secretResourceId
            ApiVersion       = '2026-02-01'
            ExpandProperties = $true
            ErrorAction      = 'Stop'
        }
    $observedId = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $metadata `
            -Name 'ResourceId'
    )
    $observedType = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $metadata `
            -Name 'ResourceType'
    )
    if (
        -not [string]::Equals(
            $observedId,
            $secretResourceId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::Equals(
            $observedType,
            'Microsoft.KeyVault/vaults/secrets',
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw (
            'The Key Vault secret control-plane response does not match ' +
            'the plan.'
        )
    }
    $properties = Get-AdltObjectPropertyValue `
        -InputObject $metadata `
        -Name 'Properties'
    foreach ($forbiddenProperty in @('SecretValue', 'SecretValueText', 'Value')) {
        $containsForbiddenProperty = if (
            $properties -is [System.Collections.IDictionary]
        ) {
            $properties.Contains($forbiddenProperty)
        }
        else {
            $properties.PSObject.Properties.Name -contains
                $forbiddenProperty
        }
        if ($containsForbiddenProperty) {
            throw (
                'The Key Vault control-plane lookup returned a ' +
                'secret-bearing property.'
            )
        }
    }

    $id = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $properties `
            -Name 'SecretUriWithVersion'
    )
    $expectedIdPattern = (
        '^https://{0}\.vault\.azure\.net/secrets/{1}/{2}/?$'
    ) -f
        [regex]::Escape($vaultName),
        [regex]::Escape($secretName),
        [regex]::Escape($secretVersion)
    if ($id -notmatch $expectedIdPattern) {
        throw 'The pinned Key Vault secret version does not match the plan.'
    }

    $attributes = Get-AdltObjectPropertyValue `
        -InputObject $properties `
        -Name 'Attributes'
    $enabled = [bool] (
        Get-AdltObjectPropertyValue `
            -InputObject $attributes `
            -Name 'Enabled'
    )
    $notBeforeValue = Get-AdltObjectPropertyValue `
        -InputObject $attributes `
        -Name 'Nbf'
    $expiresValue = Get-AdltObjectPropertyValue `
        -InputObject $attributes `
        -Name 'Exp'
    $integerTypes = @(
        [byte]
        [sbyte]
        [int16]
        [uint16]
        [int32]
        [uint32]
        [int64]
    )
    $notBefore = if ($null -eq $notBeforeValue) {
        $null
    }
    elseif ($notBeforeValue.GetType() -in $integerTypes) {
        [datetimeoffset]::FromUnixTimeSeconds([int64] $notBeforeValue)
    }
    else {
        [datetimeoffset] $notBeforeValue
    }
    $expires = if ($null -eq $expiresValue) {
        $null
    }
    elseif ($expiresValue.GetType() -in $integerTypes) {
        [datetimeoffset]::FromUnixTimeSeconds([int64] $expiresValue)
    }
    else {
        [datetimeoffset] $expiresValue
    }
    $notBeforeSatisfied = (
        $null -eq $notBefore -or
        [datetimeoffset] $notBefore -le $ObservedAt
    )
    $expiresAfterMinimumWindow = (
        $null -eq $expires -or
        [datetimeoffset] $expires -gt $ObservedAt.AddMinutes(30)
    )
    if (
        -not $enabled -or
        -not $notBeforeSatisfied -or
        -not $expiresAfterMinimumWindow
    ) {
        throw 'The pinned Key Vault secret version is disabled or outside its validity window.'
    }

    $normalized = [ordered]@{
        vaultResourceId          = $vaultId
        secretName               = $secretName
        version                  = (
            Get-AdltSecretVersion -Metadata ([pscustomobject]@{ Id = $id })
        )
        enabled                  = $enabled
        notBeforeSatisfied       = $notBeforeSatisfied
        expiresAfterMinimumWindow = $expiresAfterMinimumWindow
        notBeforeAt              = if ($null -eq $notBefore) {
            $null
        }
        else {
            ConvertTo-AdltUtcTimestamp -Value ([datetimeoffset] $notBefore)
        }
        expiresAt                = if ($null -eq $expires) {
            $null
        }
        else {
            ConvertTo-AdltUtcTimestamp -Value ([datetimeoffset] $expires)
        }
    }
    $normalized.metadataHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $normalized
    )
    return $normalized
}

function Get-AdltKeyVaultDiagnosticResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $vaultId = [string] (
        $Plan.configuration.security.secretStore.resourceId
    )
    $expectedDestination = [string] (
        $Plan.configuration.security.secretStore.diagnosticDestinationResourceId
    )
    $normalizedSettings = @(
        foreach ($setting in @(
            Invoke-AdltAzCommand `
                -ModuleName 'Az.Monitor' `
                -CommandName 'Get-AzDiagnosticSetting' `
                -Parameters @{
                    ResourceId = $vaultId
                    ErrorAction = 'Stop'
                }
        )) {
            $workspaceId = [string] (
                Get-AdltObjectPropertyValue `
                    -InputObject $setting `
                    -Name 'WorkspaceId'
            )
            $selectors = @(
                foreach ($log in @(
                    Get-AdltObjectPropertyValue `
                        -InputObject $setting `
                        -Name 'Log'
                )) {
                    $enabled = [bool] (
                        Get-AdltObjectPropertyValue `
                            -InputObject $log `
                            -Name 'Enabled'
                    )
                    if (-not $enabled) {
                        continue
                    }
                    $category = [string] (
                        Get-AdltObjectPropertyValue `
                            -InputObject $log `
                            -Name 'Category'
                    )
                    $categoryGroup = [string] (
                        Get-AdltObjectPropertyValue `
                            -InputObject $log `
                            -Name 'CategoryGroup'
                    )
                    if (-not [string]::IsNullOrWhiteSpace($category)) {
                        "category:$category"
                    }
                    if (-not [string]::IsNullOrWhiteSpace($categoryGroup)) {
                        "categoryGroup:$categoryGroup"
                    }
                }
            )
            [ordered]@{
                settingName = [string] (
                    Get-AdltObjectPropertyValue `
                        -InputObject $setting `
                        -Name 'Name'
                )
                destinationResourceId = $workspaceId
                enabledLogSelectors  = @($selectors | Sort-Object -Unique)
                auditEnabled         = (
                    'category:AuditEvent' -iin $selectors -or
                    'categoryGroup:audit' -iin $selectors -or
                    'categoryGroup:allLogs' -iin $selectors
                )
            }
        }
    )
    $matching = @(
        $normalizedSettings |
            Where-Object {
                $_.auditEnabled -and
                [string]::Equals(
                    [string] $_.destinationResourceId,
                    $expectedDestination,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($matching.Count -ne 1) {
        throw 'Key Vault audit diagnostics did not resolve exactly once at the approved destination.'
    }

    $normalized = $matching[0]
    $normalized.settingsHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $normalized
    )
    return $normalized
}

function Invoke-AdltLiveResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $context = Assert-AdltAzureContextReady -Plan $Plan
    $probes = [System.Collections.Generic.List[object]]::new()
    $providerStates = [System.Collections.Generic.List[object]]::new()
    $observedAt = ConvertTo-AdltUtcTimestamp -Value ([datetimeoffset]::UtcNow)

    foreach ($namespace in Get-AdltProviderNamespaceSet -Plan $Plan) {
        try {
            $provider = Invoke-AdltAzCommand `
                -ModuleName 'Az.Resources' `
                -CommandName 'Get-AzResourceProvider' `
                -Parameters @{
                    ProviderNamespace = $namespace
                    ErrorAction       = 'Stop'
                }
            $registered = $provider.RegistrationState -eq 'Registered'
            $providerStates.Add([ordered]@{
                namespace         = $namespace
                registrationState = [string] $provider.RegistrationState
            })
            $probes.Add([ordered]@{
                probeId       = 'probe.azure.provider.{0}' -f $namespace.ToLowerInvariant()
                status        = if ($registered) { 'pass' } else { 'fail' }
                correlationIds = @()
                observedAt    = $observedAt
                message       = if ($registered) {
                    'The Azure resource provider is registered.'
                }
                else {
                    'The Azure resource provider is not registered.'
                }
                payload       = [ordered]@{
                    namespace         = $namespace
                    registrationState = [string] $provider.RegistrationState
                }
            })
        }
        catch {
            $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
            $probes.Add([ordered]@{
                probeId       = 'probe.azure.provider.{0}' -f $namespace.ToLowerInvariant()
                status        = if ($failureKind -eq 'denied') { 'denied' } else { 'unverified' }
                correlationIds = @()
                observedAt    = $observedAt
                message       = 'The Azure resource-provider state could not be verified.'
                payload       = [ordered]@{
                    namespace   = $namespace
                    failureKind = $failureKind
                }
            })
        }
    }

    $imageResolution = $null
    try {
        $imageResolution = Get-AdltSqlVmImageResolution -Plan $Plan
        $probes.Add([ordered]@{
            probeId       = 'probe.compute.marketplace-image'
            status        = 'pass'
            correlationIds = @()
            observedAt    = $observedAt
            message       = 'An immutable marketplace image version was resolved.'
            payload       = Copy-AdltValue -InputObject $imageResolution
        })
    }
    catch {
        $probes.Add([ordered]@{
            probeId       = 'probe.compute.marketplace-image'
            status        = 'unverified'
            correlationIds = @()
            observedAt    = $observedAt
            message       = 'The marketplace image version could not be resolved.'
            payload       = [ordered]@{
                failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
            }
        })
    }

    $skuResolution = $null
    try {
        $skuResolution = Get-AdltSqlVmSkuResolution -Plan $Plan
        $probes.Add([ordered]@{
            probeId       = 'probe.compute.vm-sku'
            status        = if ($skuResolution.available) { 'pass' } else { 'fail' }
            correlationIds = @()
            observedAt    = $observedAt
            message       = if ($skuResolution.available) {
                'The VM size is available in the target region and subscription.'
            }
            else {
                'The VM size is restricted in the target region or subscription.'
            }
            payload       = Copy-AdltValue -InputObject $skuResolution
        })
    }
    catch {
        $probes.Add([ordered]@{
            probeId       = 'probe.compute.vm-sku'
            status        = 'unverified'
            correlationIds = @()
            observedAt    = $observedAt
            message       = 'VM size availability could not be verified.'
            payload       = [ordered]@{
                failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
            }
        })
    }

    $keyVaultResolution = $null
    try {
        $keyVaultResolution = Get-AdltKeyVaultCompatibilityResolution `
            -Plan $Plan
        $probes.Add([ordered]@{
            probeId        = 'probe.security.key-vault-compatibility'
            status         = 'pass'
            correlationIds = @()
            observedAt     = $observedAt
            message        = 'The reused Key Vault satisfies the first-canary security profile.'
            payload        = Copy-AdltValue -InputObject $keyVaultResolution
        })
    }
    catch {
        $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
        $probes.Add([ordered]@{
            probeId        = 'probe.security.key-vault-compatibility'
            status         = if ($failureKind -eq 'denied') {
                'denied'
            }
            else {
                'unverified'
            }
            correlationIds = @()
            observedAt     = $observedAt
            message        = 'The reused Key Vault security profile could not be verified.'
            payload        = [ordered]@{
                failureKind = $failureKind
            }
        })
    }

    $secretMetadata = $null
    try {
        $secretMetadata = Get-AdltKeyVaultSecretMetadataResolution `
            -Plan $Plan `
            -ObservedAt ([datetimeoffset]::UtcNow)
        $probes.Add([ordered]@{
            probeId        = 'probe.security.key-vault-secret-version'
            status         = 'pass'
            correlationIds = @()
            observedAt     = $observedAt
            message        = 'The pinned Key Vault secret version metadata is valid.'
            payload        = Copy-AdltValue -InputObject $secretMetadata
        })
    }
    catch {
        $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
        $probes.Add([ordered]@{
            probeId        = 'probe.security.key-vault-secret-version'
            status         = if ($failureKind -eq 'denied') {
                'denied'
            }
            else {
                'unverified'
            }
            correlationIds = @()
            observedAt     = $observedAt
            message        = 'The pinned Key Vault secret version metadata could not be verified.'
            payload        = [ordered]@{
                failureKind = $failureKind
            }
        })
    }

    $diagnosticResolution = $null
    try {
        $diagnosticResolution = Get-AdltKeyVaultDiagnosticResolution `
            -Plan $Plan
        $probes.Add([ordered]@{
            probeId        = 'probe.security.key-vault-diagnostics'
            status         = 'pass'
            correlationIds = @()
            observedAt     = $observedAt
            message        = 'Key Vault audit diagnostics target the approved destination.'
            payload        = Copy-AdltValue -InputObject $diagnosticResolution
        })
    }
    catch {
        $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
        $probes.Add([ordered]@{
            probeId        = 'probe.security.key-vault-diagnostics'
            status         = if ($failureKind -eq 'denied') {
                'denied'
            }
            else {
                'unverified'
            }
            correlationIds = @()
            observedAt     = $observedAt
            message        = 'Key Vault audit diagnostics could not be verified.'
            payload        = [ordered]@{
                failureKind = $failureKind
            }
        })
    }

    $principalObjectId = $null
    $principalType = $null
    try {
        if ([string] $context.accountType -cne 'User') {
            throw (
                'The first canary currently supports only an interactive ' +
                'user deployment principal.'
            )
        }
        $principal = Invoke-AdltAzCommand `
            -ModuleName 'Az.Resources' `
            -CommandName 'Get-AzADUser' `
            -Parameters @{
                SignedIn    = $true
                ErrorAction = 'Stop'
            }
        $principalObjectId = [string] $principal.Id
        if ([string]::IsNullOrWhiteSpace($principalObjectId)) {
            throw 'The signed-in principal object ID was empty.'
        }
        $principalType = 'user'
        $probes.Add([ordered]@{
            probeId       = 'probe.azure.principal'
            status        = 'pass'
            correlationIds = @()
            observedAt    = $observedAt
            message       = 'The signed-in deployment principal object ID was resolved.'
            payload       = [ordered]@{
                objectId = $principalObjectId
                type     = 'user'
            }
        })
    }
    catch {
        $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
        $probes.Add([ordered]@{
            probeId       = 'probe.azure.principal'
            status        = if ($failureKind -eq 'denied') { 'denied' } else { 'unverified' }
            correlationIds = @()
            observedAt    = $observedAt
            message       = 'The signed-in deployment principal object ID could not be resolved.'
            payload       = [ordered]@{
                failureKind = $failureKind
            }
        })
    }

    return [ordered]@{
        context              = $context
        providerStates       = $providerStates.ToArray()
        imageResolution      = $imageResolution
        skuResolution        = $skuResolution
        keyVaultResolution   = $keyVaultResolution
        secretMetadata       = $secretMetadata
        diagnosticResolution = $diagnosticResolution
        principalObjectId    = $principalObjectId
        principalType        = $principalType
        requiredAuthorizations = @(
            [ordered]@{
                action = 'Microsoft.KeyVault/vaults/deploy/action'
                validationStage = 'native-provider-what-if'
            }
        )
        resources            = Get-AdltResolvedResourceIdSet -Plan $Plan
        resolvedPolicyFindingIds = @(
            if ($null -ne $imageResolution) {
                'policy.compute.image-version-unresolved'
            }
            if ($null -ne $keyVaultResolution) {
                'policy.secret-store.compatibility-unresolved'
            }
            if ($null -ne $secretMetadata) {
                'policy.credentials.secret-version-unresolved'
            }
            if ($null -ne $diagnosticResolution) {
                'policy.secret-store.diagnostics-unresolved'
            }
        )
        probes               = $probes.ToArray()
    }
}
