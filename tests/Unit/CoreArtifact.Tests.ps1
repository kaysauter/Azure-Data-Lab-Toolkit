BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

Describe 'Generic artifact integrity' {
    It 'calculates a self hash without including the hash property' {
        InModuleScope AzureDataLabToolkit {
            $artifact = [ordered]@{
                schemaVersion = '1.0'
                kind          = 'TestArtifact'
                value         = 'stable'
            }
            $artifact.artifactHash = Get-AdltArtifactHash `
                -Artifact $artifact `
                -HashProperty 'artifactHash'
            $firstHash = $artifact.artifactHash

            Get-AdltArtifactHash `
                -Artifact $artifact `
                -HashProperty 'artifactHash' |
                Should -BeExactly $firstHash
        }
    }

    It 'rejects a changed artifact' {
        InModuleScope AzureDataLabToolkit {
            $artifact = [ordered]@{
                schemaVersion = '1.0'
                kind          = 'TestArtifact'
                value         = 'before'
            }
            $artifact.artifactHash = Get-AdltArtifactHash `
                -Artifact $artifact `
                -HashProperty 'artifactHash'
            $artifact.value = 'after'

            {
                Assert-AdltArtifactHash `
                    -Artifact $artifact `
                    -HashProperty 'artifactHash' `
                    -ArtifactName 'test artifact'
            } | Should -Throw -ExpectedMessage '*has changed*'
        }
    }

    It 'rejects oversized JSON before allocating its contents' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            OversizedPath = Join-Path $TestDrive 'oversized.json'
        } {
            param($OversizedPath)

            $stream = [System.IO.File]::OpenWrite($OversizedPath)
            try {
                $stream.SetLength(
                    $script:AzureDataLabToolkitMaximumJsonBytes + 1
                )
            }
            finally {
                $stream.Dispose()
            }

            {
                Read-AdltJsonFile -Path $OversizedPath
            } | Should -Throw '*oversized*'
        }
    }
}

Describe 'Complete plan contract verification' {
    BeforeAll {
        $configurationPath = Join-Path `
            $script:RepositoryRoot `
            'examples/sqlvm-minimal.yaml'
        $script:VerifiedPlan = New-AzureDataLabPlan $configurationPath
    }

    It 'accepts a generated plan with a reconstructed intent hash' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            Plan = $script:VerifiedPlan
        } {
            {
                Assert-AdltPlanContract -Plan $Plan
            } | Should -Not -Throw
        }
    }

    It 'rejects a recomputed plan hash when the intent hash is forged' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            Plan = $script:VerifiedPlan
        } {
            $forged = Copy-AdltValue -InputObject $Plan
            $forged.intentHash = "sha256:$('f' * 64)"
            foreach ($action in @($forged.actions)) {
                $action.idempotencyKey = 'adlt:v1:{0}:{1}' -f
                    $forged.intentHash,
                    $action.id
            }
            $forged.planHash = Get-AdltPlanHash -Plan $forged

            {
                Assert-AdltPlanContract -Plan $forged
            } | Should -Throw -ExpectedMessage '*intent hash verification failed*'
        }
    }
}

Describe 'Plan report distribution boundary' {
    BeforeAll {
        $script:MinimalConfigurationPath = Join-Path `
            $script:RepositoryRoot `
            'examples/sqlvm-minimal.yaml'
    }

    It 'refuses to render a plan that carries a literal secret' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            ConfigurationPath = $script:MinimalConfigurationPath
            ExportPath        = Join-Path $TestDrive 'leaking-plan.json'
        } {
            param($ConfigurationPath, $ExportPath)

            $leaking = Copy-AdltValue -InputObject (
                New-AzureDataLabPlan $ConfigurationPath
            )
            $leaking.resources[0].desiredProperties.password =
                'Contoso-Literal-Secret-1'
            $leaking.planHash = Get-AdltPlanHash -Plan $leaking

            # The hash is honest, so the pre-existing gate is satisfied and
            # only the secret-free boundary can stop the export.
            { Assert-AdltPlanHash -Plan $leaking } | Should -Not -Throw

            foreach ($format in 'Json', 'Markdown', 'Html') {
                {
                    Export-AzureDataLabPlan $leaking -Format $format
                } | Should -Throw -ExpectedMessage (
                    "*Secret values are forbidden in plan. Remove field " +
                    "'resources*desiredProperties.password' and use a " +
                    'secret reference.*'
                )
            }

            {
                Export-AzureDataLabPlan `
                    -Plan $leaking `
                    -Format Json `
                    -Path $ExportPath
            } | Should -Throw -ExpectedMessage '*Secret values are forbidden*'
            Test-Path -LiteralPath $ExportPath | Should -BeFalse
        }
    }

    It 'still exports a clean plan to stdout and to a path' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $exportPath = Join-Path $TestDrive 'clean-plan.json'

        Export-AzureDataLabPlan $plan -Format Json |
            Should -Match '"planHash":'
        Export-AzureDataLabPlan $plan -Format Json -Path $exportPath |
            Should -Be ([System.IO.Path]::GetFullPath($exportPath))
        Get-Content -LiteralPath $exportPath -Raw |
            Should -Match '"planHash":'
    }
}
