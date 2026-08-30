BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:MinimalConfigurationPath = Join-Path $script:RepositoryRoot 'examples/sqlvm-minimal.yaml'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    function New-TestConfiguration {
        return [ordered]@{
            schemaVersion = '1.0'
            kind          = 'AzureDataLab'
            template      = 'sqlvm-secure'
            metadata      = [ordered]@{
                name = 'test-lab'
            }
            target        = [ordered]@{
                type = 'sqlVm'
            }
            azure         = [ordered]@{
                cloud          = 'AzureCloud'
                tenantId       = '11111111-1111-4111-8111-111111111111'
                subscriptionId = '22222222-2222-4222-8222-222222222222'
                location       = 'eastus'
                resourceGroup  = [ordered]@{
                    mode = 'create'
                    name = 'rg-adlt-test'
                }
            }
        }
    }

    function Write-TestYaml {
        param(
            [Parameter(Mandatory)]
            [string] $Name,

            [Parameter(Mandatory)]
            [string] $Content
        )

        $path = Join-Path $TestDrive $Name
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8NoBOM
        return $path
    }
}

Describe 'Configuration resolution' {
    It 'validates the minimal example without Azure access' {
        $result = Test-AzureDataLabConfiguration $script:MinimalConfigurationPath
        $result.Valid | Should -BeTrue
        $result.Errors | Should -BeNullOrEmpty
        $result.PlanHash | Should -Match '^sha256:[a-f0-9]{64}$'
    }

    It 'applies defaults, template, YAML, and flags in that order' {
        $configuration = New-TestConfiguration
        $plan = New-AzureDataLabPlan `
            -InputObject $configuration `
            -Name 'flag-lab' `
            -Location 'westus2'

        $plan.configuration.metadata.name | Should -Be 'flag-lab'
        $plan.configuration.azure.location | Should -Be 'westus2'
        $plan.configuration.azure.authentication.mode | Should -Be 'interactive-user'
        $plan.configuration.security.secretStore.mode | Should -Be 'deploy-key-vault'

        $plan.provenance['metadata.name'].source | Should -Be 'flag:metadata.name'
        $plan.provenance['azure.location'].source | Should -Be 'flag:azure.location'
        $plan.provenance['azure.authentication.mode'].source | Should -Be 'schema-default'
        $plan.provenance['security.secretStore.mode'].source | Should -Be 'template:sqlvm-secure'
    }

    It 'records the explicitly selected template rather than a conflicting YAML label' {
        $configuration = New-TestConfiguration
        $configuration.template = 'different-template'

        $plan = New-AzureDataLabPlan `
            -InputObject $configuration `
            -Template sqlvm-secure

        $plan.configuration.template | Should -Be 'sqlvm-secure'
        $plan.provenance.template.source | Should -Be 'flag:template'
    }

    It 'records value, type, source, derivation, and validation for every resolved leaf' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $leafPaths = @($plan.provenance.Keys)

        $leafPaths.Count | Should -BeGreaterThan 20
        foreach ($path in $leafPaths) {
            $entry = $plan.provenance[$path]
            $entry.Contains('value') | Should -BeTrue
            $entry.type | Should -Not -BeNullOrEmpty
            $entry.source | Should -Not -BeNullOrEmpty
            $entry.derivation | Should -Not -BeNullOrEmpty
            $entry.validation | Should -Be 'schema-valid'
        }
    }

    It 'makes generated credentials and shell output separate explicit opt-ins' {
        {
            New-AzureDataLabPlan $script:MinimalConfigurationPath -ShowGeneratedPassword
        } | Should -Throw -ExpectedMessage '*only be requested with generate-during-deployment*'

        $plan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -GeneratePassword `
            -ShowGeneratedPassword

        $plan.decisions.vmAdministratorCredential.source | Should -Be 'generate-during-deployment'
        $plan.decisions.vmAdministratorCredential.allowShellOutput | Should -BeTrue
        $plan.warnings -join ' ' | Should -Match 'terminal history'
    }

    It 'adds bounded runtime and TTL defaults to every resolved configuration' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath

        $plan.configuration.metadata.purpose | Should -Be 'lab'
        $plan.configuration.lifecycle.maximumRuntimeMinutes | Should -Be 180
        $plan.configuration.lifecycle.timeToLiveMinutes | Should -Be 240
        $plan.configuration.lifecycle.expiryBehavior | Should -Be 'cleanup-only'
        $plan.configuration.lifecycle.teardown.mode | Should -Be 'explicit'
    }

    It 'requires TTL to cover the complete maximum runtime' {
        {
            New-AzureDataLabPlan `
                $script:MinimalConfigurationPath `
                -MaximumRuntimeMinutes 240 `
                -TimeToLiveMinutes 180
        } | Should -Throw -ExpectedMessage '*timeToLiveMinutes must be greater than or equal*'
    }

    It 'accepts preauthorized teardown only for a bounded non-sensitive canary' {
        {
            New-AzureDataLabPlan `
                $script:MinimalConfigurationPath `
                -PreauthorizeTeardown
        } | Should -Throw -ExpectedMessage "*requires metadata.purpose 'canary'*"

        $plan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -Purpose canary `
            -CostEstimate `
            -MaximumRunCostMinorUnits 2500 `
            -MaximumRuntimeMinutes 180 `
            -TimeToLiveMinutes 240 `
            -PreauthorizeTeardown `
            -DeleteBackupShareOnTeardown

        $plan.configuration.metadata.purpose | Should -Be 'canary'
        $plan.configuration.cost.maximumRunCost.amountMinorUnits | Should -Be 2500
        $plan.configuration.cost.maximumRunCost.currency | Should -Be 'USD'
        $plan.configuration.lifecycle.teardown.mode |
            Should -Be 'preauthorized-canary'
        $plan.configuration.lifecycle.teardown.retainBackupShare |
            Should -BeFalse
    }

    It 'rejects sensitive data and retained storage in a preauthorized canary' {
        {
            New-AzureDataLabPlan `
                $script:MinimalConfigurationPath `
                -Purpose canary `
                -ContainsSensitiveData `
                -CostEstimate `
                -MaximumRunCostMinorUnits 2500 `
                -PreauthorizeTeardown `
                -DeleteBackupShareOnTeardown
        } | Should -Throw -ExpectedMessage '*cannot contain sensitive data*'

        {
            New-AzureDataLabPlan `
                $script:MinimalConfigurationPath `
                -Purpose canary `
                -CostEstimate `
                -MaximumRunCostMinorUnits 2500 `
                -PreauthorizeTeardown
        } | Should -Throw -ExpectedMessage '*cannot retain its backup share*'
    }

    It 'rejects secret values without echoing the value' {
        $configuration = New-TestConfiguration
        $configuration.security = [ordered]@{
            password = 'NeverEchoThisValue!'
        }

        $result = Test-AzureDataLabConfiguration -InputObject $configuration
        $result.Valid | Should -BeFalse
        $result.Errors -join ' ' | Should -Match 'Secret values are forbidden'
        $result.Errors -join ' ' | Should -Not -Match 'NeverEchoThisValue'
    }

    It 'rejects sensitive values hidden under benign field names' {
        $sensitiveValues = @(
            'Password=NeverEchoThisValue!'
            'https://account.blob.core.windows.net/backups/db.bak?sv=2025-01-05&sp=r&sig=NeverEchoThisSignature'
            '-----BEGIN PRIVATE KEY----- NeverEchoThisKey'
            'Bearer NeverEchoThisBearerToken12345'
        )

        foreach ($sensitiveValue in $sensitiveValues) {
            $configuration = New-TestConfiguration
            $configuration.metadata.description = $sensitiveValue

            $result = Test-AzureDataLabConfiguration `
                -InputObject $configuration

            $result.Valid | Should -BeFalse
            $result.Errors -join ' ' |
                Should -Match 'Sensitive value pattern'
            $result.Errors -join ' ' |
                Should -Not -Match 'NeverEchoThis'
        }
    }

    It 'accepts normal resource IDs, documentation URLs, and hash strings' {
        $configuration = New-TestConfiguration
        $configuration.metadata.description = (
            'See https://learn.microsoft.com/azure/azure-resource-manager/' +
            'management/resource-name-rules?view=azure-resource-manager. ' +
            'Resource /subscriptions/22222222-2222-4222-8222-222222222222/' +
            'resourceGroups/rg-adlt-test uses ' +
            "sha256:$('a' * 64)."
        )

        $result = Test-AzureDataLabConfiguration `
            -InputObject $configuration

        $result.Valid | Should -BeTrue
        $result.Errors | Should -BeNullOrEmpty
    }

    It 'requires reused resource-group identity to match the Azure context' {
        $subscriptionId = '22222222-2222-4222-8222-222222222222'
        $configuration = New-TestConfiguration
        $configuration.azure.resourceGroup.mode = 'reuse'

        (Test-AzureDataLabConfiguration -InputObject $configuration).Errors -join ' ' |
            Should -Match 'resourceId is required'

        $configuration.azure.resourceGroup.resourceId =
            '/subscriptions/33333333-3333-4333-8333-333333333333/resourceGroups/rg-adlt-test'
        (Test-AzureDataLabConfiguration -InputObject $configuration).Errors -join ' ' |
            Should -Match 'must belong to azure.subscriptionId'

        $configuration.azure.resourceGroup.resourceId =
            "/subscriptions/$subscriptionId/resourceGroups/rg-different"
        (Test-AzureDataLabConfiguration -InputObject $configuration).Errors -join ' ' |
            Should -Match 'must identify azure.resourceGroup.name'

        $expectedResourceId =
            "/subscriptions/$subscriptionId/resourceGroups/rg-adlt-test"
        $configuration.azure.resourceGroup.resourceId = $expectedResourceId
        $plan = New-AzureDataLabPlan -InputObject $configuration
        $plannedResourceGroup = $plan.resources |
            Where-Object id -EQ 'azure.resource-group.primary'

        $plannedResourceGroup.externalResourceId |
            Should -BeExactly $expectedResourceId
        $plannedResourceGroup.ownership.expectedClassification |
            Should -Be 'reused'
    }

    It 'rejects a resource-group ID on create intent' {
        $configuration = New-TestConfiguration
        $configuration.azure.resourceGroup.resourceId =
            '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-adlt-test'

        (Test-AzureDataLabConfiguration -InputObject $configuration).Errors -join ' ' |
            Should -Match 'cannot be set when mode is create'
    }

    It 'rejects resource IDs whose Azure type or subscription is wrong' {
        $subscriptionId = '22222222-2222-4222-8222-222222222222'
        $otherSubscriptionId = '33333333-3333-4333-8333-333333333333'
        $configuration = New-TestConfiguration
        $configuration.security = [ordered]@{
            secretStore = [ordered]@{
                mode       = 'reuse-key-vault'
                resourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-shared/providers/Microsoft.Storage/storageAccounts/not-a-vault"
                diagnosticDestinationResourceId =
                    "/subscriptions/$subscriptionId/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/law-adlt"
            }
        }

        (Test-AzureDataLabConfiguration -InputObject $configuration).Errors -join ' ' |
            Should -Match 'Microsoft.KeyVault/vaults'

        $configuration.security.secretStore.resourceId =
            "/subscriptions/$otherSubscriptionId/resourceGroups/rg-shared/providers/Microsoft.KeyVault/vaults/kv-shared"
        (Test-AzureDataLabConfiguration -InputObject $configuration).Errors -join ' ' |
            Should -Match 'must belong to azure.subscriptionId'
    }

    It 'requires an immutable secret version when reusing a Key Vault secret' {
        $subscriptionId = '22222222-2222-4222-8222-222222222222'
        $vaultId = (
            "/subscriptions/$subscriptionId/resourceGroups/rg-shared/" +
            'providers/Microsoft.KeyVault/vaults/kv-shared'
        )
        $diagnosticDestinationId = (
            "/subscriptions/$subscriptionId/resourceGroups/rg-monitor/" +
            'providers/Microsoft.OperationalInsights/workspaces/law-adlt'
        )

        {
            New-AzureDataLabPlan `
                $script:MinimalConfigurationPath `
                -SecretStoreMode reuse-key-vault `
                -SecretStoreResourceId $vaultId `
                -KeyVaultDiagnosticDestinationResourceId `
                    $diagnosticDestinationId
        } | Should -Throw -ExpectedMessage '*secretVersion is required*'

        $plan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -SecretStoreMode reuse-key-vault `
            -SecretStoreResourceId $vaultId `
            -KeyVaultDiagnosticDestinationResourceId `
                $diagnosticDestinationId `
            -VmAdministratorSecretVersion `
                '0123456789abcdef0123456789abcdef'

        $plan.configuration.security.vmAdministratorCredential.secretVersion |
            Should -BeExactly '0123456789abcdef0123456789abcdef'
    }

    It 'rejects a secret version for generated or newly deployed credentials' {
        {
            New-AzureDataLabPlan `
                $script:MinimalConfigurationPath `
                -GeneratePassword `
                -VmAdministratorSecretVersion `
                    '0123456789abcdef0123456789abcdef'
        } | Should -Throw -ExpectedMessage '*cannot be set*generated*'

        {
            New-AzureDataLabPlan `
                $script:MinimalConfigurationPath `
                -VmAdministratorSecretVersion `
                    '0123456789abcdef0123456789abcdef'
        } | Should -Throw -ExpectedMessage '*can only be set*reusing*'
    }

    It 'requires a rationale and a typed ID when Bastion is reused' {
        $subscriptionId = '22222222-2222-4222-8222-222222222222'
        $configuration = New-TestConfiguration
        $configuration.security = [ordered]@{
            administrativeAccess = [ordered]@{
                mode       = 'reuse-bastion'
                sku        = 'basic'
                resourceId = "/subscriptions/$subscriptionId/resourceGroups/rg-shared/providers/Microsoft.Network/bastionHosts/bas-shared"
            }
        }

        (Test-AzureDataLabConfiguration -InputObject $configuration).Errors -join ' ' |
            Should -Match 'rationale is required'

        $configuration.security.administrativeAccess.Add(
            'rationale',
            'Reuse the approved shared Bastion host.'
        )
        (Test-AzureDataLabConfiguration -InputObject $configuration).Valid |
            Should -BeTrue
    }

    It 'rejects a Bastion resource ID when administrative access is opted out' {
        $configuration = New-TestConfiguration
        $configuration.security = [ordered]@{
            administrativeAccess = [ordered]@{
                mode       = 'opt-out'
                sku        = 'basic'
                rationale  = 'Administrative access is intentionally disabled.'
                resourceId = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-shared/providers/Microsoft.Network/bastionHosts/bas-shared'
            }
        }

        (Test-AzureDataLabConfiguration -InputObject $configuration).Errors -join ' ' |
            Should -Match 'cannot be set when mode is opt-out'
    }
}

