BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:ConfigurationPath = Join-Path `
        $script:RepositoryRoot `
        'examples/sqlvm-minimal.yaml'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

Describe 'Protected run orchestration helpers' {
    It 'rebinds generated evidence to the protected hash chain' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            ConfigurationPath = $script:ConfigurationPath
            StateRoot = Join-Path $TestDrive 'chain-state'
        } {
            param($ConfigurationPath, $StateRoot)

            $plan = New-AzureDataLabPlan -Path $ConfigurationPath
            $run = New-AdltLocalRunStore `
                -Plan $plan `
                -StateRoot $StateRoot
            $candidate = New-AdltEvidence `
                -RunId $run.RunId `
                -PlanHash $plan.planHash `
                -IntentHash $plan.intentHash `
                -Stage validate `
                -Status pass `
                -Payload ([ordered]@{ check = 'complete' })

            $attached = Add-AdltGeneratedRunEvidence `
                -RunPath $run.StatePath `
                -Evidence $candidate `
                -ActorId AzureDataLabToolkit
            $verified = Get-AdltVerifiedLocalRunContext `
                -RunPath $run.StatePath

            $attached.sequence | Should -Be 1
            $attached.previousEventHash |
                Should -BeExactly $verified.Evidence[0].evidenceHash
            @($verified.Evidence).Count | Should -Be 2
            $verified.Evidence[1].evidenceHash |
                Should -BeExactly $attached.evidenceHash
        }
    }

    It 'moves a planned run to blocked through an audited transition' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            ConfigurationPath = $script:ConfigurationPath
            StateRoot = Join-Path $TestDrive 'blocked-state'
        } {
            param($ConfigurationPath, $StateRoot)

            $plan = New-AzureDataLabPlan -Path $ConfigurationPath
            $run = New-AdltLocalRunStore `
                -Plan $plan `
                -StateRoot $StateRoot
            $state = Set-AdltRunBlocked `
                -RunPath $run.StatePath `
                -ActorId AzureDataLabToolkit

            $state.status | Should -BeExactly 'blocked'
            (Get-AdltVerifiedLocalRunContext `
                -RunPath $run.StatePath).State.status |
                Should -BeExactly 'blocked'
        }
    }

    It 'records the exact preflight block stage in the authoritative log' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            ConfigurationPath = $script:ConfigurationPath
            StateRoot = Join-Path $TestDrive 'preflight-block-state'
        } {
            param($ConfigurationPath, $StateRoot)

            $plan = New-AzureDataLabPlan -Path $ConfigurationPath
            $run = New-AdltLocalRunStore `
                -Plan $plan `
                -StateRoot $StateRoot
            [void] (Add-AdltLocalRunStatusTransition `
                -RunPath $run.StatePath `
                -Status authorizing `
                -ActorType toolkit `
                -ActorId AzureDataLabToolkit)

            $state = Set-AdltPreflightRunBlocked `
                -RunPath $run.StatePath `
                -Stage live-resolution `
                -ActorId AzureDataLabToolkit
            $context = Get-AdltVerifiedLocalRunContext `
                -RunPath $run.StatePath

            $state.status | Should -BeExactly 'blocked'
            $context.TailEvent.eventType |
                Should -BeExactly 'preflight-blocked'
            $context.TailEvent.data.stage |
                Should -BeExactly 'live-resolution'
        }
    }
}

Describe 'Invoke-AzureDataLabPreflight' {
    BeforeEach {
        $script:HashA = 'sha256:' + ('a' * 64)
        $script:HashB = 'sha256:' + ('b' * 64)
        $script:HashC = 'sha256:' + ('c' * 64)
        $script:HashD = 'sha256:' + ('d' * 64)
        $script:HashE = 'sha256:' + ('e' * 64)
        $script:RunId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $script:Plan = [ordered]@{
            target = [ordered]@{ type = 'sqlVm' }
            planHash = $script:HashA
            intentHash = $script:HashB
            configuration = [ordered]@{
                lifecycle = [ordered]@{
                    maximumRuntimeMinutes = 120
                }
            }
            approval = [ordered]@{
                requiredAcknowledgementIds = @(
                    'policy.test.acknowledge'
                )
            }
        }
        $script:State = [ordered]@{
            runId = $script:RunId
            status = 'planned'
            expiresAt = '2026-07-29T00:00:00.0000000Z'
        }
        $script:PlanEvidence = [ordered]@{
            stage = 'plan'
            evidenceHash = $script:HashC
        }
        $script:Context = [pscustomobject]@{
            Plan = $script:Plan
            State = $script:State
            Evidence = @($script:PlanEvidence)
            Artifacts = @()
            Events = @(
                [ordered]@{
                    eventType = 'run-created'
                    data = [ordered]@{}
                }
            )
            TailEvent = [ordered]@{
                eventType = 'run-created'
                data = [ordered]@{}
            }
        }
        $script:Live = [ordered]@{
            stage = 'live-resolution'
            status = 'pass'
            evidenceHash = $script:HashD
            payload = [ordered]@{}
        }
        $script:WhatIf = [ordered]@{
            stage = 'what-if'
            status = 'pass'
            evidenceHash = $script:HashE
            payload = [ordered]@{}
        }
        $script:Cost = [ordered]@{
            stage = 'cost'
            status = 'pass'
            evidenceHash = 'sha256:' + ('1' * 64)
            payload = [ordered]@{
                totalAmountMinorUnits = 1200
                maximumRunCost = [ordered]@{
                    amountMinorUnits = 5000
                }
                currency = 'USD'
            }
        }
        $script:Preview = [ordered]@{
            stage = 'teardown-preview'
            status = 'pass'
            evidenceHash = 'sha256:' + ('2' * 64)
            payload = [ordered]@{}
        }

        Mock Get-AdltVerifiedLocalRunContext `
            -ModuleName AzureDataLabToolkit { $script:Context }
        Mock Open-AdltLocalRunOperationLock `
            -ModuleName AzureDataLabToolkit {
            [System.IO.MemoryStream]::new()
        }
        Mock Add-AdltLocalRunStatusTransition `
            -ModuleName AzureDataLabToolkit {
            [pscustomobject]@{ State = $script:State }
        }
        Mock Get-AdltVerifiedPreflightEvidenceSet `
            -ModuleName AzureDataLabToolkit {
            [ordered]@{
                LiveResolution = $null
                WhatIf = $null
                Cost = $null
                TeardownPreview = $null
            }
        }
        Mock Resolve-AzureDataLabPlan `
            -ModuleName AzureDataLabToolkit { $script:Live }
        Mock Test-AzureDataLabWhatIf `
            -ModuleName AzureDataLabToolkit { $script:WhatIf }
        Mock New-AdltSqlVmCostEstimateEvidence `
            -ModuleName AzureDataLabToolkit { $script:Cost }
        Mock New-AdltPreDeploymentTeardownPreviewEvidence `
            -ModuleName AzureDataLabToolkit { $script:Preview }
        Mock Add-AdltValidatedPreflightEvidence `
            -ModuleName AzureDataLabToolkit {
            param($RunPath, $Evidence)
            $Evidence
        }
        Mock Set-AdltPreflightRunBlocked -ModuleName AzureDataLabToolkit
    }

    It 'returns a bounded approval summary after all four stages pass' {
        $result = Invoke-AzureDataLabPreflight `
            -RunPath '/protected/run'

        $result.Status | Should -BeExactly 'ready-for-approval'
        $result.EstimatedCostMinorUnits | Should -Be 1200
        $result.MaximumCostMinorUnits | Should -Be 5000
        $result.LiveResolutionEvidenceHash |
            Should -BeExactly $script:HashD
        Should -Invoke Add-AdltValidatedPreflightEvidence `
            -ModuleName AzureDataLabToolkit `
            -Times 4 `
            -Exactly
        Should -Invoke Add-AdltLocalRunStatusTransition `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $Status -eq 'authorizing' }
        Should -Not -Invoke Set-AdltPreflightRunBlocked `
            -ModuleName AzureDataLabToolkit
    }

    It 'blocks the run and stops before cost when WhatIf is not passing' {
        $script:WhatIf.status = 'fail'

        {
            Invoke-AzureDataLabPreflight `
                -RunPath '/protected/run'
        } | Should -Throw "*stage 'what-if'*"

        Should -Invoke Set-AdltPreflightRunBlocked `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $Stage -eq 'what-if' }
        Should -Not -Invoke New-AdltSqlVmCostEstimateEvidence `
            -ModuleName AzureDataLabToolkit
    }

    It 'requires explicit retry and positive preflight block provenance' {
        $script:State.status = 'blocked'
        $script:Context.TailEvent = [ordered]@{
            eventType = 'status-changed'
            data = [ordered]@{ status = 'blocked' }
        }

        {
            Invoke-AzureDataLabPreflight -RunPath '/protected/run'
        } | Should -Throw '*requires explicit*-RetryBlocked*'
        {
            Invoke-AzureDataLabPreflight `
                -RunPath '/protected/run' `
                -RetryBlocked
        } | Should -Throw '*typed preflight-blocked tail event*'

        Should -Not -Invoke Add-AdltLocalRunStatusTransition `
            -ModuleName AzureDataLabToolkit
        Should -Not -Invoke Set-AdltPreflightRunBlocked `
            -ModuleName AzureDataLabToolkit
    }

    It 'retries only the missing stage from a valid passing prefix' {
        $script:State.status = 'blocked'
        $script:Context.Evidence = @(
            $script:PlanEvidence
            $script:Live
        )
        $script:Context.Events = @(
            [ordered]@{
                eventType = 'run-created'
                data = [ordered]@{}
            }
            [ordered]@{
                eventType = 'status-changed'
                data = [ordered]@{ status = 'authorizing' }
            }
            [ordered]@{
                eventType = 'evidence-attached'
                data = [ordered]@{}
            }
            [ordered]@{
                eventType = 'preflight-blocked'
                data = [ordered]@{
                    status = 'blocked'
                    stage = 'what-if'
                }
            }
        )
        $script:Context.TailEvent = $script:Context.Events[-1]
        Mock Get-AdltVerifiedPreflightEvidenceSet `
            -ModuleName AzureDataLabToolkit {
            [ordered]@{
                LiveResolution = $script:Live
                WhatIf = $null
                Cost = $null
                TeardownPreview = $null
            }
        }

        $result = Invoke-AzureDataLabPreflight `
            -RunPath '/protected/run' `
            -RetryBlocked

        $result.Status | Should -BeExactly 'ready-for-approval'
        Should -Not -Invoke Resolve-AzureDataLabPlan `
            -ModuleName AzureDataLabToolkit
        Should -Invoke Test-AzureDataLabWhatIf `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly
        Should -Invoke Add-AdltLocalRunStatusTransition `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $Status -eq 'authorizing' }
    }

    It 'does not attach failed evidence to the append-only chain' {
        $script:Live.status = 'fail'

        {
            Invoke-AzureDataLabPreflight -RunPath '/protected/run'
        } | Should -Throw "*stage 'live-resolution'*"

        Should -Not -Invoke Add-AdltValidatedPreflightEvidence `
            -ModuleName AzureDataLabToolkit
        Should -Invoke Set-AdltPreflightRunBlocked `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly `
            -ParameterFilter { $Stage -eq 'live-resolution' }
    }

    It 'requires a new run when a retained retry prefix is stale' {
        $script:State.status = 'blocked'
        $script:Context.Evidence = @(
            $script:PlanEvidence
            $script:Live
        )
        $script:Context.Events = @(
            [ordered]@{
                eventType = 'run-created'
                data = [ordered]@{}
            }
            [ordered]@{
                eventType = 'status-changed'
                data = [ordered]@{ status = 'authorizing' }
            }
            [ordered]@{
                eventType = 'evidence-attached'
                data = [ordered]@{}
            }
            [ordered]@{
                eventType = 'preflight-blocked'
                data = [ordered]@{
                    status = 'blocked'
                    stage = 'what-if'
                }
            }
        )
        $script:Context.TailEvent = $script:Context.Events[-1]
        Mock Get-AdltVerifiedPreflightEvidenceSet `
            -ModuleName AzureDataLabToolkit {
            throw 'Live-resolution evidence is outside the freshness window.'
        }

        {
            Invoke-AzureDataLabPreflight `
                -RunPath '/protected/run' `
                -RetryBlocked
        } | Should -Throw '*outside the freshness window*'

        Should -Not -Invoke Add-AdltLocalRunStatusTransition `
            -ModuleName AzureDataLabToolkit
        Should -Not -Invoke Set-AdltPreflightRunBlocked `
            -ModuleName AzureDataLabToolkit
    }
}
