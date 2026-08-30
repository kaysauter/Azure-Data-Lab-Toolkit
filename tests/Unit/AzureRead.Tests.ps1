BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:ConfigurationPath = Join-Path `
        $script:RepositoryRoot `
        'examples/sqlvm-first-canary.yaml'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:Module = Get-Module AzureDataLabToolkit
    $script:RunId = '33333333-3333-4333-8333-333333333333'
    $script:KeyVaultResourceId = (
        '/subscriptions/22222222-2222-4222-8222-222222222222/' +
        'resourceGroups/rg-shared/providers/Microsoft.KeyVault/' +
        'vaults/kv-shared'
    )
    $script:DiagnosticDestinationResourceId = (
        '/subscriptions/22222222-2222-4222-8222-222222222222/' +
        'resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/' +
        'workspaces/law-adlt'
    )
    $script:SecretVersion = '0123456789abcdef0123456789abcdef'
    $script:Plan = New-AzureDataLabPlan `
        $script:ConfigurationPath `
        -SecretStoreMode reuse-key-vault `
        -SecretStoreResourceId $script:KeyVaultResourceId `
        -KeyVaultDiagnosticDestinationResourceId `
            $script:DiagnosticDestinationResourceId `
        -VmAdministratorSecretVersion $script:SecretVersion
    $script:ResolvedResourceIds = & $script:Module {
        param($Plan)
        Get-AdltResolvedResourceIdSet -Plan $Plan
    } $script:Plan

    function New-AzureReadTestErrorRecord {
        param(
            [Parameter(Mandatory)]
            [ValidateSet('ResourceNotFound', 'AuthorizationFailed')]
            [string] $Code
        )

        $category = if ($Code -ceq 'ResourceNotFound') {
            [System.Management.Automation.ErrorCategory]::ObjectNotFound
        }
        else {
            [System.Management.Automation.ErrorCategory]::PermissionDenied
        }
        return [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new(
                'Synthetic structured Azure failure.'
            ),
            $Code,
            $category,
            $null
        )
    }
}

Describe 'Exact ARM resource ID resolution' {
    It 'resolves top-level, nested, extension, and resource-group IDs' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            Plan = $script:Plan
        } {
            $ids = Get-AdltResolvedResourceIdSet -Plan $Plan
            ($ids | Where-Object stableId -eq 'azure.resource-group.primary').resourceId |
                Should -BeExactly (
                    '/subscriptions/22222222-2222-4222-8222-222222222222/' +
                    'resourceGroups/rg-adlt-sqlvm-canary'
                )
            ($ids | Where-Object stableId -eq 'azure.network.subnet.workload').resourceId |
                Should -BeExactly (
                    '/subscriptions/22222222-2222-4222-8222-222222222222/' +
                    'resourceGroups/rg-adlt-sqlvm-canary/providers/Microsoft.Network/' +
                    'virtualNetworks/vnet-sqlvm-canary/subnets/snet-workload'
                )
            $ids.stableId |
                Should -Not -Contain 'azure.authorization.key-vault-secrets.deployment'
        }
    }

    It 'rejects missing and cyclic resource ID dependencies' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            Plan = $script:Plan
        } {
            {
                Get-AdltPlanResource `
                    -Plan $Plan `
                    -StableId azure.resource.missing
            } | Should -Throw '*must resolve exactly once*'

            $cyclePlan = [ordered]@{
                context = [ordered]@{
                    subscriptionId =
                        '22222222-2222-4222-8222-222222222222'
                }
                configuration = [ordered]@{
                    azure = [ordered]@{
                        resourceGroup = [ordered]@{
                            name = 'rg-adlt-cycle'
                        }
                    }
                }
                resources = @(
                    [ordered]@{
                        id = 'azure.authorization.cycle'
                        type =
                            'Microsoft.Authorization/roleAssignments'
                        logicalName =
                            '11111111-1111-4111-8111-111111111111'
                        externalResourceId = $null
                        desiredProperties = [ordered]@{
                            scopeResourceId =
                                'azure.authorization.cycle'
                        }
                    }
                )
            }
            {
                Resolve-AdltPlanResourceId `
                    -Plan $cyclePlan `
                    -StableId azure.authorization.cycle
            } | Should -Throw '*dependency cycle detected*'
        }
    }
}

