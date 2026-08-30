BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Remove-Module AzureDataLabToolkit -Force -ErrorAction SilentlyContinue
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module AzureDataLabToolkit -Force -ErrorAction SilentlyContinue
}

Describe 'Idempotent teardown resolution outcomes' {
        BeforeEach {
            $script:ResolverRunPath = Join-Path $TestDrive 'run'
            $script:ResolverOperationId =
                '11111111-1111-4111-8111-111111111111'
            $script:ResolverRecord = [ordered]@{
                operationId = $script:ResolverOperationId
                cleanupLease = [ordered]@{
                    approver = [ordered]@{
                        id = '22222222-2222-4222-8222-222222222222'
                    }
                }
                deleteAction = [ordered]@{
                    resourceGroupName = 'rg-adlt-resolver'
                }
            }
            $script:ResolverContext = [pscustomobject][ordered]@{
                State = [ordered]@{
                    runId = '33333333-3333-4333-8333-333333333333'
                    status = 'teardown-approved'
                    scope = [ordered]@{
                        cloud = 'AzureCloud'
                        tenantId =
                            '44444444-4444-4444-8444-444444444444'
                        subscriptionId =
                            '55555555-5555-4555-8555-555555555555'
                        resourceGroupName = 'rg-adlt-resolver'
                    }
                }
                Plan = [ordered]@{}
                Events = @()
                Evidence = @()
            }

            Mock Get-AdltVerifiedLocalRunContext {
                $script:ResolverContext
            } -ModuleName AzureDataLabToolkit
            Mock Open-AdltAzureScopeOperationLock {
                [System.IO.MemoryStream]::new()
            } -ModuleName AzureDataLabToolkit
            Mock Open-AdltLocalRunOperationLock {
                [System.IO.MemoryStream]::new()
            } -ModuleName AzureDataLabToolkit
            Mock Get-AdltTeardownExecutionRecordFromContext {
                $script:ResolverRecord
            } -ModuleName AzureDataLabToolkit
            Mock Assert-AdltAzureMutationPrincipal {
                [ordered]@{
                    id = '22222222-2222-4222-8222-222222222222'
                }
            } -ModuleName AzureDataLabToolkit
            Mock Get-AdltApprovedResourceDeletionObservation {
                throw 'Deletion observation must not be repeated.'
            } -ModuleName AzureDataLabToolkit
        }

        It 'returns an approved operation that never started' {
            $result = Resolve-AzureDataLabTeardown `
                -RunPath $script:ResolverRunPath

            $result.Status | Should -BeExactly 'approved-not-started'
            $result.OperationId |
                Should -BeExactly $script:ResolverOperationId
            $result.ResourceGroupName |
                Should -BeExactly 'rg-adlt-resolver'
            $result.RequiresReconciliation | Should -BeFalse
            Should -Invoke `
                -CommandName Get-AdltApprovedResourceDeletionObservation `
                -ModuleName AzureDataLabToolkit `
                -Times 0 `
                -Exactly
        }

        It 'returns the existing terminal cleanup proof' {
            $evidenceHash = 'sha256:{0}' -f ('a' * 64)
            $script:ResolverContext.State.status = 'completed'
            $script:ResolverContext.Events = @(
                [ordered]@{
                    eventType = 'teardown-operation-finished'
                    data = [ordered]@{
                        operationId = $script:ResolverOperationId
                        evidenceHash = $evidenceHash
                    }
                }
            )
            $script:ResolverContext.Evidence = @(
                [ordered]@{
                    evidenceHash = $evidenceHash
                    payload = [ordered]@{
                        resourceGroupState = 'present'
                        retainedUnapprovedResourceCount = 2
                    }
                }
            )

            $result = Resolve-AzureDataLabTeardown `
                -RunPath $script:ResolverRunPath

            $result.Status | Should -BeExactly 'completed'
            $result.EvidenceHash | Should -BeExactly $evidenceHash
            $result.ResourceGroupRetained | Should -BeTrue
            $result.RetainedUnapprovedResourceCount | Should -Be 2
            $result.RequiresReconciliation | Should -BeFalse
            Should -Invoke `
                -CommandName Get-AdltApprovedResourceDeletionObservation `
                -ModuleName AzureDataLabToolkit `
                -Times 0 `
                -Exactly
        }

        It 'records an uncertain started teardown without resubmitting' {
            $script:ResolverContext.State.status = 'tearing-down'
            $script:ResolverContext.Events = @(
                [ordered]@{
                    eventType = 'teardown-operation-started'
                    occurredAt = '2026-07-29T00:00:00.0000000Z'
                    data = [ordered]@{
                        operationId = $script:ResolverOperationId
                    }
                }
            )
            Mock Get-AdltApprovedResourceDeletionObservation {
                [ordered]@{
                    state = 'unknown'
                    failureKind = 'throttled'
                }
            } -ModuleName AzureDataLabToolkit
            Mock Add-AdltLocalTeardownOperationEvent {
                [ordered]@{
                    eventHash = 'sha256:{0}' -f ('b' * 64)
                }
            } -ModuleName AzureDataLabToolkit

            $result = Resolve-AzureDataLabTeardown `
                -RunPath $script:ResolverRunPath

            $result.Status | Should -BeExactly 'cleanup-unknown'
            $result.RequiresReconciliation | Should -BeTrue
            $result.EvidenceHash | Should -BeNullOrEmpty
            Should -Invoke `
                -CommandName Get-AdltApprovedResourceDeletionObservation `
                -ModuleName AzureDataLabToolkit `
                -Times 1 `
                -Exactly
            Should -Invoke `
                -CommandName Add-AdltLocalTeardownOperationEvent `
                -ModuleName AzureDataLabToolkit `
                -ParameterFilter {
                    $EventType -ceq 'teardown-operation-uncertain' -and
                    $Data.operationId -ceq
                        $script:ResolverOperationId -and
                    $Data.reason -ceq 'throttled'
                } `
                -Times 1 `
                -Exactly
        }
}
