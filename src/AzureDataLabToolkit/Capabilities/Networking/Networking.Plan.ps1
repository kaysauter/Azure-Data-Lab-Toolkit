function Get-AdltNetworkingPlanFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Names,

        [Parameter(Mandatory)]
        [string] $PlanIntentHash
    )

    if ($Configuration.target.type -ne 'sqlVm') {
        throw "Networking contributor does not support target '$($Configuration.target.type)'."
    }

    $inboundRules = if (
        $Configuration.security.administrativeAccess.mode -eq 'deploy-bastion'
    ) {
        @(
            [ordered]@{
                name                    = 'AllowRdpFromBastionSubnet'
                priority                = 100
                access                  = 'Allow'
                protocol                = 'Tcp'
                sourceAddressPrefix     = '10.42.2.0/26'
                destinationPort         = 3389
            }
        )
    }
    elseif ($Configuration.security.administrativeAccess.mode -eq 'reuse-bastion') {
        @(
            [ordered]@{
                name                    = 'AllowRdpFromReusedBastion'
                priority                = 100
                access                  = 'Allow'
                protocol                = 'Tcp'
                sourceBastionResourceId = $Configuration.security.administrativeAccess.resourceId
                sourcePrefixStatus      = 'unverified'
                destinationPort         = 3389
            }
        )
    }
    else {
        @()
    }

    $resources = [System.Collections.Generic.List[object]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()
    $resourceDefinitions = @(
        [pscustomobject]@{
            Id           = 'azure.network.virtual-network.primary'
            Type         = 'Microsoft.Network/virtualNetworks'
            ApiVersion   = '2024-05-01'
            Name         = $Names.virtualNetwork
            Dependencies = @('action.resource-group.primary')
            Properties   = [ordered]@{
                location        = $Configuration.azure.location
                addressPrefixes = @('10.42.0.0/16')
                tags            = [ordered]@{
                    managedBy = 'AzureDataLabToolkit'
                    labName   = $Configuration.metadata.name
                }
            }
        }
        [pscustomobject]@{
            Id           = 'azure.network.security-group.workload'
            Type         = 'Microsoft.Network/networkSecurityGroups'
            ApiVersion   = '2024-05-01'
            Name         = $Names.networkSecurityGroup
            Dependencies = @('action.resource-group.primary')
            Properties   = [ordered]@{
                location      = $Configuration.azure.location
                inboundPolicy = 'deny-by-default'
                inboundRules  = @($inboundRules)
                outboundPolicy = 'azure-platform-default'
            }
        }
        [pscustomobject]@{
            Id           = 'azure.network.subnet.workload'
            Type         = 'Microsoft.Network/virtualNetworks/subnets'
            ApiVersion   = '2024-05-01'
            Name         = $Names.workloadSubnet
            Dependencies = @(
                'action.network.virtual-network.primary'
                'action.network.security-group.workload'
            )
            Properties   = [ordered]@{
                addressPrefix                  = '10.42.1.0/24'
                virtualNetworkResourceId       = 'azure.network.virtual-network.primary'
                networkSecurityGroupResourceId = 'azure.network.security-group.workload'
                privateEndpointNetworkPolicies = 'Disabled'
            }
        }
        [pscustomobject]@{
            Id           = 'azure.network.interface.primary'
            Type         = 'Microsoft.Network/networkInterfaces'
            ApiVersion   = '2024-05-01'
            Name         = $Names.networkInterface
            Dependencies = @('action.network.subnet.workload')
            Properties   = [ordered]@{
                location                    = $Configuration.azure.location
                subnetResourceId            = 'azure.network.subnet.workload'
                privateIpAllocation         = 'Dynamic'
                publicIpResourceId           = $null
                enableAcceleratedNetworking  = $false
                enableIpForwarding           = $false
            }
        }
    )

    foreach ($definition in $resourceDefinitions) {
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

    return [ordered]@{
        name      = 'networking'
        resources = $resources.ToArray()
        actions   = $actions.ToArray()
        warnings  = @()
    }
}

Register-AdltCapabilityPlanContributor `
    -Name 'networking' `
    -FunctionName 'Get-AdltNetworkingPlanFragment' `
    -ContractVersion '1.0' `
    -SupportedSchemaVersions @('1.0') `
    -TargetTypes @('sqlVm') `
    -AlwaysActive
