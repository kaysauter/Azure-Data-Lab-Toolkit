BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Remove-Module AzureDataLabToolkit -Force -ErrorAction SilentlyContinue
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:Module = Get-Module AzureDataLabToolkit
}

AfterAll {
    Remove-Module AzureDataLabToolkit -Force -ErrorAction SilentlyContinue
}

Describe 'Idempotent teardown resolution outcomes' {
        BeforeEach {
            $script:ResolverRunPath = Join-Path $TestDrive 'run'
            $script:ResolverOperationId =
                '11111111-1111-4111-8111-111111111111'
            $script:ResolverRecord = [ordered]@{
                operationId = $script:ResolverOperationId
                cleanupLease = [ordered]@{
                    approver = [ordered]@{
                        id = '22222222-2222-4222-8222-222222222222'
                    }
                }
                deleteAction = [ordered]@{
                    resourceGroupName = 'rg-adlt-resolver'
                }
            }
            $script:ResolverContext = [pscustomobject][ordered]@{
                State = [ordered]@{
                    runId = '33333333-3333-4333-8333-333333333333'
                    status = 'teardown-approved'
                    scope = [ordered]@{
                        cloud = 'AzureCloud'
                        tenantId =
                            '44444444-4444-4444-8444-444444444444'
                        subscriptionId =
                            '55555555-5555-4555-8555-555555555555'
                        resourceGroupName = 'rg-adlt-resolver'
                    }
                }
                Plan = [ordered]@{}
                Events = @()
                Evidence = @()
            }

            Mock Get-AdltVerifiedLocalRunContext {
                $script:ResolverContext
            } -ModuleName AzureDataLabToolkit
            Mock Open-AdltAzureScopeOperationLock {
                [System.IO.MemoryStream]::new()
            } -ModuleName AzureDataLabToolkit
            Mock Open-AdltLocalRunOperationLock {
                [System.IO.MemoryStream]::new()
            } -ModuleName AzureDataLabToolkit
            Mock Get-AdltTeardownExecutionRecordFromContext {
                $script:ResolverRecord
            } -ModuleName AzureDataLabToolkit
            Mock Assert-AdltAzureMutationPrincipal {
                [ordered]@{
                    id = '22222222-2222-4222-8222-222222222222'
                }
            } -ModuleName AzureDataLabToolkit
            Mock Get-AdltApprovedResourceDeletionObservation {
                throw 'Deletion observation must not be repeated.'
            } -ModuleName AzureDataLabToolkit
        }

        It 'returns an approved operation that never started' {
            $result = Resolve-AzureDataLabTeardown `
                -RunPath $script:ResolverRunPath

            $result.Status | Should -BeExactly 'approved-not-started'
            $result.OperationId |
                Should -BeExactly $script:ResolverOperationId
            $result.ResourceGroupName |
                Should -BeExactly 'rg-adlt-resolver'
            $result.RequiresReconciliation | Should -BeFalse
            Should -Invoke `
                -CommandName Get-AdltApprovedResourceDeletionObservation `
                -ModuleName AzureDataLabToolkit `
                -Times 0 `
                -Exactly
        }

        It 'returns the existing terminal cleanup proof' {
            $evidenceHash = 'sha256:{0}' -f ('a' * 64)
            $script:ResolverContext.State.status = 'completed'
            $script:ResolverContext.Events = @(
                [ordered]@{
                    eventType = 'teardown-operation-finished'
                    data = [ordered]@{
                        operationId = $script:ResolverOperationId
                        evidenceHash = $evidenceHash
                    }
                }
            )
            $script:ResolverContext.Evidence = @(
                [ordered]@{
                    evidenceHash = $evidenceHash
                    payload = [ordered]@{
                        resourceGroupState = 'present'
                        retainedUnapprovedResourceCount = 2
                    }
                }
            )

            $result = Resolve-AzureDataLabTeardown `
                -RunPath $script:ResolverRunPath

            $result.Status | Should -BeExactly 'completed'
            $result.EvidenceHash | Should -BeExactly $evidenceHash
            $result.ResourceGroupRetained | Should -BeTrue
            $result.RetainedUnapprovedResourceCount | Should -Be 2
            $result.RequiresReconciliation | Should -BeFalse
            Should -Invoke `
                -CommandName Get-AdltApprovedResourceDeletionObservation `
                -ModuleName AzureDataLabToolkit `
                -Times 0 `
                -Exactly
        }

        It 'records an uncertain started teardown without resubmitting' {
            $script:ResolverContext.State.status = 'tearing-down'
            $script:ResolverContext.Events = @(
                [ordered]@{
                    eventType = 'teardown-operation-started'
                    occurredAt = '2026-07-29T00:00:00.0000000Z'
                    data = [ordered]@{
                        operationId = $script:ResolverOperationId
                    }
                }
            )
            Mock Get-AdltApprovedResourceDeletionObservation {
                [ordered]@{
                    state = 'unknown'
                    failureKind = 'throttled'
                }
            } -ModuleName AzureDataLabToolkit
            Mock Add-AdltLocalTeardownOperationEvent {
                [ordered]@{
                    eventHash = 'sha256:{0}' -f ('b' * 64)
                }
            } -ModuleName AzureDataLabToolkit

            $result = Resolve-AzureDataLabTeardown `
                -RunPath $script:ResolverRunPath

            $result.Status | Should -BeExactly 'cleanup-unknown'
            $result.RequiresReconciliation | Should -BeTrue
            $result.EvidenceHash | Should -BeNullOrEmpty
            Should -Invoke `
                -CommandName Get-AdltApprovedResourceDeletionObservation `
                -ModuleName AzureDataLabToolkit `
                -Times 1 `
                -Exactly
            Should -Invoke `
                -CommandName Add-AdltLocalTeardownOperationEvent `
                -ModuleName AzureDataLabToolkit `
                -ParameterFilter {
                    $EventType -ceq 'teardown-operation-uncertain' -and
                    $Data.operationId -ceq
                        $script:ResolverOperationId -and
                    $Data.reason -ceq 'throttled'
                } `
                -Times 1 `
                -Exactly
        }
}

