function Get-AdltSqlVmArmResourceContract {
    [CmdletBinding()]
    param()

    return [ordered]@{
        'azure.resource-group.primary' = [ordered]@{
            actionId   = 'action.resource-group.primary'
            type       = 'Microsoft.Resources/resourceGroups'
            apiVersion = '2024-03-01'
            disposition = 'deploy'
            taggable   = $true
        }
        'azure.network.virtual-network.primary' = [ordered]@{
            actionId   = 'action.network.virtual-network.primary'
            type       = 'Microsoft.Network/virtualNetworks'
            apiVersion = '2024-05-01'
            disposition = 'deploy'
            taggable   = $true
        }
        'azure.network.security-group.workload' = [ordered]@{
            actionId   = 'action.network.security-group.workload'
            type       = 'Microsoft.Network/networkSecurityGroups'
            apiVersion = '2024-05-01'
            disposition = 'deploy'
            taggable   = $true
        }
        'azure.network.subnet.workload' = [ordered]@{
            actionId   = 'action.network.subnet.workload'
            type       = 'Microsoft.Network/virtualNetworks/subnets'
            apiVersion = '2024-05-01'
            disposition = 'deploy'
            taggable   = $false
        }
        'azure.network.interface.primary' = [ordered]@{
            actionId   = 'action.network.interface.primary'
            type       = 'Microsoft.Network/networkInterfaces'
            apiVersion = '2024-05-01'
            disposition = 'deploy'
            taggable   = $true
        }
        'azure.network.subnet.bastion' = [ordered]@{
            actionId   = 'action.network.subnet.bastion'
            type       = 'Microsoft.Network/virtualNetworks/subnets'
            apiVersion = '2024-05-01'
            disposition = 'deploy'
            taggable   = $false
        }
        'azure.network.public-ip.bastion' = [ordered]@{
            actionId   = 'action.network.public-ip.bastion'
            type       = 'Microsoft.Network/publicIPAddresses'
            apiVersion = '2024-05-01'
            disposition = 'deploy'
            taggable   = $true
        }
        'azure.network.bastion.primary' = [ordered]@{
            actionId   = 'action.network.bastion.primary'
            type       = 'Microsoft.Network/bastionHosts'
            apiVersion = '2024-05-01'
            disposition = 'deploy'
            taggable   = $true
        }
        'azure.security.key-vault.primary' = [ordered]@{
            actionId   = 'action.security.key-vault.primary'
            type       = 'Microsoft.KeyVault/vaults'
            apiVersion = '2026-02-01'
            disposition = 'external-reference'
            taggable   = $false
        }
        'azure.security.key-vault-secret.vm-admin' = [ordered]@{
            actionId   = 'action.security.key-vault-secret.vm-admin'
            type       = 'Microsoft.KeyVault/vaults/secrets'
            apiVersion = '2026-02-01'
            disposition = 'external-reference'
            taggable   = $false
        }
        'azure.compute.virtual-machine.primary' = [ordered]@{
            actionId   = 'action.compute.virtual-machine.primary'
            type       = 'Microsoft.Compute/virtualMachines'
            apiVersion = '2024-07-01'
            disposition = 'deploy'
            taggable   = $true
        }
        'azure.sql.virtual-machine.primary' = [ordered]@{
            actionId   = 'action.sql.virtual-machine.primary'
            type       = 'Microsoft.SqlVirtualMachine/sqlVirtualMachines'
            apiVersion = '2023-10-01'
            disposition = 'deploy'
            taggable   = $true
        }
    }
}

function Get-AdltSqlVmArmExpectedActionDependency {
    [CmdletBinding()]
    param()

    return [ordered]@{
        'action.resource-group.primary' = @()
        'action.network.virtual-network.primary' = @(
            'action.resource-group.primary'
        )
        'action.network.security-group.workload' = @(
            'action.resource-group.primary'
        )
        'action.network.subnet.workload' = @(
            'action.network.virtual-network.primary'
            'action.network.security-group.workload'
        )
        'action.network.interface.primary' = @(
            'action.network.subnet.workload'
        )
        'action.network.subnet.bastion' = @(
            'action.network.virtual-network.primary'
        )
        'action.network.public-ip.bastion' = @(
            'action.resource-group.primary'
        )
        'action.network.bastion.primary' = @(
            'action.network.subnet.bastion'
            'action.network.public-ip.bastion'
        )
        'action.security.key-vault.primary' = @()
        'action.security.key-vault-secret.vm-admin' = @(
            'action.security.key-vault.primary'
        )
        'action.compute.virtual-machine.primary' = @(
            'action.network.interface.primary'
            'action.network.security-group.workload'
            'action.security.key-vault-secret.vm-admin'
        )
        'action.sql.virtual-machine.primary' = @(
            'action.compute.virtual-machine.primary'
        )
    }
}

function Get-AdltSqlVmArmEngineIdentity {
    [CmdletBinding()]
    param()

    $identity = [ordered]@{
        name                  = 'powershell'
        contractVersion       = '1.0'
        implementationVersion = $script:AzureDataLabToolkitVersion
        compiler              = 'sqlvm-subscription-arm'
        profile               = 'sqlvm-windows-2022-trusted-launch-basic-bastion'
        resourceContract      = Get-AdltSqlVmArmResourceContract
        actionDependencies    = Get-AdltSqlVmArmExpectedActionDependency
    }
    $digest = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $identity
    )

    return [ordered]@{
        name                  = $identity.name
        contractVersion       = $identity.contractVersion
        implementationVersion = $identity.implementationVersion
        digest                = $digest
    }
}

function Assert-AdltSqlVmArmValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Actual,

        [AllowNull()]
        [object] $Expected,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $actualJson = ConvertTo-AdltCanonicalJson -InputObject $Actual
    $expectedJson = ConvertTo-AdltCanonicalJson -InputObject $Expected
    if ($actualJson -cne $expectedJson) {
        throw "The first-canary ARM compiler does not support '$Path'."
    }
}

function Get-AdltSqlVmArmResourceMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $resources = [ordered]@{}
    foreach ($resourceValue in @($Plan.resources)) {
        $resource = ConvertTo-AdltDictionary -InputObject $resourceValue
        $stableId = [string] $resource.id
        if ($resources.Contains($stableId)) {
            throw "Plan resource '$stableId' occurs more than once."
        }
        $resources[$stableId] = $resource
    }

    return $resources
}

function Get-AdltSqlVmArmActionMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $actions = [ordered]@{}
    foreach ($actionValue in @($Plan.actions)) {
        $action = ConvertTo-AdltDictionary -InputObject $actionValue
        $actionId = [string] $action.id
        if ($actions.Contains($actionId)) {
            throw "Plan action '$actionId' occurs more than once."
        }
        $actions[$actionId] = $action
    }

    return $actions
}

function Get-AdltSqlVmArmResolvedResourceMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence
    )

    $expectedResources = @(Get-AdltResolvedResourceIdSet -Plan $Plan)
    $observedResources = @($LiveResolutionEvidence.payload.resources)
    if ($expectedResources.Count -ne $observedResources.Count) {
        throw 'Live-resolution evidence resource IDs do not exactly match the first-canary plan.'
    }

    $observedByStableId = [ordered]@{}
    foreach ($observedValue in $observedResources) {
        $observed = ConvertTo-AdltDictionary -InputObject $observedValue
        $stableId = [string] $observed.stableId
        if (
            [string]::IsNullOrWhiteSpace($stableId) -or
            $observedByStableId.Contains($stableId)
        ) {
            throw 'Live-resolution evidence contains an invalid resource-ID binding.'
        }
        $observedByStableId[$stableId] = $observed
    }

    $resolved = [ordered]@{}
    foreach ($expectedValue in $expectedResources) {
        $expected = ConvertTo-AdltDictionary -InputObject $expectedValue
        $stableId = [string] $expected.stableId
        if (-not $observedByStableId.Contains($stableId)) {
            throw "Live-resolution evidence omits resource '$stableId'."
        }
        $observed = $observedByStableId[$stableId]
        foreach ($field in @(
            'stableId',
            'resourceId',
            'resourceType',
            'plannedOwnership'
        )) {
            if (
                -not $observed.Contains($field) -or
                [string] $observed[$field] -cne [string] $expected[$field]
            ) {
                throw "Live-resolution evidence resource '$stableId' has an unbound '$field'."
            }
        }
        if (
            [string] $observed.resourceId -notmatch
                '^/subscriptions/[0-9a-fA-F-]{36}/'
        ) {
            throw "Live-resolution evidence resource '$stableId' is not an immutable ARM resource ID."
        }
        $resolved[$stableId] = [string] $observed.resourceId
    }

    return $resolved
}

function Assert-AdltSqlVmArmEvidenceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence
    )

    Assert-AdltLiveResolutionEvidenceForPlan `
        -Evidence $LiveResolutionEvidence `
        -Plan $Plan
    Assert-AdltEvidence -Evidence $LiveResolutionEvidence
    if (
        $LiveResolutionEvidence.stage -cne 'live-resolution' -or
        $LiveResolutionEvidence.status -cne 'pass'
    ) {
        throw 'The first-canary ARM compiler requires passing live-resolution evidence.'
    }
    if (
        $LiveResolutionEvidence.planHash -cne $Plan.planHash -or
        $LiveResolutionEvidence.intentHash -cne $Plan.intentHash
    ) {
        throw 'Live-resolution evidence is not bound to the supplied first-canary plan.'
    }

    $payload = $LiveResolutionEvidence.payload
    if (
        $payload -isnot [System.Collections.IDictionary] -or
        -not $payload.Contains('context') -or
        -not $payload.Contains('imageResolution') -or
        -not $payload.Contains('skuResolution') -or
        -not $payload.Contains('resources')
    ) {
        throw 'Live-resolution evidence does not contain all compiler facts.'
    }

    foreach ($field in @('cloud', 'tenantId', 'subscriptionId')) {
        if (
            $payload.context -isnot [System.Collections.IDictionary] -or
            -not $payload.context.Contains($field) -or
            [string] $payload.context[$field] -cne
                [string] $Plan.context[$field]
        ) {
            throw "Live-resolution evidence context '$field' is not bound to the plan."
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
            -not $resolvedImage.Contains($field) -or
            [string] $resolvedImage[$field] -cne [string] $plannedImage[$field]
        ) {
            throw "Live-resolution evidence image '$field' is not bound to the plan."
        }
    }
    if (
        -not $resolvedImage.Contains('version') -or
        [string] $resolvedImage.version -notmatch '^[0-9]+(?:\.[0-9]+){2,3}$'
    ) {
        throw 'Live-resolution evidence must bind an immutable marketplace image version.'
    }
}

function Assert-AdltSqlVmArmPlanProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resources,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Actions,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ResolvedResourceIds
    )

    $contract = Get-AdltSqlVmArmResourceContract
    if ($Resources.Count -ne $contract.Count) {
        throw 'The first-canary ARM compiler rejects unsupported or missing resources.'
    }
    if ($Actions.Count -ne $contract.Count) {
        throw 'The first-canary ARM compiler rejects unsupported or missing actions.'
    }

    $deploymentProfile = Assert-AdltDeploymentProfileBinding -Plan $Plan
    $configuration = $Plan.configuration
    $diskEncryptionSetId = Get-AdltPathValue `
        -InputObject $configuration `
        -Path 'sqlVm.compute.diskEncryptionSetId'
    if (-not [string]::IsNullOrWhiteSpace([string] $diskEncryptionSetId)) {
        throw 'The first-canary ARM compiler does not support a disk encryption set.'
    }
    if (
        @($configuration.sqlVm.software.catalogIds).Count -ne 0 -or
        @($configuration.sqlVm.sampleData.catalogIds).Count -ne 0 -or
        @($Plan.catalogSelections).Count -ne 0
    ) {
        throw 'The first-canary ARM compiler does not support catalog or solution-pack payloads.'
    }

    $expectedDependencies = Get-AdltSqlVmArmExpectedActionDependency
    foreach ($stableId in $contract.Keys) {
        if (-not $Resources.Contains($stableId)) {
            throw "The first-canary ARM compiler requires resource '$stableId'."
        }
        $resource = $Resources[$stableId]
        $resourceContract = $contract[$stableId]
        if (
            [string] $resource.type -cne [string] $resourceContract.type -or
            [string] $resource.apiVersion -cne
                [string] $resourceContract.apiVersion
        ) {
            throw "Resource '$stableId' uses an unsupported ARM contract."
        }

        $owned = $resourceContract.disposition -eq 'deploy'
        $expectedIntent = if ($owned) { 'create' } elseif (
            $stableId -eq 'azure.security.key-vault.primary'
        ) { 'reuse' } else { 'observe' }
        $expectedClassification = if ($owned) { 'owned' } elseif (
            $stableId -eq 'azure.security.key-vault.primary'
        ) { 'reused' } else { 'external' }
        if (
            [string] $resource.ownership.intent -cne $expectedIntent -or
            [string] $resource.ownership.expectedClassification -cne
                $expectedClassification
        ) {
            throw "Resource '$stableId' has an unsupported ownership profile."
        }

        $actionId = [string] $resourceContract.actionId
        if (-not $Actions.Contains($actionId)) {
            throw "The first-canary ARM compiler requires action '$actionId'."
        }
        $action = $Actions[$actionId]
        if ([string] $action.resourceId -cne $stableId) {
            throw "Action '$actionId' is not bound to resource '$stableId'."
        }
        $expectedOperation = if ($owned) { 'ensure' } else { 'reference' }
        if (
            [string] $action.operation -cne $expectedOperation -or
            [bool] $action.mutation -ne $owned -or
            [string] $action.executionScope -cne 'azure'
        ) {
            throw "Action '$actionId' uses an unsupported execution contract."
        }
        Assert-AdltSqlVmArmValue `
            -Actual @($action.dependsOn) `
            -Expected @($expectedDependencies[$actionId]) `
            -Path "$actionId.dependsOn"
    }

    $vault = $Resources['azure.security.key-vault.primary']
    $secret = $Resources['azure.security.key-vault-secret.vm-admin']
    if (
        [string] $vault.externalResourceId -cne
            [string] $configuration.security.secretStore.resourceId -or
        [string] $secret.externalResourceId -cne
            ('{0}/secrets/{1}' -f
                ([string] $vault.externalResourceId).TrimEnd('/'),
                [string] $configuration.security.vmAdministratorCredential.secretName)
    ) {
        throw 'The first-canary ARM compiler requires an existing bound VM administrator secret.'
    }

    $expectedNetworkProperties = [ordered]@{
        'azure.resource-group.primary' = [ordered]@{
            location = [string] $Plan.context.location
            tags     = [ordered]@{
                managedBy = 'AzureDataLabToolkit'
                labName   = [string] $configuration.metadata.name
                target    = 'sqlVm'
            }
        }
        'azure.network.virtual-network.primary' = [ordered]@{
            location        = [string] $Plan.context.location
            addressPrefixes = @('10.42.0.0/16')
            tags            = [ordered]@{
                managedBy = 'AzureDataLabToolkit'
                labName   = [string] $configuration.metadata.name
            }
        }
        'azure.network.security-group.workload' = [ordered]@{
            location       = [string] $Plan.context.location
            inboundPolicy  = 'deny-by-default'
            inboundRules   = @(
                [ordered]@{
                    name                = 'AllowRdpFromBastionSubnet'
                    priority            = 100
                    access              = 'Allow'
                    protocol            = 'Tcp'
                    sourceAddressPrefix = '10.42.2.0/26'
                    destinationPort     = 3389
                }
            )
            outboundPolicy = 'azure-platform-default'
        }
        'azure.network.subnet.workload' = [ordered]@{
            addressPrefix                  = '10.42.1.0/24'
            virtualNetworkResourceId       = 'azure.network.virtual-network.primary'
            networkSecurityGroupResourceId = 'azure.network.security-group.workload'
            privateEndpointNetworkPolicies = 'Disabled'
        }
        'azure.network.interface.primary' = [ordered]@{
            location                   = [string] $Plan.context.location
            subnetResourceId           = 'azure.network.subnet.workload'
            privateIpAllocation        = 'Dynamic'
            publicIpResourceId          = $null
            enableAcceleratedNetworking = $false
            enableIpForwarding          = $false
        }
        'azure.network.subnet.bastion' = [ordered]@{
            addressPrefix            = '10.42.2.0/26'
            virtualNetworkResourceId = 'azure.network.virtual-network.primary'
        }
        'azure.network.public-ip.bastion' = [ordered]@{
            location         = [string] $Plan.context.location
            sku              = 'Standard'
            allocationMethod = 'Static'
            purpose          = 'AzureBastionOnly'
        }
    }
    foreach ($stableId in $expectedNetworkProperties.Keys) {
        Assert-AdltSqlVmArmValue `
            -Actual $Resources[$stableId].desiredProperties `
            -Expected $expectedNetworkProperties[$stableId] `
            -Path "$stableId.desiredProperties"
    }

    $diagnosticDestinationResourceId = [string] (
        $configuration.security.secretStore.diagnosticDestinationResourceId
    )
    Assert-AdltSqlVmArmValue `
        -Actual $vault.desiredProperties `
        -Expected ([ordered]@{
            compatibility           = 'verify-live'
            enableRbacAuthorization = 'required'
            enabledForTemplateDeployment = 'required'
            privateDataPlaneAccess  = 'required'
            purgeProtectionEnabled  = 'required'
            auditDiagnostics        = 'required'
            diagnosticDestinationResourceId =
                $diagnosticDestinationResourceId
        }) `
        -Path 'keyVault.desiredProperties'
    Assert-AdltSqlVmArmValue `
        -Actual $secret.desiredProperties `
        -Expected ([ordered]@{
            parentResourceId   = 'azure.security.key-vault.primary'
            valueSource        = 'external-secure-input'
            valueInPlan        = $false
            valueInState       = $false
            shellOutputAllowed = $false
            secretVersion      = [string] (
                $configuration.security.vmAdministratorCredential.secretVersion
            )
        }) `
        -Path 'vmAdministratorSecret.desiredProperties'

    $virtualMachine = $Resources['azure.compute.virtual-machine.primary']
    $virtualMachineProperties = $virtualMachine.desiredProperties
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.location `
        -Expected ([string] $Plan.context.location) `
        -Path 'virtualMachine.location'
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.identity.type `
        -Expected 'SystemAssigned' `
        -Path 'virtualMachine.identity.type'
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.hardwareProfile `
        -Expected ([ordered]@{
            vmSize = [string] $deploymentProfile.exactConfiguration[
                'sqlVm.compute.vmSize'
            ]
        }) `
        -Path 'virtualMachine.hardwareProfile'
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.securityProfile `
        -Expected ([ordered]@{
            securityType      = 'trustedLaunch'
            secureBootEnabled = $true
            virtualTpmEnabled = $true
            encryptionAtHost  = $true
        }) `
        -Path 'virtualMachine.securityProfile'
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.imageReference `
        -Expected ([ordered]@{
            publisher       = 'MicrosoftSQLServer'
            offer           = 'sql2022-ws2022'
            sku             = 'sqldev-gen2'
            version         = 'unresolved'
            sourceAlias     = 'latest'
            resolutionStage = 'what-if'
        }) `
        -Path 'virtualMachine.imageReference'
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.networkProfile `
        -Expected ([ordered]@{
            networkInterfaceResourceIds = @(
                'azure.network.interface.primary'
            )
            publicIpResourceId = $null
        }) `
        -Path 'virtualMachine.networkProfile'
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.osProfile `
        -Expected ([ordered]@{
            computerName = [string] $virtualMachine.logicalName
            administratorUsername = 'adltadmin'
            administratorCredentialResourceId = 'azure.security.key-vault-secret.vm-admin'
            provisionVmAgent       = $true
            enableAutomaticUpdates = $true
        }) `
        -Path 'virtualMachine.osProfile'
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.storageProfile `
        -Expected ([ordered]@{
            osDisk = [ordered]@{
                sizeGiB     = 128
                storageType = 'Premium_LRS'
                caching     = 'ReadWrite'
                encryption  = [ordered]@{
                    type = 'PlatformManaged'
                    diskEncryptionSetResourceId = $null
                }
            }
            dataDisks = @(
                [ordered]@{
                    purpose     = 'sql-data'
                    lun         = 0
                    sizeGiB     = 256
                    storageType = 'Premium_LRS'
                    caching     = 'ReadOnly'
                    diskEncryptionSetResourceId = $null
                }
                [ordered]@{
                    purpose     = 'sql-log'
                    lun         = 1
                    sizeGiB     = 128
                    storageType = 'Premium_LRS'
                    caching     = 'None'
                    diskEncryptionSetResourceId = $null
                }
            )
        }) `
        -Path 'virtualMachine.storageProfile'
    Assert-AdltSqlVmArmValue `
        -Actual $virtualMachineProperties.patching `
        -Expected ([ordered]@{
            patchMode      = 'AutomaticByPlatform'
            assessmentMode = 'AutomaticByPlatform'
            rebootSetting  = 'IfRequired'
        }) `
        -Path 'virtualMachine.patching'

    $sqlVirtualMachine = $Resources['azure.sql.virtual-machine.primary']
    Assert-AdltSqlVmArmValue `
        -Actual $sqlVirtualMachine.desiredProperties `
        -Expected ([ordered]@{
            location                 = [string] $Plan.context.location
            virtualMachineResourceId = [string] $ResolvedResourceIds[
                'azure.compute.virtual-machine.primary'
            ]
            sqlServerLicenseType     = 'PAYG'
            leastPrivilegeMode       = 'Enabled'
            enableAutomaticUpgrade   = $true
            sqlImageOffer            = 'SQL2022-WS2022'
            sqlImageSku              = 'Developer'
            assessmentSettings       = [ordered]@{
                enable         = $false
                runImmediately = $false
            }
            autoPatchingSettings     = [ordered]@{
                enable = $false
            }
            storageConfigurationSettings = [ordered]@{
                diskConfigurationType    = 'NEW'
                enableStorageConfigBlade = $true
                sqlDataSettings          = [ordered]@{
                    defaultFilePath = 'F:\SQLData'
                    luns            = @(0)
                    useStoragePool  = $false
                }
                sqlLogSettings           = [ordered]@{
                    defaultFilePath = 'G:\SQLLog'
                    luns            = @(1)
                    useStoragePool  = $false
                }
                sqlSystemDbOnDataDisk = $false
                storageWorkloadType   = 'GENERAL'
            }
        }) `
        -Path 'sqlVirtualMachine.desiredProperties'

    $bastion = $Resources['azure.network.bastion.primary']
    Assert-AdltSqlVmArmValue `
        -Actual $bastion.desiredProperties `
        -Expected ([ordered]@{
            location           = [string] $Plan.context.location
            sku                = [string] $deploymentProfile.exactConfiguration[
                'security.administrativeAccess.sku'
            ]
            scaleUnits         = 2
            subnetResourceId   = 'azure.network.subnet.bastion'
            publicIpResourceId = 'azure.network.public-ip.bastion'
            vmPublicIpRequired = $false
            nativeClient       = $false
            shareableLink      = $false
            ipConnect          = $false
            fileCopy           = $false
        }) `
        -Path 'bastion.desiredProperties'
}

function Get-AdltSqlVmArmActionOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Actions
    )

    $remaining = [ordered]@{}
    foreach ($actionId in $Actions.Keys) {
        $dependencies = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        foreach ($dependency in @($Actions[$actionId].dependsOn)) {
            [void] $dependencies.Add([string] $dependency)
        }
        $remaining[[string] $actionId] = $dependencies
    }

    $orderedIds = [System.Collections.Generic.List[string]]::new()
    while ($remaining.Count -gt 0) {
        $ready = [string[]] @(
            $remaining.Keys |
                Where-Object { $remaining[$_].Count -eq 0 }
        )
        if ($ready.Count -eq 0) {
            throw 'The first-canary action graph contains a dependency cycle.'
        }
        [System.Array]::Sort($ready, [System.StringComparer]::Ordinal)
        foreach ($actionId in $ready) {
            $orderedIds.Add($actionId)
            $remaining.Remove($actionId)
        }
        foreach ($dependencies in $remaining.Values) {
            foreach ($actionId in $ready) {
                [void] $dependencies.Remove($actionId)
            }
        }
    }

    return $orderedIds.ToArray()
}

function Get-AdltSqlVmArmOwnershipTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId
    )

    $tags = [ordered]@{}
    if (
        $Resource.desiredProperties.Contains('tags') -and
        $Resource.desiredProperties.tags -is [System.Collections.IDictionary]
    ) {
        $tagKeys = [string[]] @($Resource.desiredProperties.tags.Keys)
        [System.Array]::Sort($tagKeys, [System.StringComparer]::Ordinal)
        foreach ($key in $tagKeys) {
            if ($key -like 'adlt-*') {
                throw "Resource '$($Resource.id)' cannot override a reserved ownership tag."
            }
            $tags[$key] = [string] $Resource.desiredProperties.tags[$key]
        }
    }

    $tags['adlt-toolkit'] = [string] $Plan.toolkit.name
    $tags['adlt-run-id'] = $RunId
    $tags['adlt-plan-hash'] = [string] $Plan.planHash
    $tags['adlt-intent-hash'] = [string] $Plan.intentHash
    $tags['adlt-stable-id'] = [string] $Resource.id
    $tags['adlt-ownership'] = 'owned'
    $tags['adlt-desired-hash'] = Get-AdltDesiredResourceHash `
        -Resource $Resource
    return $tags
}

function Get-AdltSqlVmArmDeploymentDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Action,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Actions,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ResourceContract,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ResolvedResourceIds
    )

    $dependencies = [System.Collections.Generic.List[string]]::new()
    foreach ($dependencyActionId in @($Action.dependsOn)) {
        $dependencyAction = $Actions[[string] $dependencyActionId]
        $dependencyStableId = [string] $dependencyAction.resourceId
        if (
            $ResourceContract[$dependencyStableId].disposition -eq 'deploy' -and
            $dependencyStableId -ne 'azure.resource-group.primary'
        ) {
            $dependencies.Add([string] $ResolvedResourceIds[$dependencyStableId])
        }
    }
    return $dependencies.ToArray()
}

function New-AdltSqlVmArmNestedResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Action,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Actions,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ResourceContract,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ResolvedResourceIds,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ResolvedImage,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    $stableId = [string] $Resource.id
    $properties = $Resource.desiredProperties
    $dependsOn = @(
        Get-AdltSqlVmArmDeploymentDependency `
            -Action $Action `
            -Actions $Actions `
            -ResourceContract $ResourceContract `
            -ResolvedResourceIds $ResolvedResourceIds
    )
    $tags = if ($ResourceContract[$stableId].taggable) {
        Get-AdltSqlVmArmOwnershipTag `
            -Plan $Plan `
            -Resource $Resource `
            -RunId $RunId
    }

    switch ($stableId) {
        'azure.network.virtual-network.primary' {
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = [string] $Resource.logicalName
                location   = [string] $properties.location
                tags       = $tags
                dependsOn  = $dependsOn
                properties = [ordered]@{
                    addressSpace = [ordered]@{
                        addressPrefixes = @($properties.addressPrefixes)
                    }
                }
            }
        }
        'azure.network.security-group.workload' {
            $securityRules = @(
                foreach ($rule in @($properties.inboundRules)) {
                    [ordered]@{
                        name       = [string] $rule.name
                        properties = [ordered]@{
                            priority                 = [int] $rule.priority
                            access                   = [string] $rule.access
                            direction                = 'Inbound'
                            protocol                 = [string] $rule.protocol
                            sourcePortRange          = '*'
                            destinationPortRange     = [string] $rule.destinationPort
                            sourceAddressPrefix      = [string] $rule.sourceAddressPrefix
                            destinationAddressPrefix = '*'
                        }
                    }
                }
            )
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = [string] $Resource.logicalName
                location   = [string] $properties.location
                tags       = $tags
                dependsOn  = $dependsOn
                properties = [ordered]@{
                    securityRules = $securityRules
                }
            }
        }
        'azure.network.subnet.workload' {
            $virtualNetwork = $ResourceContract[
                'azure.network.virtual-network.primary'
            ]
            $virtualNetworkResource = $null
            foreach ($candidate in $Plan.resources) {
                if ($candidate.id -ceq 'azure.network.virtual-network.primary') {
                    $virtualNetworkResource = $candidate
                    break
                }
            }
            if ($null -eq $virtualNetwork -or $null -eq $virtualNetworkResource) {
                throw 'The workload subnet has no bound virtual network.'
            }
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = '{0}/{1}' -f
                    [string] $virtualNetworkResource.logicalName,
                    [string] $Resource.logicalName
                dependsOn  = $dependsOn
                properties = [ordered]@{
                    addressPrefix = [string] $properties.addressPrefix
                    networkSecurityGroup = [ordered]@{
                        id = [string] $ResolvedResourceIds[
                            'azure.network.security-group.workload'
                        ]
                    }
                    privateEndpointNetworkPolicies = [string] $properties.privateEndpointNetworkPolicies
                }
            }
        }
        'azure.network.interface.primary' {
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = [string] $Resource.logicalName
                location   = [string] $properties.location
                tags       = $tags
                dependsOn  = $dependsOn
                properties = [ordered]@{
                    enableAcceleratedNetworking = [bool] $properties.enableAcceleratedNetworking
                    enableIPForwarding           = [bool] $properties.enableIpForwarding
                    ipConfigurations             = @(
                        [ordered]@{
                            name       = 'ipconfig-primary'
                            properties = [ordered]@{
                                primary                   = $true
                                privateIPAllocationMethod = [string] $properties.privateIpAllocation
                                subnet                    = [ordered]@{
                                    id = [string] $ResolvedResourceIds[
                                        'azure.network.subnet.workload'
                                    ]
                                }
                            }
                        }
                    )
                }
            }
        }
        'azure.network.subnet.bastion' {
            $virtualNetworkResource = $Plan.resources |
                Where-Object id -CEQ 'azure.network.virtual-network.primary' |
                Select-Object -First 1
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = '{0}/{1}' -f
                    [string] $virtualNetworkResource.logicalName,
                    [string] $Resource.logicalName
                dependsOn  = $dependsOn
                properties = [ordered]@{
                    addressPrefix = [string] $properties.addressPrefix
                }
            }
        }
        'azure.network.public-ip.bastion' {
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = [string] $Resource.logicalName
                location   = [string] $properties.location
                tags       = $tags
                sku        = [ordered]@{
                    name = [string] $properties.sku
                }
                dependsOn  = $dependsOn
                properties = [ordered]@{
                    publicIPAllocationMethod = [string] $properties.allocationMethod
                }
            }
        }
        'azure.network.bastion.primary' {
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = [string] $Resource.logicalName
                location   = [string] $properties.location
                tags       = $tags
                sku        = [ordered]@{
                    name = 'Basic'
                }
                dependsOn  = $dependsOn
                properties = [ordered]@{
                    scaleUnits          = [int] $properties.scaleUnits
                    enableTunneling     = [bool] $properties.nativeClient
                    enableShareableLink = [bool] $properties.shareableLink
                    enableIpConnect     = [bool] $properties.ipConnect
                    enableFileCopy      = [bool] $properties.fileCopy
                    ipConfigurations    = @(
                        [ordered]@{
                            name       = 'IpConf'
                            properties = [ordered]@{
                                privateIPAllocationMethod = 'Dynamic'
                                subnet = [ordered]@{
                                    id = [string] $ResolvedResourceIds[
                                        'azure.network.subnet.bastion'
                                    ]
                                }
                                publicIPAddress = [ordered]@{
                                    id = [string] $ResolvedResourceIds[
                                        'azure.network.public-ip.bastion'
                                    ]
                                }
                            }
                        }
                    )
                }
            }
        }
        'azure.compute.virtual-machine.primary' {
            $osDisk = $properties.storageProfile.osDisk
            $dataDisks = @(
                foreach ($disk in @($properties.storageProfile.dataDisks)) {
                    [ordered]@{
                        lun          = [int] $disk.lun
                        name         = '{0}-data-{1}' -f
                            [string] $Resource.logicalName,
                            [int] $disk.lun
                        createOption = 'Empty'
                        diskSizeGB   = [int] $disk.sizeGiB
                        caching      = [string] $disk.caching
                        deleteOption = 'Delete'
                        managedDisk  = [ordered]@{
                            storageAccountType = [string] $disk.storageType
                        }
                    }
                }
            )
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = [string] $Resource.logicalName
                location   = [string] $properties.location
                tags       = $tags
                identity   = [ordered]@{
                    type = 'SystemAssigned'
                }
                dependsOn  = $dependsOn
                properties = [ordered]@{
                    hardwareProfile = [ordered]@{
                        vmSize = [string] $properties.hardwareProfile.vmSize
                    }
                    storageProfile = [ordered]@{
                        imageReference = [ordered]@{
                            publisher = [string] $ResolvedImage.publisher
                            offer     = [string] $ResolvedImage.offer
                            sku       = [string] $ResolvedImage.sku
                            version   = [string] $ResolvedImage.version
                        }
                        osDisk = [ordered]@{
                            name         = '{0}-os' -f
                                [string] $Resource.logicalName
                            createOption = 'FromImage'
                            diskSizeGB   = [int] $osDisk.sizeGiB
                            caching      = [string] $osDisk.caching
                            deleteOption = 'Delete'
                            managedDisk  = [ordered]@{
                                storageAccountType = [string] $osDisk.storageType
                            }
                        }
                        dataDisks = $dataDisks
                    }
                    osProfile = [ordered]@{
                        computerName  = [string] $properties.osProfile.computerName
                        adminUsername = [string] $properties.osProfile.administratorUsername
                        adminPassword = "[parameters('vmAdministratorPassword')]"
                        windowsConfiguration = [ordered]@{
                            provisionVMAgent       = [bool] $properties.osProfile.provisionVmAgent
                            enableAutomaticUpdates = [bool] $properties.osProfile.enableAutomaticUpdates
                            patchSettings          = [ordered]@{
                                patchMode      = [string] $properties.patching.patchMode
                                assessmentMode = [string] $properties.patching.assessmentMode
                                automaticByPlatformSettings = [ordered]@{
                                    rebootSetting = [string] $properties.patching.rebootSetting
                                }
                            }
                        }
                    }
                    networkProfile = [ordered]@{
                        networkInterfaces = @(
                            [ordered]@{
                                id = [string] $ResolvedResourceIds[
                                    'azure.network.interface.primary'
                                ]
                                properties = [ordered]@{
                                    primary = $true
                                }
                            }
                        )
                    }
                    securityProfile = [ordered]@{
                        securityType    = 'TrustedLaunch'
                        encryptionAtHost = $true
                        uefiSettings    = [ordered]@{
                            secureBootEnabled = $true
                            vTpmEnabled       = $true
                        }
                    }
                }
            }
        }
        'azure.sql.virtual-machine.primary' {
            return [ordered]@{
                type       = [string] $Resource.type
                apiVersion = [string] $Resource.apiVersion
                name       = [string] $Resource.logicalName
                location   = [string] $properties.location
                tags       = $tags
                dependsOn  = $dependsOn
                properties = Copy-AdltValue -InputObject $properties
            }
        }
        default {
            throw "Resource '$stableId' is not supported by the first-canary ARM compiler."
        }
    }
}

function New-AdltSqlVmArmCompilation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence
    )

    Assert-AdltPlanContract -Plan $Plan
    Assert-AdltSqlVmArmEvidenceBinding `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence

    $resources = Get-AdltSqlVmArmResourceMap -Plan $Plan
    $actions = Get-AdltSqlVmArmActionMap -Plan $Plan
    $resolvedResourceIds = Get-AdltSqlVmArmResolvedResourceMap `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    Assert-AdltSqlVmArmPlanProfile `
        -Plan $Plan `
        -Resources $resources `
        -Actions $actions `
        -ResolvedResourceIds $resolvedResourceIds

    $contract = Get-AdltSqlVmArmResourceContract
    $actionOrder = @(
        Get-AdltSqlVmArmActionOrder -Actions $actions
    )
    $stableIdByActionId = [ordered]@{}
    foreach ($stableId in $contract.Keys) {
        $stableIdByActionId[[string] $contract[$stableId].actionId] = $stableId
    }

    $actionBindings = [System.Collections.Generic.List[object]]::new()
    $resourceBindings = [System.Collections.Generic.List[object]]::new()
    $nestedResources = [System.Collections.Generic.List[object]]::new()
    foreach ($actionId in $actionOrder) {
        $stableId = [string] $stableIdByActionId[$actionId]
        $action = $actions[$actionId]
        $resource = $resources[$stableId]
        $disposition = [string] $contract[$stableId].disposition
        $actionBindings.Add([ordered]@{
            actionId        = $actionId
            resourceStableId = $stableId
            resourceId      = [string] $resolvedResourceIds[$stableId]
            disposition     = $disposition
            dependsOn       = @($action.dependsOn)
        })
        $resourceBindings.Add([ordered]@{
            stableId     = $stableId
            actionId     = $actionId
            resourceId   = [string] $resolvedResourceIds[$stableId]
            resourceType = [string] $resource.type
            disposition  = $disposition
        })

        if (
            $disposition -eq 'deploy' -and
            $stableId -ne 'azure.resource-group.primary'
        ) {
            $nestedResources.Add((
                New-AdltSqlVmArmNestedResource `
                    -Plan $Plan `
                    -Resource $resource `
                    -Action $action `
                    -Actions $actions `
                    -ResourceContract $contract `
                    -ResolvedResourceIds $resolvedResourceIds `
                    -ResolvedImage $LiveResolutionEvidence.payload.imageResolution `
                    -RunId ([string] $LiveResolutionEvidence.runId)
            ))
        }
    }

    $resourceGroup = $resources['azure.resource-group.primary']
    $resourceGroupId = [string] $resolvedResourceIds[
        'azure.resource-group.primary'
    ]
    $nestedTemplate = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            vmAdministratorPassword = [ordered]@{
                type = 'secureString'
            }
        }
        resources = $nestedResources.ToArray()
    }
    $nestedDeploymentName = 'adlt-sqlvm-{0}' -f
        ([string] $Plan.planHash).Substring(7, 12)
    $template = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            vmAdministratorPassword = [ordered]@{
                type = 'secureString'
            }
        }
        resources = @(
            [ordered]@{
                type       = [string] $resourceGroup.type
                apiVersion = [string] $resourceGroup.apiVersion
                name       = [string] $resourceGroup.logicalName
                location   = [string] $resourceGroup.desiredProperties.location
                tags       = Get-AdltSqlVmArmOwnershipTag `
                    -Plan $Plan `
                    -Resource $resourceGroup `
                    -RunId ([string] $LiveResolutionEvidence.runId)
            }
            [ordered]@{
                type          = 'Microsoft.Resources/deployments'
                apiVersion    = '2022-09-01'
                name          = $nestedDeploymentName
                resourceGroup = [string] $resourceGroup.logicalName
                dependsOn     = @($resourceGroupId)
                properties    = [ordered]@{
                    mode = 'Incremental'
                    expressionEvaluationOptions = [ordered]@{
                        scope = 'inner'
                    }
                    parameters = [ordered]@{
                        vmAdministratorPassword = [ordered]@{
                            value = "[parameters('vmAdministratorPassword')]"
                        }
                    }
                    template = $nestedTemplate
                }
            }
        )
    }

    $parameterReference = [ordered]@{
        keyVaultResourceId = [string] $resources[
            'azure.security.key-vault.primary'
        ].externalResourceId
        secretName = [string] $resources[
            'azure.security.key-vault-secret.vm-admin'
        ].logicalName
        secretVersion = [string] $resources[
            'azure.security.key-vault-secret.vm-admin'
        ].desiredProperties.secretVersion
    }
    $templateHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $template
    )
    $virtualMachineResource = $resources[
        'azure.compute.virtual-machine.primary'
    ]
    $virtualMachineResourceId = [string] $resolvedResourceIds[
        'azure.compute.virtual-machine.primary'
    ]
    $expectedGeneratedResources =
        [System.Collections.Generic.List[object]]::new()
    $expectedGeneratedResources.Add([ordered]@{
        stableId          = 'engine.compute.managed-disk.os'
        resourceId        = (
            '{0}/providers/Microsoft.Compute/disks/{1}-os' -f
                $resourceGroupId,
                [string] $virtualMachineResource.logicalName
        )
        resourceType      = 'Microsoft.Compute/disks'
        producerResourceId = $virtualMachineResourceId
        relationship      = 'vm-managed-disk'
        required          = $true
        profileVersion    = 'sqlvm-windows-managed-disk-v1'
        expectedProperties = [ordered]@{
            purpose      = 'os'
            lun          = $null
            sizeGiB      = [int] $virtualMachineResource.
                desiredProperties.storageProfile.osDisk.sizeGiB
            storageType  = [string] $virtualMachineResource.
                desiredProperties.storageProfile.osDisk.storageType
            deleteOption = 'Delete'
        }
    })
    foreach ($disk in @(
        $virtualMachineResource.desiredProperties.storageProfile.dataDisks |
            Sort-Object { [int] $_.lun }
    )) {
        $expectedGeneratedResources.Add([ordered]@{
            stableId          = 'engine.compute.managed-disk.data-{0}' -f
                [int] $disk.lun
            resourceId        = (
                '{0}/providers/Microsoft.Compute/disks/{1}-data-{2}' -f
                    $resourceGroupId,
                    [string] $virtualMachineResource.logicalName,
                    [int] $disk.lun
            )
            resourceType      = 'Microsoft.Compute/disks'
            producerResourceId = $virtualMachineResourceId
            relationship      = 'vm-managed-disk'
            required          = $true
            profileVersion    = 'sqlvm-windows-managed-disk-v1'
            expectedProperties = [ordered]@{
                purpose      = [string] $disk.purpose
                lun          = [int] $disk.lun
                sizeGiB      = [int] $disk.sizeGiB
                storageType  = [string] $disk.storageType
                deleteOption = 'Delete'
            }
        })
    }
    $expectedGeneratedResources.Add([ordered]@{
        stableId          = 'engine.resources.nested-deployment'
        resourceId        = (
            '{0}/providers/Microsoft.Resources/deployments/{1}' -f
                $resourceGroupId,
                $nestedDeploymentName
        )
        resourceType      = 'Microsoft.Resources/deployments'
        producerResourceId = (
            '/subscriptions/{0}/providers/Microsoft.Resources/deployments/{1}' -f
                [string] $Plan.context.subscriptionId,
                $nestedDeploymentName
        )
        relationship      = 'nested-deployment'
        required          = $false
        profileVersion    = 'subscription-nested-deployment-v1'
        expectedProperties = [ordered]@{
            name               = $nestedDeploymentName
            nestedTemplateHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject $nestedTemplate
            )
        }
    })
    $expectedGeneratedResources.Add([ordered]@{
        stableId          = 'engine.sql-iaas-agent.extension'
        resourceId        = '{0}/extensions/SqlIaasExtension' -f
            $virtualMachineResourceId
        resourceType      = 'Microsoft.Compute/virtualMachines/extensions'
        producerResourceId = [string] $resolvedResourceIds[
            'azure.sql.virtual-machine.primary'
        ]
        relationship      = 'sql-iaas-agent-extension'
        required          = $false
        profileVersion    = 'sql-iaas-windows-2023-10-01-v1'
        expectedProperties = [ordered]@{
            name             = 'SqlIaasExtension'
            parentResourceId = $virtualMachineResourceId
            publisher        = 'Microsoft.SqlServer.Management'
            type             = 'SqlIaaSAgent'
        }
    })
    $engineIdentity = Get-AdltSqlVmArmEngineIdentity
    $executionArtifactDigest = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            engine                     = $engineIdentity
            runId                      = [string] $LiveResolutionEvidence.runId
            planHash                   = [string] $Plan.planHash
            intentHash                 = [string] $Plan.intentHash
            liveResolutionEvidenceHash = [string] $LiveResolutionEvidence.evidenceHash
            templateHash               = $templateHash
            parameterReference         = $parameterReference
            actionBindings             = $actionBindings.ToArray()
            resourceBindings           = $resourceBindings.ToArray()
            expectedGeneratedResources =
                $expectedGeneratedResources.ToArray()
        })
    )

    return [ordered]@{
        schemaVersion              = '1.0'
        kind                       = 'AzureDataLabSqlVmArmCompilation'
        engine                     = $engineIdentity
        runId                      = [string] $LiveResolutionEvidence.runId
        planHash                   = [string] $Plan.planHash
        intentHash                 = [string] $Plan.intentHash
        liveResolutionEvidenceHash = [string] $LiveResolutionEvidence.evidenceHash
        template                   = $template
        parameterReference         = $parameterReference
        actionBindings             = $actionBindings.ToArray()
        resourceBindings           = $resourceBindings.ToArray()
        expectedGeneratedResources =
            $expectedGeneratedResources.ToArray()
        templateHash               = $templateHash
        executionArtifactDigest    = $executionArtifactDigest
    }
}

function Assert-AdltSqlVmArmCompilation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LiveResolutionEvidence
    )

    $forbiddenFields = @(Get-AdltForbiddenField -InputObject $Compilation)
    if ($forbiddenFields.Count -gt 0) {
        throw "SQL VM ARM compilation contains forbidden secret field '$($forbiddenFields[0])'."
    }
    $sensitiveValues = @(
        Get-AdltSensitiveValueFinding -InputObject $Compilation
    )
    if ($sensitiveValues.Count -gt 0) {
        throw (
            "SQL VM ARM compilation contains sensitive value pattern '{0}' at '{1}'." -f
                $sensitiveValues[0].kind,
                $sensitiveValues[0].path
        )
    }

    $expected = New-AdltSqlVmArmCompilation `
        -Plan $Plan `
        -LiveResolutionEvidence $LiveResolutionEvidence
    if (
        (ConvertTo-AdltCanonicalJson -InputObject $Compilation) -cne
        (ConvertTo-AdltCanonicalJson -InputObject $expected)
    ) {
        throw 'SQL VM ARM compilation does not exactly match deterministic recompilation.'
    }
}
