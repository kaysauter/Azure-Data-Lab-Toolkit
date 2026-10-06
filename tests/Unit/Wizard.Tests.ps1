BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:WizardRoot = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/Wizard'
    $script:WizardCoreFixture = Join-Path `
        $script:RepositoryRoot `
        'tests/Fixtures/Invoke-WizardCore.js'
    $script:NodeCommand = Get-Command node -ErrorAction Stop
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:Module = Get-Module AzureDataLabToolkit
}

Describe 'Offline browser configuration wizard' {
    It 'stages a private, self-contained file bundle without launching' {
        Mock Start-Process -ModuleName AzureDataLabToolkit {
            throw 'Start-Process must not be called with -NoLaunch.'
        }

        $result = Start-AzureDataLabConfigurationWizard -NoLaunch

        $result.Status | Should -BeExactly 'ready'
        $result.NetworkMode | Should -BeExactly 'offline'
        $result.Uri | Should -Match '^file:///'
        Test-Path -LiteralPath $result.Path -PathType Leaf |
            Should -BeTrue
        Should -Invoke Start-Process `
            -ModuleName AzureDataLabToolkit `
            -Times 0
        foreach ($fileName in @(
            'index.html',
            'wizard.css',
            'wizard-core.js',
            'wizard.js',
            'wizard-data.js'
        )) {
            Test-Path `
                -LiteralPath (Join-Path (Split-Path $result.Path) $fileName) `
                -PathType Leaf |
                Should -BeTrue
        }
    }

    It 'injects the authoritative profile hash and local catalog metadata' {
        $bundle = Start-AzureDataLabConfigurationWizard -NoLaunch
        $dataScript = Get-Content `
            -LiteralPath (
                Join-Path (Split-Path $bundle.Path) 'wizard-data.js'
            ) `
            -Raw
        $deploymentProfileContract = & $script:Module {
            Get-AdltDeploymentProfile
        }

        $dataScript |
            Should -Match (
                [regex]::Escape($deploymentProfileContract.id)
            )
        $dataScript |
            Should -Match (
                [regex]::Escape(
                    $deploymentProfileContract.profileHash
                )
            )
        $dataScript | Should -Match 'software\.git-for-windows'
        $dataScript | Should -Match 'sample-data\.adventureworks-2022'
        $dataScript | Should -Not -Match 'https?://'
    }

    It 'has a fail-closed browser security policy and no remote runtime' {
        $html = Get-Content `
            -LiteralPath (Join-Path $script:WizardRoot 'index.html') `
            -Raw
        $javascript = Get-Content `
            -LiteralPath (Join-Path $script:WizardRoot 'wizard.js') `
            -Raw
        $coreJavascript = Get-Content `
            -LiteralPath (Join-Path $script:WizardRoot 'wizard-core.js') `
            -Raw
        $allJavascript = $javascript + $coreJavascript

        $html | Should -Match "default-src 'none'"
        $html | Should -Match "connect-src 'none'"
        $html | Should -Match "object-src 'none'"
        $html | Should -Match "form-action 'none'"
        $html | Should -Not -Match 'https?://'
        $html | Should -Not -Match 'type\\s*=\\s*["'']password'
        $allJavascript | Should -Not -Match '\bfetch\s*\('
        $allJavascript | Should -Not -Match '\bXMLHttpRequest\b'
        $allJavascript | Should -Not -Match '\bWebSocket\b'
        $allJavascript | Should -Not -Match '\bsendBeacon\b'
        $allJavascript | Should -Not -Match '\.innerHTML\s*='
    }

    It 'keeps secret metadata out of browser persistence' {
        $javascript = Get-Content `
            -LiteralPath (Join-Path $script:WizardRoot 'wizard.js') `
            -Raw

        $persistenceCalls = @(
            [regex]::Matches(
                $javascript,
                '(?:localStorage|sessionStorage)\.(?:setItem|getItem)\((?<argument>[^)]*)\)'
            ) |
                ForEach-Object { $_.Groups['argument'].Value }
        )
        $persistenceCalls.Count | Should -BeGreaterThan 0
        foreach ($call in $persistenceCalls) {
            $call | Should -Match 'adlt-wizard-theme'
            $call | Should -Not -Match (
                'tenant|subscription|vault|secret|resource|description|lab'
            )
        }
    }

    It 'ships only planning-only catalog visibility in the YAML builder' {
        $coreJavascript = Get-Content `
            -LiteralPath (Join-Path $script:WizardRoot 'wizard-core.js') `
            -Raw

        $coreJavascript | Should -Match 'software:\\n'
        $coreJavascript | Should -Match 'sampleData:\\n'
        ([regex]::Matches($coreJavascript, 'catalogIds: \[\]')).Count |
            Should -Be 2
        $coreJavascript | Should -Not -Match 'catalogIds.*item\\.id'
    }

    It 'exposes only the locked canary and non-sensitive contract' {
        $html = Get-Content `
            -LiteralPath (Join-Path $script:WizardRoot 'index.html') `
            -Raw

        $html | Should -Not -Match 'name=["'']purpose["'']'
        $html | Should -Not -Match 'name=["'']containsSensitiveData["'']'
        $html | Should -Match 'Non-sensitive only'
        $html | Should -Match 'Separate approval, exact resources only'
        $html | Should -Match 'Authoritative PowerShell validator'
    }

    It 'passes exact generated YAML through the authoritative validator' {
        $deploymentProfileContract = & $script:Module {
            Get-AdltDeploymentProfile
        }
        $profilePath = Join-Path $TestDrive 'deployment-profile.json'
        $statePath = Join-Path $TestDrive 'wizard-state.json'
        $yamlPath = Join-Path $TestDrive 'wizard-output.yaml'
        $deploymentProfileContract |
            ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $profilePath -Encoding utf8NoBOM
        $state = [ordered]@{
            labName                        = 'sqlvm-canary'
            description                    = (
                'Secure Azure SQL VM deployment canary'
            )
            purpose                        = 'canary'
            tenantId                       = (
                '11111111-1111-1111-1111-111111111111'
            )
            subscriptionId                 = (
                '22222222-2222-2222-2222-222222222222'
            )
            location                       = 'switzerlandnorth'
            resourceGroupName              = 'rg-adlt-sqlvm-canary'
            keyVaultResourceId             = (
                '/subscriptions/22222222-2222-2222-2222-222222222222/' +
                'resourceGroups/rg-security/providers/' +
                'Microsoft.KeyVault/vaults/kv-adlt-canary'
            )
            diagnosticDestinationResourceId = (
                '/subscriptions/22222222-2222-2222-2222-222222222222/' +
                'resourceGroups/rg-monitor/providers/' +
                'Microsoft.OperationalInsights/workspaces/law-adlt'
            )
            secretName                     = 'vm-admin-password'
            secretVersion                  = ('a' * 32)
            currency                       = 'CHF'
            maximumRunCost                 = 100
            maximumRuntimeMinutes          = 120
            timeToLiveMinutes              = 180
            containsSensitiveData          = $false
        }
        $state |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $statePath -Encoding utf8NoBOM

        $nodeOutput = & $script:NodeCommand.Source `
            $script:WizardCoreFixture `
            (Join-Path $script:WizardRoot 'wizard-core.js') `
            $profilePath `
            $statePath
        $LASTEXITCODE | Should -Be 0
        $generated = $nodeOutput | ConvertFrom-Json -Depth 100

        $generated.matchesLockedProfile | Should -BeTrue
        $generated.requiresPowerShellValidation | Should -BeTrue
        $generated.requiresAzurePreflight | Should -BeTrue
        $generated.yaml |
            Set-Content -LiteralPath $yamlPath -Encoding utf8NoBOM
        $validation = Test-AzureDataLabDeploymentConfiguration `
            -Path $yamlPath

        $validation.Eligible | Should -BeTrue
        $validation.ProfileId |
            Should -BeExactly $deploymentProfileContract.id
        $validation.ProfileHash |
            Should -BeExactly $deploymentProfileContract.profileHash
    }

    It 'refuses unsupported state instead of generating eligible YAML' {
        $deploymentProfileContract = & $script:Module {
            Get-AdltDeploymentProfile
        }
        $profilePath = Join-Path $TestDrive 'unsupported-profile.json'
        $statePath = Join-Path $TestDrive 'unsupported-state.json'
        $deploymentProfileContract |
            ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $profilePath -Encoding utf8NoBOM
        [ordered]@{
            labName                        = 'unsupported-lab'
            description                    = 'Must fail closed'
            purpose                        = 'lab'
            tenantId                       = (
                '11111111-1111-1111-1111-111111111111'
            )
            subscriptionId                 = (
                '22222222-2222-2222-2222-222222222222'
            )
            location                       = 'switzerlandnorth'
            resourceGroupName              = 'rg-unsupported'
            keyVaultResourceId             = (
                '/subscriptions/22222222-2222-2222-2222-222222222222/' +
                'resourceGroups/rg-security/providers/' +
                'Microsoft.KeyVault/vaults/kv-adlt-canary'
            )
            diagnosticDestinationResourceId = (
                '/subscriptions/22222222-2222-2222-2222-222222222222/' +
                'resourceGroups/rg-monitor/providers/' +
                'Microsoft.OperationalInsights/workspaces/law-adlt'
            )
            secretName                     = 'vm-admin-password'
            secretVersion                  = ('b' * 32)
            currency                       = 'CHF'
            maximumRunCost                 = 100
            maximumRuntimeMinutes          = 120
            timeToLiveMinutes              = 180
            containsSensitiveData          = $true
        } |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $statePath -Encoding utf8NoBOM

        $nodeOutput = & $script:NodeCommand.Source `
            $script:WizardCoreFixture `
            (Join-Path $script:WizardRoot 'wizard-core.js') `
            $profilePath `
            $statePath
        $LASTEXITCODE | Should -Be 0
        $generated = $nodeOutput | ConvertFrom-Json -Depth 100

        $generated.matchesLockedProfile | Should -BeFalse
        $generated.yaml | Should -BeNullOrEmpty
        $generated.errors.profileContract |
            Should -Match 'requires a canary with non-sensitive data'
    }
}
