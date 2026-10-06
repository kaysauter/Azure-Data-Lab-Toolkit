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
    $script:KeyVaultResourceId = (
        '/subscriptions/22222222-2222-4222-8222-222222222222/' +
        'resourceGroups/rg-adlt-control/providers/Microsoft.KeyVault/' +
        'vaults/adlt-control-vault'
    )
    $script:DiagnosticDestinationResourceId = (
        '/subscriptions/22222222-2222-4222-8222-222222222222/' +
        'resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/' +
        'workspaces/law-adlt'
    )
    $script:VmAdministratorSecretVersion =
        '0123456789abcdef0123456789abcdef'

    function New-AuthorizationTestResourceNotFoundError {
        return [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new(
                'Synthetic structured Azure resource absence.'
            ),
            'ResourceNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $null
        )
    }

    function New-TestAuthorizationFixture {
        param(
            [Parameter(Mandatory)]
            [string] $StateRoot,

            [string] $VmRetailPrice = '0'
        )

        return & $script:Module {
            param(
                $ConfigurationPath,
                $StateRoot,
                $KeyVaultResourceId,
                $DiagnosticDestinationResourceId,
                $VmAdministratorSecretVersion,
                $VmRetailPrice
            )

            $plan = New-AzureDataLabPlan `
                -Path $ConfigurationPath `
                -Purpose canary `
                -SecretStoreMode reuse-key-vault `
                -SecretStoreResourceId $KeyVaultResourceId `
                -KeyVaultDiagnosticDestinationResourceId `
                    $DiagnosticDestinationResourceId `
                -VmAdministratorSecretVersion `
                    $VmAdministratorSecretVersion `
                -CostEstimate `
                -MaximumRunCostMinorUnits 50000 `
                -MaximumRuntimeMinutes 120 `
                -TimeToLiveMinutes 180 `
                -PreauthorizeTeardown `
                -DeleteBackupShareOnTeardown
            $baseTime = [datetimeoffset]::UtcNow.AddMinutes(-1)
            $run = New-AdltLocalRunStore `
                -Plan $plan `
                -StateRoot $StateRoot `
                -CreatedAt $baseTime
            $context = Get-AdltVerifiedLocalRunContext -RunPath $run.StatePath
            $principalId = '55555555-5555-4555-8555-555555555555'

            $vm = Get-AdltPlanResource `
                -Plan $plan `
                -StableId 'azure.compute.virtual-machine.primary'
            $providerStates = @(
                foreach ($namespace in Get-AdltProviderNamespaceSet -Plan $plan) {
                    [ordered]@{
                        namespace         = $namespace
                        registrationState = 'Registered'
                    }
                }
            )
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
                location  = $plan.context.location
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
                resourceId =
                    $plan.configuration.security.secretStore.resourceId
                apiVersion = '2026-02-01'
                tenantId = $plan.context.tenantId
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
                    $plan.configuration.security.secretStore.resourceId
                secretName = Get-AdltPathValue `
                    -InputObject $plan.configuration `
                    -Path 'security.vmAdministratorCredential.secretName'
                version = Get-AdltPathValue `
                    -InputObject $plan.configuration `
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
                    -InputObject $plan.configuration `
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
            $liveResolution = New-AdltEvidence `
                -RunId $run.RunId `
                -PlanHash $plan.planHash `
                -IntentHash $plan.intentHash `
                -Stage live-resolution `
                -Status pass `
                -Sequence 1 `
                -PreviousEventHash $context.Evidence[-1].evidenceHash `
                -Payload ([ordered]@{
                    context = [ordered]@{
                        cloud            = $plan.context.cloud
                        tenantId         = $plan.context.tenantId
                        subscriptionId   = $plan.context.subscriptionId
                        subscriptionName = 'Canary'
                        accountType      = 'User'
                        tokenExpiresAt   = ConvertTo-AdltUtcTimestamp `
                            -Value $baseTime.AddHours(1)
                        contextScope     = 'process'
                    }
                    providerStates    = $providerStates
                    imageResolution   = $imageResolution
                    skuResolution     = $skuResolution
                    keyVaultResolution = $vaultResolution
                    secretMetadata     = $secretMetadata
                    diagnosticResolution = $diagnosticResolution
                    principalObjectId = $principalId
                    principalType     = 'user'
                    requiredAuthorizations = @(
                        [ordered]@{
                            action =
                                'Microsoft.KeyVault/vaults/deploy/action'
                            validationStage = 'native-provider-what-if'
                        }
                    )
                    resources         = @(Get-AdltResolvedResourceIdSet -Plan $plan)
                    resolvedPolicyFindingIds = @(
                        $plan.approval.blockingFindingIds
                    )
                }) `
                -StartedAt $baseTime `
                -CompletedAt $baseTime.AddSeconds(1)
            $liveAttachment = Add-AdltLocalRunEvidence `
                -RunPath $run.StatePath `
                -Evidence $liveResolution `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $baseTime.AddSeconds(1)

            $compilation = New-AdltSqlVmArmCompilation `
                -Plan $plan `
                -LiveResolutionEvidence $liveResolution
            $whatIfResults = @(
                foreach ($resourceObject in @($plan.resources | Sort-Object id)) {
                    $resource = ConvertTo-AdltDictionary -InputObject $resourceObject
                    $resolved = $liveResolution.payload.resources |
                        Where-Object stableId -CEQ $resource.id |
                        Select-Object -First 1
                    $retained = $resource.ownership.expectedClassification -in @(
                        'reused',
                        'external'
                    )
                    [ordered]@{
                        stableId         = $resource.id
                        resourceId       = $resolved.resourceId
                        resourceType     = $resource.type
                        plannedOwnership = $resource.ownership.expectedClassification
                        observedState    = if ($retained) { 'present' } else { 'absent' }
                        classification   = if ($retained) { 'reuse' } else { 'create' }
                        desiredHash      = Get-AdltDesiredResourceHash -Resource $resource
                    }
                }
            )
            $expectedNativeChanges =
                Get-AdltSqlVmNativeWhatIfExpectedChange `
                    -Compilation $compilation `
                    -CustomResults $whatIfResults
            $nativeChanges = @(
                foreach ($resourceId in @(
                    $expectedNativeChanges.Keys | Sort-Object
                )) {
                    [ordered]@{
                        resourceId = $resourceId
                        changeType = if (
                            $expectedNativeChanges[$resourceId].stableId -ceq
                                'engine.subscription.nested-deployment'
                        ) {
                            'Deploy'
                        }
                        else {
                            'Create'
                        }
                    }
                }
            )
            $nativeChangesHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject $nativeChanges
            )
            $parameterReferenceHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson `
                    -InputObject $compilation.parameterReference
            )
            $parameterFileHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject (
                    New-AdltSqlVmArmParameterDocument `
                        -Compilation $compilation
                )
            )
            $scope = '/subscriptions/{0}' -f
                [string] $plan.context.subscriptionId
            $deploymentName = 'adlt-whatif-{0}-{1}' -f
                $run.RunId.Replace(
                    '-',
                    ''
                ).Substring(0, 8).ToLowerInvariant(),
                ([string] $plan.planHash).Substring(7, 12)
            $invocationHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                    scope = $scope
                    deploymentName = $deploymentName
                    location = [string] $plan.context.location
                    validationLevel = 'Provider'
                    resultFormat = 'ResourceIdOnly'
                    templateHash = [string] $compilation.templateHash
                    executionArtifactDigest =
                        [string] $compilation.executionArtifactDigest
                    parameterReferenceHash = $parameterReferenceHash
                    parameterFileHash = $parameterFileHash
                })
            )
            $nativeResultHash = Get-AdltNativeWhatIfResultHash `
                -Status Succeeded `
                -Changes $nativeChanges `
                -Diagnostics @() `
                -PotentialChangeCount 0 `
                -ChangesHash $nativeChangesHash `
                -FailureKind $null
            $whatIf = New-AdltEvidence `
                -RunId $run.RunId `
                -PlanHash $plan.planHash `
                -IntentHash $plan.intentHash `
                -Stage what-if `
                -Status pass `
                -Sequence 2 `
                -PreviousEventHash $liveResolution.evidenceHash `
                -Payload ([ordered]@{
                    liveResolutionEvidenceHash = $liveResolution.evidenceHash
                    results                    = $whatIfResults
                    mutationCount              = 0
                    executionArtifactDigest    = $compilation.executionArtifactDigest
                    templateHash               = $compilation.templateHash
                    scope                      = $scope
                    deploymentName             = $deploymentName
                    validationLevel            = 'Provider'
                    resultFormat               = 'ResourceIdOnly'
                    parameterReferenceHash     = $parameterReferenceHash
                    parameterFileHash          = $parameterFileHash
                    invocationHash             = $invocationHash
                    nativeChanges              = $nativeChanges
                    nativeDiagnostics          = @()
                    nativePotentialChangeCount = 0
                    nativeChangesHash          = $nativeChangesHash
                    nativeWhatIfResultHash      = $nativeResultHash
                    nativeStatus                = 'Succeeded'
                    nativeFailureKind           = $null
                }) `
                -StartedAt $baseTime.AddSeconds(2) `
                -CompletedAt $baseTime.AddSeconds(3)
            $whatIfAttachment = Add-AdltLocalRunEvidence `
                -RunPath $run.StatePath `
                -Evidence $whatIf `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $baseTime.AddSeconds(3)

            $priceOptions = [ordered]@{
                VmRetailPrice = $VmRetailPrice
            }
            $priceProvider = {
                param($Request)

                $price = if ($Request.componentKind -eq 'vm-compute') {
                    $priceOptions.VmRetailPrice
                }
                else {
                    '0'
                }
                $row = [ordered]@{
                    currencyCode        = 'USD'
                    retailPrice         = $price
                    unitOfMeasure       = $Request.unitOfMeasure
                    type                = 'Consumption'
                    meterId             = "meter-$($Request.componentId)"
                    armRegionName       = $Request.selector.armRegionName
                    serviceName         = $Request.selector.serviceName
                    productName         = if (
                        $Request.selector.Contains('productNameContains')
                    ) {
                        'Virtual Machines Dsv5 Series Windows'
                    }
                    else {
                        $Request.selector.serviceName
                    }
                    isPrimaryMeterRegion = $true
                }
                foreach ($field in @('armSkuName', 'skuName', 'meterName')) {
                    if ($Request.selector.Contains($field)) {
                        $row[$field] = $Request.selector[$field]
                    }
                }
                return [ordered]@{ Items = @($row) }
            }.GetNewClosure()
            $cost = New-AdltSqlVmCostEstimateEvidence `
                -Plan $plan `
                -LiveResolutionEvidence $liveResolution `
                -RunId $run.RunId `
                -PriceProvider $priceProvider `
                -Sequence 3 `
                -PreviousEventHash $whatIf.evidenceHash `
                -RetrievedAt $baseTime.AddSeconds(4)
            $costAttachment = Add-AdltLocalRunEvidence `
                -RunPath $run.StatePath `
                -Evidence $cost `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $baseTime.AddSeconds(4)

            $teardownPreview = New-AdltPreDeploymentTeardownPreviewEvidence `
                -Plan $plan `
                -LiveResolutionEvidence $liveResolution `
                -WhatIfEvidence $whatIf `
                -RunId $run.RunId `
                -Sequence 4 `
                -PreviousEventHash $cost.evidenceHash `
                -StartedAt $baseTime.AddSeconds(5) `
                -CompletedAt $baseTime.AddSeconds(6)
            $previewAttachment = Add-AdltLocalRunEvidence `
                -RunPath $run.StatePath `
                -Evidence $teardownPreview `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $baseTime.AddSeconds(6)
            $transition = Add-AdltLocalRunStatusTransition `
                -RunPath $run.StatePath `
                -Status authorizing `
                -ActorType interactive-user `
                -ActorId $principalId `
                -OccurredAt $baseTime.AddSeconds(7)
            $state = $transition.State
            $teardownPlan = New-AdltTeardownPlan `
                -Plan $plan `
                -State $state `
                -ObservedStateEvidence $teardownPreview `
                -LiveResolutionEvidence $liveResolution `
                -WhatIfEvidence $whatIf `
                -CreatedAt $baseTime.AddSeconds(8) `
                -ExpiresAt $baseTime.AddMinutes(90)

            return [ordered]@{
                Now             = $baseTime.AddSeconds(10)
                Plan            = $plan
                RunPath         = $run.StatePath
                State           = $state
                LiveResolution  = $liveResolution
                WhatIf          = $whatIf
                Cost            = $cost
                TeardownPreview = $teardownPreview
                TeardownPlan    = $teardownPlan
                Compilation     = $compilation
                PrincipalId     = $principalId
                Approval        = [ordered]@{
                    approver = [ordered]@{
                        type = 'user'
                        id   = $principalId
                    }
                    mechanism = 'interactive'
                    approvedAt = ConvertTo-AdltUtcTimestamp `
                        -Value $baseTime.AddSeconds(9)
                    recordId = 'interactive:approval-0001'
                }
            }
        } `
            $script:ConfigurationPath `
            $StateRoot `
            $script:KeyVaultResourceId `
            $script:DiagnosticDestinationResourceId `
            $script:VmAdministratorSecretVersion `
            $VmRetailPrice
    }

    function New-TestExecutionAuthorization {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Fixture,

            [int64] $MaximumCostMinorUnits = 40000,

            [System.Collections.IDictionary] $Approval = $Fixture.Approval
        )

        return & $script:Module {
            param($Fixture, $MaximumCostMinorUnits, $Approval)

            New-AdltExecutionAuthorization `
                -Operation deploy `
                -Plan $Fixture.Plan `
                -State $Fixture.State `
                -LiveResolutionEvidence $Fixture.LiveResolution `
                -WhatIfEvidence $Fixture.WhatIf `
                -CostEvidence $Fixture.Cost `
                -TeardownPlan $Fixture.TeardownPlan `
                -ObservedStateEvidence $Fixture.TeardownPreview `
                -Compilation $Fixture.Compilation `
                -Approval $Approval `
                -MaximumCostMinorUnits $MaximumCostMinorUnits `
                -MaximumCostCurrency USD `
                -MaximumRuntimeMinutes 120 `
                -AcknowledgementIds @(
                    $Fixture.Plan.approval.requiredAcknowledgementIds
                ) `
                -CreatedAt $Fixture.Now `
                -ExpiresAt $Fixture.Now.AddMinutes(60)
        } $Fixture $MaximumCostMinorUnits $Approval
    }

    function Assert-TestExecutionAuthorization {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Fixture,

            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Authorization
        )

        & $script:Module {
            param($Fixture, $Authorization)

            Assert-AdltExecutionAuthorization `
                -Authorization $Authorization `
                -Plan $Fixture.Plan `
                -State $Fixture.State `
                -LiveResolutionEvidence $Fixture.LiveResolution `
                -WhatIfEvidence $Fixture.WhatIf `
                -CostEvidence $Fixture.Cost `
                -TeardownPlan $Fixture.TeardownPlan `
                -ObservedStateEvidence $Fixture.TeardownPreview `
                -Compilation $Fixture.Compilation `
                -AsOf $Fixture.Now
        } $Fixture $Authorization
    }

    function New-TestDeploymentExecutionRecord {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Fixture
        )

        $authorization = New-TestExecutionAuthorization `
            -Fixture $Fixture
        return & $script:Module {
            param($Fixture, $Authorization)

            $finalGate = [ordered]@{
                liveFactsHash = Get-AdltLiveFactsGateHash `
                    -Evidence $Fixture.LiveResolution
                whatIfHash = Get-AdltWhatIfGateHash `
                    -Evidence $Fixture.WhatIf
                completedAt = ConvertTo-AdltUtcTimestamp `
                    -Value $Fixture.Now
            }
            $finalGate.finalGateHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                    liveFactsHash = $finalGate.liveFactsHash
                    whatIfHash = $finalGate.whatIfHash
                })
            )
            New-AdltDeploymentExecutionRecord `
                -Plan $Fixture.Plan `
                -State $Fixture.State `
                -LiveResolutionEvidence $Fixture.LiveResolution `
                -WhatIfEvidence $Fixture.WhatIf `
                -CostEvidence $Fixture.Cost `
                -TeardownPreviewEvidence $Fixture.TeardownPreview `
                -Compilation $Fixture.Compilation `
                -Authorization $Authorization `
                -TeardownPlan $Fixture.TeardownPlan `
                -FinalGate $finalGate `
                -CreatedAt $Fixture.Now
        } $Fixture $authorization
    }

    function Complete-TestDeploymentExecution {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Fixture
        )

        $record = New-TestDeploymentExecutionRecord -Fixture $Fixture
        return & $script:Module {
            param($Fixture, $Record)

            [void] (Add-AdltLocalExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $Record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $Fixture.Now.AddSeconds(1))
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-started `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    executionRecordHash = $Record.executionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(2))
            $result = [ordered]@{
                deploymentName = $Record.deployment.name
                deploymentId = (
                    '{0}/providers/Microsoft.Resources/deployments/{1}' -f
                        $Record.deployment.scope,
                        $Record.deployment.name
                )
                correlationId =
                    '77777777-7777-4777-8777-777777777777'
                provisioningState = 'Succeeded'
                terminal = $true
                outcome = 'succeeded'
            }
            [void] (Complete-AdltDeploymentOperation `
                -RunPath $Fixture.RunPath `
                -Plan $Fixture.Plan `
                -ExecutionRecord $Record `
                -DeploymentResult $result `
                -StartedAt $Fixture.Now.AddSeconds(2) `
                -CompletedAt $Fixture.Now.AddSeconds(3))
            [ordered]@{
                Record = $Record
                Context = Get-AdltVerifiedLocalRunContext `
                    -RunPath $Fixture.RunPath
            }
        } $Fixture $record
    }

    function New-TestTeardownAzureInventory {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Fixture,

            [Parameter(Mandatory)]
            [pscustomobject] $Context,

            [switch] $IncludeUnknown
        )

        return & $script:Module {
            param($Fixture, $Context, $IncludeUnknown)

            $compilation = New-AdltSqlVmArmCompilation `
                -Plan $Fixture.Plan `
                -LiveResolutionEvidence $Fixture.LiveResolution
            $expected = @(
                Get-AdltSqlVmTeardownExpectedResourceSet `
                    -Plan $Fixture.Plan `
                    -Compilation $compilation
            )
            $planResources = Get-AdltSqlVmArmResourceMap `
                -Plan $Fixture.Plan
            $compiledResources =
                Get-AdltSqlVmCompiledNestedResourceMap `
                    -Plan $Fixture.Plan `
                    -Compilation $compilation
            $virtualMachineId = [string] (
                $expected |
                    Where-Object {
                        $_.stableId -ceq
                            'azure.compute.virtual-machine.primary'
                    } |
                    Select-Object -First 1
            ).resourceId
            $diskEntries = @(
                $expected |
                    Where-Object relationship -CEQ 'vm-managed-disk'
            )
            $osDisk = $diskEntries |
                Where-Object {
                    $_.expectedProperties.purpose -ceq 'os'
                } |
                Select-Object -First 1
            $resources = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in $expected) {
                $tags = @{}
                $properties = [ordered]@{
                    ProvisioningState = 'Succeeded'
                }
                $sku = $null
                $identity = $null
                $location = $null
                $managedBy = $null
                if ($entry.relationship -ceq 'planned-taggable') {
                    $tags = Get-AdltSqlVmArmOwnershipTag `
                        -Plan $Fixture.Plan `
                        -Resource $planResources[$entry.stableId] `
                        -RunId $Context.State.runId
                }
                if (
                    $entry.relationship -in @(
                        'planned-taggable'
                        'planned-descendant'
                    )
                ) {
                    $compiled = $compiledResources[$entry.stableId]
                    $properties = Copy-AdltValue `
                        -InputObject $compiled.properties
                    $properties.ProvisioningState = 'Succeeded'
                    if ($compiled.Contains('sku')) {
                        $sku = [pscustomobject] (
                            Copy-AdltValue -InputObject $compiled.sku
                        )
                    }
                    if ($compiled.Contains('identity')) {
                        $identity = [pscustomobject] (
                            Copy-AdltValue -InputObject $compiled.identity
                        )
                    }
                    if ($compiled.Contains('location')) {
                        $location = [string] $compiled.location
                    }
                }
                if (
                    $entry.stableId -ceq
                        'azure.compute.virtual-machine.primary'
                ) {
                    $storageProfile = ConvertTo-AdltDictionary `
                        -InputObject $properties.StorageProfile
                    $osDiskState = ConvertTo-AdltDictionary `
                        -InputObject $storageProfile.OsDisk
                    $osDiskState.ManagedDisk =
                        ConvertTo-AdltDictionary `
                            -InputObject $osDiskState.ManagedDisk
                    $osDiskState.ManagedDisk.Id =
                        [string] $osDisk.resourceId
                    $dataDiskStates =
                        [System.Collections.Generic.List[object]]::new()
                    foreach ($dataDiskStateObject in @(
                        $storageProfile.DataDisks
                    )) {
                        $dataDiskState = ConvertTo-AdltDictionary `
                            -InputObject $dataDiskStateObject
                        $diskEntry = $diskEntries |
                            Where-Object {
                                $_.expectedProperties.purpose -cne 'os' -and
                                [int] $_.expectedProperties.lun -eq
                                    [int] $dataDiskState.Lun
                            } |
                            Select-Object -First 1
                        $dataDiskState.ManagedDisk =
                            ConvertTo-AdltDictionary `
                                -InputObject $dataDiskState.ManagedDisk
                        $dataDiskState.ManagedDisk.Id =
                            [string] $diskEntry.resourceId
                        $dataDiskStates.Add(
                            [pscustomobject] $dataDiskState
                        )
                    }
                    $storageProfile.OsDisk =
                        [pscustomobject] $osDiskState
                    $storageProfile.DataDisks =
                        @($dataDiskStates.ToArray())
                    $properties.StorageProfile =
                        [pscustomobject] $storageProfile
                }
                elseif ($entry.relationship -ceq 'vm-managed-disk') {
                    $properties.DiskSizeGB =
                        [int] $entry.expectedProperties.sizeGiB
                    $sku = [pscustomobject]@{
                        Name = [string] $entry.
                            expectedProperties.storageType
                    }
                    $managedBy = $virtualMachineId
                }
                elseif (
                    $entry.relationship -ceq
                        'sql-iaas-agent-extension'
                ) {
                    $properties.Publisher =
                        $entry.expectedProperties.publisher
                    $properties.Type = $entry.expectedProperties.type
                }
                $resources.Add([pscustomobject]@{
                    ResourceId = [string] $entry.resourceId
                    ResourceType = [string] $entry.resourceType
                    Tags = $tags
                    Properties = [pscustomobject] $properties
                    Sku = $sku
                    Identity = $identity
                    Location = $location
                    ManagedBy = $managedBy
                })
            }
            if ($IncludeUnknown) {
                $resourceGroupId = Resolve-AdltPlanResourceId `
                    -Plan $Fixture.Plan `
                    -StableId 'azure.resource-group.primary'
                $resources.Add([pscustomobject]@{
                    ResourceId = (
                        '{0}/providers/Microsoft.Storage/storageAccounts/foreign' -f
                            $resourceGroupId
                    )
                    ResourceType = 'Microsoft.Storage/storageAccounts'
                    Tags = @{}
                    Properties = [pscustomobject]@{
                        ProvisioningState = 'Succeeded'
                    }
                    Sku = $null
                    ManagedBy = $null
                })
            }
            $resourceGroup = Get-AdltPlanResource `
                -Plan $Fixture.Plan `
                -StableId 'azure.resource-group.primary'
            [ordered]@{
                Compilation = $compilation
                ResourceGroup = [pscustomobject]@{
                    ResourceId = Resolve-AdltPlanResourceId `
                        -Plan $Fixture.Plan `
                        -StableId 'azure.resource-group.primary'
                    Tags = Get-AdltSqlVmArmOwnershipTag `
                        -Plan $Fixture.Plan `
                        -Resource $resourceGroup `
                        -RunId $Context.State.runId
                }
                Resources = $resources.ToArray()
            }
        } $Fixture $Context ([bool] $IncludeUnknown)
    }
}

Describe 'Bound execution authorization and preauthorized teardown' {
    BeforeEach {
        Mock Get-AdltRuntimeIdentity -ModuleName AzureDataLabToolkit {
            [ordered]@{
                module = [ordered]@{
                    name    = 'AzureDataLabToolkit'
                    version = '0.1.0-alpha1'
                    digest  = "sha256:$('a' * 64)"
                }
                commit = ('d' * 40)
                powershell = [ordered]@{
                    version = '7.6.0'
                    edition = 'Core'
                }
                dependencies = @(
                    [ordered]@{
                        name             = 'powershell-yaml'
                        version          = '0.4.12'
                        guid             =
                            '6a75a662-7f53-425a-9777-ee61284407da'
                        author           = (
                            'Gabriel Adrian Samfira ' +
                            'Alessandro Pilotti'
                        )
                        source           = 'PSGallery'
                        packageDigest    = "sha256:$('1' * 64)"
                        contentDigest    = "sha256:$('2' * 64)"
                        manifestPathHash = "sha256:$('3' * 64)"
                    }
                )
            }
        }
        $script:Fixture = New-TestAuthorizationFixture `
            -StateRoot (Join-Path $TestDrive 'runs')
        Mock Assert-AdltAzureMutationPrincipal `
            -ModuleName AzureDataLabToolkit {
            $script:Fixture.PrincipalId
        }
    }

    It 'authorizes the complete compiler graph from a protected local run' {
        $authorization = New-TestExecutionAuthorization `
            -Fixture $script:Fixture
        $expectedActions = @(
            $script:Fixture.Plan.actions |
                Where-Object mutation |
                ForEach-Object id
        )
        $expectedResources = @(
            $script:Fixture.Compilation.actionBindings |
                Where-Object disposition -CEQ deploy |
                ForEach-Object resourceId |
                Sort-Object
        )

        $authorization.permittedActionIds.Count |
            Should -Be $expectedActions.Count
        $authorization.permittedActionIds |
            Should -Be $expectedActions
        $authorization.permittedResourceIds |
            Should -Be $expectedResources
        $authorization.stateBinding.stateHash |
            Should -BeExactly $script:Fixture.State.stateHash
        {
            Assert-TestExecutionAuthorization `
                -Fixture $script:Fixture `
                -Authorization $authorization
        } | Should -Not -Throw
    }

    It 'records non-executable exact-resource cleanup intent' {
        $teardown = $script:Fixture.TeardownPlan
        $resourceGroupId = (
            $script:Fixture.LiveResolution.payload.resources |
                Where-Object stableId -CEQ 'azure.resource-group.primary'
        ).resourceId

        $teardown.resourceGroupId | Should -BeExactly $resourceGroupId
        $teardown.strategy | Should -BeExactly 'exact-resource-ids'
        $teardown.retainResourceGroup | Should -BeTrue
        $teardown.freshInventoryRequired | Should -BeTrue
        $teardown.plannedOwnedResourceIds.Count |
            Should -Be @(
                $script:Fixture.Plan.resources |
                    Where-Object {
                        $_.ownership.teardownIntent -eq
                            'delete-after-proof-and-approval' -and
                        $_.id -cne 'azure.resource-group.primary'
                    }
            ).Count
        $teardown.futureOwnedResourceIds |
            Should -Be $teardown.plannedOwnedResourceIds
        $teardown.retainedResourceIds |
            Should -Contain $resourceGroupId
        $teardown.Keys | Should -Not -Contain 'deleteActions'
    }

    It 'rejects a partial action authorization even after rehashing' {
        $authorization = New-TestExecutionAuthorization `
            -Fixture $script:Fixture
        $authorization.permittedActionIds = @(
            $authorization.permittedActionIds |
                Select-Object -Skip 1
        )
        $authorization.authorizationHash = & $script:Module {
            param($Authorization)
            Get-AdltArtifactHash `
                -Artifact $Authorization `
                -HashProperty authorizationHash
        } $authorization

        {
            Assert-TestExecutionAuthorization `
                -Fixture $script:Fixture `
                -Authorization $authorization
        } | Should -Throw -ExpectedMessage '*deploy action IDs does not exactly match*'
    }

    It 'rejects stale or synthetic stage evidence' {
        {
            & $script:Module {
                param($Fixture)
                New-AdltEvidence `
                    -RunId $Fixture.State.runId `
                    -PlanHash $Fixture.Plan.planHash `
                    -IntentHash $Fixture.Plan.intentHash `
                    -Stage what-if `
                    -Status pass
            } $script:Fixture
        } | Should -Throw -ExpectedMessage '*payload validation failed*'
    }

    It 'rejects unresolved plan blockers' {
        $unresolved = & $script:Module {
            param($Fixture)

            $copy = Copy-AdltValue -InputObject $Fixture.LiveResolution
            $copy.payload.resolvedPolicyFindingIds = @(
                $copy.payload.resolvedPolicyFindingIds |
                    Select-Object -Skip 1
            )
            $copy.evidenceHash = Get-AdltArtifactHash `
                -Artifact $copy `
                -HashProperty evidenceHash
            return $copy
        } $script:Fixture

        {
            & $script:Module {
                param($Plan, $Evidence)
                Assert-AdltBlockingFindingsResolved `
                    -Plan $Plan `
                    -LiveResolutionEvidence $Evidence
            } $script:Fixture.Plan $unresolved
        } | Should -Throw -ExpectedMessage '*does not exactly match*'
    }

    It 'rejects a cost above the narrower authorization maximum' {
        $expensive = New-TestAuthorizationFixture `
            -StateRoot (Join-Path $TestDrive 'expensive-runs') `
            -VmRetailPrice '1.00'

        {
            New-TestExecutionAuthorization `
                -Fixture $expensive `
                -MaximumCostMinorUnits 50
        } | Should -Throw -ExpectedMessage '*exceeds the authorized amount*'
    }

    It 'rejects approval by an identity other than the verified Azure principal' {
        $approval = & $script:Module {
            param($Approval)
            $copy = Copy-AdltValue -InputObject $Approval
            $copy.approver.id = '99999999-9999-4999-8999-999999999999'
            return $copy
        } $script:Fixture.Approval

        {
            New-TestExecutionAuthorization `
                -Fixture $script:Fixture `
                -Approval $approval
        } | Should -Throw -ExpectedMessage '*approval identity*'
    }

    It 'rejects a stale state tail even after rehashing authorization' {
        $authorization = New-TestExecutionAuthorization `
            -Fixture $script:Fixture
        $authorization.stateBinding.eventHash = "sha256:$('f' * 64)"
        $authorization.authorizationHash = & $script:Module {
            param($Authorization)
            Get-AdltArtifactHash `
                -Artifact $Authorization `
                -HashProperty authorizationHash
        } $authorization

        {
            Assert-TestExecutionAuthorization `
                -Fixture $script:Fixture `
                -Authorization $authorization
        } | Should -Throw -ExpectedMessage '*run-state tail*'
    }

    It 'rejects runtime drift even after rehashing authorization' {
        $authorization = New-TestExecutionAuthorization `
            -Fixture $script:Fixture
        $authorization.module.digest = "sha256:$('f' * 64)"
        $authorization.authorizationHash = & $script:Module {
            param($Authorization)
            Get-AdltArtifactHash `
                -Artifact $Authorization `
                -HashProperty authorizationHash
        } $authorization

        {
            Assert-TestExecutionAuthorization `
                -Fixture $script:Fixture `
                -Authorization $authorization
        } | Should -Throw -ExpectedMessage '*runtime identity*'
    }

    It 'rejects tampering with the deterministic compiler artifact' {
        $tampered = & $script:Module {
            param($Compilation)

            $copy = Copy-AdltValue -InputObject $Compilation
            $copy.template.resources[0].location = 'westeurope'
            $copy.templateHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject $copy.template
            )
            return $copy
        } $script:Fixture.Compilation
        $fixture = & $script:Module {
            param($Fixture)
            Copy-AdltValue -InputObject $Fixture
        } $script:Fixture
        $fixture.Compilation = $tampered

        {
            New-TestExecutionAuthorization -Fixture $fixture
        } | Should -Throw -ExpectedMessage '*deterministic recompilation*'
    }

    It 'persists and consumes a deployment execution record once' {
        $record = New-TestDeploymentExecutionRecord `
            -Fixture $script:Fixture

        $recordResult = & $script:Module {
            param($Fixture, $Record)

            Add-AdltLocalExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $Record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $Fixture.Now.AddSeconds(1)
        } $script:Fixture $record
        $recordResult.State.status | Should -BeExactly 'ready'

        $startResult = & $script:Module {
            param($Fixture, $Record)

            Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-started `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    executionRecordHash = $Record.executionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(2)
        } $script:Fixture $record
        $startResult.State.status | Should -BeExactly 'deploying'

        {
            & $script:Module {
                param($Fixture, $Record)

                Add-AdltLocalOperationEvent `
                    -RunPath $Fixture.RunPath `
                    -EventType operation-started `
                    -Data ([ordered]@{
                        operation = 'deploy'
                        operationId = $Record.operationId
                        executionRecordHash =
                            $Record.executionRecordHash
                    }) `
                    -ActorId AzureDataLabToolkit `
                    -OccurredAt $Fixture.Now.AddSeconds(3)
            } $script:Fixture $record
        } | Should -Throw -ExpectedMessage '*already been consumed*'
    }

    It 'rejects a deployment record whose final gate does not match preflight' {
        $record = New-TestDeploymentExecutionRecord `
            -Fixture $script:Fixture
        $record.finalGate.liveFactsHash = "sha256:$('f' * 64)"
        $record.finalGate.finalGateHash = & $script:Module {
            param($Record)

            Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                    liveFactsHash = $Record.finalGate.liveFactsHash
                    whatIfHash = $Record.finalGate.whatIfHash
                })
            )
        } $record
        $record.executionRecordHash = & $script:Module {
            param($Record)

            Get-AdltArtifactHash `
                -Artifact $Record `
                -HashProperty executionRecordHash
        } $record

        {
            & $script:Module {
                param($Fixture, $Record)

                Assert-AdltDeploymentExecutionRecord `
                    -ExecutionRecord $Record `
                    -Plan $Fixture.Plan `
                    -State $Fixture.State `
                    -LiveResolutionEvidence $Fixture.LiveResolution `
                    -WhatIfEvidence $Fixture.WhatIf `
                    -CostEvidence $Fixture.Cost `
                    -TeardownPreviewEvidence $Fixture.TeardownPreview `
                    -Compilation $Fixture.Compilation `
                    -AsOf $Fixture.Now
            } $script:Fixture $record
        } | Should -Throw -ExpectedMessage '*final gate*'
    }

    It 'runs the approved deployment through a terminal evidence record' {
        Mock Open-AdltAzureScopeOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock New-AdltFinalDeploymentGate `
            -ModuleName AzureDataLabToolkit {
            $liveHash = & $script:Module {
                param($Evidence)
                Get-AdltLiveFactsGateHash -Evidence $Evidence
            } $script:Fixture.LiveResolution
            $whatIfHash = & $script:Module {
                param($Evidence)
                Get-AdltWhatIfGateHash -Evidence $Evidence
            } $script:Fixture.WhatIf
            [ordered]@{
                liveFactsHash = $liveHash
                whatIfHash = $whatIfHash
                finalGateHash = & $script:Module {
                    param($LiveHash, $WhatIfHash)
                    Get-AdltSha256Identifier -Value (
                        ConvertTo-AdltCanonicalJson `
                            -InputObject ([ordered]@{
                                liveFactsHash = $LiveHash
                                whatIfHash = $WhatIfHash
                            })
                    )
                } $liveHash $whatIfHash
                completedAt = [datetimeoffset]::UtcNow.ToUniversalTime().
                    ToString(
                        'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
            }
        }
        Mock Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit {
            param($Plan, $Compilation, $ExecutionRecord)

            [ordered]@{
                deploymentName = $ExecutionRecord.deployment.name
                deploymentId = (
                    '{0}/providers/Microsoft.Resources/deployments/{1}' -f
                        $ExecutionRecord.deployment.scope,
                        $ExecutionRecord.deployment.name
                )
                correlationId =
                    '77777777-7777-4777-8777-777777777777'
                provisioningState = 'Succeeded'
                terminal = $true
                outcome = 'succeeded'
            }
        }

        $phrase = 'DEPLOY {0} {1}' -f
            $script:Fixture.State.scope.resourceGroupName,
            $script:Fixture.State.runId.Replace(
                '-',
                ''
            ).Substring(0, 8).ToLowerInvariant()
        $result = Start-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $phrase `
            -AcknowledgementId @(
                $script:Fixture.Plan.approval.requiredAcknowledgementIds
            ) `
            -Confirm:$false

        $result.Status | Should -BeExactly 'probing'
        $result.ProvisioningState | Should -BeExactly 'Succeeded'
        $result.RequiresReconciliation | Should -BeFalse
        Should -Invoke Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly
        $run = Get-AzureDataLabRun `
            -RunId $script:Fixture.State.runId `
            -StateRoot (
                [System.IO.Directory]::GetParent(
                    $script:Fixture.RunPath
                ).FullName
            )
        $run.State.status | Should -BeExactly 'probing'
    }

    It 'does not mutate Azure when the approval phrase is wrong' {
        Mock Open-AdltAzureScopeOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit

        {
            Start-AzureDataLabDeployment `
                -RunPath $script:Fixture.RunPath `
                -ApprovalPhrase 'DEPLOY wrong wrong' `
                -AcknowledgementId @(
                    $script:Fixture.Plan.approval.
                        requiredAcknowledgementIds
                ) `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*Approval phrase*'
        Should -Not -Invoke Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit
    }

    It 'does not consume a persisted approval under another Azure user' {
        $record = New-TestDeploymentExecutionRecord `
            -Fixture $script:Fixture
        & $script:Module {
            param($Fixture, $Record)

            [void] (Add-AdltLocalExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $Record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $Fixture.Now.AddSeconds(1))
        } $script:Fixture $record
        Mock Open-AdltAzureScopeOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Assert-AdltAzureMutationPrincipal `
            -ModuleName AzureDataLabToolkit {
            throw (
                'The current Azure user does not match the user who ' +
                'approved this protected operation.'
            )
        }
        Mock Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit

        {
            Start-AzureDataLabDeployment `
                -RunPath $script:Fixture.RunPath `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*does not match*'
        Should -Not -Invoke Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit
        $context = & $script:Module {
            param($RunPath)
            Get-AdltVerifiedLocalRunContext -RunPath $RunPath
        } $script:Fixture.RunPath
        $context.State.status | Should -BeExactly 'ready'
    }

    It 'reconciles a started operation without resubmitting deployment' {
        $record = New-TestDeploymentExecutionRecord `
            -Fixture $script:Fixture
        & $script:Module {
            param($Fixture, $Record)

            [void] (Add-AdltLocalExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $Record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $Fixture.Now.AddSeconds(1))
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-started `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    executionRecordHash = $Record.executionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(2))
        } $script:Fixture $record
        Mock Open-AdltAzureScopeOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit
        Mock Get-AdltSqlVmDeploymentStatus `
            -ModuleName AzureDataLabToolkit {
            [ordered]@{
                deploymentName = $record.deployment.name
                deploymentId = (
                    '{0}/providers/Microsoft.Resources/deployments/{1}' -f
                        $record.deployment.scope,
                        $record.deployment.name
                )
                correlationId =
                    '88888888-8888-4888-8888-888888888888'
                provisioningState = 'Succeeded'
                terminal = $true
                outcome = 'succeeded'
            }
        }

        $result = Resolve-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath

        $result.Status | Should -BeExactly 'probing'
        Should -Invoke Get-AdltSqlVmDeploymentStatus `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly
        Should -Not -Invoke Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit
    }

    It 'explicitly re-approves an absent deployment before resubmitting it' {
        $record = New-TestDeploymentExecutionRecord `
            -Fixture $script:Fixture
        & $script:Module {
            param($Fixture, $Record)

            [void] (Add-AdltLocalExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $Record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $Fixture.Now.AddSeconds(1))
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-started `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    executionRecordHash = $Record.executionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(2))
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-uncertain `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    reason = 'absent'
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(3))
        } $script:Fixture $record
        Mock Open-AdltAzureScopeOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Get-AdltSqlVmDeploymentStatus `
            -ModuleName AzureDataLabToolkit {
            throw (New-AuthorizationTestResourceNotFoundError)
        }
        Mock Assert-AdltSqlVmDeploymentTargetAbsence `
            -ModuleName AzureDataLabToolkit
        Mock Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit {
            param($Plan, $Compilation, $ExecutionRecord)

            [ordered]@{
                deploymentName = $ExecutionRecord.deployment.name
                deploymentId = (
                    '{0}/providers/Microsoft.Resources/deployments/{1}' -f
                        $ExecutionRecord.deployment.scope,
                        $ExecutionRecord.deployment.name
                )
                correlationId =
                    '77777777-7777-4777-8777-777777777777'
                provisioningState = 'Succeeded'
                terminal = $true
                outcome = 'succeeded'
            }
        }
        $phrase = & $script:Module {
            param($State, $Record)

            Get-AdltDeploymentResumeApprovalPhrase `
                -State $State `
                -ExecutionRecord $Record
        } $script:Fixture.State $record

        $result = Resume-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $phrase `
            -Confirm:$false

        $result.Status | Should -BeExactly 'probing'
        Should -Invoke Get-AdltSqlVmDeploymentStatus `
            -ModuleName AzureDataLabToolkit `
            -Times 2 `
            -Exactly
        Should -Invoke Assert-AdltSqlVmDeploymentTargetAbsence `
            -ModuleName AzureDataLabToolkit `
            -Times 2 `
            -Exactly
        Should -Invoke Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly
        $context = & $script:Module {
            param($RunPath)
            Get-AdltVerifiedLocalRunContext -RunPath $RunPath
        } $script:Fixture.RunPath
        $resumeEvent = @(
            $context.Events |
                Where-Object eventType -CEQ 'operation-resumed'
        )
        $resumeEvent.Count | Should -Be 1
        $resumeEvent[0].actor.type |
            Should -BeExactly 'interactive-user'
        $resumeEvent[0].actor.id |
            Should -BeExactly $script:Fixture.PrincipalId
    }

    It 'never resubmits while the subscription deployment record exists' {
        $record = New-TestDeploymentExecutionRecord `
            -Fixture $script:Fixture
        & $script:Module {
            param($Fixture, $Record)

            [void] (Add-AdltLocalExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $Record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $Fixture.Now.AddSeconds(1))
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-started `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    executionRecordHash = $Record.executionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(2))
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-uncertain `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    reason = 'unknown'
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(3))
        } $script:Fixture $record
        Mock Open-AdltAzureScopeOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Get-AdltSqlVmDeploymentStatus `
            -ModuleName AzureDataLabToolkit {
            [ordered]@{
                deploymentName = $record.deployment.name
                provisioningState = 'Running'
                terminal = $false
                outcome = $null
            }
        }
        Mock Assert-AdltSqlVmDeploymentTargetAbsence `
            -ModuleName AzureDataLabToolkit
        Mock Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit

        {
            Resume-AzureDataLabDeployment `
                -RunPath $script:Fixture.RunPath `
                -ApprovalPhrase 'RESUBMIT invalid' `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*exists*Reconcile*'
        Should -Not -Invoke Assert-AdltSqlVmDeploymentTargetAbsence `
            -ModuleName AzureDataLabToolkit
        Should -Not -Invoke Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit
    }

    It 'never resubmits when any exact deployment target is not absent' {
        $record = New-TestDeploymentExecutionRecord `
            -Fixture $script:Fixture
        & $script:Module {
            param($Fixture, $Record)

            [void] (Add-AdltLocalExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $Record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $Fixture.Now.AddSeconds(1))
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-started `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    executionRecordHash = $Record.executionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(2))
            [void] (Add-AdltLocalOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType operation-uncertain `
                -Data ([ordered]@{
                    operation = 'deploy'
                    operationId = $Record.operationId
                    reason = 'absent'
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $Fixture.Now.AddSeconds(3))
        } $script:Fixture $record
        Mock Open-AdltAzureScopeOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Get-AdltSqlVmDeploymentStatus `
            -ModuleName AzureDataLabToolkit {
            throw (New-AuthorizationTestResourceNotFoundError)
        }
        Mock Assert-AdltSqlVmDeploymentTargetAbsence `
            -ModuleName AzureDataLabToolkit {
            throw 'Deployment target is no longer provably absent.'
        }
        Mock Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit

        {
            Resume-AzureDataLabDeployment `
                -RunPath $script:Fixture.RunPath `
                -ApprovalPhrase 'RESUBMIT invalid' `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*provably absent*'
        Should -Not -Invoke Invoke-AdltSqlVmDeployment `
            -ModuleName AzureDataLabToolkit
    }
}

Describe 'Ownership-safe SQL VM teardown execution' {
    BeforeEach {
        Mock Get-AdltRuntimeIdentity -ModuleName AzureDataLabToolkit {
            [ordered]@{
                module = [ordered]@{
                    name    = 'AzureDataLabToolkit'
                    version = '0.1.0-alpha1'
                    digest  = "sha256:$('a' * 64)"
                }
                commit = ('d' * 40)
                powershell = [ordered]@{
                    version = '7.6.0'
                    edition = 'Core'
                }
                dependencies = @(
                    [ordered]@{
                        name             = 'powershell-yaml'
                        version          = '0.4.12'
                        guid             =
                            '6a75a662-7f53-425a-9777-ee61284407da'
                        author           = (
                            'Gabriel Adrian Samfira ' +
                            'Alessandro Pilotti'
                        )
                        source           = 'PSGallery'
                        packageDigest    = "sha256:$('1' * 64)"
                        contentDigest    = "sha256:$('2' * 64)"
                        manifestPathHash = "sha256:$('3' * 64)"
                    }
                )
            }
        }
        $script:Fixture = New-TestAuthorizationFixture `
            -StateRoot (Join-Path $TestDrive 'teardown-runs')
        $script:Deployed = Complete-TestDeploymentExecution `
            -Fixture $script:Fixture
        $script:AzureInventory = New-TestTeardownAzureInventory `
            -Fixture $script:Fixture `
            -Context $script:Deployed.Context
        $script:DeletedResourceIds =
            [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
        $script:ResourceListReads = 0

        Mock Open-AdltAzureScopeOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Get-AdltCurrentInteractivePrincipalId `
            -ModuleName AzureDataLabToolkit {
            $script:Fixture.PrincipalId
        }
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -ceq 'Get-AzResourceGroup') {
                return $script:AzureInventory.ResourceGroup
            }
            if (
                $CommandName -ceq 'Get-AzResource' -and
                $Parameters.ContainsKey('ResourceGroupName')
            ) {
                $script:ResourceListReads++
                return @(
                    $script:AzureInventory.Resources |
                        Where-Object {
                            -not $script:DeletedResourceIds.Contains(
                                [string] $_.ResourceId
                            )
                        }
                )
            }
            if (
                $CommandName -ceq 'Get-AzResource' -and
                $Parameters.ContainsKey('ResourceId')
            ) {
                $match = @(
                    $script:AzureInventory.Resources |
                        Where-Object {
                            $_.ResourceId -ceq
                                $Parameters.ResourceId -and
                            -not $script:DeletedResourceIds.Contains(
                                [string] $_.ResourceId
                            )
                        }
                )
                if ($match.Count -eq 1) {
                    return $match[0]
                }
                throw (New-AuthorizationTestResourceNotFoundError)
            }
            if ($CommandName -ceq 'Remove-AzResource') {
                [void] $script:DeletedResourceIds.Add(
                    [string] $Parameters.ResourceId
                )
                return $true
            }
            if ($CommandName -ceq 'Get-AzVM') {
                $vm = $script:AzureInventory.Resources |
                    Where-Object {
                        $_.ResourceType -ceq
                            'Microsoft.Compute/virtualMachines'
                    } |
                    Select-Object -First 1
                return [pscustomobject]@{
                    Id = [string] $vm.ResourceId
                    Statuses = @(
                        [pscustomobject]@{
                            Code = 'ProvisioningState/succeeded'
                        }
                        [pscustomobject]@{
                            Code = 'PowerState/running'
                        }
                    )
                }
            }
            throw "Unexpected Azure command '$CommandName'."
        }
    }

    It 'proves the deployed resource set before advancing to running' {
        $result = Test-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath
        $again = Test-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath

        $result.Status | Should -BeExactly 'running'
        $result.EvidenceStatus | Should -BeExactly 'pass'
        $result.RequiresReconciliation | Should -BeFalse
        $again.EvidenceHash |
            Should -BeExactly $result.EvidenceHash
        $verified = & $script:Module {
            param($RunPath)
            Get-AdltVerifiedLocalRunContext -RunPath $RunPath
        } $script:Fixture.RunPath
        $verified.State.status | Should -BeExactly 'running'
        @(
            $verified.Evidence |
                Where-Object {
                    $_.stage -ceq 'probe' -and
                    $_.status -ceq 'pass'
                }
        ).Count | Should -Be 1
    }

    It 'fails the probe when the VM is not running' {
        Mock Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Get-AzVM'
            } {
            $vm = $script:AzureInventory.Resources |
                Where-Object {
                    $_.ResourceType -ceq
                        'Microsoft.Compute/virtualMachines'
                } |
                Select-Object -First 1
            [pscustomobject]@{
                Id = [string] $vm.ResourceId
                Statuses = @(
                    [pscustomobject]@{
                        Code = 'ProvisioningState/succeeded'
                    }
                    [pscustomobject]@{
                        Code = 'PowerState/deallocated'
                    }
                )
            }
        }

        $result = Test-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath

        $result.Status | Should -BeExactly 'failed'
        $result.EvidenceStatus | Should -BeExactly 'fail'
        $result.RequiresReconciliation | Should -BeFalse
    }

    It 'fails the probe when SQL IaaS registration is not healthy' {
        $sqlVm = $script:AzureInventory.Resources |
            Where-Object {
                $_.ResourceType -ceq
                    'Microsoft.SqlVirtualMachine/sqlVirtualMachines'
            } |
            Select-Object -First 1
        $sqlVm.Properties.ProvisioningState = 'Failed'

        $result = Test-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath

        $result.Status | Should -BeExactly 'failed'
        $result.EvidenceStatus | Should -BeExactly 'fail'
        $result.RequiresReconciliation | Should -BeFalse
    }

    It 'rejects material Azure drift even when ownership tags remain intact' {
        $networkSecurityGroup = $script:AzureInventory.Resources |
            Where-Object {
                $_.ResourceType -ceq
                    'Microsoft.Network/networkSecurityGroups'
            } |
            Select-Object -First 1
        $securityRule = $networkSecurityGroup.Properties.SecurityRules[0]
        $securityRule.Properties.DestinationPortRange = '22'

        $result = Test-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath

        $result.Status | Should -BeExactly 'failed'
        $result.EvidenceStatus | Should -BeExactly 'fail'
        $result.RequiresReconciliation | Should -BeFalse
        $context = & $script:Module {
            param($RunPath)
            Get-AdltVerifiedLocalRunContext -RunPath $RunPath
        } $script:Fixture.RunPath
        $context.Evidence[-1].payload.failureKind |
            Should -BeExactly 'conflict'
    }

    It 'keeps an unverified probe retryable and later records success' {
        $script:ProbeResourceGroupReads = 0
        Mock Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Get-AzResourceGroup'
            } {
            $script:ProbeResourceGroupReads++
            if ($script:ProbeResourceGroupReads -eq 1) {
                throw '429 throttled'
            }
            return $script:AzureInventory.ResourceGroup
        }

        $first = Test-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath
        $second = Test-AzureDataLabDeployment `
            -RunPath $script:Fixture.RunPath

        $first.Status | Should -BeExactly 'probing'
        $first.EvidenceStatus | Should -BeExactly 'unverified'
        $first.RequiresReconciliation | Should -BeTrue
        $second.Status | Should -BeExactly 'running'
        $second.EvidenceStatus | Should -BeExactly 'pass'
    }

    It 'proves deletable generated resources and retains deployment history' {
        $inventory = & $script:Module {
            param($Fixture, $Deployed, $Compilation)

            Get-AdltSqlVmTeardownInventory `
                -Plan $Fixture.Plan `
                -State $Deployed.Context.State `
                -Compilation $Compilation `
                -RequireCompleteDeployment
        } `
            $script:Fixture `
            $script:Deployed `
            $script:AzureInventory.Compilation

        @(
            $inventory.resources |
                Where-Object relationship -CEQ 'vm-managed-disk'
        ).Count | Should -Be 3
        $inventory.resources.relationship |
            Should -Not -Contain 'nested-deployment'
        $inventory.resources.relationship |
            Should -Contain 'sql-iaas-agent-extension'
        $inventory.inventoryHash |
            Should -Match '^sha256:[a-f0-9]{64}$'
    }

    It 'blocks an unknown contained resource before deletion' {
        $script:AzureInventory = New-TestTeardownAzureInventory `
            -Fixture $script:Fixture `
            -Context $script:Deployed.Context `
            -IncludeUnknown

        {
            Start-AzureDataLabTeardown `
                -RunPath $script:Fixture.RunPath `
                -ApprovalPhrase 'DELETE invalid' `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*unknown contained resource*'
        Should -Not -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
    }

    It 'requires an inventory-bound exact phrase before deletion' {
        {
            Start-AzureDataLabTeardown `
                -RunPath $script:Fixture.RunPath `
                -ApprovalPhrase 'DELETE wrong wrong 0 wrong' `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*Approval phrase*'
        Should -Not -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
    }

    It 'deletes only the approved resources and retains the resource group' {
        $preview = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf
        $result = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $preview.RequiredApprovalPhrase `
            -Confirm:$false

        $result.Status | Should -BeExactly 'completed'
        $result.RequiresReconciliation | Should -BeFalse
        $result.EvidenceHash |
            Should -Match '^sha256:[a-f0-9]{64}$'
        $result.ResourceGroupRetained | Should -BeTrue
        $result.RetainedUnapprovedResourceCount | Should -Be 1
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -Times $preview.ResourceCount `
            -Exactly `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
        Should -Not -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResourceGroup'
            }
        $run = Get-AzureDataLabRun `
            -RunId $script:Fixture.State.runId `
            -StateRoot (
                [System.IO.Directory]::GetParent(
                    $script:Fixture.RunPath
                ).FullName
        )
        $run.State.status | Should -BeExactly 'completed'
        $verified = & $script:Module {
            param($RunPath)
            Get-AdltVerifiedLocalRunContext -RunPath $RunPath
        } $script:Fixture.RunPath
        @(
            $verified.Evidence |
                Where-Object stage -CEQ 'cleanup-proof'
        ).Count | Should -Be 1
    }

    It 'never deletes the retained nested deployment-history resource' {
        $nestedDeploymentId = [string] (
            $script:AzureInventory.Compilation.expectedGeneratedResources |
                Where-Object relationship -CEQ 'nested-deployment' |
                Select-Object -First 1
        ).resourceId
        $preview = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf
        $result = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $preview.RequiredApprovalPhrase `
            -Confirm:$false

        $result.Status | Should -BeExactly 'completed'
        $result.RetainedUnapprovedResourceCount | Should -Be 1
        $script:DeletedResourceIds.Contains($nestedDeploymentId) |
            Should -BeFalse
        Should -Not -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource' -and
                $Parameters.ResourceId -ceq $nestedDeploymentId
            }
    }

    It 'stops deleting when the cleanup lease expires between resources' {
        $script:TeardownMutationClockCalls = 0
        Mock Get-AdltTeardownMutationTime `
            -ModuleName AzureDataLabToolkit {
            $script:TeardownMutationClockCalls++
            if ($script:TeardownMutationClockCalls -eq 1) {
                return [datetimeoffset]::UtcNow
            }
            return [datetimeoffset]::UtcNow.AddMinutes(11)
        }
        $preview = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf
        $result = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $preview.RequiredApprovalPhrase `
            -Confirm:$false

        $result.Status | Should -BeExactly 'cleanup-unknown'
        $result.RequiresReconciliation | Should -BeTrue
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
    }

    It 'reconciles absence without resubmitting a prior delete' {
        Mock Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            } {
            throw '429 throttled'
        }
        $preview = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf
        $first = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $preview.RequiredApprovalPhrase `
            -Confirm:$false
        $first.Status | Should -BeExactly 'cleanup-unknown'

        foreach ($resource in $script:AzureInventory.Resources) {
            [void] $script:DeletedResourceIds.Add(
                [string] $resource.ResourceId
            )
        }
        $resolved = Resolve-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath

        $resolved.Status | Should -BeExactly 'completed'
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
    }

    It 're-approves and resumes only the remaining approved resources' {
        $script:DeleteAttempt = 0
        $script:FailDeleteOnce = $true
        Mock Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            } {
            $script:DeleteAttempt++
            if (
                $script:DeleteAttempt -eq 2 -and
                $script:FailDeleteOnce
            ) {
                $script:FailDeleteOnce = $false
                throw '429 throttled'
            }
            [void] $script:DeletedResourceIds.Add(
                [string] $Parameters.ResourceId
            )
            return $true
        }

        $preview = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf
        $first = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $preview.RequiredApprovalPhrase `
            -Confirm:$false
        $resumePreview = Resume-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf
        $result = Resume-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $resumePreview.RequiredApprovalPhrase `
            -Confirm:$false

        $first.Status | Should -BeExactly 'cleanup-unknown'
        $resumePreview.ResourceCount |
            Should -Be ($preview.ResourceCount - 1)
        $resumePreview.RequiredApprovalPhrase |
            Should -Match '^RESUME DELETE '
        $result.Status | Should -BeExactly 'completed'
        $result.ResourceGroupRetained | Should -BeTrue
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -Times ($preview.ResourceCount + 1) `
            -Exactly `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
        $verified = & $script:Module {
            param($RunPath)
            Get-AdltVerifiedLocalRunContext -RunPath $RunPath
        } $script:Fixture.RunPath
        $resumeEvents = @(
            $verified.Events |
                Where-Object {
                    $_.eventType -ceq
                        'teardown-operation-resumed'
                }
        )
        $resumeEvents.Count | Should -Be 1
        $resumeEvents[0].actor.type |
            Should -BeExactly 'interactive-user'
        $resumeEvents[0].actor.id |
            Should -BeExactly $script:Fixture.PrincipalId
    }

    It 'detects inventory drift between approval and record creation' {
        $originalResources = @($script:AzureInventory.Resources)
        Mock Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Get-AzResource' -and
                $Parameters.ContainsKey('ResourceGroupName')
            } {
            $script:ResourceListReads++
            if ($script:ResourceListReads -eq 1) {
                return $originalResources
            }
            return @(
                $originalResources + @(
                    [pscustomobject]@{
                        ResourceId = (
                            '{0}/providers/Microsoft.Storage/storageAccounts/drift' -f
                                $script:AzureInventory.ResourceGroup.ResourceId
                        )
                        ResourceType =
                            'Microsoft.Storage/storageAccounts'
                        Tags = @{}
                        Properties = [pscustomobject]@{
                            ProvisioningState = 'Succeeded'
                        }
                    }
                )
            )
        }
        $preview = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf

        {
            Start-AzureDataLabTeardown `
                -RunPath $script:Fixture.RunPath `
                -ApprovalPhrase $preview.RequiredApprovalPhrase `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*unknown contained resource*'
        Should -Not -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
    }

    It 'blocks a newly added resource at the final delete boundary' {
        $originalResources = @($script:AzureInventory.Resources)
        Mock Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Get-AzResource' -and
                $Parameters.ContainsKey('ResourceGroupName')
            } {
            $script:ResourceListReads++
            if ($script:ResourceListReads -le 3) {
                return $originalResources
            }
            return @(
                $originalResources + @(
                    [pscustomobject]@{
                        ResourceId = (
                            '{0}/providers/Microsoft.Storage/storageAccounts/late' -f
                                $script:AzureInventory.ResourceGroup.ResourceId
                        )
                        ResourceType =
                            'Microsoft.Storage/storageAccounts'
                        Tags = @{}
                        Properties = [pscustomobject]@{
                            ProvisioningState = 'Succeeded'
                        }
                    }
                )
            )
        }
        $preview = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf
        $result = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $preview.RequiredApprovalPhrase `
            -Confirm:$false

        $result.Status | Should -BeExactly 'cleanup-unknown'
        Should -Not -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
    }

    It 'blocks a resource fingerprint change after approval' {
        Mock Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Get-AzResource' -and
                $Parameters.ContainsKey('ResourceId')
            } {
            $match = @(
                $script:AzureInventory.Resources |
                    Where-Object ResourceId -CEQ
                        $Parameters.ResourceId
            )
            if ($match.Count -ne 1) {
                throw (New-AuthorizationTestResourceNotFoundError)
            }
            $tags = @{}
            foreach ($key in @($match[0].Tags.Keys)) {
                $tags[$key] = $match[0].Tags[$key]
            }
            $tags['post-approval-change'] = 'true'
            return [pscustomobject]@{
                ResourceId = $match[0].ResourceId
                ResourceType = $match[0].ResourceType
                Tags = $tags
                Properties = $match[0].Properties
                Sku = $match[0].Sku
                ManagedBy = $match[0].ManagedBy
            }
        }
        $preview = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -WhatIf
        $result = Start-AzureDataLabTeardown `
            -RunPath $script:Fixture.RunPath `
            -ApprovalPhrase $preview.RequiredApprovalPhrase `
            -Confirm:$false

        $result.Status | Should -BeExactly 'cleanup-unknown'
        Should -Not -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
    }

    It 'refreshes an expired pending teardown lease without rewriting its record' {
        $result = & $script:Module {
            param($Fixture, $Deployed)

            $createdAt = $Fixture.Now.AddSeconds(4)
            $state = $Deployed.Context.State
            $resourceGroupId =
                '/subscriptions/{0}/resourceGroups/{1}' -f
                    $state.scope.subscriptionId,
                    $state.scope.resourceGroupName
            $inventory = [ordered]@{
                capturedAt = ConvertTo-AdltUtcTimestamp `
                    -Value $createdAt
                resourceGroupId = $resourceGroupId
                resourceGroupStatus = 'absent'
                resourceGroupProofHash =
                    Get-AdltSha256Identifier -Value (
                        ConvertTo-AdltCanonicalJson `
                            -InputObject ([ordered]@{
                                resourceGroupId = $resourceGroupId
                                observedState = 'absent'
                            })
                    )
                resourceCount = 0
                resources = @()
            }
            $inventory.inventoryHash =
                Get-AdltTeardownInventoryHash -Inventory $inventory
            $record = New-AdltTeardownExecutionRecord `
                -Plan $Fixture.Plan `
                -State $state `
                -DeploymentExecutionRecord $Deployed.Record `
                -Inventory $inventory `
                -ApproverId $Fixture.PrincipalId `
                -CreatedAt $createdAt
            [void] (Add-AdltLocalTeardownExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $createdAt)

            $refreshAt = $createdAt.AddMinutes(11)
            $refresh = Add-AdltLocalTeardownAuthorizationRefresh `
                -RunPath $Fixture.RunPath `
                -ActorId $Fixture.PrincipalId `
                -InventoryHash $inventory.inventoryHash `
                -OccurredAt $refreshAt
            $start = Add-AdltLocalTeardownOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType teardown-operation-started `
                -Data ([ordered]@{
                    operation = 'teardown'
                    operationId = $record.operationId
                    teardownExecutionRecordHash =
                        $record.teardownExecutionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $refreshAt.AddSeconds(1)
            $context = Get-AdltVerifiedLocalRunContext `
                -RunPath $Fixture.RunPath

            [ordered]@{
                originalRecordHash = $record.teardownExecutionRecordHash
                persistedRecordHash = (
                    Get-AdltTeardownExecutionRecordFromContext `
                        -Context $context
                ).teardownExecutionRecordHash
                refreshEventCount = @(
                    $context.Events |
                        Where-Object {
                            $_.eventType -ceq
                                'teardown-authorization-refreshed'
                        }
                ).Count
                refreshApprovedAt =
                    $refresh.CleanupLease.approvedAt
                expectedApprovedAt =
                    ConvertTo-AdltUtcTimestamp -Value $refreshAt
                status = $start.State.status
            }
        } $script:Fixture $script:Deployed

        $result.originalRecordHash |
            Should -BeExactly $result.persistedRecordHash
        $result.refreshEventCount | Should -Be 1
        $result.refreshApprovedAt |
            Should -BeExactly $result.expectedApprovedAt
        $result.status | Should -BeExactly 'tearing-down'
    }

    It 'rejects early or differently bound teardown lease refreshes' {
        $errors = & $script:Module {
            param($Fixture, $Deployed)

            $createdAt = $Fixture.Now.AddSeconds(4)
            $state = $Deployed.Context.State
            $resourceGroupId =
                '/subscriptions/{0}/resourceGroups/{1}' -f
                    $state.scope.subscriptionId,
                    $state.scope.resourceGroupName
            $inventory = [ordered]@{
                capturedAt = ConvertTo-AdltUtcTimestamp `
                    -Value $createdAt
                resourceGroupId = $resourceGroupId
                resourceGroupStatus = 'absent'
                resourceGroupProofHash =
                    Get-AdltSha256Identifier -Value (
                        ConvertTo-AdltCanonicalJson `
                            -InputObject ([ordered]@{
                                resourceGroupId = $resourceGroupId
                                observedState = 'absent'
                            })
                    )
                resourceCount = 0
                resources = @()
            }
            $inventory.inventoryHash =
                Get-AdltTeardownInventoryHash -Inventory $inventory
            $record = New-AdltTeardownExecutionRecord `
                -Plan $Fixture.Plan `
                -State $state `
                -DeploymentExecutionRecord $Deployed.Record `
                -Inventory $inventory `
                -ApproverId $Fixture.PrincipalId `
                -CreatedAt $createdAt
            [void] (Add-AdltLocalTeardownExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $createdAt)

            $messages = [ordered]@{}
            try {
                [void] (Add-AdltLocalTeardownAuthorizationRefresh `
                    -RunPath $Fixture.RunPath `
                    -ActorId $Fixture.PrincipalId `
                    -InventoryHash $inventory.inventoryHash `
                    -OccurredAt $createdAt.AddMinutes(1))
            }
            catch {
                $messages.early = $_.Exception.Message
            }
            try {
                [void] (Add-AdltLocalTeardownAuthorizationRefresh `
                    -RunPath $Fixture.RunPath `
                    -ActorId '99999999-9999-4999-8999-999999999999' `
                    -InventoryHash $inventory.inventoryHash `
                    -OccurredAt $createdAt.AddMinutes(11))
            }
            catch {
                $messages.principal = $_.Exception.Message
            }
            try {
                [void] (Add-AdltLocalTeardownAuthorizationRefresh `
                    -RunPath $Fixture.RunPath `
                    -ActorId $Fixture.PrincipalId `
                    -InventoryHash (
                        'sha256:' + ('f' * 64)
                    ) `
                    -OccurredAt $createdAt.AddMinutes(11))
            }
            catch {
                $messages.inventory = $_.Exception.Message
            }
            return $messages
        } $script:Fixture $script:Deployed

        $errors.early | Should -Match 'still valid'
        $errors.principal | Should -Match 'principal or inventory'
        $errors.inventory | Should -Match 'principal or inventory'
    }

    It 'blocks a pending teardown resumed by a different Azure user' {
        $pending = & $script:Module {
            param($Fixture, $Deployed)

            $inventory = Get-AdltSqlVmTeardownInventory `
                -Plan $Fixture.Plan `
                -State $Deployed.Context.State `
                -Compilation $Fixture.Compilation `
                -RequireCompleteDeployment
            $createdAt = [datetimeoffset]::UtcNow
            $record = New-AdltTeardownExecutionRecord `
                -Plan $Fixture.Plan `
                -State $Deployed.Context.State `
                -DeploymentExecutionRecord $Deployed.Record `
                -Inventory $inventory `
                -ApproverId $Fixture.PrincipalId `
                -CreatedAt $createdAt
            [void] (Add-AdltLocalTeardownExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $createdAt)
            return $record
        } $script:Fixture $script:Deployed
        Mock Get-AdltCurrentInteractivePrincipalId `
            -ModuleName AzureDataLabToolkit {
            '99999999-9999-4999-8999-999999999999'
        }

        {
            Start-AzureDataLabTeardown `
                -RunPath $script:Fixture.RunPath `
                -ApprovalPhrase 'DELETE anything' `
                -Confirm:$false
        } | Should -Throw -ExpectedMessage '*same interactive Azure user*'
        $pending.cleanupLease.approver.id |
            Should -BeExactly $script:Fixture.PrincipalId
        Should -Not -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -ceq 'Remove-AzResource'
            }
    }

    It 'permits a fresh cleanup lease after the run itself expires' {
        $expiredAt = [datetimeoffset]::Parse(
            [string] $script:Deployed.Context.State.expiresAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        ).AddMinutes(1)
        $result = & $script:Module {
            param($Fixture, $Deployed, $ExpiredAt)

            $state = $Deployed.Context.State
            $resourceGroupId =
                '/subscriptions/{0}/resourceGroups/{1}' -f
                    $state.scope.subscriptionId,
                    $state.scope.resourceGroupName
            $inventory = [ordered]@{
                capturedAt = ConvertTo-AdltUtcTimestamp `
                    -Value $ExpiredAt
                resourceGroupId = $resourceGroupId
                resourceGroupStatus = 'absent'
                resourceGroupProofHash =
                    Get-AdltSha256Identifier -Value (
                        ConvertTo-AdltCanonicalJson `
                            -InputObject ([ordered]@{
                                resourceGroupId = $resourceGroupId
                                observedState = 'absent'
                            })
                    )
                resourceCount = 0
                resources = @()
            }
            $inventory.inventoryHash =
                Get-AdltTeardownInventoryHash -Inventory $inventory
            $record = New-AdltTeardownExecutionRecord `
                -Plan $Fixture.Plan `
                -State $state `
                -DeploymentExecutionRecord $Deployed.Record `
                -Inventory $inventory `
                -ApproverId $Fixture.PrincipalId `
                -CreatedAt $ExpiredAt
            [void] (Add-AdltLocalTeardownExecutionRecord `
                -RunPath $Fixture.RunPath `
                -ExecutionRecord $record `
                -ActorId $Fixture.PrincipalId `
                -OccurredAt $ExpiredAt)
            [void] (Add-AdltLocalTeardownOperationEvent `
                -RunPath $Fixture.RunPath `
                -EventType teardown-operation-started `
                -Data ([ordered]@{
                    operation = 'teardown'
                    operationId = $record.operationId
                    teardownExecutionRecordHash =
                        $record.teardownExecutionRecordHash
                }) `
                -ActorId AzureDataLabToolkit `
                -OccurredAt $ExpiredAt.AddSeconds(1))
            Complete-AdltTeardownOperation `
                -RunPath $Fixture.RunPath `
                -Plan $Fixture.Plan `
                -ExecutionRecord $record `
                -Observation ([ordered]@{
                    state = 'approved-resources-absent'
                    failureKind = 'absent'
                    remainingApprovedResourceCount = 0
                    resourceGroupState = 'absent'
                    retainedUnapprovedResourceCount = 0
                }) `
                -StartedAt $ExpiredAt.AddSeconds(1) `
                -CompletedAt $ExpiredAt.AddSeconds(2)
        } $script:Fixture $script:Deployed $expiredAt

        $result.Status | Should -BeExactly 'completed'
    }
}
