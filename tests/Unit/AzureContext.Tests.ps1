BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:ConfigurationPath = Join-Path `
        $script:RepositoryRoot `
        'examples/sqlvm-minimal.yaml'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:Plan = New-AzureDataLabPlan $script:ConfigurationPath
    $script:RunId = '33333333-3333-4333-8333-333333333333'
    $script:DefaultTestTokenCache = [pscustomobject]@{}

    function New-TestAzureContext {
        param(
            [string] $TenantId = '11111111-1111-4111-8111-111111111111',
            [string] $SubscriptionId = '22222222-2222-4222-8222-222222222222',
            [string] $Cloud = 'AzureCloud',
            [string] $SubscriptionName = 'Canary subscription',
            [string] $AccountId = 'canary.user@example.test',
            [object] $TokenCache = $script:DefaultTestTokenCache
        )

        return [pscustomobject]@{
            Account      = [pscustomobject]@{
                Id   = $AccountId
                Type = 'User'
            }
            Tenant       = [pscustomobject]@{
                Id = $TenantId
            }
            Subscription = [pscustomobject]@{
                Id   = $SubscriptionId
                Name = $SubscriptionName
            }
            Environment  = [pscustomobject]@{
                Name = $Cloud
            }
            TokenCache   = $TokenCache
        }
    }

    function New-TestSecureAccessToken {
        param(
            [datetimeoffset] $ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
        )

        return [pscustomobject]@{
            Token     = ConvertTo-SecureString `
                -String 'secure-test-token' `
                -AsPlainText `
                -Force
            ExpiresOn = $ExpiresOn
        }
    }
}

Describe 'Process-scoped Azure sign-in' {
    AfterEach {
        Remove-Variable `
            -Name AdltContextReadCount, AdltCommandTrace `
            -Scope Global `
            -ErrorAction SilentlyContinue
        InModuleScope AzureDataLabToolkit {
            Clear-AdltAzureDefaultProfileBinding
        }
    }

    It 'returns a token-free summary only after the exact context and secure token are verified' {
        $global:AdltContextReadCount = 0
        $global:AdltCommandTrace =
            [System.Collections.Generic.List[string]]::new()

        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            [void] $global:AdltCommandTrace.Add($CommandName)
            switch ($CommandName) {
                'Get-AzContext' {
                    [void] $global:AdltContextReadCount++
                    if ($global:AdltContextReadCount -eq 1) {
                        return $null
                    }
                    return New-TestAzureContext
                }
                'Set-AzContext' {
                    return New-TestAzureContext
                }
                'Get-AzAccessToken' {
                    return New-TestSecureAccessToken
                }
            }
        }

        $result = Connect-AzureDataLabAccount `
            -TenantId '11111111-1111-4111-8111-111111111111' `
            -SubscriptionId '22222222-2222-4222-8222-222222222222' `
            -UseDeviceAuthentication

        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Disable-AzContextAutosave' -and
                $Parameters.Scope -eq 'Process'
            } `
            -Times 1
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Clear-AzContext' -and
                $Parameters.Scope -eq 'Process' -and
                $Parameters.Force
            } `
            -Times 1
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Connect-AzAccount' -and
                $Parameters.Scope -eq 'Process' -and
                $Parameters.SkipContextPopulation -and
                $Parameters.Tenant -eq '11111111-1111-4111-8111-111111111111' -and
                $Parameters.Subscription -eq '22222222-2222-4222-8222-222222222222' -and
                $Parameters.Environment -eq 'AzureCloud' -and
                $Parameters.UseDeviceAuthentication
            } `
            -Times 1
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Get-AzAccessToken' -and
                $Parameters.ResourceTypeName -eq 'Arm' -and
                $Parameters.TenantId -eq '11111111-1111-4111-8111-111111111111' -and
                $Parameters.AsSecureString
            } `
            -Times 1
        $global:AdltCommandTrace.IndexOf(
            'Disable-AzContextAutosave'
        ) | Should -BeLessThan (
            $global:AdltCommandTrace.IndexOf('Clear-AzContext')
        )
        $global:AdltCommandTrace.IndexOf(
            'Clear-AzContext'
        ) | Should -BeLessThan (
            $global:AdltCommandTrace.IndexOf('Get-AzContext')
        )
        [System.Environment]::GetEnvironmentVariable(
            'Azure_Profile_Autosave',
            [System.EnvironmentVariableTarget]::Process
        ) | Should -BeExactly 'false'

        $result.cloud | Should -Be 'AzureCloud'
        $result.tenantId | Should -Be '11111111-1111-4111-8111-111111111111'
        $result.subscriptionId | Should -Be '22222222-2222-4222-8222-222222222222'
        $result.contextScope | Should -Be 'process'
        $result.tokenExpiresAt | Should -Not -BeNullOrEmpty
        $result.Keys | Should -Not -Contain 'Token'
        $result.Values -join ' ' | Should -Not -Match 'secure-test-token'
    }

    It 'requires a fresh process when Az.Accounts is already loaded' {
        [System.Environment]::SetEnvironmentVariable(
            'Azure_Profile_Autosave',
            'false',
            [System.EnvironmentVariableTarget]::Process
        )
        $preloadedModule = New-Module -Name Az.Accounts -ScriptBlock {}
        Import-Module $preloadedModule -Force
        try {
            {
                Connect-AzureDataLabAccount `
                    -TenantId '11111111-1111-4111-8111-111111111111' `
                    -SubscriptionId '22222222-2222-4222-8222-222222222222'
            } | Should -Throw '*Az.Accounts is already loaded*fresh PowerShell*'
        }
        finally {
            Remove-Module $preloadedModule -Force
        }
    }

    It 'does not start sign-in when process-only autosave cannot be disabled' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Disable-AzContextAutosave') {
                throw 'Process autosave control failed.'
            }
            throw "Unexpected command: $CommandName"
        }

        {
            Connect-AzureDataLabAccount `
                -TenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionId '22222222-2222-4222-8222-222222222222'
        } | Should -Throw '*sign-in was not started*process-only*'

        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter { $CommandName -eq 'Clear-AzContext' } `
            -Times 0
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter { $CommandName -eq 'Connect-AzAccount' } `
            -Times 0
    }

    It 'reports an unverified clear when Az context cleanup throws' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Clear-AzContext') {
                throw 'Process context cleanup failed.'
            }
            throw "Unexpected command: $CommandName"
        }

        InModuleScope AzureDataLabToolkit {
            Clear-AdltAzureProcessContext | Should -BeFalse
            $script:AdltAzureDefaultProfile | Should -BeNullOrEmpty
        }
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter { $CommandName -eq 'Get-AzContext' } `
            -Times 0
    }

    It 'clears the process context when Azure selects the wrong context' {
        $global:AdltContextReadCount = 0

        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            switch ($CommandName) {
                'Get-AzContext' {
                    [void] $global:AdltContextReadCount++
                    if ($global:AdltContextReadCount -eq 1) {
                        return $null
                    }
                    if ($global:AdltContextReadCount -eq 2) {
                        return New-TestAzureContext `
                            -SubscriptionId '99999999-9999-4999-8999-999999999999'
                    }
                    return $null
                }
                'Set-AzContext' {
                    return New-TestAzureContext `
                        -SubscriptionId '99999999-9999-4999-8999-999999999999'
                }
            }
        }

        {
            Connect-AzureDataLabAccount `
                -TenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionId '22222222-2222-4222-8222-222222222222'
        } | Should -Throw '*process context was cleared*'

        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Set-AzContext' -and
                $Parameters.ContainsKey('Context')
            } `
            -Times 0
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Clear-AzContext' -and
                $Parameters.Scope -eq 'Process' -and
                $Parameters.Force
            } `
            -Times 2
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter { $CommandName -eq 'Get-AzAccessToken' } `
            -Times 0
    }

    It 'clears the process context when connection fails and no prior context exists' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            switch ($CommandName) {
                'Get-AzContext' {
                    return $null
                }
                'Connect-AzAccount' {
                    throw 'Interactive authentication failed.'
                }
            }
        }

        {
            Connect-AzureDataLabAccount `
                -TenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionId '22222222-2222-4222-8222-222222222222'
        } | Should -Throw '*process context was cleared*'

        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Clear-AzContext' -and
                $Parameters.Scope -eq 'Process' -and
                $Parameters.Force
            } `
            -Times 2
    }

    It 'rejects an account change after token validation' {
        $global:AdltContextReadCount = 0

        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            switch ($CommandName) {
                'Get-AzContext' {
                    [void] $global:AdltContextReadCount++
                    if ($global:AdltContextReadCount -eq 1) {
                        return $null
                    }
                    if ($global:AdltContextReadCount -eq 2) {
                        return New-TestAzureContext `
                            -AccountId 'first.user@example.test'
                    }
                    if ($global:AdltContextReadCount -eq 3) {
                        return New-TestAzureContext `
                            -AccountId 'second.user@example.test'
                    }
                    return $null
                }
                'Set-AzContext' {
                    return New-TestAzureContext `
                        -AccountId 'first.user@example.test'
                }
                'Get-AzAccessToken' {
                    return New-TestSecureAccessToken
                }
            }
        }

        {
            Connect-AzureDataLabAccount `
                -TenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionId '22222222-2222-4222-8222-222222222222'
        } | Should -Throw '*process context was cleared*'

        InModuleScope AzureDataLabToolkit {
            $script:AdltAzureDefaultProfile | Should -BeNullOrEmpty
            $script:AdltAzureTokenReadinessLease | Should -BeNullOrEmpty
        }
    }

    It 'does not start authentication when a stale context survives the clear' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            switch ($CommandName) {
                'Get-AzContext' {
                    return New-TestAzureContext `
                        -TenantId 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' `
                        -SubscriptionId 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
                }
            }
        }

        {
            Connect-AzureDataLabAccount `
                -TenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionId '22222222-2222-4222-8222-222222222222'
        } | Should -Throw '*sign-in was not started*could not be cleared*'

        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Connect-AzAccount'
            } `
            -Times 0
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Clear-AzContext' -and
                $Parameters.Scope -eq 'Process'
            } `
            -Times 1
    }

    It 'fails closed when the recovery clear cannot be verified' {
        $global:AdltContextReadCount = 0

        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            switch ($CommandName) {
                'Get-AzContext' {
                    [void] $global:AdltContextReadCount++
                    if ($global:AdltContextReadCount -eq 1) {
                        return $null
                    }
                    return New-TestAzureContext
                }
                'Connect-AzAccount' {
                    throw 'Interactive authentication failed.'
                }
            }
        }

        {
            Connect-AzureDataLabAccount `
                -TenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionId '22222222-2222-4222-8222-222222222222'
        } | Should -Throw '*could not be cleared and verified safely*'

        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Clear-AzContext' -and
                $Parameters.Scope -eq 'Process'
            } `
            -Times 2
    }

    It 'rejects a plaintext token, clears the context, and does not expose the token' {
        $global:AdltContextReadCount = 0

        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            switch ($CommandName) {
                'Get-AzContext' {
                    [void] $global:AdltContextReadCount++
                    if ($global:AdltContextReadCount -eq 1) {
                        return $null
                    }
                    if ($global:AdltContextReadCount -eq 2) {
                        return New-TestAzureContext
                    }
                    return $null
                }
                'Set-AzContext' {
                    return New-TestAzureContext
                }
                'Get-AzAccessToken' {
                    return [pscustomobject]@{
                        Token     = 'plain-token-must-not-leak'
                        ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
                    }
                }
            }
        }

        $caughtMessage = $null
        try {
            [void] (Connect-AzureDataLabAccount `
                -TenantId '11111111-1111-4111-8111-111111111111' `
                -SubscriptionId '22222222-2222-4222-8222-222222222222')
        }
        catch {
            $caughtMessage = $_.Exception.Message
        }

        $caughtMessage | Should -Match 'process context was cleared'
        $caughtMessage | Should -Not -Match 'plain-token-must-not-leak'
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Set-AzContext' -and
                $Parameters.ContainsKey('Context')
            } `
            -Times 0
    }
}