Describe 'Native ARM WhatIf normalization' {
    It 'normalizes diagnostics, errors, relative IDs, and unsupported changes' {
        InModuleScope AzureDataLabToolkit {
            $scope = (
                '/subscriptions/22222222-2222-4222-8222-222222222222/' +
                'resourceGroups/rg-adlt-whatif'
            )
            $result = [pscustomobject]@{
                Status = 'Failed'
                Diagnostics = @(
                    [pscustomobject]@{
                        Level = 'Warning'
                        Code = 'ProviderWarning'
                        Target = 'deployment'
                    }
                )
                Error = [pscustomobject]@{
                    Code = 'ProviderFailure'
                    Target = 'deployment'
                }
                Changes = @(
                    [pscustomobject]@{
                        FullyQualifiedResourceId = $null
                        Scope = $scope
                        RelativeResourceId = (
                            'providers/Microsoft.Compute/' +
                            'virtualMachines/vm-adlt-whatif'
                        )
                        ChangeType = 'Modify'
                        UnsupportedReason = 'ProviderNoRbac'
                    }
                )
                PotentialChanges = @()
            }

            $normalized = ConvertTo-AdltNativeWhatIfResult `
                -Result $result

            $normalized.status | Should -BeExactly 'Failed'
            @($normalized.changes).Count | Should -Be 1
            $normalized.changes[0].resourceId |
                Should -BeExactly (
                    "$scope/providers/Microsoft.Compute/" +
                    'virtualMachines/vm-adlt-whatif'
                )
            @($normalized.diagnostics).code |
                Sort-Object |
                Should -Be @(
                    'ProviderFailure'
                    'ProviderWarning'
                    'UnsupportedChange'
                )
            $normalized.potentialChangeCount | Should -Be 0
            $normalized.changesHash |
                Should -Match '^sha256:[a-f0-9]{64}$'
            $normalized.resultHash |
                Should -Match '^sha256:[a-f0-9]{64}$'
        }
    }
}

Describe 'Azure-aware live resolution and WhatIf' {
    BeforeEach {
        $script:DisableEncryptionAtHostCapability = $false
        $script:SecretMetadataIncludesValue = $false
        $script:UseWrongDiagnosticDestination = $false
        $script:UsePublicKeyVault = $false
        $script:SecretMetadataQuery = $null
        $script:NativeChangeOverride = $null
        $script:NativeParameterPath = $null
        $script:NativeParameterDocument = $null
        $script:NativeParameterPrivate = $false
        Mock Assert-AdltAzureContextReady -ModuleName AzureDataLabToolkit {
            return [ordered]@{
                cloud            = 'AzureCloud'
                tenantId         = '11111111-1111-4111-8111-111111111111'
                subscriptionId   = '22222222-2222-4222-8222-222222222222'
                subscriptionName = 'Canary'
                accountType      = 'User'
                tokenExpiresAt   = '2026-07-28T20:00:00Z'
                contextScope     = 'process'
            }
        }
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            switch ($CommandName) {
                'Get-AzResourceProvider' {
                    return [pscustomobject]@{
                        RegistrationState = 'Registered'
                    }
                }
                'Get-AzVMImage' {
                    if ($Parameters.ContainsKey('Version')) {
                        return [pscustomobject]@{
                            HyperVGeneration = 'V2'
                            Features = @(
                                [pscustomobject]@{
                                    Name  = 'SecurityType'
                                    Value = 'TrustedLaunchSupported'
                                }
                            )
                        }
                    }
                    return @(
                        [pscustomobject]@{ Version = '16.0.1000' }
                        [pscustomobject]@{ Version = '16.0.2000' }
                    )
                }
                'Get-AzComputeResourceSku' {
                    return [pscustomobject]@{
                        ResourceType = 'virtualMachines'
                        Name         = 'Standard_D4s_v5'
                        Locations    = @('switzerlandnorth')
                        Restrictions = @()
                        Capabilities = @(
                            [pscustomobject]@{
                                Name  = 'EncryptionAtHostSupported'
                                Value = if (
                                    $script:DisableEncryptionAtHostCapability
                                ) {
                                    'False'
                                }
                                else {
                                    'True'
                                }
                            }
                            [pscustomobject]@{
                                Name  = 'HyperVGenerations'
                                Value = 'V1,V2'
                            }
                            [pscustomobject]@{
                                Name  = 'TrustedLaunchDisabled'
                                Value = 'False'
                            }
                        )
                    }
                }
                'Get-AzADUser' {
                    return [pscustomobject]@{
                        Id = '55555555-5555-4555-8555-555555555555'
                    }
                }
                'Get-AzDiagnosticSetting' {
                    return [pscustomobject]@{
                        Name        = 'audit-to-law'
                        WorkspaceId = if (
                            $script:UseWrongDiagnosticDestination
                        ) {
                            $script:DiagnosticDestinationResourceId -replace
                                'law-adlt$',
                                'law-wrong'
                        }
                        else {
                            $script:DiagnosticDestinationResourceId
                        }
                        Log         = @(
                            [pscustomobject]@{
                                Category = 'AuditEvent'
                                Enabled  = $true
                            }
                        )
                    }
                }
                'Get-AzDeploymentWhatIfResult' {
                    $script:NativeParameterPath =
                        [string] $Parameters.TemplateParameterFile
                    $script:NativeParameterDocument = Get-Content `
                        -LiteralPath $script:NativeParameterPath `
                        -Raw |
                        ConvertFrom-Json -AsHashtable -Depth 100
                    if (-not $IsWindows) {
                        $mode = [System.IO.File]::GetUnixFileMode(
                            $script:NativeParameterPath
                        )
                        $nonOwnerMask =
                            [System.IO.UnixFileMode]::GroupRead -bor
                            [System.IO.UnixFileMode]::GroupWrite -bor
                            [System.IO.UnixFileMode]::GroupExecute -bor
                            [System.IO.UnixFileMode]::OtherRead -bor
                            [System.IO.UnixFileMode]::OtherWrite -bor
                            [System.IO.UnixFileMode]::OtherExecute
                        $script:NativeParameterPrivate =
                            ($mode -band $nonOwnerMask) -eq 0
                    }
                    else {
                        $script:NativeParameterPrivate = $true
                    }
                    $resolvedIds = $script:ResolvedResourceIds
                    $ownedStableIds = @(
                        $script:Plan.resources |
                            Where-Object {
                                $_.ownership.expectedClassification -eq
                                    'owned'
                            } |
                            ForEach-Object id
                    )
                    $changes = @(
                        foreach ($resource in $resolvedIds) {
                            if ($resource.stableId -in $ownedStableIds) {
                                [pscustomobject]@{
                                    FullyQualifiedResourceId =
                                        $resource.resourceId
                                    ChangeType = 'Create'
                                    UnsupportedReason = $null
                                }
                            }
                        }
                    )
                    $resourceGroupId = (
                        $resolvedIds |
                            Where-Object {
                                $_.stableId -eq
                                    'azure.resource-group.primary'
                            }
                    ).resourceId
                    $nestedDeployment = (
                        $Parameters.TemplateObject.resources |
                            Where-Object {
                                $_.type -eq
                                    'Microsoft.Resources/deployments'
                            }
                    )
                    $changes += [pscustomobject]@{
                        FullyQualifiedResourceId = (
                            "$resourceGroupId/providers/Microsoft.Resources/" +
                            "deployments/$($nestedDeployment.name)"
                        )
                        ChangeType = 'Deploy'
                        UnsupportedReason = $null
                    }
                    if (
                        -not [string]::IsNullOrWhiteSpace(
                            [string] $script:NativeChangeOverride
                        )
                    ) {
                        $changes[0].ChangeType =
                            $script:NativeChangeOverride
                    }
                    return [pscustomobject]@{
                        Status           = 'Succeeded'
                        Error            = $null
                        Changes          = $changes
                        Diagnostics      = @()
                        PotentialChanges = @()
                    }
                }
                'Get-AzResource' {
                    if (
                        [string]::Equals(
                            [string] $Parameters.ResourceId,
                            $script:KeyVaultResourceId,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    ) {
                        return [pscustomobject]@{
                            ResourceId   = $script:KeyVaultResourceId
                            ResourceType = 'Microsoft.KeyVault/vaults'
                            Properties   = [pscustomobject]@{
                                TenantId = '11111111-1111-4111-8111-111111111111'
                                ProvisioningState = 'Succeeded'
                                EnableRbacAuthorization = $true
                                EnabledForTemplateDeployment = $true
                                EnablePurgeProtection = $true
                                SoftDeleteRetentionInDays = 90
                                PublicNetworkAccess = if (
                                    $script:UsePublicKeyVault
                                ) {
                                    'Enabled'
                                }
                                else {
                                    'Disabled'
                                }
                                NetworkAcls = [pscustomobject]@{
                                    DefaultAction = 'Deny'
                                }
                                PrivateEndpointConnections = @(
                                    [pscustomobject]@{
                                        Properties = [pscustomobject]@{
                                            ProvisioningState = 'Succeeded'
                                            PrivateLinkServiceConnectionState =
                                                [pscustomobject]@{
                                                    Status = 'Approved'
                                                }
                                        }
                                    }
                                )
                            }
                        }
                    }
                    if (
                        [string] $Parameters.ResourceId -like
                            "$($script:KeyVaultResourceId)/secrets/*"
                    ) {
                        $script:SecretMetadataQuery = [ordered]@{
                            moduleName = $ModuleName
                            commandName = $CommandName
                            apiVersion = [string] $Parameters.ApiVersion
                        }
                        $properties = [pscustomobject]@{
                            SecretUriWithVersion = (
                                'https://kv-shared.vault.azure.net/secrets/' +
                                "vm-admin-password/$($script:SecretVersion)"
                            )
                            Attributes = [pscustomobject]@{
                                Enabled = $true
                                Nbf = [datetimeoffset]::UtcNow.
                                    AddMinutes(-5).ToUnixTimeSeconds()
                                Exp = [datetimeoffset]::UtcNow.
                                    AddDays(1).ToUnixTimeSeconds()
                            }
                        }
                        if ($script:SecretMetadataIncludesValue) {
                            $properties |
                                Add-Member `
                                    -NotePropertyName Value `
                                    -NotePropertyValue '[redacted]'
                        }
                        return [pscustomobject]@{
                            ResourceId   = [string] $Parameters.ResourceId
                            ResourceType = (
                                'Microsoft.KeyVault/vaults/secrets'
                            )
                            Properties   = $properties
                        }
                    }
                    throw (
                        New-AzureReadTestErrorRecord `
                            -Code ResourceNotFound
                    )
                }
                'Get-AzResourceGroup' {
                    throw (
                        New-AzureReadTestErrorRecord `
                            -Code ResourceNotFound
                    )
                }
                default {
                    throw "Unexpected Azure command '$CommandName'."
                }
            }
        }
    }

    It 'binds immutable image, provider, principal, SKU, and resource IDs' {
        $evidence = Resolve-AzureDataLabPlan `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'pass'
        $evidence.payload.imageResolution.version | Should -Be '16.0.2000'
        $evidence.payload.skuResolution.available | Should -BeTrue
        $evidence.payload.skuResolution.encryptionAtHostSupported |
            Should -BeTrue
        $evidence.payload.imageResolution.trustedLaunchSupported |
            Should -BeTrue
        $evidence.payload.keyVaultResolution.enableRbacAuthorization |
            Should -BeTrue
        $evidence.payload.secretMetadata.version |
            Should -BeExactly $script:SecretVersion
        $script:SecretMetadataQuery.moduleName |
            Should -BeExactly 'Az.Resources'
        $script:SecretMetadataQuery.commandName |
            Should -BeExactly 'Get-AzResource'
        $script:SecretMetadataQuery.apiVersion |
            Should -BeExactly '2026-02-01'
        $evidence.payload.diagnosticResolution.auditEnabled |
            Should -BeTrue
        $evidence.payload.principalObjectId |
            Should -Be '55555555-5555-4555-8555-555555555555'
        $evidence.payload.resources.Count | Should -Be $script:Plan.resources.Count
    }

    It 'classifies absent owned resources as create without mutation' {
        $resolution = Resolve-AzureDataLabPlan `
            -Plan $script:Plan `
            -RunId $script:RunId
        $whatIf = Test-AzureDataLabWhatIf `
            -Plan $script:Plan `
            -LiveResolutionEvidence $resolution `
            -RunId $script:RunId

        $whatIf.payload.mutationCount | Should -Be 0
        $whatIf.payload.validationLevel | Should -BeExactly 'Provider'
        $whatIf.payload.resultFormat | Should -BeExactly 'ResourceIdOnly'
        $whatIf.payload.nativeStatus | Should -BeExactly 'Succeeded'
        $whatIf.payload.nativeChanges.Count | Should -Be 11
        $whatIf.payload.nativeFailureKind | Should -BeNullOrEmpty
        $script:NativeParameterPrivate | Should -BeTrue
        Test-Path -LiteralPath $script:NativeParameterPath |
            Should -BeFalse
        $reference = $script:NativeParameterDocument[
            'parameters'
        ]['vmAdministratorPassword']['reference']
        $reference.keyVault.id |
            Should -BeExactly $script:KeyVaultResourceId
        $reference.secretName | Should -BeExactly 'vm-admin-password'
        $reference.secretVersion |
            Should -BeExactly $script:SecretVersion
        ($script:NativeParameterDocument | ConvertTo-Json -Depth 20) |
            Should -Not -Match '(?i)secretValue|plainText|accessToken'
        $owned = @(
            $whatIf.payload.results |
                Where-Object plannedOwnership -eq 'owned'
        )
        $owned.classification | Should -Not -Contain 'reuse'
        $owned.classification | Should -Not -Contain 'denied'
        $owned.classification | Should -Not -Contain 'conflict'
    }

    It 'never treats denied reads as absence or create' {
        $resolution = Resolve-AzureDataLabPlan `
            -Plan $script:Plan `
            -RunId $script:RunId
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)
            throw (
                New-AzureReadTestErrorRecord `
                    -Code AuthorizationFailed
            )
        }

        $whatIf = Test-AzureDataLabWhatIf `
            -Plan $script:Plan `
            -LiveResolutionEvidence $resolution `
            -RunId $script:RunId

        $whatIf.status | Should -Be 'denied'
        $whatIf.payload.results.classification | Should -Not -Contain 'create'
        $whatIf.payload.results.classification | Should -Contain 'denied'
    }

    It 'classifies an untagged existing owned resource as a conflict' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            Plan  = $script:Plan
            RunId = $script:RunId
        } {
            $resource = Get-AdltPlanResource `
                -Plan $Plan `
                -StableId 'azure.compute.virtual-machine.primary'
            $read = [ordered]@{
                status      = 'present'
                failureKind = $null
                observed    = [pscustomobject]@{ Tags = @{} }
            }

            Get-AdltWhatIfClassification `
                -Resource $resource `
                -ReadResult $read `
                -RunId $RunId |
                Should -Be 'conflict'
        }
    }

    It 'fails closed when native ARM WhatIf reports a delete' {
        $resolution = Resolve-AzureDataLabPlan `
            -Plan $script:Plan `
            -RunId $script:RunId
        $script:NativeChangeOverride = 'Delete'

        $whatIf = Test-AzureDataLabWhatIf `
            -Plan $script:Plan `
            -LiveResolutionEvidence $resolution `
            -RunId $script:RunId

        $whatIf.status | Should -Be 'unverified'
        $whatIf.payload.nativeStatus | Should -Be 'Unavailable'
        $whatIf.payload.nativeFailureKind | Should -Be 'unknown'
        Test-Path -LiteralPath $script:NativeParameterPath |
            Should -BeFalse
    }

    It 'fails closed on secret-bearing metadata without retaining its value' {
        $script:SecretMetadataIncludesValue = $true

        $evidence = Resolve-AzureDataLabPlan `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'unverified'
        $evidence.payload.secretMetadata | Should -BeNullOrEmpty
        ($evidence | ConvertTo-Json -Depth 100) |
            Should -Not -Match '\[redacted\]'
    }

    It 'fails closed for a SKU without encryption-at-host support' {
        $script:DisableEncryptionAtHostCapability = $true

        $evidence = Resolve-AzureDataLabPlan `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'fail'
        $evidence.payload.skuResolution.available | Should -BeFalse
        $evidence.payload.skuResolution.encryptionAtHostSupported |
            Should -BeFalse
    }

    It 'fails closed for the wrong diagnostic destination or public vault access' {
        $script:UseWrongDiagnosticDestination = $true
        $wrongDestination = Resolve-AzureDataLabPlan `
            -Plan $script:Plan `
            -RunId $script:RunId

        $wrongDestination.status | Should -Be 'unverified'
        $wrongDestination.payload.diagnosticResolution |
            Should -BeNullOrEmpty

        $script:UseWrongDiagnosticDestination = $false
        $script:UsePublicKeyVault = $true
        $publicVault = Resolve-AzureDataLabPlan `
            -Plan $script:Plan `
            -RunId $script:RunId

        $publicVault.status | Should -Be 'unverified'
        $publicVault.payload.keyVaultResolution |
            Should -BeNullOrEmpty
    }
}

Describe 'Approved Azure command boundaries' {
    It 'does not permit direct or plaintext Key Vault secret retrieval' {
        InModuleScope AzureDataLabToolkit {
            {
                Invoke-AdltAzCommand `
                    -ModuleName Az.KeyVault `
                    -CommandName Get-AzKeyVaultSecret `
                    -Parameters @{
                        VaultName = 'kv-shared'
                        Name      = 'vm-admin-password'
                        ErrorAction = 'Stop'
                    }
            } | Should -Throw

            {
                Invoke-AdltAzCommand `
                    -ModuleName Az.KeyVault `
                    -CommandName Get-AzKeyVaultSecret `
                    -Parameters @{
                        VaultName       = 'kv-shared'
                        Name            = 'vm-admin-password'
                        IncludeVersions = $true
                        AsPlainText     = $true
                        ErrorAction     = 'Stop'
                    }
            } | Should -Throw
        }
    }

    It 'does not permit ProviderNoRbac or hidden WhatIf change types' {
        InModuleScope AzureDataLabToolkit {
            {
                Invoke-AdltAzCommand `
                    -ModuleName Az.Resources `
                    -CommandName Get-AzDeploymentWhatIfResult `
                    -Parameters @{
                        Name = 'adlt-whatif-33333333-0123456789ab'
                        Location = 'switzerlandnorth'
                        TemplateObject = @{}
                        TemplateParameterFile = '/tmp/parameters.json'
                        ResultFormat = 'ResourceIdOnly'
                        ValidationLevel = 'ProviderNoRbac'
                        SkipTemplateParameterPrompt = $true
                        ExcludeChangeType = @('Ignore')
                        ErrorAction = 'Stop'
                    }
            } | Should -Throw
        }
    }
}
