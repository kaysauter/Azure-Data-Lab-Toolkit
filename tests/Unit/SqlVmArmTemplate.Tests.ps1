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
    $script:RunId = '88888888-8888-4888-8888-888888888888'
    $script:KeyVaultResourceId = (
        '/subscriptions/22222222-2222-4222-8222-222222222222/' +
        'resourceGroups/rg-shared/providers/Microsoft.KeyVault/vaults/kv-shared'
    )
    $script:DiagnosticDestinationResourceId = (
        '/subscriptions/22222222-2222-4222-8222-222222222222/' +
        'resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/' +
        'workspaces/law-adlt'
    )
    $script:VmAdministratorSecretVersion =
        '0123456789abcdef0123456789abcdef'

    function New-TestSqlVmArmFixture {
        param(
            [hashtable] $PlanParameters = @{}
        )

        $parameters = @{
            Path                  = $script:ConfigurationPath
            SecretStoreMode       = 'reuse-key-vault'
            SecretStoreResourceId = $script:KeyVaultResourceId
            KeyVaultDiagnosticDestinationResourceId =
                $script:DiagnosticDestinationResourceId
            VmAdministratorSecretVersion =
                $script:VmAdministratorSecretVersion
        }
        foreach ($key in $PlanParameters.Keys) {
            $parameters[$key] = $PlanParameters[$key]
        }
        $plan = New-AzureDataLabPlan @parameters
        $evidence = & $script:Module {
            param($Plan, $RunId)

            $vm = Get-AdltPlanResource `
                -Plan $Plan `
                -StableId 'azure.compute.virtual-machine.primary'
            $imageResolution = [ordered]@{
                publisher = $vm.desiredProperties.imageReference.publisher
                offer     = $vm.desiredProperties.imageReference.offer
                sku       = $vm.desiredProperties.imageReference.sku
                version   = '16.0.2000'
                hyperVGeneration = 'V2'
                trustedLaunchSupported = $true
            }
            $imageResolution.imageMetadataHash =
                Get-AdltSha256Identifier -Value (
                    ConvertTo-AdltCanonicalJson `
                        -InputObject $imageResolution
                )
            $skuResolution = [ordered]@{
                name      = $vm.desiredProperties.hardwareProfile.vmSize
                location  = $Plan.context.location
                available = $true
                encryptionAtHostSupported = $true
                trustedLaunchSupported = $true
                hyperVGenerationV2 = $true
                capabilities = @(
                    [ordered]@{
                        name  = 'EncryptionAtHostSupported'
                        value = 'True'
                    }
                    [ordered]@{
                        name  = 'HyperVGenerations'
                        value = 'V1,V2'
                    }
                )
                restrictions = @()
            }
            $skuResolution.resourceSkuHash =
                Get-AdltSha256Identifier -Value (
                    ConvertTo-AdltCanonicalJson `
                        -InputObject $skuResolution
                )
            $vaultResolution = [ordered]@{
                resourceId = $Plan.configuration.security.secretStore.resourceId
                apiVersion = '2026-02-01'
                tenantId = $Plan.context.tenantId
                provisioningState = 'Succeeded'
                enableRbacAuthorization = $true
                enabledForTemplateDeployment = $true
                purgeProtectionEnabled = $true
                softDeleteRetentionDays = 90
                publicNetworkAccess = 'Disabled'
                networkDefaultAction = 'Deny'
                approvedPrivateEndpointCount = 1
            }
            $vaultResolution.resourceStateHash =
                Get-AdltSha256Identifier -Value (
                    ConvertTo-AdltCanonicalJson `
                        -InputObject $vaultResolution
                )
            $secretMetadata = [ordered]@{
                vaultResourceId =
                    $Plan.configuration.security.secretStore.resourceId
                secretName =
                    $Plan.configuration.security.vmAdministratorCredential.secretName
                version =
                    $Plan.configuration.security.vmAdministratorCredential.secretVersion
                enabled = $true
                notBeforeSatisfied = $true
                expiresAfterMinimumWindow = $true
                notBeforeAt = $null
                expiresAt = $null
            }
            $secretMetadata.metadataHash =
                Get-AdltSha256Identifier -Value (
                    ConvertTo-AdltCanonicalJson `
                        -InputObject $secretMetadata
                )
            $diagnosticResolution = [ordered]@{
                settingName = 'audit-to-law'
                destinationResourceId = Get-AdltPathValue `
                    -InputObject $Plan.configuration `
                    -Path (
                        'security.secretStore.' +
                        'diagnosticDestinationResourceId'
                    )
                enabledLogSelectors = @('category:AuditEvent')
                auditEnabled = $true
            }
            $diagnosticResolution.settingsHash =
                Get-AdltSha256Identifier -Value (
                    ConvertTo-AdltCanonicalJson `
                        -InputObject $diagnosticResolution
                )
            $now = [datetimeoffset]::UtcNow
            New-AdltEvidence `
                -RunId $RunId `
                -PlanHash $Plan.planHash `
                -IntentHash $Plan.intentHash `
                -Stage live-resolution `
                -Status pass `
                -Payload ([ordered]@{
                    context = [ordered]@{
                        cloud          = $Plan.context.cloud
                        tenantId       = $Plan.context.tenantId
                        subscriptionId = $Plan.context.subscriptionId
                    }
                    imageResolution = $imageResolution
                    skuResolution = $skuResolution
                    keyVaultResolution = $vaultResolution
                    secretMetadata = $secretMetadata
                    diagnosticResolution = $diagnosticResolution
                    providerStates = @(
                        foreach ($namespace in (
                            Get-AdltProviderNamespaceSet -Plan $Plan
                        )) {
                            [ordered]@{
                                namespace = $namespace
                                registrationState = 'Registered'
                            }
                        }
                    )
                    principalObjectId = '99999999-9999-4999-8999-999999999999'
                    principalType = 'user'
                    requiredAuthorizations = @(
                        [ordered]@{
                            action =
                                'Microsoft.KeyVault/vaults/deploy/action'
                            validationStage = 'native-provider-what-if'
                        }
                    )
                    resources = @(Get-AdltResolvedResourceIdSet -Plan $Plan)
                    resolvedPolicyFindingIds = @(
                        $Plan.approval.blockingFindingIds
                    )
                }) `
                -StartedAt $now.AddSeconds(-1) `
                -CompletedAt $now
        } $plan $script:RunId

        return [ordered]@{
            Plan     = $plan
            Evidence = $evidence
        }
    }

    function Invoke-TestSqlVmArmCompilation {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Fixture
        )

        return & $script:Module {
            param($Plan, $Evidence)
            New-AdltSqlVmArmCompilation `
                -Plan $Plan `
                -LiveResolutionEvidence $Evidence
        } $Fixture.Plan $Fixture.Evidence
    }

    function Get-TestNestedTemplate {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Compilation
        )

        $deployment = $Compilation.template.resources |
            Where-Object type -CEQ 'Microsoft.Resources/deployments' |
            Select-Object -First 1
        return $deployment.properties.template
    }

    function Get-TestCompiledResource {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Compilation,

            [Parameter(Mandatory)]
            [string] $Type
        )

        return (Get-TestNestedTemplate -Compilation $Compilation).resources |
            Where-Object type -CEQ $Type |
            Select-Object -First 1
    }
}

Describe 'Pure first-canary SQL VM ARM compilation' {
    BeforeEach {
        $script:Fixture = New-TestSqlVmArmFixture
    }

    It 'is deterministic for the same bound plan and evidence' {
        $first = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $second = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture

        $first.templateHash | Should -BeExactly $second.templateHash
        $first.executionArtifactDigest |
            Should -BeExactly $second.executionArtifactDigest
        (& $script:Module {
            param($Value)
            ConvertTo-AdltCanonicalJson -InputObject $Value
        } $first) | Should -BeExactly (& $script:Module {
            param($Value)
            ConvertTo-AdltCanonicalJson -InputObject $Value
        } $second)
    }

    It 'returns independently verifiable template and execution digests' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $hashes = & $script:Module {
            param($Compilation)

            $templateHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject $Compilation.template
            )
            $artifactDigest = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                    engine                     = $Compilation.engine
                    runId                      = $Compilation.runId
                    planHash                   = $Compilation.planHash
                    intentHash                 = $Compilation.intentHash
                    liveResolutionEvidenceHash = $Compilation.liveResolutionEvidenceHash
                    templateHash               = $Compilation.templateHash
                    parameterReference         = $Compilation.parameterReference
                    actionBindings             = $Compilation.actionBindings
                    resourceBindings           = $Compilation.resourceBindings
                    expectedGeneratedResources =
                        $Compilation.expectedGeneratedResources
                })
            )
            return [ordered]@{
                template = $templateHash
                artifact = $artifactDigest
            }
        } $compilation

        $compilation.templateHash | Should -BeExactly $hashes.template
        $compilation.executionArtifactDigest |
            Should -BeExactly $hashes.artifact
    }

    It 'compiles exactly the owned first-canary resources' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $nested = Get-TestNestedTemplate -Compilation $compilation
        $nestedTypes = @($nested.resources.type)

        $compilation.template.resources.Count | Should -Be 2
        $nested.resources.Count | Should -Be 9
        foreach ($type in @(
            'Microsoft.Network/virtualNetworks'
            'Microsoft.Network/networkSecurityGroups'
            'Microsoft.Network/virtualNetworks/subnets'
            'Microsoft.Network/networkInterfaces'
            'Microsoft.Network/publicIPAddresses'
            'Microsoft.Network/bastionHosts'
            'Microsoft.Compute/virtualMachines'
            'Microsoft.SqlVirtualMachine/sqlVirtualMachines'
        )) {
            $nestedTypes | Should -Contain $type
        }
        @(
            $nested.resources |
                Where-Object type -CEQ 'Microsoft.Network/virtualNetworks/subnets'
        ).Count | Should -Be 2
        $nestedTypes | Should -Not -Contain 'Microsoft.KeyVault/vaults'
        $nestedTypes | Should -Not -Contain 'Microsoft.KeyVault/vaults/secrets'
        $nestedTypes | Should -Not -Contain 'Microsoft.Authorization/roleAssignments'
        @(
            $compilation.actionBindings |
                Where-Object disposition -CEQ 'external-reference'
        ).Count | Should -Be 2
        $compilation.actionBindings.Count | Should -Be 12
        $compilation.resourceBindings.Count | Should -Be 12
    }

    It 'uses one secure parameter and never accepts or emits credential plaintext' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $nested = Get-TestNestedTemplate -Compilation $compilation
        $virtualMachine = Get-TestCompiledResource `
            -Compilation $compilation `
            -Type 'Microsoft.Compute/virtualMachines'

        $compilation.template.parameters.Keys |
            Should -Be @('vmAdministratorPassword')
        $compilation.template.parameters.vmAdministratorPassword.type |
            Should -BeExactly 'secureString'
        $nested.parameters.Keys | Should -Be @('vmAdministratorPassword')
        $nested.parameters.vmAdministratorPassword.type |
            Should -BeExactly 'secureString'
        $virtualMachine.properties.osProfile.adminPassword |
            Should -BeExactly "[parameters('vmAdministratorPassword')]"
        @($compilation.parameterReference.Keys) |
            Should -Be @(
                'keyVaultResourceId'
                'secretName'
                'secretVersion'
            )
        $compilation.parameterReference.keyVaultResourceId |
            Should -BeExactly $script:KeyVaultResourceId
        $compilation.parameterReference.secretName |
            Should -BeExactly 'vm-admin-password'
        $compilation.parameterReference.secretVersion |
            Should -BeExactly $script:VmAdministratorSecretVersion

        $serialized = $compilation | ConvertTo-Json -Depth 100 -Compress
        $serialized | Should -Not -Match 'NeverPutPlaintextHere'
        $serialized | Should -Not -Match 'secretValue'
        $serialized | Should -Not -Match 'secureValue'
    }

    It 'emits the exact Trusted Launch and encryption-at-host profile' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $virtualMachine = Get-TestCompiledResource `
            -Compilation $compilation `
            -Type 'Microsoft.Compute/virtualMachines'

        $virtualMachine.identity.type | Should -BeExactly 'SystemAssigned'
        $virtualMachine.properties.securityProfile.securityType |
            Should -BeExactly 'TrustedLaunch'
        $virtualMachine.properties.securityProfile.encryptionAtHost |
            Should -BeTrue
        $virtualMachine.properties.securityProfile.uefiSettings.secureBootEnabled |
            Should -BeTrue
        $virtualMachine.properties.securityProfile.uefiSettings.vTpmEnabled |
            Should -BeTrue
        $virtualMachine.properties.networkProfile.networkInterfaces.Count |
            Should -Be 1
        $virtualMachine.properties.storageProfile.osDisk.managedDisk.storageAccountType |
            Should -BeExactly 'Premium_LRS'
        $vmName = (
            $script:Fixture.Plan.resources |
                Where-Object {
                    $_.id -ceq
                        'azure.compute.virtual-machine.primary'
                } |
                Select-Object -First 1
        ).logicalName
        $virtualMachine.properties.storageProfile.osDisk.name |
            Should -BeExactly "$vmName-os"
        $virtualMachine.properties.storageProfile.dataDisks.Count | Should -Be 2
        $virtualMachine.properties.storageProfile.dataDisks.name |
            Should -Be @("$vmName-data-0", "$vmName-data-1")
    }

    It 'contracts every provider-generated teardown resource' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $generated = @($compilation.expectedGeneratedResources)

        $generated.Count | Should -Be 5
        $generated.stableId | Should -Be @(
            'engine.compute.managed-disk.os'
            'engine.compute.managed-disk.data-0'
            'engine.compute.managed-disk.data-1'
            'engine.resources.nested-deployment'
            'engine.sql-iaas-agent.extension'
        )
        @(
            $generated |
                Where-Object relationship -CEQ 'vm-managed-disk'
        ).required | Should -Not -Contain $false
        (
            $generated |
                Where-Object {
                    $_.stableId -ceq
                        'engine.sql-iaas-agent.extension'
                }
        ).expectedProperties.publisher |
            Should -BeExactly 'Microsoft.SqlServer.Management'
        (
            $generated |
                Where-Object {
                    $_.stableId -ceq
                        'engine.resources.nested-deployment'
                }
        ).expectedProperties.nestedTemplateHash |
            Should -Match '^sha256:[a-f0-9]{64}$'
    }

    It 'uses only the immutable image version from bound live resolution' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $image = (
            Get-TestCompiledResource `
                -Compilation $compilation `
                -Type 'Microsoft.Compute/virtualMachines'
        ).properties.storageProfile.imageReference

        $image.publisher | Should -BeExactly 'MicrosoftSQLServer'
        $image.offer | Should -BeExactly 'sql2022-ws2022'
        $image.sku | Should -BeExactly 'sqldev-gen2'
        $image.version | Should -BeExactly '16.0.2000'
        $image.version | Should -Not -BeIn @('latest', 'unresolved')
    }

    It 'tags every taggable owned resource with exact reconciliation data' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $nested = Get-TestNestedTemplate -Compilation $compilation
        $taggableStableIds = @(
            'azure.resource-group.primary'
            'azure.network.virtual-network.primary'
            'azure.network.security-group.workload'
            'azure.network.interface.primary'
            'azure.network.public-ip.bastion'
            'azure.network.bastion.primary'
            'azure.compute.virtual-machine.primary'
            'azure.sql.virtual-machine.primary'
        )

        foreach ($stableId in $taggableStableIds) {
            $planResource = $script:Fixture.Plan.resources |
                Where-Object id -CEQ $stableId |
                Select-Object -First 1
            $compiledResource = if (
                $stableId -eq 'azure.resource-group.primary'
            ) {
                $compilation.template.resources |
                    Where-Object type -CEQ 'Microsoft.Resources/resourceGroups' |
                    Select-Object -First 1
            }
            else {
                $nested.resources |
                    Where-Object {
                        $_ -is [System.Collections.IDictionary] -and
                        $_.Contains('tags') -and
                        $_.tags['adlt-stable-id'] -ceq $stableId
                    } |
                    Select-Object -First 1
            }
            $expectedDesiredHash = & $script:Module {
                param($Resource)
                Get-AdltDesiredResourceHash -Resource $Resource
            } $planResource

            $compiledResource | Should -Not -BeNullOrEmpty
            $compiledResource.tags['adlt-toolkit'] |
                Should -BeExactly 'AzureDataLabToolkit'
            $compiledResource.tags['adlt-run-id'] |
                Should -BeExactly $script:RunId
            $compiledResource.tags['adlt-plan-hash'] |
                Should -BeExactly $script:Fixture.Plan.planHash
            $compiledResource.tags['adlt-intent-hash'] |
                Should -BeExactly $script:Fixture.Plan.intentHash
            $compiledResource.tags['adlt-stable-id'] |
                Should -BeExactly $stableId
            $compiledResource.tags['adlt-ownership'] |
                Should -BeExactly 'owned'
            $compiledResource.tags['adlt-desired-hash'] |
                Should -BeExactly $expectedDesiredHash
        }
    }

    It 'uses a subscription template and an incremental nested RG deployment' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $deployment = $compilation.template.resources |
            Where-Object type -CEQ 'Microsoft.Resources/deployments' |
            Select-Object -First 1

        $compilation.template.'$schema' |
            Should -Match 'subscriptionDeploymentTemplate'
        $deployment.resourceGroup |
            Should -BeExactly $script:Fixture.Plan.configuration.azure.resourceGroup.name
        $deployment.properties.mode | Should -BeExactly 'Incremental'
        $deployment.properties.expressionEvaluationOptions.scope |
            Should -BeExactly 'inner'
        $deployment.name | Should -BeExactly (
            'adlt-sqlvm-{0}' -f
            $script:Fixture.Plan.planHash.Substring(7, 12)
        )
    }

    It 'preserves topological action order and direct ARM dependencies' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $positions = @{}
        for ($index = 0; $index -lt $compilation.actionBindings.Count; $index++) {
            $positions[$compilation.actionBindings[$index].actionId] = $index
        }
        foreach ($binding in $compilation.actionBindings) {
            foreach ($dependency in @($binding.dependsOn)) {
                $positions[$dependency] | Should -BeLessThan $positions[$binding.actionId]
            }
        }

        $resolved = @{}
        foreach ($resource in $script:Fixture.Evidence.payload.resources) {
            $resolved[$resource.stableId] = $resource.resourceId
        }
        $virtualMachine = Get-TestCompiledResource `
            -Compilation $compilation `
            -Type 'Microsoft.Compute/virtualMachines'
        $virtualMachine.dependsOn | Should -Be @(
            $resolved['azure.network.interface.primary']
            $resolved['azure.network.security-group.workload']
        )
        $virtualMachine.dependsOn |
            Should -Not -Contain $resolved['azure.security.key-vault-secret.vm-admin']
    }

    It 'registers the SQL VM with least privilege and planned storage settings' {
        $compilation = Invoke-TestSqlVmArmCompilation -Fixture $script:Fixture
        $sqlVirtualMachine = Get-TestCompiledResource `
            -Compilation $compilation `
            -Type 'Microsoft.SqlVirtualMachine/sqlVirtualMachines'

        $sqlVirtualMachine.properties.leastPrivilegeMode |
            Should -BeExactly 'Enabled'
        $sqlVirtualMachine.properties.sqlImageOffer |
            Should -BeExactly 'SQL2022-WS2022'
        $sqlVirtualMachine.properties.sqlImageSku |
            Should -BeExactly 'Developer'
        $sqlVirtualMachine.properties.storageConfigurationSettings.diskConfigurationType |
            Should -BeExactly 'NEW'
        $sqlVirtualMachine.properties.storageConfigurationSettings.sqlDataSettings.luns |
            Should -Be @(0)
        $sqlVirtualMachine.properties.storageConfigurationSettings.sqlLogSettings.luns |
            Should -Be @(1)
    }

    It 'rejects unsupported first-canary profiles' {
        $unsupportedSecurity = New-TestSqlVmArmFixture `
            -PlanParameters @{ VmSecurityType = 'standard' }
        {
            Invoke-TestSqlVmArmCompilation -Fixture $unsupportedSecurity
        } | Should -Throw -ExpectedMessage '*requires*securityType*trustedLaunch*'
    }

    It 'rejects a contract-valid plan with a drifted secure network profile' {
        $candidate = & $script:Module {
            param($Fixture)

            $plan = Copy-AdltValue -InputObject $Fixture.Plan
            $networkSecurityGroup = $plan.resources |
                Where-Object id -CEQ 'azure.network.security-group.workload' |
                Select-Object -First 1
            $networkSecurityGroup.desiredProperties.inboundRules[0].destinationPort = 3390
            $plan = Set-AdltPlanIntentBinding -Plan $plan

            $evidence = Copy-AdltValue -InputObject $Fixture.Evidence
            $evidence.planHash = $plan.planHash
            $evidence.intentHash = $plan.intentHash
            $evidence.evidenceHash = Get-AdltArtifactHash `
                -Artifact $evidence `
                -HashProperty 'evidenceHash'
            return [ordered]@{
                Plan     = $plan
                Evidence = $evidence
            }
        } $script:Fixture

        {
            Invoke-TestSqlVmArmCompilation -Fixture $candidate
        } | Should -Throw -ExpectedMessage '*does not support*network.security-group*'
    }

    It 'rejects any unsupported resource rather than omitting it' {
        $fixture = New-TestSqlVmArmFixture `
            -PlanParameters @{ EnableBackupShare = $true }

        {
            Invoke-TestSqlVmArmCompilation -Fixture $fixture
        } | Should -Throw -ExpectedMessage '*unsupported or missing resources*'
    }

    It 'rejects tampered resource bindings even when evidence is rehashed' {
        $candidate = & $script:Module {
            param($Evidence)
            $copy = Copy-AdltValue -InputObject $Evidence
            $copy.payload.resources[0].resourceId = (
                $copy.payload.resources[0].resourceId + '-tampered'
            )
            $copy.evidenceHash = Get-AdltArtifactHash `
                -Artifact $copy `
                -HashProperty 'evidenceHash'
            return $copy
        } $script:Fixture.Evidence

        {
            & $script:Module {
                param($Plan, $Evidence)
                New-AdltSqlVmArmCompilation `
                    -Plan $Plan `
                    -LiveResolutionEvidence $Evidence
            } $script:Fixture.Plan $candidate
        } | Should -Throw -ExpectedMessage '*resource*does not match*'
    }

    It 'rejects live evidence bound to another valid plan' {
        $other = New-TestSqlVmArmFixture `
            -PlanParameters @{ Name = 'other-sqlvm-lab' }

        {
            & $script:Module {
                param($Plan, $Evidence)
                New-AdltSqlVmArmCompilation `
                    -Plan $Plan `
                    -LiveResolutionEvidence $Evidence
            } $script:Fixture.Plan $other.Evidence
        } | Should -Throw -ExpectedMessage '*not bound*'
    }

    It 'contains no compiler-side clock, randomness, Azure call, or file write' {
        $sourcePath = Join-Path `
            $script:RepositoryRoot `
            'src/AzureDataLabToolkit/Private/82-SqlVmArmTemplate.ps1'
        $source = Get-Content -LiteralPath $sourcePath -Raw

        $source | Should -Not -Match 'Invoke-AdltAzCommand'
        $source | Should -Not -Match 'Invoke-RestMethod'
        $source | Should -Not -Match '\[guid\]::NewGuid'
        $source | Should -Not -Match 'UtcNow'
        $source | Should -Not -Match 'Get-Random'
        $source | Should -Not -Match 'Set-Content|Add-Content|Out-File|WriteAll'
        $source | Should -Not -Match 'New-Az|Set-Az|Remove-Az'
    }
}
