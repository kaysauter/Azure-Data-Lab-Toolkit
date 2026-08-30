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
