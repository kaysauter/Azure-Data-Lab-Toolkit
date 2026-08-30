BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:BuildScript = Join-Path $script:RepositoryRoot 'build.ps1'
    $script:SourceManifest = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:BuiltModuleRoot = Join-Path `
        $script:RepositoryRoot `
        'out/module/AzureDataLabToolkit/0.1.0'
    $script:PackagePath = Join-Path `
        $script:RepositoryRoot `
        'out/packages/AzureDataLabToolkit-0.1.0-alpha1.zip'
    $script:AuthorizationSchemaPath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/Schemas/execution-authorization.schema.json'
    $script:PowerShellYamlRoot = (
        Get-Module `
            -ListAvailable `
            -FullyQualifiedName @{
                ModuleName = 'powershell-yaml'
                RequiredVersion = '0.4.12'
                Guid = '6a75a662-7f53-425a-9777-ee61284407da'
            } |
            Select-Object -First 1
    ).ModuleBase

    function Expand-TestPackagedModule {
        param(
            [Parameter(Mandatory)]
            [string] $Name
        )

        $target = Join-Path $TestDrive $Name
        Expand-Archive `
            -LiteralPath $script:PackagePath `
            -DestinationPath $target `
            -Force
        return Join-Path $target 'AzureDataLabToolkit/0.1.0'
    }

    function Import-TestModule {
        param(
            [Parameter(Mandatory)]
            [string] $ModuleRoot
        )

        Remove-Module AzureDataLabToolkit -Force -ErrorAction SilentlyContinue
        Import-Module `
            (Join-Path $ModuleRoot 'AzureDataLabToolkit.psd1') `
            -Force `
            -ErrorAction Stop
        return Get-Module AzureDataLabToolkit
    }

    & $script:BuildScript -Task Package
}

AfterAll {
    Remove-Module AzureDataLabToolkit -Force -ErrorAction SilentlyContinue
}