Describe 'Pre-delete proof verification for every deletable relationship' {
    BeforeAll {
        $script:GateSubscriptionId =
            '66666666-6666-4666-8666-666666666666'
        $script:GateResourceGroupName = 'rg-adlt-gate'
        $script:GateResourceGroupId = '/subscriptions/{0}/resourceGroups/{1}' -f
            $script:GateSubscriptionId,
            $script:GateResourceGroupName
        $script:GateVirtualMachineId =
            '{0}/providers/Microsoft.Compute/virtualMachines/vm-adlt' -f
            $script:GateResourceGroupId
        $script:GateSubnetId = (
            '{0}/providers/Microsoft.Network/virtualNetworks/' +
            'vnet-adlt/subnets/snet-adlt'
        ) -f $script:GateResourceGroupId
        $script:GateDiskId =
            '{0}/providers/Microsoft.Compute/disks/vm-adlt-os' -f
            $script:GateResourceGroupId
        $script:GateExtensionId = '{0}/extensions/SqlIaasExtension' -f
            $script:GateVirtualMachineId
        $script:GateNestedDeploymentId = (
            '{0}/providers/Microsoft.Resources/deployments/adlt-sqlvm'
        ) -f $script:GateResourceGroupId
        $script:GateForeignVirtualMachineId = (
            '/subscriptions/{0}/resourceGroups/rg-adlt-foreign/providers/' +
            'Microsoft.Compute/virtualMachines/vm-foreign'
        ) -f $script:GateSubscriptionId
        $script:GatePlannedProofHash = 'sha256:{0}' -f ('a' * 64)
        $script:GateDescendantProofHash = 'sha256:{0}' -f ('b' * 64)
        $script:GateDiskProofHash = 'sha256:{0}' -f ('c' * 64)
        $script:GateExtensionPublisher = 'Microsoft.SqlVirtualMachine'
        $script:GateExtensionType = 'SqlIaaSAgent'
        $script:GateDiskSizeGiB = 127
        $script:GateDiskStorageType = 'Premium_LRS'

        function New-GateApprovedResource {
            param(
                [Parameter(Mandatory)]
                [object] $Observed,

                [Parameter(Mandatory)]
                [string] $StableId,

                [Parameter(Mandatory)]
                [string] $Relationship,

                [Parameter(Mandatory)]
                [string] $ApiVersion,

                [Parameter(Mandatory)]
                [string] $ProofHash
            )

            return & $script:Module {
                param(
                    $Observed,
                    $StableId,
                    $Relationship,
                    $ApiVersion,
                    $ProofHash
                )

                return [ordered]@{
                    stableId     = $StableId
                    resourceId   = Get-AdltObservedResourceId `
                        -Observed $Observed
                    resourceType = Get-AdltObservedResourceType `
                        -Observed $Observed
                    apiVersion   = $ApiVersion
                    etag         = Get-AdltObservedResourceEtag `
                        -Observed $Observed
                    observationFingerprint =
                        Get-AdltObservedResourceFingerprint `
                            -Observed $Observed
                    relationship = $Relationship
                    required     = $true
                    proofHash    = $ProofHash
                }
            } `
                $Observed `
                $StableId `
                $Relationship `
                $ApiVersion `
                $ProofHash
        }

        function Get-GateExtensionProofHash {
            param(
                [Parameter(Mandatory)]
                [string] $ResourceId,

                [Parameter(Mandatory)]
                [string] $ParentResourceId,

                [Parameter(Mandatory)]
                [string] $ProducerResourceId,

                [Parameter(Mandatory)]
                [string] $Publisher,

                [Parameter(Mandatory)]
                [string] $ExtensionType
            )

            return & $script:Module {
                param(
                    $ResourceId,
                    $ParentResourceId,
                    $ProducerResourceId,
                    $Publisher,
                    $ExtensionType
                )

                return Get-AdltSha256Identifier -Value (
                    ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                        resourceId = $ResourceId
                        parentResourceId = $ParentResourceId
                        producerResourceId = $ProducerResourceId
                        publisher = $Publisher
                        type = $ExtensionType
                        profileVersion = 'sql-iaas-windows-2023-10-01-v1'
                    })
                )
            } `
                $ResourceId `
                $ParentResourceId `
                $ProducerResourceId `
                $Publisher `
                $ExtensionType
        }

        function Test-GateApprovedResourceUnchanged {
            param(
                [Parameter(Mandatory)]
                [System.Collections.IDictionary] $Resource
            )

            return & $script:Module {
                param($Resource, $ExecutionRecord)

                return Test-AdltApprovedResourceUnchanged `
                    -Resource $Resource `
                    -ExecutionRecord $ExecutionRecord `
                    -Plan ([ordered]@{ id = 'plan' }) `
                    -Compilation ([ordered]@{ id = 'compilation' })
            } `
                $Resource `
                $script:GateExecutionRecord
        }

        function Remove-GateListedResource {
            param(
                [Parameter(Mandatory)]
                [string] $ResourceId
            )

            $script:GateListing = @(
                $script:GateListing |
                    Where-Object { $_.ResourceId -cne $ResourceId }
            )
        }
    }

    BeforeEach {
        $script:GateObservedVirtualMachine = [pscustomobject][ordered]@{
            ResourceId   = $script:GateVirtualMachineId
            ResourceType = 'Microsoft.Compute/virtualMachines'
            Location     = 'westeurope'
            Tags         = @{ 'adlt:managed-by' = 'azure-data-lab-toolkit' }
            Properties   = [pscustomobject][ordered]@{
                ProvisioningState = 'Succeeded'
            }
        }
        $script:GateObservedSubnet = [pscustomobject][ordered]@{
            ResourceId   = $script:GateSubnetId
            ResourceType = 'Microsoft.Network/virtualNetworks/subnets'
            ETag         = 'W/"subnet-etag"'
            Properties   = [pscustomobject][ordered]@{
                ProvisioningState = 'Succeeded'
            }
        }
        $script:GateObservedDisk = [pscustomobject][ordered]@{
            ResourceId   = $script:GateDiskId
            ResourceType = 'Microsoft.Compute/disks'
            Location     = 'westeurope'
            ManagedBy    = ''
            Sku          = [pscustomobject][ordered]@{
                Name = $script:GateDiskStorageType
            }
            Properties   = [pscustomobject][ordered]@{
                DiskSizeGB        = $script:GateDiskSizeGiB
                ProvisioningState = 'Succeeded'
            }
        }
        $script:GateObservedExtension = [pscustomobject][ordered]@{
            ResourceId   = $script:GateExtensionId
            ResourceType = 'Microsoft.Compute/virtualMachines/extensions'
            Location     = 'westeurope'
            Properties   = [pscustomobject][ordered]@{
                Publisher         = $script:GateExtensionPublisher
                Type              = $script:GateExtensionType
                ProvisioningState = 'Succeeded'
            }
        }
        $script:GateObservedNestedDeployment =
            [pscustomobject][ordered]@{
                ResourceId   = $script:GateNestedDeploymentId
                ResourceType = 'Microsoft.Resources/deployments'
            }
        $script:GateListing = @(
            $script:GateObservedVirtualMachine
            $script:GateObservedSubnet
            $script:GateObservedDisk
            $script:GateObservedExtension
            $script:GateObservedNestedDeployment
        )

        $script:GateExtensionProofHash = Get-GateExtensionProofHash `
            -ResourceId $script:GateExtensionId `
            -ParentResourceId $script:GateVirtualMachineId `
            -ProducerResourceId $script:GateVirtualMachineId `
            -Publisher $script:GateExtensionPublisher `
            -ExtensionType $script:GateExtensionType

        $script:GateVirtualMachineResource = New-GateApprovedResource `
            -Observed $script:GateObservedVirtualMachine `
            -StableId 'azure.compute.virtual-machine.primary' `
            -Relationship 'planned-taggable' `
            -ApiVersion '2024-03-01' `
            -ProofHash $script:GatePlannedProofHash
        $script:GateSubnetResource = New-GateApprovedResource `
            -Observed $script:GateObservedSubnet `
            -StableId 'azure.network.virtual-network.primary.subnet' `
            -Relationship 'planned-descendant' `
            -ApiVersion '2024-01-01' `
            -ProofHash $script:GateDescendantProofHash
        $script:GateDiskResource = New-GateApprovedResource `
            -Observed $script:GateObservedDisk `
            -StableId 'azure.compute.virtual-machine.primary.os-disk' `
            -Relationship 'vm-managed-disk' `
            -ApiVersion '2024-03-02' `
            -ProofHash $script:GateDiskProofHash
        $script:GateExtensionResource = New-GateApprovedResource `
            -Observed $script:GateObservedExtension `
            -StableId 'azure.compute.virtual-machine.primary.sql-iaas' `
            -Relationship 'sql-iaas-agent-extension' `
            -ApiVersion '2024-03-01' `
            -ProofHash $script:GateExtensionProofHash

        $script:GateExecutionRecord = [ordered]@{
            operationId  = '77777777-7777-4777-8777-777777777777'
            runId        = '88888888-8888-4888-8888-888888888888'
            deleteAction = [ordered]@{
                resourceGroupName = $script:GateResourceGroupName
            }
            inventory    = [ordered]@{
                resourceCount = 4
                resources     = @(
                    $script:GateVirtualMachineResource
                    $script:GateSubnetResource
                    $script:GateDiskResource
                    $script:GateExtensionResource
                )
            }
        }

        $script:GateExpectedSet = @(
            [ordered]@{
                stableId           = 'azure.compute.virtual-machine.primary'
                resourceId         = $script:GateVirtualMachineId
                resourceType       = 'Microsoft.Compute/virtualMachines'
                relationship       = 'planned-taggable'
                required           = $true
                apiVersion         = '2024-03-01'
                producerResourceId = $null
                expectedProperties = [ordered]@{}
            }
            [ordered]@{
                stableId           =
                    'azure.network.virtual-network.primary.subnet'
                resourceId         = $script:GateSubnetId
                resourceType       =
                    'Microsoft.Network/virtualNetworks/subnets'
                relationship       = 'planned-descendant'
                required           = $true
                apiVersion         = '2024-01-01'
                producerResourceId =
                    '{0}/providers/Microsoft.Network/virtualNetworks/vnet-adlt' -f
                    $script:GateResourceGroupId
                expectedProperties = [ordered]@{}
            }
            [ordered]@{
                stableId           =
                    'azure.compute.virtual-machine.primary.os-disk'
                resourceId         = $script:GateDiskId
                resourceType       = 'Microsoft.Compute/disks'
                relationship       = 'vm-managed-disk'
                required           = $true
                apiVersion         = '2024-03-02'
                producerResourceId = $script:GateVirtualMachineId
                expectedProperties = [ordered]@{
                    purpose     = 'os'
                    sizeGiB     = $script:GateDiskSizeGiB
                    storageType = $script:GateDiskStorageType
                }
            }
            [ordered]@{
                stableId           =
                    'azure.compute.virtual-machine.primary.sql-iaas'
                resourceId         = $script:GateExtensionId
                resourceType       =
                    'Microsoft.Compute/virtualMachines/extensions'
                relationship       = 'sql-iaas-agent-extension'
                required           = $true
                apiVersion         = '2024-03-01'
                producerResourceId = $script:GateVirtualMachineId
                expectedProperties = [ordered]@{
                    parentResourceId = $script:GateVirtualMachineId
                    publisher        = $script:GateExtensionPublisher
                    type             = $script:GateExtensionType
                }
            }
            [ordered]@{
                stableId           = 'azure.resources.deployment.primary'
                resourceId         = $script:GateNestedDeploymentId
                resourceType       = 'Microsoft.Resources/deployments'
                relationship       = 'nested-deployment'
                required           = $true
                apiVersion         = '2022-09-01'
                producerResourceId = $null
                expectedProperties = [ordered]@{}
            }
        )
        $script:GateStableIdMap = [ordered]@{
            'azure.compute.virtual-machine.primary' = [ordered]@{
                id = 'azure.compute.virtual-machine.primary'
            }
            'azure.network.virtual-network.primary.subnet' = [ordered]@{
                id = 'azure.network.virtual-network.primary.subnet'
            }
        }

        Mock Get-AdltSqlVmTeardownExpectedResourceSet {
            $script:GateExpectedSet
        } -ModuleName AzureDataLabToolkit
        Mock Get-AdltSqlVmArmResourceMap {
            $script:GateStableIdMap
        } -ModuleName AzureDataLabToolkit
        Mock Get-AdltSqlVmCompiledNestedResourceMap {
            $script:GateStableIdMap
        } -ModuleName AzureDataLabToolkit
        Mock Get-AdltSqlVmPlannedResourceProof {
            [string] $script:GatePlannedProofResult
        } -ModuleName AzureDataLabToolkit
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            if ($CommandName -cne 'Get-AzResource') {
                throw "Unexpected Azure command '$CommandName'."
            }
            if ($Parameters.ContainsKey('ResourceGroupName')) {
                return @($script:GateListing)
            }
            $match = @(
                $script:GateListing |
                    Where-Object {
                        $_.ResourceId -ceq [string] $Parameters.ResourceId
                    }
            )
            if ($match.Count -ne 1) {
                throw "Unexpected resource read '$($Parameters.ResourceId)'."
            }
            return $match[0]
        }
    }

    It 'reproves the planned-taggable material state before deletion' {
        $script:GatePlannedProofResult = $script:GatePlannedProofHash

        Test-GateApprovedResourceUnchanged `
            -Resource $script:GateVirtualMachineResource |
            Should -BeTrue
        Should -Invoke `
            -CommandName Get-AdltSqlVmPlannedResourceProof `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $Expected.relationship -ceq 'planned-taggable' -and
                $Expected.resourceId -ceq $script:GateVirtualMachineId
            } `
            -Times 1 `
            -Exactly
    }

    It 'blocks a planned-taggable resource whose fresh proof moved' {
        $script:GatePlannedProofResult = 'sha256:{0}' -f ('d' * 64)

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateVirtualMachineResource
        } | Should -Throw -ExpectedMessage '*proof changed before deletion*'
    }

    It 'reproves the planned-descendant material state before deletion' {
        $script:GatePlannedProofResult = $script:GateDescendantProofHash

        Test-GateApprovedResourceUnchanged `
            -Resource $script:GateSubnetResource |
            Should -BeTrue
        Should -Invoke `
            -CommandName Get-AdltSqlVmPlannedResourceProof `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $Expected.relationship -ceq 'planned-descendant' -and
                $Expected.resourceId -ceq $script:GateSubnetId
            } `
            -Times 1 `
            -Exactly
    }

    It 'blocks a planned-descendant resource whose fresh proof moved' {
        $script:GatePlannedProofResult = 'sha256:{0}' -f ('d' * 64)

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateSubnetResource
        } | Should -Throw -ExpectedMessage '*proof changed before deletion*'
    }

    It 'reproves the sql-iaas-agent-extension proof before deletion' {
        Test-GateApprovedResourceUnchanged `
            -Resource $script:GateExtensionResource |
            Should -BeTrue
    }

    It 'blocks an extension whose observed publisher moved' {
        $script:GateObservedExtension.Properties.Publisher =
            'Contoso.SqlVirtualMachine'

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateExtensionResource
        } | Should -Throw -ExpectedMessage '*proof changed before deletion*'
    }

    It 'blocks an extension whose observed extension type moved' {
        $script:GateObservedExtension.Properties.Type = 'CustomScript'

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateExtensionResource
        } | Should -Throw -ExpectedMessage '*proof changed before deletion*'
    }

    It 'blocks an extension whose owning VM is no longer observed' {
        Remove-GateListedResource -ResourceId $script:GateVirtualMachineId

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateExtensionResource
        } | Should -Throw -ExpectedMessage '*lacks its owned VM*'
    }

    It 'reproves the vm-managed-disk back-reference while the VM lives' {
        $script:GateObservedDisk.ManagedBy = $script:GateVirtualMachineId

        Test-GateApprovedResourceUnchanged `
            -Resource $script:GateDiskResource |
            Should -BeTrue
    }

    It 'blocks a managed disk detached while its planned VM still lives' {
        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateDiskResource
        } | Should -Throw `
            -ExpectedMessage '*is not managed by the planned VM*'
    }

    It 'reproves the derivable vm-managed-disk contract once the VM is gone' {
        Remove-GateListedResource -ResourceId $script:GateVirtualMachineId

        Test-GateApprovedResourceUnchanged `
            -Resource $script:GateDiskResource |
            Should -BeTrue
    }

    It 'blocks a managed disk re-attached to an unapproved VM' {
        Remove-GateListedResource -ResourceId $script:GateVirtualMachineId
        $script:GateObservedDisk.ManagedBy =
            $script:GateForeignVirtualMachineId

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateDiskResource
        } | Should -Throw `
            -ExpectedMessage '*is not managed by the planned VM*'
    }

    It 'blocks a managed disk whose size left the compiler contract' {
        Remove-GateListedResource -ResourceId $script:GateVirtualMachineId
        $script:GateObservedDisk.Properties.DiskSizeGB = 1024

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateDiskResource
        } | Should -Throw -ExpectedMessage '*proof changed before deletion*'
    }

    It 'blocks a managed disk whose storage type left the contract' {
        Remove-GateListedResource -ResourceId $script:GateVirtualMachineId
        $script:GateObservedDisk.Sku.Name = 'Standard_LRS'

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateDiskResource
        } | Should -Throw -ExpectedMessage '*proof changed before deletion*'
    }

    It 'blocks an approved resource whose compiler relationship moved' {
        $script:GateExpectedSet[3].relationship = 'planned-taggable'

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateExtensionResource
        } | Should -Throw `
            -ExpectedMessage '*no longer has its approved relationship*'
    }

    It 'blocks an approved resource with an unsupported relationship' {
        $script:GateExpectedSet[3].relationship = 'future-relationship'
        $script:GateExtensionResource.relationship = 'future-relationship'

        {
            Test-GateApprovedResourceUnchanged `
                -Resource $script:GateExtensionResource
        } | Should -Throw -ExpectedMessage '*is unsupported before deletion*'
    }
}
