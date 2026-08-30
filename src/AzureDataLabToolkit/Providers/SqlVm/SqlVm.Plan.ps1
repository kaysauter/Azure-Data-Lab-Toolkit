function Get-AdltPlanSupportEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Matrix,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    $checks = @(
        [pscustomobject]@{ Axis = 'engine'; Value = $Configuration.engine.type }
        [pscustomobject]@{ Axis = 'authentication'; Value = $Configuration.azure.authentication.mode }
        [pscustomobject]@{ Axis = 'platform'; Value = $Configuration.sqlVm.platform }
        [pscustomobject]@{ Axis = 'sqlServerVersion'; Value = $Configuration.sqlVm.sqlServerVersion }
        [pscustomobject]@{ Axis = 'securityType'; Value = $Configuration.sqlVm.compute.securityType }
        [pscustomobject]@{ Axis = 'encryptionAtHost'; Value = $(if ($Configuration.sqlVm.compute.encryptionAtHost) { 'enabled' } else { 'disabled' }) }
        [pscustomobject]@{ Axis = 'diskEncryption'; Value = $(if ((Get-AdltPathValue -InputObject $Configuration -Path 'sqlVm.compute.diskEncryptionSetId')) { 'customer-managed-existing' } else { 'platform-managed' }) }
        [pscustomobject]@{ Axis = 'secretStore'; Value = $Configuration.security.secretStore.mode }
        [pscustomobject]@{ Axis = 'credentialSource'; Value = $Configuration.security.vmAdministratorCredential.source }
        [pscustomobject]@{ Axis = 'shellPasswordOutput'; Value = $(if ($Configuration.security.vmAdministratorCredential.allowShellOutput) { 'enabled' } else { 'disabled' }) }
        [pscustomobject]@{ Axis = 'administrativeAccess'; Value = $Configuration.security.administrativeAccess.mode }
        [pscustomobject]@{ Axis = 'bastionSku'; Value = $Configuration.security.administrativeAccess.sku }
        [pscustomobject]@{ Axis = 'vmPublicIp'; Value = $(if ($Configuration.sqlVm.network.vmPublicIp) { 'enabled' } else { 'disabled' }) }
    )

    $backupValue = if ($Configuration.capabilities.backupShare.enabled) {
        if ($Configuration.solutionPacks.sqlVmBackupRestore.restoreMode -eq 'local-staging') {
            'managed-identity-smb-oauth-private-endpoint-local-staging'
        }
        else {
            'direct-unc-experimental'
        }
    }
    else {
        'disabled'
    }
    $checks += [pscustomobject]@{ Axis = 'backupShare'; Value = $backupValue }

    $evaluations = foreach ($check in $checks) {
        $entry = if (
            $Matrix.axes.Contains($check.Axis) -and
            $Matrix.axes[$check.Axis].Contains($check.Value)
        ) {
            $Matrix.axes[$check.Axis][$check.Value]
        }
        else {
            [ordered]@{
                plan       = 'unsupported'
                deployment = 'unavailable'
            }
        }

        [ordered]@{
            axis       = $check.Axis
            value      = $check.Value
            plan       = $entry.plan
            deployment = $entry.deployment
            supported  = $entry.plan -in @('supported', 'supported-with-warning')
        }
    }

    return $evaluations
}

