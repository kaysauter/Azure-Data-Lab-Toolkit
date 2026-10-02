function Assert-AdltCostSourceUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SourceUri
    )

    $uri = $null
    if (
        -not [uri]::TryCreate(
            $SourceUri,
            [System.UriKind]::Absolute,
            [ref] $uri
        ) -or
        $uri.Scheme -cne 'https' -or
        $uri.Host -cne 'prices.azure.com' -or
        $uri.AbsolutePath.TrimEnd('/') -cne '/api/retail/prices' -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)
    ) {
        throw (
            'The cost source URI must be the HTTPS Azure Retail Prices API ' +
            'endpoint without user information, query parameters, or fragments.'
        )
    }
}

function Assert-AdltCostLiveResolutionBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    Assert-AdltPlanContract -Plan $Plan
    Assert-AdltEvidence -Evidence $LiveResolutionEvidence

    if ($Plan.target.type -cne 'sqlVm') {
        throw 'SQL VM cost estimation requires a SQL VM plan.'
    }
    if ($LiveResolutionEvidence.stage -cne 'live-resolution') {
        throw 'Cost estimation requires live-resolution evidence.'
    }
    if ($LiveResolutionEvidence.status -cne 'pass') {
        throw 'Cost estimation requires passing live-resolution evidence.'
    }
    if ($LiveResolutionEvidence.runId -cne $RunId) {
        throw 'Live-resolution evidence run ID does not match the cost-estimate run.'
    }
    if ($LiveResolutionEvidence.planHash -cne $Plan.planHash) {
        throw 'Live-resolution evidence plan hash does not match the supplied plan.'
    }
    if ($LiveResolutionEvidence.intentHash -cne $Plan.intentHash) {
        throw 'Live-resolution evidence intent hash does not match the supplied plan.'
    }

    $payload = $LiveResolutionEvidence.payload
    if (
        $payload -isnot [System.Collections.IDictionary] -or
        -not $payload.Contains('context') -or
        -not $payload.Contains('imageResolution') -or
        -not $payload.Contains('skuResolution') -or
        -not $payload.Contains('resources')
    ) {
        throw 'Live-resolution evidence does not contain the required bound facts.'
    }

    $context = $payload.context
    foreach ($field in @('cloud', 'tenantId', 'subscriptionId')) {
        if (
            $context -isnot [System.Collections.IDictionary] -or
            -not $context.Contains($field) -or
            [string] $context[$field] -cne [string] $Plan.context[$field]
        ) {
            throw "Live-resolution evidence context field '$field' is not bound to the plan."
        }
    }

    $virtualMachine = Get-AdltPlanResource `
        -Plan $Plan `
        -StableId 'azure.compute.virtual-machine.primary'
    $sku = $payload.skuResolution
    if (
        $sku -isnot [System.Collections.IDictionary] -or
        [string] $sku.name -cne
            [string] $virtualMachine.desiredProperties.hardwareProfile.vmSize -or
        [string] $sku.location -cne [string] $Plan.context.location -or
        [bool] $sku.available -ne $true
    ) {
        throw 'Live-resolution evidence does not bind an available planned VM SKU.'
    }

    $plannedImage = $virtualMachine.desiredProperties.imageReference
    $resolvedImage = $payload.imageResolution
    foreach ($field in @('publisher', 'offer', 'sku')) {
        if (
            $resolvedImage -isnot [System.Collections.IDictionary] -or
            [string] $resolvedImage[$field] -cne [string] $plannedImage[$field]
        ) {
            throw "Live-resolution evidence image field '$field' is not bound to the plan."
        }
    }
    if (
        [string]::IsNullOrWhiteSpace([string] $resolvedImage.version) -or
        [string] $resolvedImage.version -in @('latest', 'unresolved')
    ) {
        throw 'Live-resolution evidence does not contain an immutable image version.'
    }

    $expectedResources = @(Get-AdltResolvedResourceIdSet -Plan $Plan)
    $observedResources = @($payload.resources)
    if ($expectedResources.Count -ne $observedResources.Count) {
        throw 'Live-resolution evidence resource IDs do not exactly match the plan.'
    }
    $observedByStableId = @{}
    foreach ($resource in $observedResources) {
        if (
            $resource -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string] $resource.stableId) -or
            $observedByStableId.ContainsKey([string] $resource.stableId)
        ) {
            throw 'Live-resolution evidence contains an invalid resource-ID binding.'
        }
        $observedByStableId[[string] $resource.stableId] = [string] $resource.resourceId
    }
    foreach ($resource in $expectedResources) {
        if (
            -not $observedByStableId.ContainsKey([string] $resource.stableId) -or
            $observedByStableId[[string] $resource.stableId] -cne
                [string] $resource.resourceId
        ) {
            throw "Live-resolution evidence resource '$($resource.stableId)' is not bound to the plan."
        }
    }
}

