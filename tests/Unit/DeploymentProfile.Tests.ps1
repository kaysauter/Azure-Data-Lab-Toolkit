BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:CanaryPath = Join-Path `
        $script:RepositoryRoot `
        'examples/sqlvm-first-canary.yaml'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:Module = Get-Module AzureDataLabToolkit
}

Describe 'Versioned SQL VM deployment profile' {
    It 'is schema-valid, hashed, and bound to the deployable example' {
        $profile = & $script:Module {
            Get-AdltDeploymentProfile -Id 'sqlvm-first-canary/v1'
        }
        $configuration = & $script:Module {
            param($Path)
            (Resolve-AdltConfiguration `
                -Path $Path `
                -Overrides ([ordered]@{})).Configuration
        } $script:CanaryPath

        $profile.kind | Should -BeExactly 'AzureDataLabDeploymentProfile'
        $profile.profileHash | Should -Match '^sha256:[a-f0-9]{64}$'
        $configuration.deploymentProfile.id |
            Should -BeExactly $profile.id
        $configuration.deploymentProfile.hash |
            Should -BeExactly $profile.profileHash
        $configuration.template |
            Should -BeExactly $profile.template
    }

    It 'proves static eligibility and deterministic plan identity' {
        $first = Test-AzureDataLabDeploymentConfiguration `
            -Path $script:CanaryPath
        $second = Test-AzureDataLabDeploymentConfiguration `
            -Path $script:CanaryPath

        $first.Eligible | Should -BeTrue
        $first.RequiresAzurePreflight | Should -BeTrue
        $first.PlanHash | Should -BeExactly $second.PlanHash
        $first.IntentHash | Should -BeExactly $second.IntentHash
        $first.RequiredLiveChecks | Should -Contain 'native-arm-what-if'
        $first.RequiredLiveChecks | Should -Contain 'teardown-preview'
    }

    It 'rejects a stale profile hash before Azure access' {
        $configuration = & $script:Module {
            param($Path)
            (Resolve-AdltConfiguration `
                -Path $Path `
                -Overrides ([ordered]@{})).Configuration
        } $script:CanaryPath
        $configuration.deploymentProfile.hash =
            'sha256:' + ('f' * 64)

        $result = Test-AzureDataLabDeploymentConfiguration `
            -InputObject $configuration

        $result.Eligible | Should -BeFalse
        $result.Errors -join ' ' | Should -Match 'profile hash is stale'
    }

    It 'does not confuse generic configuration validity with deployability' {
        $minimalPath = Join-Path `
            $script:RepositoryRoot `
            'examples/sqlvm-minimal.yaml'

        (Test-AzureDataLabConfiguration -Path $minimalPath).Valid |
            Should -BeTrue
        $deployment = Test-AzureDataLabDeploymentConfiguration `
            -Path $minimalPath

        $deployment.Eligible | Should -BeFalse
        $deployment.Errors -join ' ' |
            Should -Match 'versioned deploymentProfile binding'
    }

    It 'rejects catalog payloads from the deployable canary profile' {
        $configuration = & $script:Module {
            param($Path)
            (Resolve-AdltConfiguration `
                -Path $Path `
                -Overrides ([ordered]@{})).Configuration
        } $script:CanaryPath
        $configuration.sqlVm.software.catalogIds = @(
            'software.git-for-windows'
        )

        $result = Test-AzureDataLabDeploymentConfiguration `
            -InputObject $configuration

        $result.Eligible | Should -BeFalse
        $result.Errors -join ' ' |
            Should -Match 'sqlVm.software.catalogIds.*empty'
    }
}