Describe 'Hostile or ambiguous YAML rejection' {
    It 'rejects duplicate mapping keys' {
        $path = Write-TestYaml -Name 'duplicate.yaml' -Content @'
schemaVersion: "1.0"
kind: AzureDataLab
metadata:
  name: first
  name: second
target:
  type: sqlVm
azure: {}
'@
        (Test-AzureDataLabConfiguration $path).Errors -join ' ' | Should -Match 'Duplicate key'
    }

    It 'rejects anchors and aliases' {
        $path = Write-TestYaml -Name 'alias.yaml' -Content @'
schemaVersion: "1.0"
kind: AzureDataLab
metadata: &metadata
  name: alias-lab
target:
  type: sqlVm
azure:
  copied: *metadata
'@
        (Test-AzureDataLabConfiguration $path).Errors -join ' ' | Should -Match 'anchors and aliases'
    }

    It 'rejects explicit YAML tags' {
        $path = Write-TestYaml -Name 'tag.yaml' -Content @'
schemaVersion: "1.0"
kind: AzureDataLab
metadata:
  name: !custom tagged-lab
target:
  type: sqlVm
azure: {}
'@
        (Test-AzureDataLabConfiguration $path).Errors -join ' ' | Should -Match 'tags are not allowed'
    }

    It 'rejects multiple YAML documents' {
        $path = Write-TestYaml -Name 'multiple.yaml' -Content @'
schemaVersion: "1.0"
kind: AzureDataLab
metadata:
  name: first
target:
  type: sqlVm
azure: {}
---
schemaVersion: "1.0"
kind: AzureDataLab
'@
        (Test-AzureDataLabConfiguration $path).Errors -join ' ' | Should -Match 'exactly one YAML document'
    }

    It 'rejects unknown keys through the resolved schema' {
        $configuration = New-TestConfiguration
        $configuration.unexpected = 'not-allowed'
        $result = Test-AzureDataLabConfiguration -InputObject $configuration

        $result.Valid | Should -BeFalse
        $result.Errors -join ' ' | Should -Match 'schema validation failed'
    }
}