function Get-AdltCostCurrencyScale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z]{3}$')]
        [string] $Currency
    )

    if ($Currency -in @(
        'BIF', 'CLP', 'DJF', 'GNF', 'ISK', 'JPY', 'KMF',
        'KRW', 'PYG', 'RWF', 'UGX', 'UYI', 'VND', 'VUV',
        'XAF', 'XOF', 'XPF'
    )) {
        return [int64] 1
    }
    if ($Currency -in @('BHD', 'IQD', 'JOD', 'KWD', 'LYD', 'OMR', 'TND')) {
        return [int64] 1000
    }

    return [int64] 100
}

function ConvertTo-AdltCostDecimal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Value
    )

    $text = if ($Value -is [string]) {
        $Value
    }
    elseif ($Value -is [System.IFormattable]) {
        $Value.ToString(
            $null,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    else {
        [string] $Value
    }

    $result = [decimal] 0
    if (
        -not [decimal]::TryParse(
            $text,
            [System.Globalization.NumberStyles]::Number,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref] $result
        )
    ) {
        throw 'The Retail Prices API row does not contain a valid decimal price.'
    }

    return $result
}

function ConvertTo-AdltCostScaledInteger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [decimal] $Value,

        [Parameter(Mandatory)]
        [ValidateRange(1, 1000000000)]
        [int64] $Scale
    )

    $scaled = [decimal]::Round(
        ($Value * [decimal] $Scale),
        0,
        [System.MidpointRounding]::AwayFromZero
    )
    if (
        $scaled -lt [decimal] -9007199254740991 -or
        $scaled -gt [decimal] 9007199254740991
    ) {
        throw 'The scaled price exceeds the interoperable evidence integer range.'
    }

    return [int64] $scaled
}

function Get-AdltManagedDiskMeterName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $StorageType,

        [Parameter(Mandatory)]
        [int] $SizeGiB
    )

    $prefix = switch ($StorageType) {
        'Premium_LRS' { 'P' }
        'StandardSSD_LRS' { 'E' }
        'Standard_LRS' { 'S' }
        default { return $null }
    }
    $tiers = @(
        [pscustomobject]@{ SizeGiB = 4; Tier = 1 }
        [pscustomobject]@{ SizeGiB = 8; Tier = 2 }
        [pscustomobject]@{ SizeGiB = 16; Tier = 3 }
        [pscustomobject]@{ SizeGiB = 32; Tier = 4 }
        [pscustomobject]@{ SizeGiB = 64; Tier = 6 }
        [pscustomobject]@{ SizeGiB = 128; Tier = 10 }
        [pscustomobject]@{ SizeGiB = 256; Tier = 15 }
        [pscustomobject]@{ SizeGiB = 512; Tier = 20 }
        [pscustomobject]@{ SizeGiB = 1024; Tier = 30 }
        [pscustomobject]@{ SizeGiB = 2048; Tier = 40 }
        [pscustomobject]@{ SizeGiB = 4096; Tier = 50 }
        [pscustomobject]@{ SizeGiB = 8192; Tier = 60 }
        [pscustomobject]@{ SizeGiB = 16384; Tier = 70 }
        [pscustomobject]@{ SizeGiB = 32767; Tier = 80 }
    )
    $tier = $tiers |
        Where-Object SizeGiB -GE $SizeGiB |
        Select-Object -First 1
    if ($null -eq $tier) {
        return $null
    }

    return '{0}{1} LRS Disk' -f $prefix, $tier.Tier
}

function New-AdltCostRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ComponentId,

        [Parameter(Mandatory)]
        [string] $ComponentKind,

        [Parameter(Mandatory)]
        [string] $ResourceStableId,

        [Parameter(Mandatory)]
        [ValidateSet('create', 'reuse', 'observe')]
        [string] $OwnershipIntent,

        [Parameter(Mandatory)]
        [ValidateSet('hourly', 'monthly', 'gigabyte-monthly', 'fixed-zero')]
        [string] $BillingModel,

        [Parameter(Mandatory)]
        [string] $UnitOfMeasure,

        [Parameter(Mandatory)]
        [int] $Quantity,

        [Parameter(Mandatory)]
        [int] $BillingDurationMinutes,

        [Parameter(Mandatory)]
        [bool] $StillBillableAfterShutdown,

        [Parameter(Mandatory)]
        [ValidateSet('high', 'medium', 'low')]
        [string] $VerifiedConfidence,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Selector
    )

    return [ordered]@{
        componentId                   = $ComponentId
        componentKind                 = $ComponentKind
        resourceStableId              = $ResourceStableId
        ownershipIntent               = $OwnershipIntent
        billingModel                  = $BillingModel
        unitOfMeasure                 = $UnitOfMeasure
        quantity                      = $Quantity
        billingDurationMinutes        = $BillingDurationMinutes
        stillBillableAfterShutdown    = $StillBillableAfterShutdown
        verifiedConfidence            = $VerifiedConfidence
        requiredForIncrementalEstimate = (
            $OwnershipIntent -eq 'create' -and
            $BillingModel -ne 'fixed-zero'
        )
        selector                      = Copy-AdltValue -InputObject $Selector
    }
}