function New-AdltSqlVmPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance
    )

    $matrixPath = Get-AdltDataPath -ChildPath 'Support/sqlvm-support-matrix.json'
    $matrix = Read-AdltJsonFile -Path $matrixPath
    $matrixValidation = Test-AdltObjectAgainstSchema `
        -InputObject $matrix `
        -SchemaPath (Get-AdltDataPath -ChildPath 'Schemas/support-matrix.schema.json')
    if (-not $matrixValidation.Valid) {
        throw 'The SQL VM support matrix failed schema validation.'
    }
    $supportEvaluation = @(
        Get-AdltPlanSupportEvaluation -Configuration $Configuration -Matrix $matrix
    )
    $unsupportedCapabilities = @($supportEvaluation | Where-Object { -not $_.supported })
    if ($unsupportedCapabilities.Count -gt 0) {
        $firstUnsupported = $unsupportedCapabilities[0]
        $exception = [System.InvalidOperationException]::new(
            "The SQL VM plan contract does not support $($firstUnsupported.axis) '$($firstUnsupported.value)'."
        )
        $exception.Data['unsupportedCapabilities'] = ConvertTo-AdltCanonicalJson `
            -InputObject $unsupportedCapabilities
        throw $exception
    }
    $deploymentStatus = if (
        @(
            $supportEvaluation |
                Where-Object { $_.deployment -cne 'available' }
        ).Count -eq 0
    ) {
        'available'
    }
    else {
        'unavailable'
    }

    $catalogSelections = Resolve-AdltCatalogSelection `
        -SoftwareIds @($Configuration.sqlVm.software.catalogIds) `
        -SampleDataIds @($Configuration.sqlVm.sampleData.catalogIds) `
        -TargetType $Configuration.target.type `
        -Platform $Configuration.sqlVm.platform `
        -SqlServerVersion $Configuration.sqlVm.sqlServerVersion
    $contracts = [ordered]@{
        configurationSchemaVersion = $Configuration.schemaVersion
        planSchemaVersion          = '1.0'
        catalogSchemaVersion       = '1.0'
        catalogRevisions           = @(Get-AdltCatalogContractSet)
        contributors               = Get-AdltContributorContractSet `
            -Configuration $Configuration
        engine                     = [ordered]@{
            name                 = $Configuration.engine.type
            contractVersion      = 'sqlvm-first-canary/v1'
            implementationStatus = if (
                $Configuration.engine.type -ceq 'powershell'
            ) {
                'available'
            }
            else {
                'unavailable'
            }
        }
    }
    $planIntent = [ordered]@{
        toolkit          = [ordered]@{
            name    = 'AzureDataLabToolkit'
            version = $script:AzureDataLabToolkitVersion
        }
        contracts        = Copy-AdltValue -InputObject $contracts
        configuration    = Copy-AdltValue -InputObject $Configuration
        catalogSelections = @($catalogSelections)
    }
    $planIntentHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $planIntent
    )

    $names = New-AdltStableAzureNameSet -Configuration $Configuration
    $virtualMachineArmResourceId = (
        '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Compute/virtualMachines/{2}' -f
            $Configuration.azure.subscriptionId,
            $Configuration.azure.resourceGroup.name,
            $names.virtualMachine
    )
    $diskEncryptionSetId = Get-AdltPathValue `
        -InputObject $Configuration `
        -Path 'sqlVm.compute.diskEncryptionSetId'
    $resources = [System.Collections.Generic.List[object]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $policyFindings = [System.Collections.Generic.List[object]]::new()
    $solutionPackDecisions = [ordered]@{}
    $catalogReadiness = if ($catalogSelections.Count -eq 0) {
        'not-requested'
    }
    elseif (@($catalogSelections | Where-Object deploymentReadiness -NE 'ready').Count -gt 0) {
        'blocked'
    }
    else {
        'ready'
    }

    $resourceGroupClassification = if ($Configuration.azure.resourceGroup.mode -eq 'create') {
        'owned'
    }
    else {
        'reused'
    }
    $resourceGroupIntent = if ($Configuration.azure.resourceGroup.mode -eq 'create') {
        'create'
    }
    else {
        'reuse'
    }
    $resourceGroupExternalId = if ($resourceGroupIntent -eq 'reuse') {
        $configuredResourceGroupId = Get-AdltPathValue `
            -InputObject $Configuration `
            -Path 'azure.resourceGroup.resourceId'
        if ([string]::IsNullOrWhiteSpace([string] $configuredResourceGroupId)) {
            '/subscriptions/{0}/resourceGroups/{1}' -f
                $Configuration.azure.subscriptionId,
                $Configuration.azure.resourceGroup.name
        }
        else {
            [string] $configuredResourceGroupId
        }
    }
    else {
        $null
    }

    $resourceGroupParameters = @{
        Id                     = 'azure.resource-group.primary'
        Type                   = 'Microsoft.Resources/resourceGroups'
        ApiVersion             = '2024-03-01'
        LogicalName            = $Configuration.azure.resourceGroup.name
        DesiredProperties      = [ordered]@{
            location = $Configuration.azure.location
            tags     = [ordered]@{
                managedBy = 'AzureDataLabToolkit'
                labName   = $Configuration.metadata.name
                target    = $Configuration.target.type
            }
        }
        OwnershipIntent        = $resourceGroupIntent
        ExpectedClassification = $resourceGroupClassification
    }
    if ($null -ne $resourceGroupExternalId) {
        $resourceGroupParameters.ExternalResourceId = $resourceGroupExternalId
    }
    $resources.Add((New-AdltResource @resourceGroupParameters))
    $actions.Add((New-AdltAction `
        -Id 'action.resource-group.primary' `
        -Operation $(if ($resourceGroupIntent -eq 'create') { 'ensure' } else { 'reference' }) `
        -ResourceId 'azure.resource-group.primary' `
        -PlanIntentHash $planIntentHash `
        -Mutation ($resourceGroupIntent -eq 'create') `
        -OwnershipEffect $(if ($resourceGroupIntent -eq 'create') { 'intend-owned' } else { 'intend-reused' })))

    if (-not [string]::IsNullOrWhiteSpace([string] $diskEncryptionSetId)) {
        $resources.Add((New-AdltResource `
            -Id 'azure.compute.disk-encryption-set.external' `
            -Type 'Microsoft.Compute/diskEncryptionSets' `
            -ApiVersion '2024-03-02' `
            -LogicalName (Get-AdltResourceNameFromId -ResourceId $diskEncryptionSetId) `
            -ExternalResourceId $diskEncryptionSetId `
            -DesiredProperties ([ordered]@{
                compatibility       = 'verify-live'
                region              = $Configuration.azure.location
                identityAccess      = 'verify-live'
                keyVaultKeyStatus   = 'verify-live'
            }) `
            -OwnershipIntent 'reuse' `
            -ExpectedClassification 'reused'))
        $actions.Add((New-AdltAction `
            -Id 'action.compute.disk-encryption-set.external' `
            -Operation 'reference' `
            -ResourceId 'azure.compute.disk-encryption-set.external' `
            -PlanIntentHash $planIntentHash `
            -Mutation $false `
            -OwnershipEffect 'intend-reused' `
            -Postconditions @('disk-encryption-set-compatibility-verified-live')))
    }

    foreach ($fragment in Get-AdltCapabilityPlanFragment `
        -Configuration $Configuration `
        -Names $names `
        -PlanIntentHash $planIntentHash) {
        foreach ($resource in @($fragment.resources)) {
            $resources.Add($resource)
        }
        foreach ($action in @($fragment.actions)) {
            $actions.Add($action)
        }
        foreach ($warning in @($fragment.warnings)) {
            $warnings.Add([string] $warning)
        }
        if ($fragment.Contains('policyFindings')) {
            foreach ($finding in @($fragment.policyFindings)) {
                $policyFindings.Add($finding)
            }
        }
    }

    $vmDependencies = [System.Collections.Generic.List[string]]::new()
    foreach ($dependency in @(
        'action.network.interface.primary'
        'action.network.security-group.workload'
        'action.security.key-vault-secret.vm-admin'
    )) {
        $vmDependencies.Add($dependency)
    }
    if (-not [string]::IsNullOrWhiteSpace([string] $diskEncryptionSetId)) {
        $vmDependencies.Add('action.compute.disk-encryption-set.external')
    }

    $baseResources = @(
        [pscustomobject]@{
            Id         = 'azure.compute.virtual-machine.primary'
            Type       = 'Microsoft.Compute/virtualMachines'
            ApiVersion = '2024-07-01'
            Name       = $names.virtualMachine
            Dependencies = $vmDependencies.ToArray()
            Properties = [ordered]@{
                location = $Configuration.azure.location
                identity = [ordered]@{
                    type = 'SystemAssigned'
                }
                hardwareProfile = [ordered]@{
                    vmSize = $Configuration.sqlVm.compute.vmSize
                }
                securityProfile = [ordered]@{
                    securityType         = $Configuration.sqlVm.compute.securityType
                    secureBootEnabled    = $Configuration.sqlVm.compute.securityType -eq 'trustedLaunch'
                    virtualTpmEnabled    = $Configuration.sqlVm.compute.securityType -eq 'trustedLaunch'
                    encryptionAtHost     = [bool] $Configuration.sqlVm.compute.encryptionAtHost
                }
                imageReference = [ordered]@{
                    publisher       = 'MicrosoftSQLServer'
                    offer           = 'sql2022-ws2022'
                    sku             = 'sqldev-gen2'
                    version         = 'unresolved'
                    sourceAlias     = 'latest'
                    resolutionStage = 'what-if'
                }
                osProfile = [ordered]@{
                    computerName                   = $names.virtualMachine
                    administratorUsername          = 'adltadmin'
                    administratorCredentialResourceId = 'azure.security.key-vault-secret.vm-admin'
                    provisionVmAgent               = $true
                    enableAutomaticUpdates         = $true
                }
                networkProfile = [ordered]@{
                    networkInterfaceResourceIds = @('azure.network.interface.primary')
                    publicIpResourceId           = $null
                }
                storageProfile = [ordered]@{
                    osDisk = [ordered]@{
                        sizeGiB     = 128
                        storageType = 'Premium_LRS'
                        caching     = 'ReadWrite'
                        encryption  = [ordered]@{
                            type = if ($diskEncryptionSetId) { 'CustomerManaged' } else { 'PlatformManaged' }
                            diskEncryptionSetResourceId = $diskEncryptionSetId
                        }
                    }
                    dataDisks = @(
                        [ordered]@{
                            purpose     = 'sql-data'
                            lun         = 0
                            sizeGiB     = 256
                            storageType = 'Premium_LRS'
                            caching     = 'ReadOnly'
                            diskEncryptionSetResourceId = $diskEncryptionSetId
                        }
                        [ordered]@{
                            purpose     = 'sql-log'
                            lun         = 1
                            sizeGiB     = 128
                            storageType = 'Premium_LRS'
                            caching     = 'None'
                            diskEncryptionSetResourceId = $diskEncryptionSetId
                        }
                    )
                }
                patching = [ordered]@{
                    patchMode       = 'AutomaticByPlatform'
                    assessmentMode  = 'AutomaticByPlatform'
                    rebootSetting   = 'IfRequired'
                }
            }
        }
        [pscustomobject]@{
            Id         = 'azure.sql.virtual-machine.primary'
            Type       = 'Microsoft.SqlVirtualMachine/sqlVirtualMachines'
            ApiVersion = '2023-10-01'
            Name       = $names.sqlVirtualMachine
            Dependencies = @('action.compute.virtual-machine.primary')
            Properties = [ordered]@{
                location                 = $Configuration.azure.location
                virtualMachineResourceId = $virtualMachineArmResourceId
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
                    diskConfigurationType  = 'NEW'
                    enableStorageConfigBlade = $true
                    sqlDataSettings        = [ordered]@{
                        defaultFilePath = 'F:\SQLData'
                        luns            = @(0)
                        useStoragePool  = $false
                    }
                    sqlLogSettings         = [ordered]@{
                        defaultFilePath = 'G:\SQLLog'
                        luns            = @(1)
                        useStoragePool  = $false
                    }
                    sqlSystemDbOnDataDisk = $false
                    storageWorkloadType   = 'GENERAL'
                }
            }
        }
    )

    foreach ($resourceDefinition in $baseResources) {
        $resources.Add((New-AdltResource `
            -Id $resourceDefinition.Id `
            -Type $resourceDefinition.Type `
            -ApiVersion $resourceDefinition.ApiVersion `
            -LogicalName $resourceDefinition.Name `
            -DesiredProperties $resourceDefinition.Properties `
            -OwnershipIntent 'create' `
            -ExpectedClassification 'owned'))
        $actions.Add((New-AdltAction `
            -Id ('action.{0}' -f ($resourceDefinition.Id -replace '^azure\.', '')) `
            -Operation 'ensure' `
            -ResourceId $resourceDefinition.Id `
            -PlanIntentHash $planIntentHash `
            -DependsOn @($resourceDefinition.Dependencies) `
            -OwnershipEffect 'intend-owned'))
    }

    foreach ($fragment in Get-AdltSolutionPackPlanFragment `
        -Configuration $Configuration `
        -Names $names `
        -PlanIntentHash $planIntentHash) {
        foreach ($resource in @($fragment.resources)) {
            $resources.Add($resource)
        }
        foreach ($action in @($fragment.actions)) {
            $actions.Add($action)
        }
        foreach ($warning in @($fragment.warnings)) {
            $warnings.Add([string] $warning)
        }
        if ($fragment.Contains('policyFindings')) {
            foreach ($finding in @($fragment.policyFindings)) {
                $policyFindings.Add($finding)
            }
        }
        if ($fragment.Contains('decisions')) {
            $solutionPackDecisions[[string] $fragment.name] = Copy-AdltValue `
                -InputObject $fragment.decisions
        }
    }

    foreach ($selection in @($catalogSelections)) {
        $actions.Add((New-AdltAction `
            -Id ('action.catalog.stage.{0}' -f $selection.id) `
            -Operation 'stage' `
            -ResourceId ('catalog.{0}' -f $selection.id) `
            -PlanIntentHash $planIntentHash `
            -DependsOn @('action.compute.virtual-machine.primary') `
            -OwnershipEffect 'none' `
            -Postconditions @(
                'source-provenance-recorded'
                'license-recorded'
                'integrity-verified-before-deployment'
            )))
    }

    if ($Configuration.sqlVm.compute.securityType -eq 'standard') {
        $warnings.Add('The standard VM security type is weaker than the trusted-launch default.')
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.compute.standard-security' `
            -Severity high `
            -Effect acknowledge `
            -ConfigurationPath 'sqlVm.compute.securityType' `
            -Message 'Standard VM security weakens the trusted-launch baseline.'))
    }

    if (-not $Configuration.sqlVm.compute.encryptionAtHost) {
        $warnings.Add('Encryption at host is disabled in the resolved configuration.')
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.compute.host-encryption-disabled' `
            -Severity high `
            -Effect acknowledge `
            -ConfigurationPath 'sqlVm.compute.encryptionAtHost' `
            -Message 'Encryption at host is disabled.'))
    }
    if (-not [string]::IsNullOrWhiteSpace([string] $diskEncryptionSetId)) {
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.compute.disk-encryption-set-unverified' `
            -Severity warning `
            -Effect acknowledge `
            -ConfigurationPath 'sqlVm.compute.diskEncryptionSetId' `
            -Message 'The existing disk encryption set, key, region, and identity access require authenticated compatibility verification.'))
    }

    if ($Configuration.security.vmAdministratorCredential.source -eq 'generate-during-deployment') {
        $warnings.Add('Password generation is an explicit deployment-time opt-in and is not performed by offline planning.')
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.credentials.generated-password' `
            -Severity warning `
            -Effect acknowledge `
            -ConfigurationPath 'security.vmAdministratorCredential.source' `
            -Message 'Deployment-time password generation was explicitly selected.'))
    }
    elseif ($Configuration.security.secretStore.mode -eq 'deploy-key-vault') {
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.credentials.external-secret-required' `
            -Severity blocking `
            -Effect resolve-before-deploy `
            -ConfigurationPath 'security.vmAdministratorCredential.secretName' `
            -Message 'An approved secure workflow must populate the referenced secret in the new vault before VM creation.'))
    }

    if ($Configuration.security.vmAdministratorCredential.allowShellOutput) {
        $warnings.Add('Printing a generated password to the shell is explicitly requested and may expose it through terminal history or capture.')
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.credentials.shell-output' `
            -Severity high `
            -Effect acknowledge `
            -ConfigurationPath 'security.vmAdministratorCredential.allowShellOutput' `
            -Message 'The generated password may be printed to the interactive shell.'))
    }

    if ($Configuration.security.containsSensitiveData) {
        $warnings.Add('The lab is marked as containing sensitive data; later deployment requires applicable policy and approval checks.')
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.data.sensitive-content' `
            -Severity high `
            -Effect acknowledge `
            -ConfigurationPath 'security.containsSensitiveData' `
            -Message 'The lab is marked as containing sensitive data and requires the applicable data-handling controls.'))
    }

    if ($Configuration.cost.estimateRequested) {
        $warnings.Add(
            'The offline plan cannot verify current Azure retail prices; ' +
            'protected live preflight must prove the estimate is within the ' +
            'configured admission limit. The limit does not cap Azure billing.'
        )
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.cost.estimate-unavailable' `
            -Severity information `
            -Effect observe `
            -ConfigurationPath 'cost.estimateRequested' `
            -Message 'Live price evidence is unavailable in offline planning.'))
    }
    if (-not $Configuration.cost.Contains('maximumRunCost')) {
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.cost.maximum-run-cost-required' `
            -Severity blocking `
            -Effect resolve-before-deploy `
            -ConfigurationPath 'cost.maximumRunCost' `
            -Message 'An estimate admission limit in integer minor units is required before deployment can be authorized. This is not an Azure billing cap.'))
    }
    $warnings.Add(
        'Maximum runtime and TTL are authorization and pricing assumptions; ' +
        'this profile does not automatically stop or delete Azure resources.'
    )
    $policyFindings.Add((New-AdltPolicyFinding `
        -Id 'policy.lifecycle.runtime-not-enforced' `
        -Severity high `
        -Effect acknowledge `
        -ConfigurationPath 'lifecycle.maximumRuntimeMinutes' `
        -Message 'The configured runtime and TTL do not trigger automatic shutdown or teardown. The operator remains responsible for protected teardown.'))
    $warnings.Add(
        'Create-only checks are client-side and cannot exclude a concurrent ' +
        'Azure contributor. Use this canary only in an isolated scope with ' +
        'no other writers during deployment.'
    )
    $policyFindings.Add((New-AdltPolicyFinding `
        -Id 'policy.deployment.isolated-scope-required' `
        -Severity high `
        -Effect acknowledge `
        -ConfigurationPath 'azure.subscriptionId' `
        -Message 'The locked canary requires an isolated Azure scope with no concurrent contributors because create-only reads and ARM submission are not atomic.'))
    if ($Configuration.lifecycle.teardown.mode -eq 'preauthorized-canary') {
        $warnings.Add('Canary teardown is intended for separate preauthorization before deployment; this configuration value does not authorize deletion.')
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.lifecycle.preauthorized-canary-teardown' `
            -Severity high `
            -Effect acknowledge `
            -ConfigurationPath 'lifecycle.teardown.mode' `
            -Message 'A separately hashed teardown plan and approval remain required before automatic canary cleanup.'))
    }
    if ($catalogReadiness -eq 'blocked') {
        $warnings.Add('At least one catalog selection is blocked until its integrity metadata is verified.')
        $policyFindings.Add((New-AdltPolicyFinding `
            -Id 'policy.catalog.integrity-unresolved' `
            -Severity blocking `
            -Effect resolve-before-deploy `
            -ConfigurationPath 'sqlVm.software.catalogIds' `
            -Message 'At least one catalog selection lacks verified immutable integrity metadata.'))
    }
    $policyFindings.Add((New-AdltPolicyFinding `
        -Id 'policy.compute.image-version-unresolved' `
        -Severity blocking `
        -Effect resolve-before-deploy `
        -ConfigurationPath 'sqlVm.sqlServerVersion' `
        -Message 'Authenticated WhatIf must resolve and bind an immutable SQL VM marketplace image version.'))
    $policyFindings.Add((New-AdltPolicyFinding `
        -Id 'policy.licensing.authoritative-terms-required' `
        -Severity warning `
        -Effect acknowledge `
        -ConfigurationPath 'sqlVm.sqlServerVersion' `
        -Message 'The user must verify current Microsoft licensing terms for the selected SQL Server image and intended use.'))

    $resourcesArray = @($resources.ToArray() | Sort-Object { $_.id })
    $actionsArray = @($actions.ToArray() | Sort-Object { $_.id })
    $policyFindingsArray = @($policyFindings.ToArray() | Sort-Object { $_.id })
    $requiredAcknowledgementIds = @(
        $policyFindingsArray |
            Where-Object acknowledgementRequired |
            ForEach-Object id
    )
    $blockingFindingIds = @(
        $policyFindingsArray |
            Where-Object blocksDeployment |
            ForEach-Object id
    )
    $plan = [ordered]@{
        planSchemaVersion = '1.0'
        kind              = 'AzureDataLabPlan'
        toolkit           = [ordered]@{
            name    = 'AzureDataLabToolkit'
            version = $script:AzureDataLabToolkitVersion
        }
        contracts          = Copy-AdltValue -InputObject $contracts
        canonicalization  = 'rfc8785'
        intentHash         = $planIntentHash
        target            = [ordered]@{
            type             = 'sqlVm'
            planSupport      = if (
                @($supportEvaluation | Where-Object { $_.plan -eq 'supported-with-warning' }).Count -gt 0
            ) {
                'supported-with-warning'
            }
            else {
                'supported'
            }
            deploymentStatus = $deploymentStatus
            catalogReadiness = $catalogReadiness
        }
        context           = [ordered]@{
            cloud                 = $Configuration.azure.cloud
            tenantId              = $Configuration.azure.tenantId
            subscriptionId        = $Configuration.azure.subscriptionId
            location              = $Configuration.azure.location
            authenticationStatus  = 'unverified'
            azureContextStatus     = 'unverified'
        }
        unverifiedFacts   = [ordered]@{
            subscriptionAccess = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            regionAvailability = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            vmSkuAvailability = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            resourceNameAvailability = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            currentResourceState = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            pricing = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'cost-estimate'
            }
            marketplaceImageVersion = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            resourceProviderRegistration = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            deploymentPrincipalObjectId = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            keyVaultDataPlaneAccess = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
            administrativeAccessCompatibility = [ordered]@{
                status       = 'unverified'
                resolvedBy   = 'what-if'
            }
        }
        configuration     = Copy-AdltValue -InputObject $Configuration
        decisions         = [ordered]@{
            target = [ordered]@{
                provider = 'sqlVm'
                secretStoreDecision = Copy-AdltValue `
                    -InputObject $Configuration.security.secretStore
                administrativeAccessDecision = Copy-AdltValue `
                    -InputObject $Configuration.security.administrativeAccess
            }
            solutionPacks = Copy-AdltValue -InputObject $solutionPackDecisions
            authentication = [ordered]@{
                mode = $Configuration.azure.authentication.mode
                contextScope = $Configuration.azure.authentication.contextScope
                tokenPersistence = 'none-in-plan'
            }
            azureContext = [ordered]@{
                selection = 'explicit-tenant-and-subscription'
                processScope = $true
                verification = 'required-before-whatif-or-deploy'
            }
            secretStore = Copy-AdltValue -InputObject $Configuration.security.secretStore
            identity = [ordered]@{
                deploymentPrincipal = $Configuration.azure.authentication.mode
                virtualMachine      = $Configuration.security.vmManagedIdentity
                verification        = 'required-before-whatif-or-deploy'
            }
            administrativeAccess = Copy-AdltValue -InputObject $Configuration.security.administrativeAccess
            vmAdministratorCredential = Copy-AdltValue -InputObject $Configuration.security.vmAdministratorCredential
            computeSecurity = [ordered]@{
                securityType     = $Configuration.sqlVm.compute.securityType
            }
            diskProtection = [ordered]@{
                encryptionAtHost    = $Configuration.sqlVm.compute.encryptionAtHost
                diskEncryptionSetId = $diskEncryptionSetId
                liveCompatibility   = 'unverified'
            }
            network = [ordered]@{
                vmPublicIp       = $Configuration.sqlVm.network.vmPublicIp
                privateWorkload  = $true
                liveCompatibility = 'unverified'
            }
            licensing = [ordered]@{
                status                     = 'unverified'
                resolvedBy                 = 'provider-image-and-license-plan'
                authoritativeTermsRequired = $true
            }
            patching = [ordered]@{
                status     = 'unverified'
                resolvedBy = 'provider-plan'
            }
            guestExecution = [ordered]@{
                status            = 'contract-only'
                automaticRestore  = $false
                systemUserRestore = $false
            }
            dataSensitivity = [ordered]@{
                containsSensitiveData = $Configuration.security.containsSensitiveData
            }
            cost = [ordered]@{
                estimateRequested = $Configuration.cost.estimateRequested
                status            = 'unverified'
                budget            = Copy-AdltValue -InputObject $Configuration.cost.budget
                maximumRunCost    = if ($Configuration.cost.Contains('maximumRunCost')) {
                    Copy-AdltValue -InputObject $Configuration.cost.maximumRunCost
                }
                else {
                    $null
                }
            }
            lifecycle = [ordered]@{
                purpose               = $Configuration.metadata.purpose
                maximumRuntimeMinutes = $Configuration.lifecycle.maximumRuntimeMinutes
                timeToLiveMinutes      = $Configuration.lifecycle.timeToLiveMinutes
                expiryBehavior        = $Configuration.lifecycle.expiryBehavior
            }
            backupShare = Copy-AdltValue -InputObject $Configuration.capabilities.backupShare
            backupRestore = Copy-AdltValue -InputObject $Configuration.solutionPacks.sqlVmBackupRestore
            teardown = Copy-AdltValue -InputObject $Configuration.lifecycle.teardown
        }
        resources         = $resourcesArray
        actions           = $actionsArray
        catalogSelections = @($catalogSelections)
        supportEvaluation  = @($supportEvaluation)
        provenance        = Copy-AdltValue -InputObject $Provenance
        unsupportedCapabilities = @()
        policyFindings     = $policyFindingsArray
        warnings          = @($warnings.ToArray())
        approval          = [ordered]@{
            required                 = $true
            approvedPlanHashRequired = $true
            acknowledgementPlanHashRequired = $true
            requiredAcknowledgementIds = $requiredAcknowledgementIds
            blockingFindingIds       = $blockingFindingIds
            destructiveActions       = @()
            teardownRequiresSeparatePlan = $true
        }
    }

    Assert-AdltPlanStructure -Plan $plan
    $plan.planHash = Get-AdltPlanHash -Plan $plan
    $planValidation = Test-AdltObjectAgainstSchema `
        -InputObject $plan `
        -SchemaPath (Get-AdltDataPath -ChildPath 'Schemas/plan.schema.json')
    if (-not $planValidation.Valid) {
        throw "Generated plan schema validation failed: $($planValidation.Errors -join ' ')"
    }

    return $plan
}

Register-AdltTargetPlanContributor `
    -TargetType 'sqlVm' `
    -FunctionName 'New-AdltSqlVmPlan' `
    -ContractVersion '1.0' `
    -SupportedSchemaVersions @('1.0')
