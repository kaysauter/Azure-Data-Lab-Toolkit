BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:MinimalConfigurationPath = Join-Path $script:RepositoryRoot 'examples/sqlvm-minimal.yaml'
    $script:BackupConfigurationPath = Join-Path $script:RepositoryRoot 'examples/sqlvm-backup-share.yaml'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

Describe 'Extension boundaries' {
    It 'registers networking, Key Vault, Bastion, and Azure Files as capabilities' {
        InModuleScope AzureDataLabToolkit {
            $script:AdltCapabilityPlanContributors.Keys |
                Should -Contain 'networking'
            $script:AdltCapabilityPlanContributors.Keys |
                Should -Contain 'keyVault'
            $script:AdltCapabilityPlanContributors.Keys |
                Should -Contain 'bastion'
            $script:AdltCapabilityPlanContributors.Keys |
                Should -Contain 'azureFilesBackup'

            foreach ($descriptor in $script:AdltCapabilityPlanContributors.Values) {
                $descriptor.contractVersion | Should -Be '1.0'
                $descriptor.supportedSchemaVersions | Should -Contain '1.0'
                $descriptor.source | Should -Be 'bundled-module'
                $descriptor.integrity | Should -Be 'covered-by-module-package'
            }
        }
    }

    It 'keeps the SQL VM provider free of embedded capability registration' {
        $providerPath = Join-Path `
            $script:RepositoryRoot `
            'src/AzureDataLabToolkit/Providers/SqlVm/SqlVm.Plan.ps1'
        $providerSource = Get-Content -LiteralPath $providerPath -Raw

        $providerSource | Should -Not -Match 'function New-AdltResource'
        $providerSource | Should -Not -Match 'function New-AdltAction'
        $providerSource | Should -Not -Match 'Microsoft\.KeyVault/vaults'
        $providerSource | Should -Not -Match 'Microsoft\.Network/bastionHosts'
    }

    It 'rejects missing and cyclic contributor dependencies' {
        $module = Get-Module AzureDataLabToolkit
        {
            & $module {
                param($ConfigurationPath)
                $resolution = Resolve-AdltConfiguration `
                    -Path $ConfigurationPath `
                    -Overrides ([ordered]@{})
                $descriptor = $script:AdltCapabilityPlanContributors.bastion
                $original = @($descriptor.dependencies)
                try {
                    $descriptor.dependencies = @('capability:not-registered')
                    Assert-AdltContributorGraph -Configuration $resolution.Configuration
                }
                finally {
                    $descriptor.dependencies = $original
                }
            } $script:MinimalConfigurationPath
        } | Should -Throw -ExpectedMessage '*missing or inactive contributor*'

        {
            & $module {
                param($ConfigurationPath)
                $resolution = Resolve-AdltConfiguration `
                    -Path $ConfigurationPath `
                    -Overrides ([ordered]@{})
                $networking = $script:AdltCapabilityPlanContributors.networking
                $original = @($networking.dependencies)
                try {
                    $networking.dependencies = @('capability:bastion')
                    Assert-AdltContributorGraph -Configuration $resolution.Configuration
                }
                finally {
                    $networking.dependencies = $original
                }
            } $script:MinimalConfigurationPath
        } | Should -Throw -ExpectedMessage '*contain a cycle*'
    }
}

