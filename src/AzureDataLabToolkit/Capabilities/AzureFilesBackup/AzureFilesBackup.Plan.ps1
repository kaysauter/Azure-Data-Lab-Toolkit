function Get-AdltAzureFilesBackupPlanFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Names,

        [Parameter(Mandatory)]
        [string] $PlanIntentHash
    )

    if (-not $Configuration.capabilities.backupShare.enabled) {
        return
    }

    $resources = [System.Collections.Generic.List[object]]::new()
    $actions = [System.Collections.Generic.List[object]]::new()

    $resourceDefinitions = @(
        [pscustomobject]@{
            Id             = 'azure.storage.account.backups'
            Type           = 'Microsoft.Storage/storageAccounts'
            ApiVersion     = '2023-05-01'
            Name           = $Names.storageAccount
            Dependencies   = @('action.resource-group.primary')
            TeardownIntent = 'retain-until-separately-approved'
            Properties     = [ordered]@{
                location                  = $Configuration.azure.location
                kind                      = 'StorageV2'
                sku                       = 'Standard_LRS'
                minimumTlsVersion         = 'TLS1_2'
                httpsTrafficOnly          = $true
                sharedKeyAccess           = $false
                publicNetworkAccess       = 'Disabled'
                managedIdentitySmbOAuth   = $true
            }
        }
        [pscustomobject]@{
            Id             = 'azure.storage.file-share.backups'
            Type           = 'Microsoft.Storage/storageAccounts/fileServices/shares'
            ApiVersion     = '2023-05-01'
            Name           = $Names.fileShare
            Dependencies   = @('action.storage.account.backups')
            TeardownIntent = 'retain-until-separately-approved'
            Properties     = [ordered]@{
                storageAccountResourceId = 'azure.storage.account.backups'
                enabledProtocol          = 'SMB'
                quotaGiB                 = $Configuration.capabilities.backupShare.quotaGiB
                accessTier               = 'TransactionOptimized'
            }
        }
        [pscustomobject]@{
            Id             = 'azure.network.private-dns-zone.backups'
            Type           = 'Microsoft.Network/privateDnsZones'
            ApiVersion     = '2024-06-01'
            Name           = $Names.backupPrivateDnsZone
            Dependencies   = @('action.resource-group.primary')
            TeardownIntent = 'delete-after-proof-and-approval'
            Properties     = [ordered]@{
                zoneName = $Names.backupPrivateDnsZone
            }
        }
        [pscustomobject]@{
            Id             = 'azure.network.private-dns-vnet-link.backups'
            Type           = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
            ApiVersion     = '2024-06-01'
            Name           = $Names.backupDnsZoneLink
            Dependencies   = @(
                'action.network.private-dns-zone.backups'
                'action.network.virtual-network.primary'
            )
            TeardownIntent = 'delete-after-proof-and-approval'
            Properties     = [ordered]@{
                privateDnsZoneResourceId = 'azure.network.private-dns-zone.backups'
                virtualNetworkResourceId = 'azure.network.virtual-network.primary'
                registrationEnabled      = $false
            }
        }
        [pscustomobject]@{
            Id             = 'azure.network.private-endpoint.backups'
            Type           = 'Microsoft.Network/privateEndpoints'
            ApiVersion     = '2024-05-01'
            Name           = $Names.privateEndpoint
            Dependencies   = @(
                'action.storage.account.backups'
                'action.network.subnet.workload'
            )
            TeardownIntent = 'delete-after-proof-and-approval'
            Properties     = [ordered]@{
                location                  = $Configuration.azure.location
                subnetResourceId          = 'azure.network.subnet.workload'
                privateLinkResourceId     = 'azure.storage.account.backups'
                groupIds                  = @('file')
                manualPrivateLinkApproval = $false
            }
        }
        [pscustomobject]@{
            Id             = 'azure.network.private-dns-zone-group.backups'
            Type           = 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
            ApiVersion     = '2024-05-01'
            Name           = $Names.backupDnsZoneGroup
            Dependencies   = @(
                'action.network.private-endpoint.backups'
                'action.network.private-dns-vnet-link.backups'
            )
            TeardownIntent = 'delete-after-proof-and-approval'
            Properties     = [ordered]@{
                privateEndpointResourceId = 'azure.network.private-endpoint.backups'
                privateDnsZoneResourceId  = 'azure.network.private-dns-zone.backups'
            }
        }
        [pscustomobject]@{
            Id             = 'azure.authorization.file-share-smb.backups'
            Type           = 'Microsoft.Authorization/roleAssignments'
            ApiVersion     = '2022-04-01'
            Name           = $Names.fileShareRole
            Dependencies   = @(
                'action.compute.virtual-machine.primary'
                'action.storage.file-share.backups'
            )
            TeardownIntent = 'delete-after-proof-and-approval'
            Properties     = [ordered]@{
                scopeResourceId    = 'azure.storage.file-share.backups'
                principalReference = 'azure.compute.virtual-machine.primary.identity.systemAssigned'
                principalIdStatus  = 'unverified'
                roleDefinitionName = 'Storage File Data SMB MI Admin'
            }
        }
    )

    foreach ($resourceDefinition in $resourceDefinitions) {
        $resources.Add((New-AdltResource `
            -Id $resourceDefinition.Id `
            -Type $resourceDefinition.Type `
            -ApiVersion $resourceDefinition.ApiVersion `
            -LogicalName $resourceDefinition.Name `
            -DesiredProperties $resourceDefinition.Properties `
            -OwnershipIntent 'create' `
            -ExpectedClassification 'owned' `
            -TeardownIntent $resourceDefinition.TeardownIntent))
        $actions.Add((New-AdltAction `
            -Id ('action.{0}' -f ($resourceDefinition.Id -replace '^azure\.', '')) `
            -Operation 'ensure' `
            -ResourceId $resourceDefinition.Id `
            -DependsOn @($resourceDefinition.Dependencies) `
            -PlanIntentHash $PlanIntentHash `
            -OwnershipEffect 'intend-owned'))
    }

    $actions.Add((New-AdltAction `
        -Id 'action.guest.mount-script.backups' `
        -Operation 'render' `
        -ResourceId 'guest.mount-script.backups' `
        -PlanIntentHash $PlanIntentHash `
        -Mutation $false `
        -OwnershipEffect 'none' `
        -Postconditions @(
            'mount-script-rendered'
            'configured-drive-letter-recorded'
            'managed-identity-authentication-only'
            'storage-account-key-not-required'
            'az-files-smb-mi-client-required'
        )))
    $actions.Add((New-AdltAction `
        -Id 'action.guest.mount-script.stage.backups' `
        -Operation 'stage' `
        -ResourceId 'guest.mount-script.backups' `
        -PlanIntentHash $PlanIntentHash `
        -DependsOn @(
            'action.guest.mount-script.backups'
            'action.authorization.file-share-smb.backups'
            'action.network.private-dns-zone-group.backups'
        ) `
        -OwnershipEffect 'none' `
        -Postconditions @(
            'mount-script-present-on-vm'
            'remote-staging-requires-approved-engine'
            'az-files-smb-mi-client-installed-and-verified'
            'managed-identity-credential-refresh-probe-passed'
        )))

    return [ordered]@{
        name           = 'azureFilesBackup'
        resources      = $resources.ToArray()
        actions        = $actions.ToArray()
        policyFindings = @(
            New-AdltPolicyFinding `
                -Id 'policy.backup-share.smb-oauth-client-unavailable' `
                -Severity blocking `
                -Effect resolve-before-deploy `
                -ConfigurationPath 'capabilities.backupShare.enabled' `
                -Message 'Deployment is blocked until AzFilesSmbMIClient acquisition, integrity, installation, credential refresh, and probing are governed.'
        )
        warnings       = @(
            'Azure Files identity, DNS, private-endpoint, and VM compatibility require authenticated WhatIf verification.'
            'The SMB OAuth guest client path is intentionally blocked until its artifact and lifecycle contract is implemented.'
        )
    }
}

Register-AdltCapabilityPlanContributor `
    -Name 'azureFilesBackup' `
    -FunctionName 'Get-AdltAzureFilesBackupPlanFragment' `
    -ContractVersion '1.0' `
    -SupportedSchemaVersions @('1.0') `
    -TargetTypes @('sqlVm') `
    -ActivationPaths @('capabilities.backupShare.enabled')
