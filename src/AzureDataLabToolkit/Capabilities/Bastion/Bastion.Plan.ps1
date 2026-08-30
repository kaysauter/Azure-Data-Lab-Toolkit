function Get-AdltBastionPlanFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Names,

        [Parameter(Mandatory)]
        [string] $PlanIntentHash
    )

    $access = $Configuration.security.administrativeAccess
    if ($access.mode -eq 'opt-out') {
        return [ordered]@{
            name           = 'bastion'
            resources      = @()
            actions        = @()
            policyFindings = @(
                New-AdltPolicyFinding `
                    -Id 'policy.access.bastion-opt-out' `
                    -Severity high `
                    -Effect acknowledge `
                    -ConfigurationPath 'security.administrativeAccess.mode' `
                    -Message 'Azure Bastion was explicitly declined for VM administrative access.'
            )
            warnings       = @(
                'Administrative access explicitly opts out of Azure Bastion; the rationale requires approval.'
            )
        }
    }

    if ($access.mode -eq 'reuse-bastion') {
        $resource = New-AdltResource `
            -Id 'azure.network.bastion.primary' `
            -Type 'Microsoft.Network/bastionHosts' `
            -ApiVersion '2024-05-01' `
            -LogicalName (Get-AdltResourceNameFromId -ResourceId $access.resourceId) `
            -ExternalResourceId $access.resourceId `
            -DesiredProperties ([ordered]@{
                sku                     = $access.sku
                compatibility           = 'verify-live'
                targetVirtualNetworkId  = 'azure.network.virtual-network.primary'
                vmPublicIpRequired      = $false
            }) `
            -OwnershipIntent 'reuse' `
            -ExpectedClassification 'reused'
        $action = New-AdltAction `
            -Id 'action.network.bastion.primary' `
            -Operation 'reference' `
            -ResourceId 'azure.network.bastion.primary' `
            -PlanIntentHash $PlanIntentHash `
            -Mutation $false `
            -OwnershipEffect 'intend-reused' `
            -Postconditions @('bastion-compatibility-requires-live-verification')

        return [ordered]@{
            name           = 'bastion'
            resources      = @($resource)
            actions        = @($action)
            policyFindings = @(
                New-AdltPolicyFinding `
                    -Id 'policy.access.bastion-reuse' `
                    -Severity warning `
                    -Effect acknowledge `
                    -ConfigurationPath 'security.administrativeAccess.resourceId' `
                    -Message 'The reused Bastion host and its network compatibility require live verification.'
            )
            warnings       = @(
                'Reused Bastion access requires the recorded rationale and live network compatibility verification.'
            )
        }
    }

    $resources = [System.Collections.Generic.List[object]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()
    $definitions = @(
        [pscustomobject]@{
            Id           = 'azure.network.subnet.bastion'
            Type         = 'Microsoft.Network/virtualNetworks/subnets'
            ApiVersion   = '2024-05-01'
            Name         = $Names.bastionSubnet
            Dependencies = @('action.network.virtual-network.primary')
            Properties   = [ordered]@{
                addressPrefix            = '10.42.2.0/26'
                virtualNetworkResourceId = 'azure.network.virtual-network.primary'
            }
        }
        [pscustomobject]@{
            Id           = 'azure.network.public-ip.bastion'
            Type         = 'Microsoft.Network/publicIPAddresses'
            ApiVersion   = '2024-05-01'
            Name         = $Names.bastionPublicIp
            Dependencies = @('action.resource-group.primary')
            Properties   = [ordered]@{
                location         = $Configuration.azure.location
                sku              = 'Standard'
                allocationMethod = 'Static'
                purpose          = 'AzureBastionOnly'
            }
        }
        [pscustomobject]@{
            Id           = 'azure.network.bastion.primary'
            Type         = 'Microsoft.Network/bastionHosts'
            ApiVersion   = '2024-05-01'
            Name         = $Names.bastion
            Dependencies = @(
                'action.network.subnet.bastion'
                'action.network.public-ip.bastion'
            )
            Properties   = [ordered]@{
                location                 = $Configuration.azure.location
                sku                      = $access.sku
                scaleUnits               = 2
                subnetResourceId         = 'azure.network.subnet.bastion'
                publicIpResourceId       = 'azure.network.public-ip.bastion'
                vmPublicIpRequired       = $false
                nativeClient             = $false
                shareableLink            = $false
                ipConnect                = $false
                fileCopy                 = $false
            }
        }
    )

    foreach ($definition in $definitions) {
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
        name           = 'bastion'
        resources      = $resources.ToArray()
        actions        = $actions.ToArray()
        policyFindings = @()
        warnings       = @()
    }
}

Register-AdltCapabilityPlanContributor `
    -Name 'bastion' `
    -FunctionName 'Get-AdltBastionPlanFragment' `
    -ContractVersion '1.0' `
    -SupportedSchemaVersions @('1.0') `
    -TargetTypes @('sqlVm') `
    -Dependencies @('capability:networking') `
    -AlwaysActive