Describe 'Immutable Azure default-profile binding' {
    AfterEach {
        InModuleScope AzureDataLabToolkit {
            Clear-AdltAzureDefaultProfileBinding
        }
    }

    It 'adds the verified context without allowing caller override' {
        $testContext = New-TestAzureContext
        InModuleScope AzureDataLabToolkit -Parameters @{
            TestContext = $testContext
        } {
            param($TestContext)

            Set-AdltAzureDefaultProfileBinding -Context $TestContext
            $original = @{ ErrorAction = 'Stop' }
            $bound = Get-AdltBoundAzCommandParameter `
                -Parameters $original

            [object]::ReferenceEquals(
                $bound.DefaultProfile,
                $TestContext
            ) | Should -BeTrue
            $original.ContainsKey('DefaultProfile') |
                Should -BeFalse
            {
                Get-AdltBoundAzCommandParameter `
                    -Parameters @{
                        DefaultProfile = [pscustomobject]@{}
                    }
            } | Should -Throw '*cannot override*'
        }
    }

    It 'fails closed when no verified context is bound' {
        InModuleScope AzureDataLabToolkit {
            Clear-AdltAzureDefaultProfileBinding
            {
                Get-AdltBoundAzCommandParameter `
                    -Parameters @{ ErrorAction = 'Stop' }
            } | Should -Throw '*No verified Azure default profile*'
        }
    }

    It 'detects in-place mutation of the bound Azure profile' {
        $testContext = New-TestAzureContext
        InModuleScope AzureDataLabToolkit -Parameters @{
            TestContext = $testContext
        } {
            param($TestContext)

            Set-AdltAzureDefaultProfileBinding -Context $TestContext
            $TestContext.Subscription.Id =
                '99999999-9999-4999-8999-999999999999'

            {
                Get-AdltBoundAzCommandParameter `
                    -Parameters @{ ErrorAction = 'Stop' }
            } | Should -Throw '*changed after binding*'
            $script:AdltAzureDefaultProfile | Should -BeNullOrEmpty
            $script:AdltAzureTokenReadinessLease | Should -BeNullOrEmpty
        }
    }

    It 'rejects an unapproved ARM access-token request contract' {
        InModuleScope AzureDataLabToolkit {
            {
                Invoke-AdltAzCommand `
                    -ModuleName Az.Accounts `
                    -CommandName Get-AzAccessToken `
                    -Parameters @{
                        ResourceTypeName = 'MSGraph'
                        TenantId =
                            '11111111-1111-4111-8111-111111111111'
                        AsSecureString = $true
                        ErrorAction = 'Stop'
                    }
            } | Should -Throw '*not approved*'
        }
    }

    It 'rejects a mutation approved by another Azure user' {
        Mock Assert-AdltAzureContextReady `
            -ModuleName AzureDataLabToolkit {
            [ordered]@{ accountType = 'User' }
        }
        Mock Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit {
            [pscustomobject]@{
                Id = '55555555-5555-4555-8555-555555555555'
            }
        }

        InModuleScope AzureDataLabToolkit {
            $plan = [ordered]@{}
            {
                Assert-AdltAzureMutationPrincipal `
                    -Plan $plan `
                    -ExpectedPrincipalId (
                        '99999999-9999-4999-8999-999999999999'
                    )
            } | Should -Throw '*does not match*'
        }
    }
}

Describe 'Azure context evidence' {
    AfterEach {
        InModuleScope AzureDataLabToolkit {
            Clear-AdltAzureDefaultProfileBinding
        }
    }

    It 'passes only for the exact cloud, tenant, subscription, and ready secure ARM token' {
        $testContext = New-TestAzureContext
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return $testContext
            }
            throw "Unexpected command: $CommandName"
        }
        InModuleScope AzureDataLabToolkit -Parameters @{
            TestContext = $testContext
        } {
            param($TestContext)

            Set-AdltAzureDefaultProfileBinding `
                -Context $TestContext `
                -TokenExpiresOn ([datetimeoffset]::UtcNow.AddHours(1))
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'pass'
        $evidence.stage | Should -Be 'validate'
        $evidence.probes.status | Should -Not -Contain 'fail'
        $evidence.payload.observedContext.Keys | Should -Not -Contain 'Token'
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Get-AzAccessToken'
            } `
            -Times 0
    }

    It 'does not renew the token-readiness observation during inspection' {
        $testContext = New-TestAzureContext
        $originalObservedAt = [datetimeoffset]::UtcNow.AddMinutes(-5)
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return $testContext
            }
            throw "Unexpected command: $CommandName"
        }
        InModuleScope AzureDataLabToolkit -Parameters @{
            TestContext      = $testContext
            OriginalObserved = $originalObservedAt
        } {
            param($TestContext, $OriginalObserved)

            Set-AdltAzureDefaultProfileBinding `
                -Context $TestContext `
                -TokenExpiresOn ([datetimeoffset]::UtcNow.AddHours(1))
            $script:AdltAzureTokenReadinessLease.observedAt =
                $OriginalObserved
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId
        $observedAfter = InModuleScope AzureDataLabToolkit {
            $script:AdltAzureTokenReadinessLease.observedAt
        }

        $evidence.status | Should -Be 'pass'
        $observedAfter | Should -BeExactly $originalObservedAt
    }

    It 'fails closed when the ARM token lease expires inside the readiness margin' {
        $testContext = New-TestAzureContext
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return $testContext
            }
            throw "Unexpected command: $CommandName"
        }
        InModuleScope AzureDataLabToolkit -Parameters @{
            TestContext = $testContext
        } {
            param($TestContext)

            Set-AdltAzureDefaultProfileBinding `
                -Context $TestContext `
                -TokenExpiresOn ([datetimeoffset]::UtcNow.AddHours(1))
            $script:AdltAzureTokenReadinessLease.expiresOn =
                [datetimeoffset]::UtcNow.AddMinutes(5)
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'fail'
        $tokenProbe = $evidence.probes |
            Where-Object probeId -eq 'probe.azure.context.arm-token'
        $tokenProbe.status | Should -Be 'fail'
        $tokenProbe.payload.failureKind |
            Should -Be 'reauthentication-required'
        $evidence.payload.observedContext.tokenExpiresAt |
            Should -BeNullOrEmpty
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Get-AzAccessToken'
            } `
            -Times 0
    }

    It 'fails closed when the ARM token lease is older than ten minutes' {
        $testContext = New-TestAzureContext
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return $testContext
            }
            throw "Unexpected command: $CommandName"
        }
        InModuleScope AzureDataLabToolkit -Parameters @{
            TestContext = $testContext
        } {
            param($TestContext)

            Set-AdltAzureDefaultProfileBinding `
                -Context $TestContext `
                -TokenExpiresOn ([datetimeoffset]::UtcNow.AddHours(1))
            $script:AdltAzureTokenReadinessLease.observedAt =
                [datetimeoffset]::UtcNow.AddMinutes(-11)
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'fail'
        ($evidence.probes |
            Where-Object probeId -eq 'probe.azure.context.arm-token'
        ).payload.failureKind | Should -Be 'reauthentication-required'
    }

    It 'does not serialize account or token-cache lease metadata' {
        $testContext = New-TestAzureContext `
            -AccountId 'private.user@example.test'
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return $testContext
            }
            throw "Unexpected command: $CommandName"
        }
        InModuleScope AzureDataLabToolkit -Parameters @{
            TestContext = $testContext
        } {
            param($TestContext)

            Set-AdltAzureDefaultProfileBinding `
                -Context $TestContext `
                -TokenExpiresOn ([datetimeoffset]::UtcNow.AddHours(1))
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $serialized = $evidence | ConvertTo-Json -Depth 20
        $evidence.status | Should -Be 'pass'
        $serialized | Should -Not -Match 'private.user@example.test'
        $serialized | Should -Not -Match 'TokenCache'
    }

    It 'invalidates a lease when the account changes in the same Azure scope' {
        $tokenCache = [pscustomobject]@{}
        $boundContext = New-TestAzureContext `
            -AccountId 'first.user@example.test' `
            -TokenCache $tokenCache
        $observedContext = New-TestAzureContext `
            -AccountId 'second.user@example.test' `
            -TokenCache $tokenCache
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return $observedContext
            }
            throw "Unexpected command: $CommandName"
        }
        InModuleScope AzureDataLabToolkit -Parameters @{
            BoundContext = $boundContext
        } {
            param($BoundContext)

            Set-AdltAzureDefaultProfileBinding `
                -Context $BoundContext `
                -TokenExpiresOn ([datetimeoffset]::UtcNow.AddHours(1))
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'fail'
        ($evidence.probes |
            Where-Object probeId -eq 'probe.azure.context.arm-token'
        ).payload.failureKind | Should -Be 'reauthentication-required'
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Get-AzAccessToken'
            } `
            -Times 0
    }

    It 'invalidates a lease when the token-cache instance changes' {
        $boundContext = New-TestAzureContext `
            -TokenCache ([pscustomobject]@{})
        $observedContext = New-TestAzureContext `
            -TokenCache ([pscustomobject]@{})
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return $observedContext
            }
            throw "Unexpected command: $CommandName"
        }
        InModuleScope AzureDataLabToolkit -Parameters @{
            BoundContext = $boundContext
        } {
            param($BoundContext)

            Set-AdltAzureDefaultProfileBinding `
                -Context $BoundContext `
                -TokenExpiresOn ([datetimeoffset]::UtcNow.AddHours(1))
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'fail'
        ($evidence.probes |
            Where-Object probeId -eq 'probe.azure.context.arm-token'
        ).payload.failureKind | Should -Be 'reauthentication-required'
    }

    It 'fails closed for the wrong subscription without requesting a token' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return New-TestAzureContext `
                    -SubscriptionId '99999999-9999-4999-8999-999999999999'
            }
            throw "Unexpected command: $CommandName"
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'fail'
        $subscriptionProbe = $evidence.probes |
            Where-Object probeId -eq 'probe.azure.context.subscription'
        $subscriptionProbe.status | Should -Be 'fail'
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter { $CommandName -eq 'Get-AzAccessToken' } `
            -Times 0
    }

    It 'requires a fresh process lease without retrying token acquisition' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return New-TestAzureContext
            }
            throw "Unexpected command: $CommandName"
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'fail'
        $tokenProbe = $evidence.probes |
            Where-Object probeId -eq 'probe.azure.context.arm-token'
        $tokenProbe.payload.failureKind |
            Should -Be 'reauthentication-required'
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter {
                $CommandName -eq 'Get-AzAccessToken'
            } `
            -Times 0
    }

    It 'reports no active context without attempting token acquisition' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                return $null
            }
            throw "Unexpected command: $CommandName"
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -Be 'fail'
        $evidence.payload.observedContext | Should -BeNullOrEmpty
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -ParameterFilter { $CommandName -eq 'Get-AzAccessToken' } `
            -Times 0
    }
}