function Get-AdltSqlVmCostRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    Assert-AdltCostLiveResolutionBinding `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence `
        -RunId $RunId

    $requirements = [System.Collections.Generic.List[object]]::new()
    $location = [string] $Plan.context.location
    $maximumRuntimeMinutes =
        [int] $Plan.configuration.lifecycle.maximumRuntimeMinutes
    $billingDurationMinutes =
        [int] $Plan.configuration.lifecycle.timeToLiveMinutes
    $virtualMachine = Get-AdltPlanResource `
        -Plan $Plan `
        -StableId 'azure.compute.virtual-machine.primary'
    $resolvedImage = $LiveResolutionEvidence.payload.imageResolution
    $vmSize = [string] $virtualMachine.desiredProperties.hardwareProfile.vmSize

    $requirements.Add((New-AdltCostRequirement `
        -ComponentId 'cost.compute.virtual-machine.primary' `
        -ComponentKind 'vm-compute' `
        -ResourceStableId $virtualMachine.id `
        -OwnershipIntent $virtualMachine.ownership.intent `
        -BillingModel hourly `
        -UnitOfMeasure '1 Hour' `
        -Quantity 1 `
        -BillingDurationMinutes $maximumRuntimeMinutes `
        -StillBillableAfterShutdown $false `
        -VerifiedConfidence high `
        -Selector ([ordered]@{
            serviceName = 'Virtual Machines'
            armRegionName = $location
            armSkuName = $vmSize
            productNameContains = 'Windows'
            imagePublisher = [string] $resolvedImage.publisher
            imageOffer = [string] $resolvedImage.offer
            imageSku = [string] $resolvedImage.sku
            imageVersion = [string] $resolvedImage.version
        })))

    $osDisk = $virtualMachine.desiredProperties.storageProfile.osDisk
    $osMeterName = Get-AdltManagedDiskMeterName `
        -StorageType ([string] $osDisk.storageType) `
        -SizeGiB ([int] $osDisk.sizeGiB)
    $requirements.Add((New-AdltCostRequirement `
        -ComponentId 'cost.compute.disk.os' `
        -ComponentKind 'managed-disk-os' `
        -ResourceStableId $virtualMachine.id `
        -OwnershipIntent $virtualMachine.ownership.intent `
        -BillingModel monthly `
        -UnitOfMeasure '1/Month' `
        -Quantity 1 `
        -BillingDurationMinutes $billingDurationMinutes `
        -StillBillableAfterShutdown $true `
        -VerifiedConfidence medium `
        -Selector ([ordered]@{
            serviceName = 'Storage'
            armRegionName = $location
            storageType = [string] $osDisk.storageType
            sizeGiB = [int] $osDisk.sizeGiB
            meterName = $osMeterName
        })))

    foreach ($disk in @($virtualMachine.desiredProperties.storageProfile.dataDisks)) {
        $purpose = ([string] $disk.purpose).ToLowerInvariant() -replace '[^a-z0-9-]', '-'
        $meterName = Get-AdltManagedDiskMeterName `
            -StorageType ([string] $disk.storageType) `
            -SizeGiB ([int] $disk.sizeGiB)
        $requirements.Add((New-AdltCostRequirement `
            -ComponentId ('cost.compute.disk.data.{0}.{1}' -f $disk.lun, $purpose) `
            -ComponentKind 'managed-disk-data' `
            -ResourceStableId $virtualMachine.id `
            -OwnershipIntent $virtualMachine.ownership.intent `
            -BillingModel monthly `
            -UnitOfMeasure '1/Month' `
            -Quantity 1 `
            -BillingDurationMinutes $billingDurationMinutes `
            -StillBillableAfterShutdown $true `
            -VerifiedConfidence medium `
            -Selector ([ordered]@{
                serviceName = 'Storage'
                armRegionName = $location
                storageType = [string] $disk.storageType
                sizeGiB = [int] $disk.sizeGiB
                meterName = $meterName
            })))
    }

    foreach ($bastion in @(
        $Plan.resources |
            Where-Object type -EQ 'Microsoft.Network/bastionHosts'
    )) {
        $requirements.Add((New-AdltCostRequirement `
            -ComponentId ('cost.network.bastion.{0}' -f $bastion.id.Split('.')[-1]) `
            -ComponentKind 'azure-bastion' `
            -ResourceStableId $bastion.id `
            -OwnershipIntent $bastion.ownership.intent `
            -BillingModel hourly `
            -UnitOfMeasure '1 Hour' `
            -Quantity 1 `
            -BillingDurationMinutes $billingDurationMinutes `
            -StillBillableAfterShutdown $true `
            -VerifiedConfidence high `
            -Selector ([ordered]@{
                serviceName = 'Azure Bastion'
                armRegionName = $location
                skuName = [string] $bastion.desiredProperties.sku
                meterName = [string] $bastion.desiredProperties.sku
            })))
    }

    foreach ($publicIp in @(
        $Plan.resources |
            Where-Object type -EQ 'Microsoft.Network/publicIPAddresses'
    )) {
        $requirements.Add((New-AdltCostRequirement `
            -ComponentId ('cost.network.public-ip.{0}' -f $publicIp.id.Split('.')[-1]) `
            -ComponentKind 'public-ip-address' `
            -ResourceStableId $publicIp.id `
            -OwnershipIntent $publicIp.ownership.intent `
            -BillingModel hourly `
            -UnitOfMeasure '1 Hour' `
            -Quantity 1 `
            -BillingDurationMinutes $billingDurationMinutes `
            -StillBillableAfterShutdown $true `
            -VerifiedConfidence high `
            -Selector ([ordered]@{
                serviceName = 'Virtual Network'
                armRegionName = $location
                skuName = [string] $publicIp.desiredProperties.sku
                allocationMethod = [string] $publicIp.desiredProperties.allocationMethod
                meterName = 'Standard IPv4 Static Public IP'
            })))
    }

    foreach ($privateEndpoint in @(
        $Plan.resources |
            Where-Object type -EQ 'Microsoft.Network/privateEndpoints'
    )) {
        $componentSuffix = $privateEndpoint.id -replace '^azure\.network\.private-endpoint\.', ''
        $requirements.Add((New-AdltCostRequirement `
            -ComponentId ('cost.network.private-endpoint.{0}' -f $componentSuffix) `
            -ComponentKind 'private-endpoint' `
            -ResourceStableId $privateEndpoint.id `
            -OwnershipIntent $privateEndpoint.ownership.intent `
            -BillingModel hourly `
            -UnitOfMeasure '1 Hour' `
            -Quantity 1 `
            -BillingDurationMinutes $billingDurationMinutes `
            -StillBillableAfterShutdown $true `
            -VerifiedConfidence high `
            -Selector ([ordered]@{
                serviceName = 'Virtual Network'
                armRegionName = $location
                meterName = 'Private Endpoint'
            })))
    }

    foreach ($dnsZone in @(
        $Plan.resources |
            Where-Object type -EQ 'Microsoft.Network/privateDnsZones'
    )) {
        $componentSuffix = $dnsZone.id -replace '^azure\.network\.private-dns-zone\.', ''
        $requirements.Add((New-AdltCostRequirement `
            -ComponentId ('cost.network.private-dns-zone.{0}' -f $componentSuffix) `
            -ComponentKind 'private-dns-zone' `
            -ResourceStableId $dnsZone.id `
            -OwnershipIntent $dnsZone.ownership.intent `
            -BillingModel monthly `
            -UnitOfMeasure '1/Month' `
            -Quantity 1 `
            -BillingDurationMinutes $billingDurationMinutes `
            -StillBillableAfterShutdown $true `
            -VerifiedConfidence medium `
            -Selector ([ordered]@{
                serviceName = 'Azure DNS'
                armRegionName = $location
                meterName = 'Private Zone'
            })))
    }

    foreach ($storageAccount in @(
        $Plan.resources |
            Where-Object type -EQ 'Microsoft.Storage/storageAccounts'
    )) {
        $componentSuffix = $storageAccount.id -replace '^azure\.storage\.account\.', ''
        $requirements.Add((New-AdltCostRequirement `
            -ComponentId ('cost.storage.account.{0}' -f $componentSuffix) `
            -ComponentKind 'storage-account-container' `
            -ResourceStableId $storageAccount.id `
            -OwnershipIntent $storageAccount.ownership.intent `
            -BillingModel fixed-zero `
            -UnitOfMeasure 'No fixed resource charge' `
            -Quantity 1 `
            -BillingDurationMinutes $billingDurationMinutes `
            -StillBillableAfterShutdown $true `
            -VerifiedConfidence high `
            -Selector ([ordered]@{
                serviceName = 'Storage'
                armRegionName = $location
                skuName = [string] $storageAccount.desiredProperties.sku
            })))
    }

    foreach ($fileShare in @(
        $Plan.resources |
            Where-Object type -EQ 'Microsoft.Storage/storageAccounts/fileServices/shares'
    )) {
        $componentSuffix = $fileShare.id -replace '^azure\.storage\.file-share\.', ''
        $requirements.Add((New-AdltCostRequirement `
            -ComponentId ('cost.storage.file-share.{0}' -f $componentSuffix) `
            -ComponentKind 'azure-files-capacity' `
            -ResourceStableId $fileShare.id `
            -OwnershipIntent $fileShare.ownership.intent `
            -BillingModel gigabyte-monthly `
            -UnitOfMeasure '1 GB/Month' `
            -Quantity ([int] $fileShare.desiredProperties.quotaGiB) `
            -BillingDurationMinutes $billingDurationMinutes `
            -StillBillableAfterShutdown $true `
            -VerifiedConfidence low `
            -Selector ([ordered]@{
                serviceName = 'Storage'
                armRegionName = $location
                redundancy = 'LRS'
                accessTier = [string] $fileShare.desiredProperties.accessTier
                meterName = 'LRS Data Stored'
            })))
    }

    $sqlVirtualMachine = Get-AdltPlanResource `
        -Plan $Plan `
        -StableId 'azure.sql.virtual-machine.primary'
    if ($sqlVirtualMachine.desiredProperties.sqlImageSku -cne 'Developer') {
        throw 'The cost core does not yet support a priced SQL Server license SKU.'
    }
    $requirements.Add((New-AdltCostRequirement `
        -ComponentId 'cost.sql.license.primary' `
        -ComponentKind 'sql-server-developer-license' `
        -ResourceStableId $sqlVirtualMachine.id `
        -OwnershipIntent $sqlVirtualMachine.ownership.intent `
        -BillingModel fixed-zero `
        -UnitOfMeasure 'No license charge modeled' `
        -Quantity 1 `
        -BillingDurationMinutes $maximumRuntimeMinutes `
        -StillBillableAfterShutdown $false `
        -VerifiedConfidence high `
        -Selector ([ordered]@{
            imageSku = [string] $sqlVirtualMachine.desiredProperties.sqlImageSku
            licenseType = [string] $sqlVirtualMachine.desiredProperties.sqlServerLicenseType
        })))

    return @($requirements.ToArray() | Sort-Object componentId)
}

