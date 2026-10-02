BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:ConfigurationPath = Join-Path `
        $script:RepositoryRoot `
        'examples/sqlvm-minimal.yaml'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:Module = Get-Module AzureDataLabToolkit
    $script:RunId = '77777777-7777-4777-8777-777777777777'
    $script:RetrievedAt = [datetimeoffset] '2026-07-28T12:00:00Z'
    $script:KeyVaultResourceId = (
        '/subscriptions/22222222-2222-4222-8222-222222222222/' +
        'resourceGroups/rg-shared/providers/Microsoft.KeyVault/vaults/kv-shared'
    )
    $script:DiagnosticDestinationResourceId = (
        '/subscriptions/22222222-2222-4222-8222-222222222222/' +
        'resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/' +
        'workspaces/law-adlt'
    )
    $script:SecretVersion = '0123456789abcdef0123456789abcdef'

    function New-TestCostFixture {
        param(
            [int64] $MaximumRunCostMinorUnits = 100000,
            [int] $MaximumRuntimeMinutes = 60,
            [int] $TimeToLiveMinutes = 60,
            [switch] $EnableBackupShare
        )

        $planParameters = @{
            Path                     = $script:ConfigurationPath
            CostEstimate             = $true
            MaximumRunCostMinorUnits = $MaximumRunCostMinorUnits
            MaximumRuntimeMinutes    = $MaximumRuntimeMinutes
            TimeToLiveMinutes        = $TimeToLiveMinutes
            SecretStoreMode          = 'reuse-key-vault'
            SecretStoreResourceId    = $script:KeyVaultResourceId
            KeyVaultDiagnosticDestinationResourceId =
                $script:DiagnosticDestinationResourceId
            VmAdministratorSecretVersion = $script:SecretVersion
        }
        if ($EnableBackupShare) {
            $planParameters.EnableBackupShare = $true
        }
        $plan = New-AzureDataLabPlan @planParameters
        $liveResolution = & $script:Module {
            param($Plan, $RunId, $RetrievedAt)

            $vm = Get-AdltPlanResource `
                -Plan $Plan `
                -StableId 'azure.compute.virtual-machine.primary'
            $image = $vm.desiredProperties.imageReference
            $imageResolution = [ordered]@{
                publisher = $image.publisher
                offer     = $image.offer
                sku       = $image.sku
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
                name = $vm.desiredProperties.hardwareProfile.vmSize
                location = $Plan.context.location
                available = $true
                encryptionAtHostSupported = $true
                trustedLaunchSupported = $true
                hyperVGenerationV2 = $true
                capabilities = @(
                    [ordered]@{
                        name = 'EncryptionAtHostSupported'
                        value = 'True'
                    }
                    [ordered]@{
                        name = 'HyperVGenerations'
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
                resourceId =
                    $Plan.configuration.security.secretStore.resourceId
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
                secretName = Get-AdltPathValue `
                    -InputObject $Plan.configuration `
                    -Path 'security.vmAdministratorCredential.secretName'
                version = Get-AdltPathValue `
                    -InputObject $Plan.configuration `
                    -Path 'security.vmAdministratorCredential.secretVersion'
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
                    imageResolution = $imageResolution
                    skuResolution = $skuResolution
                    keyVaultResolution = $vaultResolution
                    secretMetadata = $secretMetadata
                    diagnosticResolution = $diagnosticResolution
                    principalObjectId = '55555555-5555-4555-8555-555555555555'
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
                -StartedAt $RetrievedAt.AddMinutes(-1) `
                -CompletedAt $RetrievedAt.AddSeconds(-1)
        } $plan $script:RunId $script:RetrievedAt

        return [ordered]@{
            Plan           = $plan
            LiveResolution = $liveResolution
        }
    }

    function New-TestRetailPriceProvider {
        param(
            [string] $Currency = 'USD',
            [string] $MissingComponentId,
            [string] $VmRetailPrice = '0',
            [switch] $IncludeSecretField
        )

        $options = [ordered]@{
            Currency            = $Currency
            MissingComponentId  = $MissingComponentId
            VmRetailPrice       = $VmRetailPrice
            IncludeSecretField  = $IncludeSecretField.IsPresent
        }
        return {
            param($Request)

            if ($Request.componentId -ceq $options.MissingComponentId) {
                return [ordered]@{ Items = @() }
            }
            $retailPrice = if ($Request.componentKind -eq 'vm-compute') {
                $options.VmRetailPrice
            }
            else {
                '0'
            }
            $row = [ordered]@{
                currencyCode  = $options.Currency
                retailPrice   = $retailPrice
                unitOfMeasure = $Request.unitOfMeasure
                type          = 'Consumption'
                meterId       = (
                    'meter-{0}' -f
                    ($Request.componentId -replace '[^A-Za-z0-9.-]', '-')
                )
                armRegionName = $Request.selector.armRegionName
                serviceName   = $Request.selector.serviceName
                productName   = if (
                    $Request.selector.Contains('productNameContains')
                ) {
                    'Virtual Machines Dsv5 Series Windows'
                }
                else {
                    $Request.selector.serviceName
                }
                isPrimaryMeterRegion = $true
            }
            foreach ($selectorField in @('armSkuName', 'skuName', 'meterName')) {
                if (
                    $Request.selector.Contains($selectorField) -and
                    -not [string]::IsNullOrWhiteSpace(
                        [string] $Request.selector[$selectorField]
                    )
                ) {
                    $row[$selectorField] = $Request.selector[$selectorField]
                }
            }
            if ($options.IncludeSecretField) {
                $row.accessToken = 'provider-value-must-not-be-retained'
            }
            return [ordered]@{ Items = @($row) }
        }.GetNewClosure()
    }

    function Invoke-TestCostEstimate {
        param(
            [System.Collections.IDictionary] $Fixture,
            [scriptblock] $PriceProvider
        )

        return & $script:Module {
            param($Fixture, $RunId, $Provider, $RetrievedAt)
            New-AdltSqlVmCostEstimateEvidence `
                -Plan $Fixture.Plan `
                -LiveResolutionEvidence $Fixture.LiveResolution `
                -RunId $RunId `
                -PriceProvider $Provider `
                -RetrievedAt $RetrievedAt
        } $Fixture $script:RunId $PriceProvider $script:RetrievedAt
    }
}

Describe 'S3 SQL VM cost-estimate core' {
    It 'rounds decimal prices to integer minor units deterministically' {
        $fixture = New-TestCostFixture
        $provider = New-TestRetailPriceProvider -VmRetailPrice '0.005'

        $evidence = Invoke-TestCostEstimate `
            -Fixture $fixture `
            -PriceProvider $provider

        $evidence.status | Should -BeExactly 'pass'
        $evidence.payload.totalAmountMinorUnits | Should -Be 1
        $vm = $evidence.payload.components |
            Where-Object componentKind -EQ 'vm-compute'
        $vm.amountMinorUnits | Should -Be 1
        $vm.priceReference.unitPriceNanoUnits | Should -Be 5000000
        $evidence.payload.currency | Should -BeExactly 'USD'
        $evidence.payload.billingDurationMinutes | Should -Be 60
    }

    It 'derives every required SQL VM and optional backup-share component' {
        $fixture = New-TestCostFixture -EnableBackupShare
        $provider = New-TestRetailPriceProvider

        $evidence = Invoke-TestCostEstimate `
            -Fixture $fixture `
            -PriceProvider $provider
        $componentKinds = @($evidence.payload.components.componentKind)

        $componentKinds | Should -Contain 'vm-compute'
        $componentKinds | Should -Contain 'managed-disk-os'
        @($componentKinds | Where-Object { $_ -eq 'managed-disk-data' }).Count |
            Should -Be 2
        $componentKinds | Should -Contain 'azure-bastion'
        $componentKinds | Should -Contain 'public-ip-address'
        @($componentKinds | Where-Object { $_ -eq 'private-endpoint' }).Count |
            Should -Be 1
        $componentKinds | Should -Contain 'storage-account-container'
        $componentKinds | Should -Contain 'azure-files-capacity'

        ($evidence.payload.components |
            Where-Object componentKind -EQ 'vm-compute'
        ).stillBillableAfterShutdown | Should -BeFalse
        ($evidence.payload.components |
            Where-Object componentKind -EQ 'managed-disk-os'
        ).stillBillableAfterShutdown | Should -BeTrue
        $evidence.payload.stillBillableAfterShutdown |
            Should -Contain 'cost.network.bastion.primary'
        $evidence.payload.unknowns.reason |
            Should -Contain (
                'usage-dependent-storage-operations-and-egress-not-declared-in-plan'
            )
    }

    It 'returns unverified evidence when a required price is unavailable' {
        $fixture = New-TestCostFixture
        $provider = New-TestRetailPriceProvider `
            -MissingComponentId 'cost.compute.disk.os'

        $evidence = Invoke-TestCostEstimate `
            -Fixture $fixture `
            -PriceProvider $provider

        $evidence.status | Should -BeExactly 'unverified'
        $evidence.payload.pricingComplete | Should -BeFalse
        $evidence.payload.totalAmountMinorUnits | Should -BeNullOrEmpty
        $evidence.payload.unknowns.reason |
            Should -Contain 'retail-price-not-found'
    }

    It 'returns unverified evidence for a Retail Prices currency mismatch' {
        $fixture = New-TestCostFixture
        $provider = New-TestRetailPriceProvider -Currency 'EUR'

        $evidence = Invoke-TestCostEstimate `
            -Fixture $fixture `
            -PriceProvider $provider

        $evidence.status | Should -BeExactly 'unverified'
        $evidence.payload.guardrail.status | Should -BeExactly 'unverified'
        $evidence.payload.unknowns.reason |
            Should -Contain 'currency-mismatch'
    }

    It 'fails closed when the verified estimate exceeds the plan maximum' {
        $fixture = New-TestCostFixture -MaximumRunCostMinorUnits 50
        $provider = New-TestRetailPriceProvider -VmRetailPrice '1.00'

        $evidence = Invoke-TestCostEstimate `
            -Fixture $fixture `
            -PriceProvider $provider

        $evidence.status | Should -BeExactly 'fail'
        $evidence.payload.totalAmountMinorUnits | Should -Be 100
        $evidence.payload.guardrail.status | Should -BeExactly 'exceeded'
        $evidence.payload.guardrail.headroomMinorUnits | Should -Be -50
    }

    It 'rejects live-resolution evidence that is not bound to the plan' {
        $fixture = New-TestCostFixture
        $fixture.LiveResolution = & $script:Module {
            param($Evidence)
            $copy = Copy-AdltValue -InputObject $Evidence
            $copy.planHash = "sha256:$('f' * 64)"
            $copy.evidenceHash = Get-AdltArtifactHash `
                -Artifact $copy `
                -HashProperty 'evidenceHash'
            return $copy
        } $fixture.LiveResolution
        $provider = New-TestRetailPriceProvider

        {
            Invoke-TestCostEstimate `
                -Fixture $fixture `
                -PriceProvider $provider
        } | Should -Throw -ExpectedMessage '*plan hash does not match*'
    }

    It 'rejects cost evidence that predates live resolution' {
        $fixture = New-TestCostFixture
        $provider = New-TestRetailPriceProvider

        {
            & $script:Module {
                param($Fixture, $RunId, $Provider, $RetrievedAt)
                New-AdltSqlVmCostEstimateEvidence `
                    -Plan $Fixture.Plan `
                    -LiveResolutionEvidence $Fixture.LiveResolution `
                    -RunId $RunId `
                    -PriceProvider $Provider `
                    -RetrievedAt $RetrievedAt
            } `
                $fixture `
                $script:RunId `
                $provider `
                $script:RetrievedAt.AddMinutes(-2)
        } | Should -Throw -ExpectedMessage '*cannot predate*'
    }

    It 'does not retain provider tokens or secret-like response fields' {
        $fixture = New-TestCostFixture
        $provider = New-TestRetailPriceProvider -IncludeSecretField

        $evidence = Invoke-TestCostEstimate `
            -Fixture $fixture `
            -PriceProvider $provider
        $canonical = & $script:Module {
            param($Evidence)
            ConvertTo-AdltCanonicalJson -InputObject $Evidence
        } $evidence

        $evidence.status | Should -BeExactly 'pass'
        $canonical | Should -Not -Match '(?i)token|secret|credential|signature'
        {
            & $script:Module {
                param($Evidence)
                Assert-AdltEvidence -Evidence $Evidence
            } $evidence
        } | Should -Not -Throw
    }
}