Describe 'Azure token-readiness lease edge cases' {
    AfterEach {
        InModuleScope AzureDataLabToolkit {
            Clear-AdltAzureDefaultProfileBinding
        }
    }

    It 'requires complete account and token-cache evidence for a lease' {
        $missingAccount = New-TestAzureContext
        $missingAccount.Account.Id = ''
        $missingAccountType = New-TestAzureContext
        $missingAccountType.Account.Type = ''
        $missingTokenCache = New-TestAzureContext
        $missingTokenCache.PSObject.Properties.Remove('TokenCache')
        $validContext = New-TestAzureContext

        InModuleScope AzureDataLabToolkit -Parameters @{
            MissingAccount      = $missingAccount
            MissingAccountType  = $missingAccountType
            MissingTokenCache   = $missingTokenCache
            ValidContext        = $validContext
        } {
            param(
                $MissingAccount,
                $MissingAccountType,
                $MissingTokenCache,
                $ValidContext
            )

            Get-AdltAzureContextTokenCache -Context $null |
                Should -BeNullOrEmpty
            Get-AdltAzureContextTokenCache -Context $MissingTokenCache |
                Should -BeNullOrEmpty

            foreach ($context in @(
                $MissingAccount
                $MissingAccountType
                $MissingTokenCache
            )) {
                {
                    Set-AdltAzureDefaultProfileBinding `
                        -Context $context `
                        -TokenExpiresOn (
                            [datetimeoffset]::UtcNow.AddHours(1)
                        )
                } | Should -Throw '*lease is incomplete*'
            }

            {
                Set-AdltAzureDefaultProfileBinding `
                    -Context $ValidContext `
                    -TokenExpiresOn (
                        [datetimeoffset]::UtcNow.AddMinutes(5)
                    )
            } | Should -Throw '*expires too soon*'
        }
    }

    It 'fails closed for malformed or impossible lease metadata' {
        $testContext = New-TestAzureContext

        InModuleScope AzureDataLabToolkit -Parameters @{
            TestContext = $testContext
        } {
            param($TestContext)

            $asOf = [datetimeoffset]::UtcNow
            Set-AdltAzureDefaultProfileBinding `
                -Context $TestContext `
                -TokenExpiresOn $asOf.AddHours(1)

            $script:AdltAzureTokenReadinessLease.audience =
                'https://graph.microsoft.com/'
            $wrongAudience = Get-AdltAzureTokenReadinessLease `
                -Context $TestContext `
                -AsOf $asOf
            $wrongAudience.ready | Should -BeFalse
            $wrongAudience.failureKind |
                Should -BeExactly 'reauthentication-required'

            $script:AdltAzureTokenReadinessLease.audience =
                $script:AdltArmTokenAudience
            $script:AdltAzureTokenReadinessLease.observedAt =
                'not-a-timestamp'
            $malformed = Get-AdltAzureTokenReadinessLease `
                -Context $TestContext `
                -AsOf $asOf
            $malformed.ready | Should -BeFalse
            $malformed.expiresOn | Should -BeNullOrEmpty

            $script:AdltAzureTokenReadinessLease.observedAt =
                $asOf.AddMinutes(2)
            $script:AdltAzureTokenReadinessLease.expiresOn =
                $asOf.AddHours(1)
            $futureObservation = Get-AdltAzureTokenReadinessLease `
                -Context $TestContext `
                -AsOf $asOf
            $futureObservation.ready | Should -BeFalse

            $script:AdltAzureTokenReadinessLease.observedAt = $asOf
            $script:AdltAzureTokenReadinessLease.expiresOn = $asOf
            $invertedLifetime = Get-AdltAzureTokenReadinessLease `
                -Context $TestContext `
                -AsOf $asOf
            $invertedLifetime.ready | Should -BeFalse
            $invertedLifetime.expiresOn | Should -BeExactly $asOf
        }
    }
}

