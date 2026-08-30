BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Remove-Module AzureDataLabToolkit -ErrorAction SilentlyContinue
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

Describe 'AzureDataLabToolkit module contract' {
    It 'has a valid module manifest' {
        $manifest = Test-ModuleManifest $script:ModulePath
        $manifest.Name | Should -Be 'AzureDataLabToolkit'
        $manifest.Version.ToString() | Should -Be '0.1.0'
        $manifest.PowerShellVersion.ToString() | Should -Be '7.6'
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
        @(Get-Module -Name 'Az.*').Count | Should -Be 0
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
            $matches = @($sourceFiles | Select-String -Pattern $pattern -SimpleMatch)
            $matches | Should -BeNullOrEmpty -Because "'$pattern' is outside the offline core"
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
                    $_ -match '^(Connect|Disconnect|Get|New|Set|Remove|Invoke)-Az(?!ureDataLab)'
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