Describe 'SQL VM dependency graph' {
    BeforeAll {
        $script:Plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
    }

    It 'models the private VM network and secure access resources explicitly' {
        $script:Plan.resources.id | Should -Contain 'azure.network.virtual-network.primary'
        $script:Plan.resources.id | Should -Contain 'azure.network.security-group.workload'
        $script:Plan.resources.id | Should -Contain 'azure.network.subnet.workload'
        $script:Plan.resources.id | Should -Contain 'azure.network.interface.primary'
        $script:Plan.resources.id | Should -Contain 'azure.network.subnet.bastion'
        $script:Plan.resources.id | Should -Contain 'azure.network.public-ip.bastion'
        $script:Plan.resources.id | Should -Contain 'azure.network.bastion.primary'
        $script:Plan.resources.id | Should -Contain 'azure.security.key-vault.primary'
    }

    It 'gives every resource an API version and engine-facing desired properties' {
        foreach ($resource in $script:Plan.resources) {
            $resource.apiVersion | Should -Match '^\d{4}-\d{2}-\d{2}'
            $resource.desiredProperties.Count | Should -BeGreaterThan 0
            if ($resource.ownership.intent -eq 'create') {
                $resource.externalResourceId | Should -BeNullOrEmpty
            }
        }
    }

    It 'orders VM creation after its network and credential-store prerequisites' {
        $vmAction = $script:Plan.actions |
            Where-Object id -EQ 'action.compute.virtual-machine.primary'

        $vmAction.dependsOn | Should -Contain 'action.network.interface.primary'
        $vmAction.dependsOn | Should -Contain 'action.network.security-group.workload'
        $vmAction.dependsOn |
            Should -Contain 'action.security.key-vault-secret.vm-admin'
    }

    It 'defines one fixed secure SQL VM alpha profile' {
        $vm = $script:Plan.resources |
            Where-Object id -EQ 'azure.compute.virtual-machine.primary'
        $sqlVm = $script:Plan.resources |
            Where-Object id -EQ 'azure.sql.virtual-machine.primary'

        $vm.desiredProperties.identity.type | Should -Be 'SystemAssigned'
        $vm.desiredProperties.securityProfile.securityType |
            Should -Be 'trustedLaunch'
        $vm.desiredProperties.securityProfile.secureBootEnabled | Should -BeTrue
        $vm.desiredProperties.securityProfile.virtualTpmEnabled | Should -BeTrue
        $vm.desiredProperties.networkProfile.publicIpResourceId |
            Should -BeNullOrEmpty
        $vm.desiredProperties.imageReference.sku | Should -Be 'sqldev-gen2'
        $sqlVm.logicalName | Should -Be $vm.logicalName
        $sqlVm.desiredProperties.virtualMachineResourceId |
            Should -Match '/providers/Microsoft\.Compute/virtualMachines/'
        $sqlVm.desiredProperties.leastPrivilegeMode | Should -Be 'Enabled'
        $sqlVm.desiredProperties.sqlServerLicenseType | Should -Be 'PAYG'
        $sqlVm.desiredProperties.storageConfigurationSettings.sqlDataSettings.luns |
            Should -Contain 0
    }

    It 'rejects unknown or incorrectly typed SQL VM desired properties' {
        $schemaPath = Join-Path `
            $script:RepositoryRoot `
            'src/AzureDataLabToolkit/Schemas/plan.schema.json'
        $wrongType = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $sqlVm = $wrongType.resources |
            Where-Object id -EQ 'azure.sql.virtual-machine.primary'
        $sqlVm.desiredProperties.sqlServerLicenseType = 7

        Test-Json `
            -Json ($wrongType | ConvertTo-Json -Depth 100 -Compress) `
            -SchemaFile $schemaPath `
            -ErrorAction SilentlyContinue |
            Should -BeFalse

        $unknownProperty = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $unknownSqlVm = $unknownProperty.resources |
            Where-Object id -EQ 'azure.sql.virtual-machine.primary'
        $unknownSqlVm.desiredProperties.Add('unrecognizedSetting', $true)

        Test-Json `
            -Json ($unknownProperty | ConvertTo-Json -Depth 100 -Compress) `
            -SchemaFile $schemaPath `
            -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'models a satisfiable no-plaintext Key Vault credential gate' {
        $vault = $script:Plan.resources |
            Where-Object id -EQ 'azure.security.key-vault.primary'
        $secret = $script:Plan.resources |
            Where-Object id -EQ 'azure.security.key-vault-secret.vm-admin'
        $secretAction = $script:Plan.actions |
            Where-Object id -EQ 'action.security.key-vault-secret.vm-admin'

        $vault.desiredProperties.publicNetworkAccess | Should -Be 'Disabled'
        $vault.desiredProperties.enableRbacAuthorization | Should -BeTrue
        $vault.desiredProperties.purgeProtectionEnabled | Should -BeTrue
        $script:Plan.resources.id |
            Should -Contain 'azure.network.private-dns-vnet-link.key-vault'
        $secret.desiredProperties.valueInPlan | Should -BeFalse
        $secret.desiredProperties.valueInState | Should -BeFalse
        $secretAction.operation | Should -Be 'reference'
        $secretAction.mutation | Should -BeFalse
        $secretAction.dependsOn |
            Should -Contain 'action.security.key-vault.primary'
        $script:Plan.resources.id |
            Should -Not -Contain 'azure.authorization.key-vault-secrets.deployment'
        $script:Plan.actions.id |
            Should -Not -Contain 'action.authorization.key-vault-secrets.deployment'
    }

    It 'records Bastion Basic network and cost-relevant shape explicitly' {
        $bastion = $script:Plan.resources |
            Where-Object id -EQ 'azure.network.bastion.primary'
        $publicIp = $script:Plan.resources |
            Where-Object id -EQ 'azure.network.public-ip.bastion'
        $subnet = $script:Plan.resources |
            Where-Object id -EQ 'azure.network.subnet.bastion'

        $bastion.desiredProperties.sku | Should -Be 'basic'
        $bastion.desiredProperties.vmPublicIpRequired | Should -BeFalse
        $publicIp.desiredProperties.sku | Should -Be 'Standard'
        $publicIp.desiredProperties.allocationMethod | Should -Be 'Static'
        $subnet.desiredProperties.addressPrefix | Should -Be '10.42.2.0/26'
    }

    It 'treats reused Key Vault and Bastion resources as non-mutating references' {
        $subscriptionId = '22222222-2222-4222-8222-222222222222'
        $diagnosticDestinationId =
            "/subscriptions/$subscriptionId/resourceGroups/rg-monitor/" +
            'providers/Microsoft.OperationalInsights/workspaces/law-adlt'
        $plan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -SecretStoreMode reuse-key-vault `
            -SecretStoreResourceId "/subscriptions/$subscriptionId/resourceGroups/rg-shared/providers/Microsoft.KeyVault/vaults/kv-shared" `
            -KeyVaultDiagnosticDestinationResourceId $diagnosticDestinationId `
            -VmAdministratorSecretVersion '0123456789abcdef0123456789abcdef' `
            -AdministrativeAccessMode reuse-bastion `
            -BastionResourceId "/subscriptions/$subscriptionId/resourceGroups/rg-shared/providers/Microsoft.Network/bastionHosts/bas-shared" `
            -AdministrativeAccessRationale 'Reuse the approved shared Bastion host.'

        foreach ($actionId in @(
            'action.security.key-vault.primary'
            'action.network.bastion.primary'
        )) {
            $action = $plan.actions | Where-Object id -EQ $actionId
            $action.operation | Should -Be 'reference'
            $action.mutation | Should -BeFalse
            $action.ownershipEffect | Should -Be 'intend-reused'
        }

        $plan.resources |
            Where-Object { $_.id -in @(
                'azure.security.key-vault.primary'
                'azure.network.bastion.primary'
            ) } |
            ForEach-Object {
                $_.ownership.expectedClassification | Should -Be 'reused'
                $_.ownership.teardownIntent | Should -Be 'retain'
        }
    }

    It 'does not accept a disk encryption set without wiring it into every managed disk' {
        $subscriptionId = '22222222-2222-4222-8222-222222222222'
        $diskEncryptionSetId = "/subscriptions/$subscriptionId/resourceGroups/rg-security/providers/Microsoft.Compute/diskEncryptionSets/des-lab"
        $plan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -DiskEncryptionSetResourceId $diskEncryptionSetId
        $diskEncryptionSet = $plan.resources |
            Where-Object id -EQ 'azure.compute.disk-encryption-set.external'
        $vm = $plan.resources |
            Where-Object id -EQ 'azure.compute.virtual-machine.primary'
        $vmAction = $plan.actions |
            Where-Object id -EQ 'action.compute.virtual-machine.primary'

        $diskEncryptionSet.externalResourceId |
            Should -BeExactly $diskEncryptionSetId
        $diskEncryptionSet.ownership.expectedClassification |
            Should -Be 'reused'
        $vm.desiredProperties.storageProfile.osDisk.encryption.type |
            Should -Be 'CustomerManaged'
        $vm.desiredProperties.storageProfile.dataDisks.diskEncryptionSetResourceId |
            Should -Not -Contain $null
        $vmAction.dependsOn |
            Should -Contain 'action.compute.disk-encryption-set.external'
        $plan.approval.requiredAcknowledgementIds |
            Should -Contain 'policy.compute.disk-encryption-set-unverified'
    }
}

Describe 'Azure Files backup capability graph' {
    BeforeAll {
        $script:BackupPlan = New-AzureDataLabPlan $script:BackupConfigurationPath
    }

    It 'plans private DNS, private endpoint, managed-identity authorization, and mount preparation' {
        $script:BackupPlan.resources.id |
            Should -Contain 'azure.network.private-dns-zone.backups'
        $script:BackupPlan.resources.id |
            Should -Contain 'azure.network.private-dns-vnet-link.backups'
        $script:BackupPlan.resources.id |
            Should -Contain 'azure.network.private-endpoint.backups'
        $script:BackupPlan.resources.id |
            Should -Contain 'azure.network.private-dns-zone-group.backups'
        $script:BackupPlan.resources.id |
            Should -Contain 'azure.authorization.file-share-smb.backups'

        $mount = $script:BackupPlan.actions |
            Where-Object id -EQ 'action.guest.mount-script.backups'
        $mount.postconditions | Should -Contain 'managed-identity-authentication-only'
        $mount.postconditions | Should -Contain 'storage-account-key-not-required'

        $storage = $script:BackupPlan.resources |
            Where-Object id -EQ 'azure.storage.account.backups'
        $role = $script:BackupPlan.resources |
            Where-Object id -EQ 'azure.authorization.file-share-smb.backups'
        $storage.desiredProperties.managedIdentitySmbOAuth | Should -BeTrue
        $storage.desiredProperties.sharedKeyAccess | Should -BeFalse
        $role.desiredProperties.roleDefinitionName |
            Should -Be 'Storage File Data SMB MI Admin'
        $role.desiredProperties.principalReference |
            Should -Match 'systemAssigned'
    }

    It 'separates offline rendering from remote mount and restore staging' {
        $mountRender = $script:BackupPlan.actions |
            Where-Object id -EQ 'action.guest.mount-script.backups'
        $mountStage = $script:BackupPlan.actions |
            Where-Object id -EQ 'action.guest.mount-script.stage.backups'
        $restore = $script:BackupPlan.actions |
            Where-Object id -EQ 'action.guest.restore-script.render.backups'

        $mountRender.dependsOn | Should -BeNullOrEmpty
        $restore.dependsOn | Should -BeNullOrEmpty
        $mountRender.executionScope | Should -Be 'offline'
        $restore.executionScope | Should -Be 'offline'
        $mountRender.preconditions | Should -Not -Contain 'live-state-observed'
        $restore.preconditions | Should -Not -Contain 'live-state-observed'
        $restore.postconditions | Should -Contain 'manual-restore-required'
        $restore.mutation | Should -BeFalse
        $mountStage.dependsOn |
            Should -Contain 'action.guest.mount-script.backups'
        $mountStage.executionScope | Should -Be 'guest'
        $mountStage.postconditions |
            Should -Contain 'az-files-smb-mi-client-installed-and-verified'

        $stage = $script:BackupPlan.actions |
            Where-Object id -EQ 'action.guest.restore-script.stage.backups'
        $stage.dependsOn | Should -Contain 'action.guest.restore-script.render.backups'
        $stage.dependsOn | Should -Contain 'action.guest.mount-script.stage.backups'
        $stage.dependsOn | Should -Contain 'action.catalog.stage.software.dbatools'
        $stage.postconditions |
            Should -Contain 'remote-staging-requires-approved-engine'
        $script:BackupPlan.approval.blockingFindingIds |
            Should -Contain 'policy.backup-share.smb-oauth-client-unavailable'
    }
}

Describe 'Terminal UI handoff contract' {
    It 'keeps software and sample-data selections in separate typed collections' {
        $selection = [ordered]@{
            schemaVersion = '1.0'
            kind          = 'AzureDataLabTuiSelection'
            template      = 'sqlvm-secure'
            softwareIds   = @('software.dbatools')
            sampleDataIds = @('sample-data.adventureworks-2022')
            overrides     = [ordered]@{
                securityType    = 'trustedLaunch'
                enableBackupShare = $true
            }
        }
        $schemaPath = Join-Path `
            $script:RepositoryRoot `
            'src/AzureDataLabToolkit/Schemas/tui-selection.schema.json'

        Test-Json `
            -Json ($selection | ConvertTo-Json -Depth 20 -Compress) `
            -SchemaFile $schemaPath |
            Should -BeTrue
    }
}
