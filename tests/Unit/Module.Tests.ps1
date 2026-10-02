BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Remove-Module AzureDataLabToolkit -ErrorAction SilentlyContinue
    $script:AzureModulesBeforeImport = @(
        Get-Module -Name 'Az.*' |
            Select-Object -ExpandProperty Name |
            Sort-Object
    )
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:AzureModulesAfterImport = @(
        Get-Module -Name 'Az.*' |
            Select-Object -ExpandProperty Name |
            Sort-Object
    )
}

Describe 'AzureDataLabToolkit module contract' {
    It 'has a valid module manifest' {
        $manifest = Test-ModuleManifest $script:ModulePath
        $manifest.Name | Should -Be 'AzureDataLabToolkit'
        $manifest.Version.ToString() | Should -Be '0.1.0'
        $manifest.PowerShellVersion.ToString() | Should -Be '7.6'
    }

    It 'declares no manifest field that loads code outside the root module' {
        # The module script lock covers .ps1 and .psm1 content only:
        # Support/module-scripts.lock.json holds no .psd1 entry, so the
        # manifest sits outside every content digest the psm1 verifies.
        # ScriptsToProcess, NestedModules, RequiredAssemblies,
        # FormatsToProcess and TypesToProcess are all loaded by the engine
        # before or instead of RootModule, so anything named in them runs
        # without ever reaching the closed-world check - the lock would still
        # report success. This test, not the script lock, is what keeps that
        # surface empty. A future reader must not assume the lock covers it.
        $manifest = Import-PowerShellDataFile `
            -LiteralPath $script:ModulePath `
            -ErrorAction Stop

        # Absence, not emptiness. An empty declaration is a slot a later edit
        # fills without anyone noticing the security meaning of the key, so
        # the manifest must not name these fields at all.
        $loadingFields = @(
            'ScriptsToProcess'
            'NestedModules'
            'RequiredAssemblies'
            'FormatsToProcess'
            'TypesToProcess'
        )
        foreach ($loadingField in $loadingFields) {
            $manifest.Contains($loadingField) |
                Should -BeFalse `
                    -Because (
                        "'$loadingField' loads code that the module script " +
                        'lock does not cover'
                    )
        }

        [string] $manifest.RootModule |
            Should -BeExactly 'AzureDataLabToolkit.psm1'
    }

    It 'exports only the implemented commands' {
        $expectedCommands = @(
            'Connect-AzureDataLabAccount'
            'Export-AzureDataLabEvidence'
            'Export-AzureDataLabPlan'
            'Find-AzureDataLabCatalogItem'
            'Get-AzureDataLabEvidence'
            'Get-AzureDataLabRun'
            'Get-AzureDataLabSupportMatrix'
            'Get-AzureDataLabTemplate'
            'Invoke-AzureDataLabPreflight'
            'New-AzureDataLabPlan'
            'New-AzureDataLabRun'
            'Resolve-AzureDataLabDeployment'
            'Resolve-AzureDataLabPlan'
            'Resolve-AzureDataLabTeardown'
            'Resume-AzureDataLabDeployment'
            'Resume-AzureDataLabTeardown'
            'Start-AzureDataLabConfigurationWizard'
            'Start-AzureDataLabDeployment'
            'Start-AzureDataLabTeardown'
            'Test-AzureDataLabAzureContext'
            'Test-AzureDataLabConfiguration'
            'Test-AzureDataLabDeployment'
            'Test-AzureDataLabDeploymentConfiguration'
            'Test-AzureDataLabWhatIf'
        )

        $actualCommands = @(
            Get-Command -Module AzureDataLabToolkit |
                Select-Object -ExpandProperty Name |
                Sort-Object
        )
        $actualCommands | Should -Be $expectedCommands
    }

    It 'loads no Azure modules as an import side effect' {
        # Compare the snapshots taken around the single import in BeforeAll
        # rather than asserting that the session holds no Az module at all.
        # Loaded modules are session-global state this test does not own: a
        # developer machine, or any earlier test in the run, may already have
        # imported one, and a global count check would fail there for reasons
        # that say nothing about this module. The delta still fails closed -
        # any Az module the import pulls in appears here.
        $importedAzureModules = @(
            $script:AzureModulesAfterImport |
                Where-Object { $_ -cnotin $script:AzureModulesBeforeImport }
        )
        $importedAzureModules | Should -BeNullOrEmpty
    }

    It 'keeps the offline core free of cloud or web invocation' {
        $literalPatterns = @(
            'Connect-AzAccount'
            'Invoke-AzRestMethod'
            'Invoke-RestMethod'
            'Invoke-WebRequest'
        )
        $sourceFiles = Get-ChildItem `
            -LiteralPath (Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit') `
            -Include '*.ps1', '*.psm1' `
            -File `
            -Recurse |
            Where-Object {
                $_.FullName -notmatch '[\\/]Private[\\/]7[02]-' -and
                $_.Name -notin @(
                    'Connect-AzureDataLabAccount.ps1'
                    'Test-AzureDataLabAzureContext.ps1'
                )
            }

        foreach ($pattern in $literalPatterns) {
            # Not $matches: that is the automatic variable the -match operator
            # writes, so assigning to it here would be overwritten by the next
            # regex comparison in this test and the assertion would read a
            # value it did not set.
            $patternHits = @(
                $sourceFiles | Select-String -Pattern $pattern -SimpleMatch
            )
            $patternHits |
                Should -BeNullOrEmpty `
                    -Because "'$pattern' is outside the offline core"
        }

        $azCommandInvocations = foreach ($sourceFile in $sourceFiles) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $sourceFile.FullName,
                [ref] $tokens,
                [ref] $parseErrors
            )
            $ast.FindAll(
                {
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                },
                $true
            ) |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object {
                    # Any verb, not an enumerated few. The earlier list of
                    # seven verbs let Update-AzVM, Stop-AzVM, Start-AzVM,
                    # Move-AzResource and Register-AzResourceProvider through
                    # the gate while the suite stayed green.
                    $_ -match '^[A-Z][A-Za-z]+-Az(?!ureDataLab)'
                }
        }

        @($azCommandInvocations) | Should -BeNullOrEmpty
    }

    It 'rejects an unexpected script before it can execute' {
        $copyRoot = Join-Path $TestDrive 'unexpected-script'
        Copy-Item `
            -LiteralPath (
                Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit'
            ) `
            -Destination $copyRoot `
            -Recurse
        $roguePath = Join-Path $copyRoot 'Public/Invoke-RogueCode.ps1'
        [System.IO.File]::WriteAllText(
            $roguePath,
            '$global:AdltUnexpectedScriptExecuted = $true'
        )
        Remove-Module AzureDataLabToolkit -Force
        try {
            {
                Import-Module `
                    (Join-Path $copyRoot 'AzureDataLabToolkit.psd1') `
                    -Force `
                    -ErrorAction Stop
            } | Should -Throw '*unexpected or unlocked script*'
            Get-Variable `
                -Name AdltUnexpectedScriptExecuted `
                -Scope Global `
                -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }
        finally {
            Remove-Variable `
                -Name AdltUnexpectedScriptExecuted `
                -Scope Global `
                -ErrorAction SilentlyContinue
            Import-Module $script:ModulePath -Force -ErrorAction Stop
        }
    }

    It 'rejects a changed locked script before it can execute' {
        $copyRoot = Join-Path $TestDrive 'changed-script'
        Copy-Item `
            -LiteralPath (
                Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit'
            ) `
            -Destination $copyRoot `
            -Recurse
        $changedPath = Join-Path `
            $copyRoot `
            'Public/Get-AzureDataLabTemplate.ps1'
        [System.IO.File]::AppendAllText(
            $changedPath,
            "`n`$global:AdltChangedScriptExecuted = `$true`n"
        )
        Remove-Module AzureDataLabToolkit -Force
        try {
            {
                Import-Module `
                    (Join-Path $copyRoot 'AzureDataLabToolkit.psd1') `
                    -Force `
                    -ErrorAction Stop
            } | Should -Throw '*failed content verification*'
            Get-Variable `
                -Name AdltChangedScriptExecuted `
                -Scope Global `
                -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }
        finally {
            Remove-Variable `
                -Name AdltChangedScriptExecuted `
                -Scope Global `
                -ErrorAction SilentlyContinue
            Import-Module $script:ModulePath -Force -ErrorAction Stop
        }
    }

    It 'rejects a changed dependency lock before importing a dependency' {
        $copyRoot = Join-Path $TestDrive 'changed-dependency-lock'
        Copy-Item `
            -LiteralPath (
                Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit'
            ) `
            -Destination $copyRoot `
            -Recurse
        $changedPath = Join-Path `
            $copyRoot `
            'Support/runtime-dependencies.lock.json'
        [System.IO.File]::AppendAllText($changedPath, "`n")
        Remove-Module AzureDataLabToolkit -Force
        Remove-Module powershell-yaml -Force -ErrorAction SilentlyContinue
        try {
            {
                Import-Module `
                    (Join-Path $copyRoot 'AzureDataLabToolkit.psd1') `
                    -Force `
                    -ErrorAction Stop
            } | Should -Throw '*runtime dependency lock digest is invalid*'
            Get-Module powershell-yaml |
                Should -BeNullOrEmpty
        }
        finally {
            Import-Module $script:ModulePath -Force -ErrorAction Stop
        }
    }
}