Describe 'Azure access-token readiness edge cases' {
    AfterEach {
        InModuleScope AzureDataLabToolkit {
            Clear-AdltAzureDefaultProfileBinding
        }
    }

    It 'distinguishes missing, invalid, and expiring secure tokens' {
        $secureToken = ConvertTo-SecureString `
            -String 'secure-test-token' `
            -AsPlainText `
            -Force

        InModuleScope AzureDataLabToolkit -Parameters @{
            SecureToken = $secureToken
        } {
            param($SecureToken)

            {
                Get-AdltAzureAccessTokenReadiness `
                    -AccessToken $null `
                    -MinimumRemainingLifetime ([timespan]::Zero)
            } | Should -Throw '*margin must be greater than zero*'

            $missing = Get-AdltAzureAccessTokenReadiness `
                -AccessToken $null
            $missing.ready | Should -BeFalse
            $missing.failureKind | Should -BeExactly 'missing-token'
            $missing.expiresOn | Should -BeNullOrEmpty

            $missingExpiry = Get-AdltAzureAccessTokenReadiness `
                -AccessToken ([pscustomobject]@{
                    Token = $SecureToken
                })
            $missingExpiry.ready | Should -BeFalse
            $missingExpiry.failureKind |
                Should -BeExactly 'invalid-expiry'

            $invalidExpiry = Get-AdltAzureAccessTokenReadiness `
                -AccessToken ([pscustomobject]@{
                    Token     = $SecureToken
                    ExpiresOn = 'not-a-timestamp'
                })
            $invalidExpiry.ready | Should -BeFalse
            $invalidExpiry.failureKind |
                Should -BeExactly 'invalid-expiry'

            $asOf = [datetimeoffset]::UtcNow
            $expiring = Get-AdltAzureAccessTokenReadiness `
                -AccessToken ([pscustomobject]@{
                    Token     = $SecureToken
                    ExpiresOn = $asOf.AddMinutes(5)
                }) `
                -AsOf $asOf `
                -MinimumRemainingLifetime ([timespan]::FromMinutes(10))
            $expiring.ready | Should -BeFalse
            $expiring.failureKind | Should -BeExactly 'token-expiring'
            $expiring.expiresOn |
                Should -BeExactly $asOf.AddMinutes(5)
        }
    }

    It 'records a failed probe when the Azure context cannot be read' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            if ($CommandName -eq 'Get-AzContext') {
                throw [System.InvalidOperationException]::new(
                    'Neutral context-read failure.'
                )
            }
            throw "Unexpected command: $CommandName"
        }

        $evidence = Test-AzureDataLabAzureContext `
            -Plan $script:Plan `
            -RunId $script:RunId

        $evidence.status | Should -BeExactly 'fail'
        $contextProbe = $evidence.probes |
            Where-Object probeId -eq 'probe.azure.context'
        $contextProbe.status | Should -BeExactly 'fail'
        $contextProbe.message |
            Should -BeExactly 'The current Azure context could not be read.'
        $contextProbe.payload.failureKind | Should -BeExactly 'unknown'
        $evidence.payload.observedContext | Should -BeNullOrEmpty
    }
}