function Get-AdltRetailPriceRow {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Response
    )

    if ($null -eq $Response) {
        return @()
    }
    if ($Response -is [System.Collections.IDictionary]) {
        if ($Response.Contains('Items')) {
            return @($Response.Items)
        }
        if ($Response.Contains('items')) {
            return @($Response.items)
        }
    }
    if (
        $Response -is [pscustomobject] -and
        $Response.PSObject.Properties.Name -contains 'Items'
    ) {
        return @($Response.Items)
    }

    return @($Response)
}

function New-AdltCostUnknown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Id,

        [Parameter(Mandatory)]
        [string] $Reason,

        [AllowNull()]
        [string] $ComponentId,

        [Parameter(Mandatory)]
        [bool] $RequiredForIncrementalEstimate
    )

    return [ordered]@{
        id                             = $Id
        reason                         = $Reason
        componentId                    = if (
            [string]::IsNullOrWhiteSpace($ComponentId)
        ) {
            $null
        }
        else {
            $ComponentId
        }
        requiredForIncrementalEstimate = $RequiredForIncrementalEstimate
    }
}

function Get-AdltCostComponentEstimate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Requirement,

        [Parameter(Mandatory)]
        [scriptblock] $PriceProvider,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z]{3}$')]
        [string] $Currency
    )

    $baseResult = [ordered]@{
        componentId                = $Requirement.componentId
        componentKind              = $Requirement.componentKind
        resourceStableId           = $Requirement.resourceStableId
        ownershipIntent            = $Requirement.ownershipIntent
        billingModel               = $Requirement.billingModel
        unitOfMeasure              = $Requirement.unitOfMeasure
        quantity                   = [int] $Requirement.quantity
        billingDurationMinutes     = [int] $Requirement.billingDurationMinutes
        stillBillableAfterShutdown = [bool] $Requirement.stillBillableAfterShutdown
        pricingStatus              = 'unverified'
        confidence                 = 'unverified'
        amountMinorUnits           = $null
        currency                   = $Currency
        priceReference             = $null
    }

    if ($Requirement.ownershipIntent -ne 'create') {
        $baseResult.pricingStatus = 'excluded-existing'
        $baseResult.confidence = 'high'
        $baseResult.amountMinorUnits = [int64] 0
        return [ordered]@{
            Component = $baseResult
            Unknown   = $null
        }
    }
    if ($Requirement.billingModel -eq 'fixed-zero') {
        $baseResult.pricingStatus = 'verified'
        $baseResult.confidence = $Requirement.verifiedConfidence
        $baseResult.amountMinorUnits = [int64] 0
        return [ordered]@{
            Component = $baseResult
            Unknown   = $null
        }
    }

    $request = [ordered]@{
        schemaVersion = '1.0'
        kind          = 'AzureRetailPriceLookup'
        componentId   = $Requirement.componentId
        componentKind = $Requirement.componentKind
        currency      = $Currency
        unitOfMeasure = $Requirement.unitOfMeasure
        selector      = Copy-AdltValue -InputObject $Requirement.selector
    }
    try {
        $response = & $PriceProvider (Copy-AdltValue -InputObject $request)
        $rows = @(Get-AdltRetailPriceRow -Response $response)
    }
    catch {
        return [ordered]@{
            Component = $baseResult
            Unknown   = New-AdltCostUnknown `
                -Id ('unknown.{0}.provider' -f $Requirement.componentId) `
                -Reason 'pricing-provider-failure' `
                -ComponentId $Requirement.componentId `
                -RequiredForIncrementalEstimate $true
        }
    }

    if ($rows.Count -ne 1) {
        $reason = if ($rows.Count -eq 0) {
            'retail-price-not-found'
        }
        else {
            'retail-price-ambiguous'
        }
        return [ordered]@{
            Component = $baseResult
            Unknown   = New-AdltCostUnknown `
                -Id ('unknown.{0}.price' -f $Requirement.componentId) `
                -Reason $reason `
                -ComponentId $Requirement.componentId `
                -RequiredForIncrementalEstimate $true
        }
    }

    $row = ConvertTo-AdltDictionary -InputObject $rows[0]
    foreach ($requiredField in @(
        'currencyCode',
        'retailPrice',
        'unitOfMeasure',
        'type',
        'meterId',
        'armRegionName',
        'serviceName',
        'productName',
        'isPrimaryMeterRegion'
    )) {
        if (
            -not $row.Contains($requiredField) -or
            [string]::IsNullOrWhiteSpace([string] $row[$requiredField])
        ) {
            return [ordered]@{
                Component = $baseResult
                Unknown   = New-AdltCostUnknown `
                    -Id ('unknown.{0}.row' -f $Requirement.componentId) `
                    -Reason 'retail-price-row-incomplete' `
                    -ComponentId $Requirement.componentId `
                    -RequiredForIncrementalEstimate $true
            }
        }
    }
    if ([string] $row.currencyCode -cne $Currency) {
        return [ordered]@{
            Component = $baseResult
            Unknown   = New-AdltCostUnknown `
                -Id ('unknown.{0}.currency' -f $Requirement.componentId) `
                -Reason 'currency-mismatch' `
                -ComponentId $Requirement.componentId `
                -RequiredForIncrementalEstimate $true
        }
    }
    if (
        [string] $row.type -cne 'Consumption' -or
        $row.isPrimaryMeterRegion -isnot [bool] -or
        [bool] $row.isPrimaryMeterRegion -ne $true -or
        [string] $row.unitOfMeasure -cne [string] $Requirement.unitOfMeasure -or
        [string] $row.armRegionName -cne
            [string] $Requirement.selector.armRegionName -or
        [string] $row.serviceName -cne
            [string] $Requirement.selector.serviceName
    ) {
        return [ordered]@{
            Component = $baseResult
            Unknown   = New-AdltCostUnknown `
                -Id ('unknown.{0}.meter' -f $Requirement.componentId) `
                -Reason 'retail-price-row-does-not-match-request' `
                -ComponentId $Requirement.componentId `
            -RequiredForIncrementalEstimate $true
        }
    }
    if (
        $Requirement.selector.Contains('productNameContains') -and
        -not [string]::IsNullOrWhiteSpace(
            [string] $Requirement.selector.productNameContains
        ) -and
        -not ([string] $row.productName).Contains(
            [string] $Requirement.selector.productNameContains,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return [ordered]@{
            Component = $baseResult
            Unknown   = New-AdltCostUnknown `
                -Id ('unknown.{0}.product' -f $Requirement.componentId) `
                -Reason 'retail-price-row-does-not-match-request' `
                -ComponentId $Requirement.componentId `
                -RequiredForIncrementalEstimate $true
        }
    }
    foreach ($selectorField in @('armSkuName', 'skuName', 'meterName')) {
        if (
            $Requirement.selector.Contains($selectorField) -and
            -not [string]::IsNullOrWhiteSpace(
                [string] $Requirement.selector[$selectorField]
            ) -and
            (
                -not $row.Contains($selectorField) -or
                [string] $row[$selectorField] -cne
                    [string] $Requirement.selector[$selectorField]
            )
        ) {
            return [ordered]@{
                Component = $baseResult
                Unknown   = New-AdltCostUnknown `
                    -Id ('unknown.{0}.selector' -f $Requirement.componentId) `
                    -Reason 'retail-price-row-does-not-match-request' `
                    -ComponentId $Requirement.componentId `
                    -RequiredForIncrementalEstimate $true
            }
        }
    }
    if (
        [string] $row.meterId -notmatch '^[A-Za-z0-9.-]{1,128}$'
    ) {
        return [ordered]@{
            Component = $baseResult
            Unknown   = New-AdltCostUnknown `
                -Id ('unknown.{0}.meter-id' -f $Requirement.componentId) `
                -Reason 'retail-price-meter-id-invalid' `
                -ComponentId $Requirement.componentId `
                -RequiredForIncrementalEstimate $true
        }
    }

    try {
        $retailPrice = ConvertTo-AdltCostDecimal -Value $row.retailPrice
        if ($retailPrice -lt [decimal] 0) {
            throw 'Negative retail prices are invalid.'
        }
        $duration = [decimal] $Requirement.billingDurationMinutes
        $quantity = [decimal] $Requirement.quantity
        $amount = switch ($Requirement.billingModel) {
            'hourly' {
                $retailPrice * $quantity * ($duration / [decimal] 60)
            }
            'monthly' {
                $retailPrice * $quantity * ($duration / [decimal] 43800)
            }
            'gigabyte-monthly' {
                $retailPrice * $quantity * ($duration / [decimal] 43800)
            }
            default {
                throw "Unsupported billing model '$($Requirement.billingModel)'."
            }
        }
        $amountMinorUnits = ConvertTo-AdltCostScaledInteger `
            -Value $amount `
            -Scale (Get-AdltCostCurrencyScale -Currency $Currency)
        $unitPriceNanoUnits = ConvertTo-AdltCostScaledInteger `
            -Value $retailPrice `
            -Scale 1000000000
    }
    catch {
        return [ordered]@{
            Component = $baseResult
            Unknown   = New-AdltCostUnknown `
                -Id ('unknown.{0}.arithmetic' -f $Requirement.componentId) `
                -Reason 'retail-price-arithmetic-invalid' `
                -ComponentId $Requirement.componentId `
                -RequiredForIncrementalEstimate $true
        }
    }

    $baseResult.pricingStatus = 'verified'
    $baseResult.confidence = $Requirement.verifiedConfidence
    $baseResult.amountMinorUnits = $amountMinorUnits
    $baseResult.priceReference = [ordered]@{
        meterId               = [string] $row.meterId
        unitPriceNanoUnits    = $unitPriceNanoUnits
        currencyUnitNanoScale = [int64] 1000000000
    }
    return [ordered]@{
        Component = $baseResult
        Unknown   = $null
    }
}

function New-AdltSqlVmCostEstimateEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId,

        [Parameter(Mandatory)]
        [scriptblock] $PriceProvider,

        [string] $SourceUri = 'https://prices.azure.com/api/retail/prices',

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Sequence = 0,

        [AllowNull()]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $PreviousEventHash,

        [datetimeoffset] $RetrievedAt = [datetimeoffset]::UtcNow
    )

    Assert-AdltCostSourceUri -SourceUri $SourceUri
    $liveResolutionCompletedAt = [datetimeoffset]::Parse(
        [string] $LiveResolutionEvidence.completedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if ($RetrievedAt -lt $liveResolutionCompletedAt) {
        throw 'Cost evidence cannot predate its live-resolution evidence.'
    }
    $requirements = @(
        Get-AdltSqlVmCostRequirement `
            -Plan $Plan `
            -LiveResolutionEvidence $LiveResolutionEvidence `
            -RunId $RunId
    )

    $currency = [string] $Plan.configuration.cost.budget.currency
    $components = [System.Collections.Generic.List[object]]::new()
    $unknowns = [System.Collections.Generic.List[object]]::new()
    foreach ($requirement in $requirements) {
        $result = Get-AdltCostComponentEstimate `
            -Requirement $requirement `
            -PriceProvider $PriceProvider `
            -Currency $currency
        $components.Add($result.Component)
        if ($null -ne $result.Unknown) {
            $unknowns.Add($result.Unknown)
        }
    }

    $unknowns.Add((New-AdltCostUnknown `
        -Id 'unknown.cost.network-egress' `
        -Reason 'usage-dependent-network-egress-not-declared-in-plan' `
        -ComponentId $null `
        -RequiredForIncrementalEstimate $false))
    if (@($Plan.resources | Where-Object type -EQ 'Microsoft.KeyVault/vaults').Count -gt 0) {
        $unknowns.Add((New-AdltCostUnknown `
            -Id 'unknown.cost.key-vault-operations' `
            -Reason 'usage-dependent-key-vault-operations-not-declared-in-plan' `
            -ComponentId $null `
            -RequiredForIncrementalEstimate $false))
    }
    if (
        @(
            $Plan.resources |
                Where-Object type -Like 'Microsoft.Storage/storageAccounts*'
        ).Count -gt 0
    ) {
        $unknowns.Add((New-AdltCostUnknown `
            -Id 'unknown.cost.storage-operations' `
            -Reason 'usage-dependent-storage-operations-and-egress-not-declared-in-plan' `
            -ComponentId $null `
            -RequiredForIncrementalEstimate $false))
    }
    if (
        @(
            $Plan.resources |
                Where-Object type -EQ 'Microsoft.Network/privateDnsZones'
        ).Count -gt 0
    ) {
        $unknowns.Add((New-AdltCostUnknown `
            -Id 'unknown.cost.private-dns-queries' `
            -Reason 'usage-dependent-private-dns-queries-not-declared-in-plan' `
            -ComponentId $null `
            -RequiredForIncrementalEstimate $false))
    }

    $knownSubtotalMinorUnits = [int64] 0
    foreach ($component in $components) {
        if ($null -ne $component.amountMinorUnits) {
            $knownSubtotalMinorUnits += [int64] $component.amountMinorUnits
        }
    }
    $requiredUnknowns = @(
        $unknowns |
            Where-Object requiredForIncrementalEstimate
    )
    $totalAmountMinorUnits = if ($requiredUnknowns.Count -eq 0) {
        $knownSubtotalMinorUnits
    }
    else {
        $null
    }

    $maximumRunCost = if (
        $Plan.configuration.cost.Contains('maximumRunCost')
    ) {
        $Plan.configuration.cost.maximumRunCost
    }
    else {
        $null
    }
    if ($null -eq $maximumRunCost) {
        $unknowns.Add((New-AdltCostUnknown `
            -Id 'unknown.cost.maximum-run-cost' `
            -Reason 'maximum-run-cost-not-defined' `
            -ComponentId $null `
            -RequiredForIncrementalEstimate $true))
        $requiredUnknowns = @(
            $unknowns |
                Where-Object requiredForIncrementalEstimate
        )
        $totalAmountMinorUnits = $null
    }

    $status = 'pass'
    $guardrailStatus = 'within-limit'
    $headroomMinorUnits = $null
    if ($requiredUnknowns.Count -gt 0) {
        $status = 'unverified'
        $guardrailStatus = 'unverified'
    }
    elseif (
        [string] $maximumRunCost.currency -cne $currency
    ) {
        $status = 'unverified'
        $guardrailStatus = 'unverified'
        $unknowns.Add((New-AdltCostUnknown `
            -Id 'unknown.cost.maximum-run-cost-currency' `
            -Reason 'maximum-run-cost-currency-mismatch' `
            -ComponentId $null `
            -RequiredForIncrementalEstimate $true))
        $totalAmountMinorUnits = $null
    }
    elseif (
        [int64] $totalAmountMinorUnits -gt
        [int64] $maximumRunCost.amountMinorUnits
    ) {
        $status = 'fail'
        $guardrailStatus = 'exceeded'
        $headroomMinorUnits =
            [int64] $maximumRunCost.amountMinorUnits -
            [int64] $totalAmountMinorUnits
    }
    else {
        $headroomMinorUnits =
            [int64] $maximumRunCost.amountMinorUnits -
            [int64] $totalAmountMinorUnits
    }
    $requiredUnknowns = @(
        $unknowns |
            Where-Object requiredForIncrementalEstimate
    )

    $stillBillable = @(
        $components |
            Where-Object stillBillableAfterShutdown |
            ForEach-Object componentId |
            Sort-Object
    )
    $payload = [ordered]@{
        estimateModelVersion       = '1.0'
        estimateScope              = 'incremental-new-resources'
        billingDurationMinutes     =
            [int] $Plan.configuration.lifecycle.timeToLiveMinutes
        activeComputeDurationMinutes =
            [int] $Plan.configuration.lifecycle.maximumRuntimeMinutes
        currency                   = $currency
        source                     = [ordered]@{
            uri         = $SourceUri
            retrievedAt = ConvertTo-AdltUtcTimestamp -Value $RetrievedAt
        }
        liveResolutionEvidenceHash = $LiveResolutionEvidence.evidenceHash
        components                 = @($components.ToArray() | Sort-Object componentId)
        knownSubtotalMinorUnits    = $knownSubtotalMinorUnits
        totalAmountMinorUnits      = $totalAmountMinorUnits
        maximumRunCost             = if ($null -eq $maximumRunCost) {
            $null
        }
        else {
            [ordered]@{
                amountMinorUnits = [int64] $maximumRunCost.amountMinorUnits
                currency         = [string] $maximumRunCost.currency
            }
        }
        guardrail                  = [ordered]@{
            status             = $guardrailStatus
            headroomMinorUnits = $headroomMinorUnits
        }
        pricingComplete            = $requiredUnknowns.Count -eq 0
        unknowns                   = @($unknowns.ToArray() | Sort-Object id)
        stillBillableAfterShutdown = $stillBillable
    }

    $evidenceParameters = @{
        RunId       = $RunId
        PlanHash    = $Plan.planHash
        IntentHash  = $Plan.intentHash
        Stage       = 'cost'
        Status      = $status
        Sequence    = $Sequence
        Payload     = $payload
        StartedAt   = $RetrievedAt
        CompletedAt = $RetrievedAt
    }
    if (-not [string]::IsNullOrWhiteSpace($PreviousEventHash)) {
        $evidenceParameters.PreviousEventHash = $PreviousEventHash
    }
    return New-AdltEvidence @evidenceParameters
}
