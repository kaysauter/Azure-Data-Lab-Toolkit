function Get-AdltKeyVaultPlanFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Names,

        [Parameter(Mandatory)]
        [string] $PlanIntentHash
    )

    $secretStore = $Configuration.security.secretStore
    if ($secretStore.mode -notin @('deploy-key-vault', 'reuse-key-vault')) {
        throw "The SQL VM provider cannot use secret-store mode '$($secretStore.mode)'."
    }

    $resources = [System.Collections.Generic.List[object]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()
    $createVault = $secretStore.mode -eq 'deploy-key-vault'
    $vaultName = if ($createVault) {
        $Names.keyVault
    }
    else {
        Get-AdltResourceNameFromId -ResourceId $secretStore.resourceId
    }
    $vaultProperties = if ($createVault) {
        [ordered]@{
            location                = $Configuration.azure.location
            tenantId                = $Configuration.azure.tenantId
            sku                     = 'standard'
            enableRbacAuthorization = $true
            enabledForTemplateDeployment = $true
            publicNetworkAccess     = 'Disabled'
            softDeleteRetentionDays = 90
            purgeProtectionEnabled  = $true
        }
    }
    else {
        [ordered]@{
            compatibility              = 'verify-live'
            enableRbacAuthorization    = 'required'
            enabledForTemplateDeployment = 'required'
            privateDataPlaneAccess     = 'required'
            purgeProtectionEnabled     = 'required'
            auditDiagnostics           = 'required'
            diagnosticDestinationResourceId =
                [string] $secretStore.diagnosticDestinationResourceId
        }
    }

    $vaultParameters = @{
        Id                     = 'azure.security.key-vault.primary'
        Type                   = 'Microsoft.KeyVault/vaults'
        ApiVersion             = '2026-02-01'
        LogicalName            = $vaultName
        DesiredProperties      = $vaultProperties
        OwnershipIntent        = if ($createVault) { 'create' } else { 'reuse' }
        ExpectedClassification = if ($createVault) { 'owned' } else { 'reused' }
    }
    if (-not $createVault) {
        $vaultParameters.ExternalResourceId = $secretStore.resourceId
    }
    $resources.Add((New-AdltResource @vaultParameters))

    $vaultActionParameters = @{
        Id              = 'action.security.key-vault.primary'
        Operation       = if ($createVault) { 'ensure' } else { 'reference' }
        ResourceId      = 'azure.security.key-vault.primary'
        PlanIntentHash  = $PlanIntentHash
        Mutation        = $createVault
        OwnershipEffect = if ($createVault) { 'intend-owned' } else { 'intend-reused' }
    }
    if ($createVault) {
        $vaultActionParameters.DependsOn = @('action.resource-group.primary')
    }
    $actions.Add((New-AdltAction @vaultActionParameters))

    $secretPrerequisites = [System.Collections.Generic.List[string]]::new()
    $secretPrerequisites.Add('action.security.key-vault.primary')
    if ($createVault) {
        $networkDefinitions = @(
            [pscustomobject]@{
                Id           = 'azure.network.private-dns-zone.key-vault'
                Type         = 'Microsoft.Network/privateDnsZones'
                ApiVersion   = '2024-06-01'
                Name         = $Names.keyVaultPrivateDnsZone
                Dependencies = @('action.resource-group.primary')
                Properties   = [ordered]@{
                    zoneName = $Names.keyVaultPrivateDnsZone
                }
            }
            [pscustomobject]@{
                Id           = 'azure.network.private-dns-vnet-link.key-vault'
                Type         = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
                ApiVersion   = '2024-06-01'
                Name         = $Names.keyVaultDnsZoneLink
                Dependencies = @(
                    'action.network.private-dns-zone.key-vault'
                    'action.network.virtual-network.primary'
                )
                Properties   = [ordered]@{
                    privateDnsZoneResourceId = 'azure.network.private-dns-zone.key-vault'
                    virtualNetworkResourceId = 'azure.network.virtual-network.primary'
                    registrationEnabled      = $false
                }
            }
            [pscustomobject]@{
                Id           = 'azure.network.private-endpoint.key-vault'
                Type         = 'Microsoft.Network/privateEndpoints'
                ApiVersion   = '2024-05-01'
                Name         = $Names.keyVaultPrivateEndpoint
                Dependencies = @(
                    'action.security.key-vault.primary'
                    'action.network.subnet.workload'
                )
                Properties   = [ordered]@{
                    location                     = $Configuration.azure.location
                    subnetResourceId             = 'azure.network.subnet.workload'
                    privateLinkResourceId        = 'azure.security.key-vault.primary'
                    groupIds                     = @('vault')
                    manualPrivateLinkApproval    = $false
                }
            }
            [pscustomobject]@{
                Id           = 'azure.network.private-dns-zone-group.key-vault'
                Type         = 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
                ApiVersion   = '2024-05-01'
                Name         = $Names.keyVaultDnsZoneGroup
                Dependencies = @(
                    'action.network.private-endpoint.key-vault'
                    'action.network.private-dns-vnet-link.key-vault'
                )
                Properties   = [ordered]@{
                    privateEndpointResourceId = 'azure.network.private-endpoint.key-vault'
                    privateDnsZoneResourceId  = 'azure.network.private-dns-zone.key-vault'
                }
            }
        )

        foreach ($definition in $networkDefinitions) {
            $resources.Add((New-AdltResource `
                -Id $definition.Id `
                -Type $definition.Type `
                -ApiVersion $definition.ApiVersion `
                -LogicalName $definition.Name `
                -DesiredProperties $definition.Properties `
                -OwnershipIntent 'create' `
                -ExpectedClassification 'owned'))
            $actions.Add((New-AdltAction `
                -Id ('action.{0}' -f ($definition.Id -replace '^azure\.', '')) `
                -Operation 'ensure' `
                -ResourceId $definition.Id `
                -PlanIntentHash $PlanIntentHash `
                -DependsOn @($definition.Dependencies) `
                -OwnershipEffect 'intend-owned'))
        }
        $secretPrerequisites.Add('action.network.private-dns-zone-group.key-vault')
    }

    $credential = $Configuration.security.vmAdministratorCredential
    $generatesSecret = $credential.source -eq 'generate-during-deployment'
    if ($generatesSecret) {
        $roleProperties = [ordered]@{
            scopeResourceId    = 'azure.security.key-vault.primary'
            principalReference = 'deployment-principal'
            roleDefinitionName = 'Key Vault Secrets Officer'
            principalIdStatus  = 'unverified'
        }
        $roleParameters = @{
            Id                = 'azure.authorization.key-vault-secrets.deployment'
            Type              = 'Microsoft.Authorization/roleAssignments'
            ApiVersion        = '2022-04-01'
            LogicalName       = $Names.keyVaultRole
            DesiredProperties = $roleProperties
            OwnershipIntent   = 'create'
            ExpectedClassification = 'owned'
            TeardownIntent    = 'delete-after-proof-and-approval'
        }
        $resources.Add((New-AdltResource @roleParameters))
        $roleAction = New-AdltAction `
            -Id 'action.authorization.key-vault-secrets.deployment' `
            -Operation 'ensure' `
            -ResourceId 'azure.authorization.key-vault-secrets.deployment' `
            -PlanIntentHash $PlanIntentHash `
            -DependsOn @($secretPrerequisites) `
            -OwnershipEffect 'intend-owned' `
            -Postconditions @(
                'least-privilege-secret-write-role-established'
                'principal-id-resolved-during-whatif'
            )
        $actions.Add($roleAction)
        $secretPrerequisites.Clear()
        $secretPrerequisites.Add(
            'action.authorization.key-vault-secrets.deployment'
        )
    }

    $secretExternalId = if ($createVault) {
        $null
    }
    else {
        '{0}/secrets/{1}' -f $secretStore.resourceId.TrimEnd('/'), $credential.secretName
    }
    $secretDesiredProperties = [ordered]@{
        parentResourceId   = 'azure.security.key-vault.primary'
        valueSource        = if ($generatesSecret) { 'secure-generation' } else { 'external-secure-input' }
        valueInPlan        = $false
        valueInState       = $false
        shellOutputAllowed = [bool] $credential.allowShellOutput
    }
    if ($credential.Contains('secretVersion')) {
        $secretDesiredProperties.secretVersion = [string] $credential.secretVersion
    }
    $secretParameters = @{
        Id                = 'azure.security.key-vault-secret.vm-admin'
        Type              = 'Microsoft.KeyVault/vaults/secrets'
        ApiVersion        = '2026-02-01'
        LogicalName       = $credential.secretName
        DesiredProperties = $secretDesiredProperties
        OwnershipIntent        = if ($generatesSecret) { 'create' } else { 'observe' }
        ExpectedClassification = if ($generatesSecret) { 'owned' } else { 'external' }
        TeardownIntent          = if ($generatesSecret) { 'delete-after-proof-and-approval' } else { 'retain' }
    }
    if (-not [string]::IsNullOrWhiteSpace($secretExternalId)) {
        $secretParameters.ExternalResourceId = $secretExternalId
    }
    $resources.Add((New-AdltResource @secretParameters))
    $secretAction = New-AdltAction `
        -Id 'action.security.key-vault-secret.vm-admin' `
        -Operation $(if ($generatesSecret) { 'ensure' } else { 'reference' }) `
        -ResourceId 'azure.security.key-vault-secret.vm-admin' `
        -PlanIntentHash $PlanIntentHash `
        -DependsOn @($secretPrerequisites) `
        -Mutation $generatesSecret `
        -OwnershipEffect $(if ($generatesSecret) { 'intend-owned' } else { 'none' }) `
        -Postconditions @(
            'secret-exists-before-vm-creation'
            'plaintext-never-enters-plan-state-or-log'
            'secret-value-resolved-only-by-approved-engine'
            'template-deployment-authorization-proven-by-native-whatif'
        )
    $actions.Add($secretAction)

    return [ordered]@{
        name           = 'keyVault'
        resources      = $resources.ToArray()
        actions        = $actions.ToArray()
        policyFindings = @(
            if (-not $createVault) {
                New-AdltPolicyFinding `
                    -Id 'policy.secret-store.compatibility-unresolved' `
                    -Severity blocking `
                    -Effect resolve-before-deploy `
                    -ConfigurationPath 'security.secretStore.resourceId' `
                    -Message 'The reused Key Vault security and network profile must be verified before deployment.'
                New-AdltPolicyFinding `
                    -Id 'policy.credentials.secret-version-unresolved' `
                    -Severity blocking `
                    -Effect resolve-before-deploy `
                    -ConfigurationPath 'security.vmAdministratorCredential.secretVersion' `
                    -Message 'The pinned VM administrator secret version metadata must be verified before deployment.'
            }
            New-AdltPolicyFinding `
                -Id 'policy.secret-store.diagnostics-unresolved' `
                -Severity blocking `
                -Effect resolve-before-deploy `
                -ConfigurationPath 'security.secretStore.mode' `
                -Message 'Key Vault diagnostic settings and their approved destination must be resolved before deployment.'
        )
        warnings       = @(
            if (-not $generatesSecret -and $createVault) {
                'The new vault requires an external secure workflow to populate the referenced VM administrator secret before deployment can continue.'
            }
            'The offline plan cannot verify Key Vault security and audit ' +
            'diagnostics; protected live preflight must prove both before ' +
            'deployment authorization.'
        )
    }
}

Register-AdltCapabilityPlanContributor `
    -Name 'keyVault' `
    -FunctionName 'Get-AdltKeyVaultPlanFragment' `
    -ContractVersion '1.0' `
    -SupportedSchemaVersions @('1.0') `
    -TargetTypes @('sqlVm') `
    -Dependencies @('capability:networking') `
    -AlwaysActive
