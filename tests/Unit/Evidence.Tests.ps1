BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
    $script:HashA = "sha256:$('a' * 64)"
    $script:HashB = "sha256:$('b' * 64)"
    $script:RunId = '33333333-3333-4333-8333-333333333333'
}

Describe 'Evidence model' {
    It 'creates schema-valid, self-hashed evidence without Azure access' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            HashA = $script:HashA
            HashB = $script:HashB
            RunId = $script:RunId
        } {
            $evidence = New-AdltEvidence `
                -RunId $RunId `
                -PlanHash $HashA `
                -IntentHash $HashB `
                -Stage plan `
                -Status pass `
                -Payload ([ordered]@{ resourceCount = 12 })

            $evidence.evidenceHash | Should -Match '^sha256:[a-f0-9]{64}$'
            {
                Assert-AdltEvidence -Evidence $evidence
            } | Should -Not -Throw
        }
    }

    It 'rejects nested secret fields and floating-point payloads' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            HashA = $script:HashA
            HashB = $script:HashB
            RunId = $script:RunId
        } {
            {
                New-AdltEvidence `
                    -RunId $RunId `
                    -PlanHash $HashA `
                    -IntentHash $HashB `
                    -Stage report `
                    -Status pass `
                    -Payload ([ordered]@{
                        nested = [ordered]@{
                            clientSecret = 'must-never-appear'
                        }
                    })
            } | Should -Throw -ExpectedMessage '*Secret values are forbidden*'

            {
                New-AdltEvidence `
                    -RunId $RunId `
                    -PlanHash $HashA `
                    -IntentHash $HashB `
                    -Stage cost `
                    -Status pass `
                    -Payload ([ordered]@{ estimate = 1.25 })
            } | Should -Throw -ExpectedMessage '*floating-point*'
        }
    }

    It 'rejects secret values hidden under benign field names' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            HashA = $script:HashA
            HashB = $script:HashB
            RunId = $script:RunId
        } {
            $unsafeValues = @(
                'https://example.test/file?sv=2026-01-01&sig=not-a-real-signature'
                'Password=not-a-real-password;Server=example.test'
                '-----BEGIN PRIVATE KEY----- not-a-real-key'
                'eyJaaaaaaaaaaaa.eyJbbbbbbbbbbbb.cccccccccccccc'
            )
            foreach ($unsafeValue in $unsafeValues) {
                {
                    New-AdltEvidence `
                        -RunId $RunId `
                        -PlanHash $HashA `
                        -IntentHash $HashB `
                        -Stage report `
                        -Status fail `
                        -Payload ([ordered]@{ output = $unsafeValue })
                } | Should -Throw -ExpectedMessage '*Sensitive value pattern*'
            }
        }
    }

    It 'requires the envelope status to match aggregate probe status' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            HashA = $script:HashA
            HashB = $script:HashB
            RunId = $script:RunId
        } {
            $probe = [ordered]@{
                probeId       = 'probe.compute.vm'
                status        = 'fail'
                correlationIds = @()
                observedAt    = '2026-07-28T09:31:00Z'
                message       = 'VM not ready.'
                payload       = [ordered]@{}
            }

            {
                New-AdltEvidence `
                    -RunId $RunId `
                    -PlanHash $HashA `
                    -IntentHash $HashB `
                    -Stage probe `
                    -Status pass `
                    -Probes @($probe)
            } | Should -Throw -ExpectedMessage '*must match aggregate*'
        }
    }
}

Describe 'Evidence export and import' {
    BeforeEach {
        $module = Get-Module AzureDataLabToolkit
        $script:Evidence = & $module {
            param($RunId, $PlanHash, $IntentHash)
            New-AdltEvidence `
                -RunId $RunId `
                -PlanHash $PlanHash `
                -IntentHash $IntentHash `
                -Stage report `
                -Status warning `
                -Payload ([ordered]@{
                    message = '<script>alert("not executable")</script>'
                })
        } $script:RunId $script:HashA $script:HashB
    }

    It 'round-trips canonical JSON and detects tampering' {
        $path = Join-Path $TestDrive 'evidence.json'
        Export-AzureDataLabEvidence `
            -Evidence $script:Evidence `
            -Format Json `
            -Path $path

        $loaded = Get-AzureDataLabEvidence -Path $path
        $loaded.evidenceHash | Should -BeExactly $script:Evidence.evidenceHash

        $tampered = Get-Content -LiteralPath $path -Raw |
            ConvertFrom-Json -AsHashtable
        $tampered.status = 'pass'
        Set-Content `
            -LiteralPath $path `
            -Value ($tampered | ConvertTo-Json -Depth 100 -Compress) `
            -Encoding utf8NoBOM

        {
            Get-AzureDataLabEvidence -Path $path
        } | Should -Throw -ExpectedMessage '*hash verification failed*'
    }

    It 'writes evidence exports with owner-only permissions on Unix' -Skip:$IsWindows {
        $path = Join-Path $TestDrive 'private-evidence.json'

        Export-AzureDataLabEvidence `
            -Evidence $script:Evidence `
            -Format Json `
            -Path $path

        $mode = [System.IO.File]::GetUnixFileMode($path)
        $mode | Should -Be (
            [System.IO.UnixFileMode]::UserRead -bor
                [System.IO.UnixFileMode]::UserWrite
        )
    }

    It 'renders script-free encoded HTML' {
        $html = Export-AzureDataLabEvidence `
            -Evidence $script:Evidence `
            -Format Html

        $html | Should -Match '<!doctype html>'
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
    }

    It 'renders untrusted Markdown fields as text without fence injection' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            HashA = $script:HashA
            HashB = $script:HashB
            RunId = $script:RunId
        } {
            $evidence = New-AdltEvidence `
                -RunId $RunId `
                -PlanHash $HashA `
                -IntentHash $HashB `
                -Stage report `
                -Status warning `
                -Probes @(
                    [ordered]@{
                        probeId       = 'probe.render.markdown'
                        status        = 'warning'
                        correlationIds = @()
                        observedAt    = '2026-07-28T09:31:00Z'
                        message       = '<script>x</script> [click](javascript:alert(1))'
                        payload       = [ordered]@{}
                    }
                ) `
                -Payload ([ordered]@{ text = '``` closes a short fence' })
            $markdown = ConvertTo-AdltEvidenceMarkdown -Evidence $evidence

            $markdown | Should -Not -Match '<script>'
            $markdown | Should -Not -Match '\[click\]\(javascript:'
            $markdown | Should -Not -Match '```json'
            $markdown | Should -Match '&lt;script&gt;'
        }
    }
}