Describe 'Fail-closed capability selection' {
    It 'rejects deployment engines that are not in the first plan contract' {
        {
            New-AzureDataLabPlan $script:MinimalConfigurationPath -Engine bicep
        } | Should -Throw -ExpectedMessage "*does not support engine 'bicep'*"
    }

    It 'rejects unproven confidential VM planning rather than downgrading' {
        {
            New-AzureDataLabPlan $script:MinimalConfigurationPath -VmSecurityType confidentialVm
        } | Should -Throw -ExpectedMessage "*does not support securityType 'confidentialVm'*"
    }

    It 'rejects Bastion tiers whose resource shape is not implemented' {
        {
            New-AzureDataLabPlan $script:MinimalConfigurationPath -BastionSku standard
        } | Should -Throw -ExpectedMessage "*does not support bastionSku 'standard'*"
    }

    It 'refuses database replacement in the first restore contract' {
        $configuration = New-TestConfiguration
        $configuration.solutionPacks = [ordered]@{
            sqlVmBackupRestore = [ordered]@{
                enabled                 = $true
                replaceExistingDatabase = $true
            }
        }

        $result = Test-AzureDataLabConfiguration -InputObject $configuration
        $result.Valid | Should -BeFalse
        $result.Errors -join ' ' | Should -Match 'replacement is refused'
    }
}