Describe 'Runtime module build provenance' {
    It 'is deterministic across equivalent package builds' {
        $first = [System.IO.File]::ReadAllText(
            (Join-Path $script:BuiltModuleRoot 'build-provenance.json')
        )

        & $script:BuildScript -Task Build

        $second = [System.IO.File]::ReadAllText(
            (Join-Path $script:BuiltModuleRoot 'build-provenance.json')
        )
        $second | Should -BeExactly $first
    }

    It 'authorizes an extracted module without Git metadata' {
        $moduleRoot = Expand-TestPackagedModule -Name 'installed-module'
        $candidate = [System.IO.DirectoryInfo]::new($moduleRoot)
        while ($null -ne $candidate) {
            Test-Path -LiteralPath (Join-Path $candidate.FullName '.git') |
                Should -BeFalse
            $candidate = $candidate.Parent
        }

        $module = Import-TestModule -ModuleRoot $moduleRoot
        $identity = & $module {
            Get-AdltRuntimeIdentity
        }

        $identity.module.name | Should -BeExactly 'AzureDataLabToolkit'
        $identity.module.version | Should -BeExactly '0.1.0-alpha1'
        $identity.module.digest |
            Should -Match '^sha256:[a-f0-9]{64}$'
        $identity.module.revisionKind |
            Should -BeIn @('git', 'content-derived')
        $identity.commit |
            Should -Match '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'
    }

    It 'produces an authorization-schema-valid runtime identity' {
        $moduleRoot = Expand-TestPackagedModule `
            -Name 'schema-valid-module'
        $module = Import-TestModule -ModuleRoot $moduleRoot
        $identity = & $module {
            Get-AdltRuntimeIdentity
        }
        $authorizationSchema = Get-Content `
            -LiteralPath $script:AuthorizationSchemaPath `
            -Raw |
            ConvertFrom-Json -AsHashtable
        $identitySchema = [ordered]@{
            '$schema' = 'https://json-schema.org/draft/2020-12/schema'
            type = 'object'
            additionalProperties = $false
            required = @('module', 'commit', 'runtime')
            properties = [ordered]@{
                module = $authorizationSchema.properties.module
                commit = $authorizationSchema.properties.commit
                runtime = $authorizationSchema.properties.runtime
            }
            '$defs' = $authorizationSchema['$defs']
        }
        $identityArtifact = [ordered]@{
            module = $identity.module
            commit = $identity.commit
            runtime = [ordered]@{
                powershell = $identity.powershell
                dependencies = @($identity.dependencies)
            }
        }
        $identitySchemaPath = Join-Path `
            $TestDrive `
            'runtime-identity.schema.json'
        $identitySchema |
            ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $identitySchemaPath

        Test-Json `
            -Json (
                $identityArtifact |
                    ConvertTo-Json -Depth 100 -Compress
            ) `
            -SchemaFile $identitySchemaPath |
            Should -BeTrue
    }

    It 'validates packaged provenance through the source trust boundary' {
        $provenance = Get-Content `
            -LiteralPath (
                Join-Path $script:BuiltModuleRoot 'build-provenance.json'
            ) `
            -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $module = Import-TestModule -ModuleRoot (
            Split-Path $script:SourceManifest -Parent
        )

        {
            & $module {
                param($Candidate)

                Assert-AdltBuildProvenanceShape -Provenance $Candidate
            } $provenance
        } | Should -Not -Throw

        $contentDerived = $provenance |
            ConvertTo-Json -Depth 100 -Compress |
            ConvertFrom-Json -AsHashtable -Depth 100
        $contentDerived.sourceRevisionKind = 'content-derived'
        $contentDerived.sourceRevision =
            ([string] $contentDerived.aggregateDigest).Substring(
                'sha256:'.Length
            )
        {
            & $module {
                param($Candidate)

                Assert-AdltBuildProvenanceShape -Provenance $Candidate
            } $contentDerived
        } | Should -Not -Throw

        $pathEscape = $provenance |
            ConvertTo-Json -Depth 100 -Compress |
            ConvertFrom-Json -AsHashtable -Depth 100
        $pathEscape.files[0].path = '../escape.ps1'
        {
            & $module {
                param($Candidate)

                Assert-AdltBuildProvenanceShape -Provenance $Candidate
            } $pathEscape
        } | Should -Throw '*invalid file entry*'
    }

    It 'verifies the complete built package with the source trust code' {
        $module = Import-TestModule -ModuleRoot (
            Split-Path $script:SourceManifest -Parent
        )
        $identity = & $module {
            param($BuiltModuleRoot)

            $previousRoot = $script:AzureDataLabToolkitRoot
            $previousRequirement =
                $script:AzureDataLabToolkitBuildProvenanceRequired
            try {
                $script:AzureDataLabToolkitRoot = $BuiltModuleRoot
                $script:AzureDataLabToolkitBuildProvenanceRequired = $true
                Get-AdltVerifiedRuntimeModuleContent
            }
            finally {
                $script:AzureDataLabToolkitRoot = $previousRoot
                $script:AzureDataLabToolkitBuildProvenanceRequired =
                    $previousRequirement
            }
        } $script:BuiltModuleRoot

        $identity.module.name | Should -BeExactly 'AzureDataLabToolkit'
        $identity.module.version | Should -BeExactly '0.1.0-alpha1'
        $identity.module.digest | Should -Match '^sha256:[a-f0-9]{64}$'
        $identity.module.revisionKind |
            Should -BeIn @('git', 'content-derived')
        $identity.sourceRevision |
            Should -Match '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'
    }

    It 'rejects malformed provenance at each structural trust gate' {
        $provenance = Get-Content `
            -LiteralPath (
                Join-Path $script:BuiltModuleRoot 'build-provenance.json'
            ) `
            -Raw |
            ConvertFrom-Json -AsHashtable -Depth 100
        $module = Import-TestModule -ModuleRoot (
            Split-Path $script:SourceManifest -Parent
        )
        $cases = @(
            [ordered]@{
                pattern = '*invalid property set*'
                mutate  = {
                    param($Candidate)
                    [void] $Candidate.Remove('selfHash')
                }
            }
            [ordered]@{
                pattern = '*metadata is invalid*'
                mutate  = {
                    param($Candidate)
                    $Candidate.moduleVersion = '0.1.1'
                }
            }
            [ordered]@{
                pattern = '*source revision kind is invalid*'
                mutate  = {
                    param($Candidate)
                    $Candidate.sourceRevisionKind = 'branch'
                }
            }
            [ordered]@{
                pattern = '*Git revision is invalid*'
                mutate  = {
                    param($Candidate)
                    $Candidate.sourceRevisionKind = 'git'
                    $Candidate.sourceRevision = 'main'
                }
            }
            [ordered]@{
                pattern = '*content-derived revision is invalid*'
                mutate  = {
                    param($Candidate)
                    $Candidate.sourceRevisionKind = 'content-derived'
                    $Candidate.sourceRevision = '0' * 64
                }
            }
            [ordered]@{
                pattern = '*file manifest is empty or invalid*'
                mutate  = {
                    param($Candidate)
                    $Candidate.files = @()
                }
            }
            [ordered]@{
                pattern = '*invalid file entry*'
                mutate  = {
                    param($Candidate)
                    $Candidate.files = @('not-a-file-entry')
                }
            }
            [ordered]@{
                pattern = '*file paths are not uniquely sorted*'
                mutate  = {
                    param($Candidate)
                    $Candidate.files[1].path = $Candidate.files[0].path
                }
            }
        )

        foreach ($case in $cases) {
            $candidate = $provenance |
                ConvertTo-Json -Depth 100 -Compress |
                ConvertFrom-Json -AsHashtable -Depth 100
            & $case.mutate $candidate
            {
                & $module {
                    param($Candidate)

                    Assert-AdltBuildProvenanceShape -Provenance $Candidate
                } $candidate
            } | Should -Throw $case.pattern
        }
    }

    It 'binds authorization to the exact executing runtime identity' {
        $module = Import-TestModule -ModuleRoot (
            Split-Path $script:SourceManifest -Parent
        )
        $identity = & $module {
            Get-AdltRuntimeIdentity
        }
        $authorization = [ordered]@{
            module  = $identity.module
            commit  = $identity.commit
            runtime = [ordered]@{
                powershell   = $identity.powershell
                dependencies = $identity.dependencies
            }
        }

        {
            & $module {
                param($Candidate)

                Assert-AdltRuntimeAuthorizationBinding `
                    -Authorization $Candidate
            } $authorization
        } | Should -Not -Throw

        $authorization.commit = '0' * 64
        {
            & $module {
                param($Candidate)

                Assert-AdltRuntimeAuthorizationBinding `
                    -Authorization $Candidate
            } $authorization
        } | Should -Throw '*runtime identity does not match*'
    }

    It 'uses a marked content-derived revision for source-tree execution' {
        $module = Import-TestModule -ModuleRoot (
            Split-Path $script:SourceManifest -Parent
        )
        $identity = & $module {
            Get-AdltRuntimeIdentity
        }

        $identity.module.revisionKind |
            Should -BeExactly 'content-derived'
        $identity.commit | Should -Match '^[a-f0-9]{64}$'
        $identity.commit |
            Should -BeExactly (
                $identity.module.digest.Substring('sha256:'.Length)
            )
    }

    It 'rejects a changed listed runtime file' {
        $moduleRoot = Expand-TestPackagedModule -Name 'tampered-module'
        $module = Import-TestModule -ModuleRoot $moduleRoot
        Add-Content `
            -LiteralPath (Join-Path $moduleRoot 'Templates/sqlvm-secure.yaml') `
            -Value '# tampered'

        {
            & $module {
                Get-AdltRuntimeIdentity
            }
        } | Should -Throw '*do not match*provenance manifest*'
    }

    It 'rejects a nested unlisted provenance-named file' {
        $moduleRoot = Expand-TestPackagedModule `
            -Name 'unlisted-file-module'
        $module = Import-TestModule -ModuleRoot $moduleRoot
        $unexpectedDirectory = Join-Path $moduleRoot 'Nested'
        New-Item `
            -ItemType Directory `
            -Path $unexpectedDirectory `
            -Force |
            Out-Null
        Set-Content `
            -LiteralPath (
                Join-Path $unexpectedDirectory 'build-provenance.json'
            ) `
            -Value 'unexpected'

        {
            & $module {
                Get-AdltRuntimeIdentity
            }
        } | Should -Throw '*do not match*provenance manifest*'
    }

    It 'rejects modified provenance metadata' {
        $moduleRoot = Expand-TestPackagedModule `
            -Name 'provenance-tamper-module'
        $provenancePath = Join-Path `
            $moduleRoot `
            'build-provenance.json'
        $provenance = Get-Content `
            -LiteralPath $provenancePath `
            -Raw |
            ConvertFrom-Json -AsHashtable
        $provenance.moduleVersion = '0.1.1'
        $provenance |
            ConvertTo-Json -Depth 100 -Compress |
            Set-Content -LiteralPath $provenancePath
        $module = Import-TestModule -ModuleRoot $moduleRoot

        {
            & $module {
                Get-AdltRuntimeIdentity
            }
        } | Should -Throw '*provenance metadata is invalid*'
    }

    It 'rejects missing provenance in an official package' {
        $moduleRoot = Expand-TestPackagedModule `
            -Name 'missing-provenance-module'
        $provenancePath = Join-Path `
            $moduleRoot `
            'build-provenance.json'
        Remove-Item -LiteralPath $provenancePath -Force
        $module = Import-TestModule -ModuleRoot $moduleRoot

        {
            & $module {
                Get-AdltRuntimeIdentity
            }
        } | Should -Throw '*packaged module build provenance is missing*'
    }
}

Describe 'Locked runtime dependency provenance' {
    BeforeEach {
        $script:SourceModule = Import-TestModule -ModuleRoot (
            Split-Path $script:SourceManifest -Parent
        )
    }

    It 'binds every canary dependency to reviewed package content' {
        $identity = & $script:SourceModule {
            Get-AdltRuntimeIdentity
        }

        @($identity.dependencies).Count | Should -Be 6
        @($identity.dependencies).name | Should -Be @(
            'Az.Accounts'
            'Az.Compute'
            'Az.KeyVault'
            'Az.Monitor'
            'Az.Resources'
            'powershell-yaml'
        )
        foreach ($dependency in @($identity.dependencies)) {
            $dependency.guid | Should -Match '^[0-9a-f-]{36}$'
            $dependency.source | Should -BeExactly 'PSGallery'
            $dependency.packageDigest |
                Should -Match '^sha256:[a-f0-9]{64}$'
            $dependency.contentDigest |
                Should -Match '^sha256:[a-f0-9]{64}$'
            $dependency.manifestPathHash |
                Should -Match '^sha256:[a-f0-9]{64}$'
        }
    }

    It 'rejects changed or additional files under a locked module root' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            DependencySource = $script:PowerShellYamlRoot
            CopyRoot = Join-Path $TestDrive 'dependency-copy'
        } {
            param($DependencySource, $CopyRoot)

            Copy-Item `
                -LiteralPath $DependencySource `
                -Destination $CopyRoot `
                -Recurse
            $manifest = Test-ModuleManifest `
                -Path (Join-Path $CopyRoot 'powershell-yaml.psd1')
            $lockEntry = Get-AdltLockedRuntimeDependency `
                -Name powershell-yaml

            {
                Get-AdltRuntimeDependencyContentIdentity `
                    -Module $manifest `
                    -LockEntry $lockEntry
            } | Should -Not -Throw

            Add-Content `
                -LiteralPath (Join-Path $CopyRoot 'powershell-yaml.psm1') `
                -Value '# changed'
            {
                Get-AdltRuntimeDependencyContentIdentity `
                    -Module $manifest `
                    -LockEntry $lockEntry
            } | Should -Throw '*reviewed package content digest*'

            Set-Content `
                -LiteralPath (Join-Path $CopyRoot 'unexpected.ps1') `
                -Value 'throw'
            {
                Get-AdltRuntimeDependencyContentIdentity `
                    -Module $manifest `
                    -LockEntry $lockEntry
            } | Should -Throw '*file set is invalid*'
        }
    }

    It 'rejects ambiguous exact-version module manifests' {
        InModuleScope AzureDataLabToolkit {
            $module = Get-Module `
                -ListAvailable `
                -FullyQualifiedName @{
                    ModuleName = 'powershell-yaml'
                    RequiredVersion = '0.4.12'
                    Guid = '6a75a662-7f53-425a-9777-ee61284407da'
                } |
                Select-Object -First 1
            Mock Get-Module { @($module, $module) } `
                -ParameterFilter { $ListAvailable }

            {
                Get-AdltVerifiedRuntimeDependency `
                    -Name powershell-yaml
            } | Should -Throw '*exactly one locked module manifest*'
        }
    }

    It 'rejects reparse points inside a locked module root' -Skip:$IsWindows {
        InModuleScope AzureDataLabToolkit -Parameters @{
            DependencySource = $script:PowerShellYamlRoot
            CopyRoot = Join-Path $TestDrive 'linked-dependency'
        } {
            param($DependencySource, $CopyRoot)

            Copy-Item `
                -LiteralPath $DependencySource `
                -Destination $CopyRoot `
                -Recurse
            [void] (New-Item `
                -ItemType SymbolicLink `
                -Path (Join-Path $CopyRoot 'linked-readme') `
                -Target (Join-Path $CopyRoot 'README.md'))
            $manifest = Test-ModuleManifest `
                -Path (Join-Path $CopyRoot 'powershell-yaml.psd1')
            $lockEntry = Get-AdltLockedRuntimeDependency `
                -Name powershell-yaml

            {
                Get-AdltRuntimeDependencyContentIdentity `
                    -Module $manifest `
                    -LockEntry $lockEntry
            } | Should -Throw '*contains a reparse point*'
        }
    }
}
