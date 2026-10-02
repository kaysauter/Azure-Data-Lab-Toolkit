BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:BuildScript = Join-Path $script:RepositoryRoot 'build.ps1'
    $script:BuildToolLockPath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/Support/build-tools.lock.json'
    $script:WorkflowPath = Join-Path `
        $script:RepositoryRoot `
        '.github/workflows/module-ci.yml'

    . $script:BuildScript

    function New-TestGitRepositoryPath {
        param(
            [Parameter(Mandatory)]
            [string] $Name
        )

        $path = Join-Path $TestDrive $Name
        [void] (New-Item `
            -ItemType Directory `
            -Path (Join-Path $path '.git') `
            -Force)
        return [System.IO.Path]::GetFullPath($path)
    }

    function Get-TestBuildToolModule {
        param(
            [Parameter(Mandatory)]
            [string] $Name
        )

        $lock = Get-AdltBuildToolLock
        $entry = @(
            $lock.buildTools |
                Where-Object { [string] $_.name -ceq $Name }
        )[0]
        return Get-Module `
            -ListAvailable `
            -FullyQualifiedName @{
                ModuleName      = [string] $entry.name
                RequiredVersion = [string] $entry.version
                Guid            = [guid] $entry.guid
            } |
            Select-Object -First 1
    }
}

Describe 'Build source revision trust' {
    It 'reports Git only for an exact clean repository' {
        $repositoryPath = New-TestGitRepositoryPath -Name 'clean'
        $head = 'a' * 40
        $gitInvoker = {
            param($RepositoryPath, $Arguments)

            $output = switch ($Arguments -join ' ') {
                'rev-parse --show-toplevel' { @($RepositoryPath) }
                'rev-parse --verify HEAD^{commit}' { @($head) }
                (
                    'status --porcelain=v1 --untracked-files=all ' +
                    '--ignore-submodules=none'
                ) { @() }
                (
                    'ls-files --others --ignored --exclude-standard -- ' +
                    'src/AzureDataLabToolkit'
                ) { @() }
                default { throw 'Unexpected Git invocation.' }
            }
            return [ordered]@{
                exitCode = 0
                output   = @($output)
            }
        }

        $result = Get-AdltBuildSourceRevision `
            -AggregateDigest ('sha256:' + ('f' * 64)) `
            -RepositoryPath $repositoryPath `
            -GitInvoker $gitInvoker

        $result.kind | Should -BeExactly 'git'
        $result.revision | Should -BeExactly $head
    }

    It 'falls back to content identity for dirty or untracked content' {
        $repositoryPath = New-TestGitRepositoryPath -Name 'dirty'
        $aggregate = 'sha256:' + ('b' * 64)
        $gitInvoker = {
            param($RepositoryPath, $Arguments)

            $output = switch ($Arguments -join ' ') {
                'rev-parse --show-toplevel' { @($RepositoryPath) }
                'rev-parse --verify HEAD^{commit}' { @('a' * 40) }
                (
                    'status --porcelain=v1 --untracked-files=all ' +
                    '--ignore-submodules=none'
                ) {
                    @('?? untracked.ps1')
                }
                (
                    'ls-files --others --ignored --exclude-standard -- ' +
                    'src/AzureDataLabToolkit'
                ) { @() }
                default { throw 'Unexpected Git invocation.' }
            }
            return [ordered]@{
                exitCode = 0
                output   = @($output)
            }
        }

        $result = Get-AdltBuildSourceRevision `
            -AggregateDigest $aggregate `
            -RepositoryPath $repositoryPath `
            -GitInvoker $gitInvoker

        $result.kind | Should -BeExactly 'content-derived'
        $result.revision |
            Should -BeExactly $aggregate.Substring('sha256:'.Length)
    }

    It 'falls back for a mismatched top level or Git error' {
        $repositoryPath = New-TestGitRepositoryPath -Name 'ambiguous'
        $aggregate = 'sha256:' + ('c' * 64)
        $wrongTopLevel = {
            param($RepositoryPath, $Arguments)

            $output = switch ($Arguments -join ' ') {
                'rev-parse --show-toplevel' {
                    @(Join-Path $RepositoryPath 'nested')
                }
                'rev-parse --verify HEAD^{commit}' { @('a' * 40) }
                (
                    'status --porcelain=v1 --untracked-files=all ' +
                    '--ignore-submodules=none'
                ) { @() }
                (
                    'ls-files --others --ignored --exclude-standard -- ' +
                    'src/AzureDataLabToolkit'
                ) { @() }
            }
            return [ordered]@{
                exitCode = 0
                output   = @($output)
            }
        }
        $failingGit = {
            throw 'Git failed.'
        }

        foreach ($invoker in @($wrongTopLevel, $failingGit)) {
            $result = Get-AdltBuildSourceRevision `
                -AggregateDigest $aggregate `
                -RepositoryPath $repositoryPath `
                -GitInvoker $invoker
            $result.kind | Should -BeExactly 'content-derived'
            $result.revision |
                Should -BeExactly $aggregate.Substring('sha256:'.Length)
        }
    }

    It 'falls back when HEAD changes during Git verification' {
        $repositoryPath = New-TestGitRepositoryPath -Name 'changing-head'
        $aggregate = 'sha256:' + ('d' * 64)
        $state = @{ headReads = 0 }
        $gitInvoker = {
            param($RepositoryPath, $Arguments)

            $output = switch ($Arguments -join ' ') {
                'rev-parse --show-toplevel' { @($RepositoryPath) }
                'rev-parse --verify HEAD^{commit}' {
                    $state.headReads++
                    if ($state.headReads -eq 1) {
                        @('a' * 40)
                    }
                    else {
                        @('b' * 40)
                    }
                }
                (
                    'status --porcelain=v1 --untracked-files=all ' +
                    '--ignore-submodules=none'
                ) { @() }
                (
                    'ls-files --others --ignored --exclude-standard -- ' +
                    'src/AzureDataLabToolkit'
                ) { @() }
            }
            return [ordered]@{
                exitCode = 0
                output   = @($output)
            }
        }.GetNewClosure()

        $result = Get-AdltBuildSourceRevision `
            -AggregateDigest $aggregate `
            -RepositoryPath $repositoryPath `
            -GitInvoker $gitInvoker

        $result.kind | Should -BeExactly 'content-derived'
        $result.revision |
            Should -BeExactly $aggregate.Substring('sha256:'.Length)
    }

    It 'falls back when an ignored package input exists' {
        $repositoryPath = New-TestGitRepositoryPath `
            -Name 'ignored-package-input'
        $aggregate = 'sha256:' + ('e' * 64)
        $gitInvoker = {
            param($RepositoryPath, $Arguments)

            $output = switch ($Arguments -join ' ') {
                'rev-parse --show-toplevel' { @($RepositoryPath) }
                'rev-parse --verify HEAD^{commit}' { @('a' * 40) }
                (
                    'status --porcelain=v1 --untracked-files=all ' +
                    '--ignore-submodules=none'
                ) { @() }
                (
                    'ls-files --others --ignored --exclude-standard -- ' +
                    'src/AzureDataLabToolkit'
                ) {
                    @('src/AzureDataLabToolkit/ignored.ps1xml')
                }
                default { throw 'Unexpected Git invocation.' }
            }
            return [ordered]@{
                exitCode = 0
                output   = @($output)
            }
        }

        $result = Get-AdltBuildSourceRevision `
            -AggregateDigest $aggregate `
            -RepositoryPath $repositoryPath `
            -GitInvoker $gitInvoker

        $result.kind | Should -BeExactly 'content-derived'
        $result.revision |
            Should -BeExactly $aggregate.Substring('sha256:'.Length)
    }
}

Describe 'Locked build-tool trust' {
    It 'accepts only the strict reviewed lock contract' {
        $lock = Get-AdltBuildToolLock

        @($lock.buildTools).name | Should -Be @(
            'Pester'
            'PSScriptAnalyzer'
        )

        $copyPath = Join-Path $TestDrive 'invalid-build-tools.lock.json'
        $invalid = $lock |
            ConvertTo-Json -Depth 20 |
            ConvertFrom-Json -AsHashtable -Depth 20
        $invalid.unexpected = $true
        $invalid |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $copyPath

        {
            Get-AdltBuildToolLock -Path $copyPath
        } | Should -Throw '*lock contract is invalid*'
    }

    It 'verifies every required installed tool without importing it' {
        foreach ($name in @(
            'Pester'
            'PSScriptAnalyzer'
        )) {
            $loadedBefore = @(
                Get-Module -Name $name |
                    Select-Object -ExpandProperty Path
            )
            # Resolve from an explicit candidate rather than the ambient
            # PSModulePath. Hosted runners preinstall these exact locked
            # versions, so an ambient lookup finds two identical manifests and
            # fails the uniqueness check for reasons unrelated to this test.
            $identity = Get-AdltVerifiedBuildTool `
                -Name $name `
                -Candidates @(Get-TestBuildToolModule -Name $name)
            $loadedAfter = @(
                Get-Module -Name $name |
                    Select-Object -ExpandProperty Path
            )

            $identity.name | Should -BeExactly $name
            $identity.manifestPath |
                Should -BeExactly (Get-TestBuildToolModule -Name $name).Path
            $loadedAfter | Should -BeExactly $loadedBefore
        }
    }

    It 'rejects changed or additional bytes before import' {
        $source = Get-TestBuildToolModule -Name 'Pester'
        $loadedBefore = @(
            Get-Module -Name Pester |
                Select-Object -ExpandProperty Path
        )
        $copyRoot = Join-Path $TestDrive 'tampered-pester'
        Copy-Item `
            -LiteralPath $source.ModuleBase `
            -Destination $copyRoot `
            -Recurse
        $tamperedPath = Join-Path $copyRoot 'Pester.psm1'
        $tamperedBytes = [System.IO.File]::ReadAllBytes($tamperedPath)
        $tamperedBytes[0] = $tamperedBytes[0] -bxor 1
        [System.IO.File]::WriteAllBytes($tamperedPath, $tamperedBytes)
        $candidate = Test-ModuleManifest `
            -Path (Join-Path $copyRoot 'Pester.psd1')

        {
            Get-AdltVerifiedBuildTool `
                -Name Pester `
                -Candidates @($candidate)
        } | Should -Throw '*reviewed complete content identity*'
        $loadedAfter = @(
            Get-Module -Name Pester |
                Select-Object -ExpandProperty Path
        )
        $loadedAfter | Should -BeExactly $loadedBefore
    }

    It 'rejects ambiguous exact-version manifests' {
        $candidate = Get-TestBuildToolModule -Name 'Pester'

        {
            Get-AdltVerifiedBuildTool `
                -Name Pester `
                -Candidates @($candidate, $candidate)
        } | Should -Throw '*exactly one locked module manifest*'
    }

    It 'rejects reparse points in a build-tool tree' -Skip:$IsWindows {
        $source = Get-TestBuildToolModule -Name 'Pester'
        $copyRoot = Join-Path $TestDrive 'linked-pester'
        Copy-Item `
            -LiteralPath $source.ModuleBase `
            -Destination $copyRoot `
            -Recurse
        [void] (New-Item `
            -ItemType SymbolicLink `
            -Path (Join-Path $copyRoot 'linked-readme') `
            -Target (Join-Path $copyRoot 'README.md'))
        $candidate = Test-ModuleManifest `
            -Path (Join-Path $copyRoot 'Pester.psd1')

        {
            Get-AdltVerifiedBuildTool `
                -Name Pester `
                -Candidates @($candidate)
        } | Should -Throw '*contains a reparse point*'
    }

    It 'records build tools as release SBOM inputs' {
        $workflow = [System.IO.File]::ReadAllText($script:WorkflowPath)

        $workflow | Should -Match 'Support/build-tools\.lock\.json'
        $workflow | Should -Match 'BUILD_DEPENDENCY_OF'
        $workflow | Should -Match "relationshipType = 'DESCRIBES'"
        $workflow | Should -Match 'SPDXRef-Package-BuildTool'
        $workflow | Should -Match 'Test-AdltBuildProvenance'
        $workflow | Should -Match 'Expand-Archive'
        $workflow | Should -Match 'RequireGit'
        $workflow |
            Should -Not -Match 'checksumValue = \$contentHash'
    }

    It 'verifies complete package provenance and detects changed content' {
        $moduleRoot = Join-Path $TestDrive 'package-provenance'
        [void] (New-Item -ItemType Directory -Path $moduleRoot)
        Copy-Item `
            -LiteralPath (
                Join-Path `
                    $script:RepositoryRoot `
                    'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
            ) `
            -Destination $moduleRoot
        [System.IO.File]::WriteAllText(
            (Join-Path $moduleRoot 'payload.txt'),
            'reviewed payload',
            [System.Text.UTF8Encoding]::new($false)
        )
        # Bind provenance to a directory that is deliberately not a Git
        # repository. Reading the ambient repository would make the recorded
        # kind depend on whether the developer's working tree happens to be
        # clean, which is not what this test is about.
        New-AdltBuildProvenance `
            -ModulePath $moduleRoot `
            -RepositoryPath (Join-Path $TestDrive 'no-repository')

        $identity = Test-AdltBuildProvenance `
            -ModulePath $moduleRoot `
            -ExpectedModuleVersion '0.1.0-alpha1'
        $identity.sourceRevisionKind |
            Should -BeExactly 'content-derived'
        {
            Test-AdltBuildProvenance `
                -ModulePath $moduleRoot `
                -RequireGit
        } | Should -Throw '*source or version binding is invalid*'

        [System.IO.File]::WriteAllText(
            (Join-Path $moduleRoot 'payload.txt'),
            'changed payload',
            [System.Text.UTF8Encoding]::new($false)
        )
        {
            Test-AdltBuildProvenance -ModulePath $moduleRoot
        } | Should -Throw '*complete module content*'
    }

    It 'records a git source revision from a clean repository' {
        $moduleRoot = Join-Path $TestDrive 'git-provenance'
        [void] (New-Item -ItemType Directory -Path $moduleRoot)
        Copy-Item `
            -LiteralPath (
                Join-Path `
                    $script:RepositoryRoot `
                    'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
            ) `
            -Destination $moduleRoot

        $repositoryPath = New-TestGitRepositoryPath -Name 'clean-repository'
        $revision = 'a' * 40
        $gitInvoker = {
            param($RepositoryPath, $Arguments)

            $output = switch -Regex ($Arguments -join ' ') {
                'rev-parse --show-toplevel' { @($repositoryPath) }
                'rev-parse --verify HEAD'   { @($revision) }
                default                     { @() }
            }
            return [ordered]@{ exitCode = 0; output = $output }
        }.GetNewClosure()

        New-AdltBuildProvenance `
            -ModulePath $moduleRoot `
            -RepositoryPath $repositoryPath `
            -GitInvoker $gitInvoker

        $identity = Test-AdltBuildProvenance `
            -ModulePath $moduleRoot `
            -ExpectedModuleVersion '0.1.0-alpha1' `
            -RequireGit
        $identity.sourceRevisionKind | Should -BeExactly 'git'
        $identity.sourceRevision | Should -BeExactly $revision
    }
}
