BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    $script:MinimalConfigurationPath = Join-Path $script:RepositoryRoot 'examples/sqlvm-minimal.yaml'
    $script:BackupConfigurationPath = Join-Path $script:RepositoryRoot 'examples/sqlvm-backup-share.yaml'
    $script:MinimalPlanHashPath = Join-Path `
        $script:RepositoryRoot `
        'tests/Fixtures/sqlvm-minimal.plan.sha256'
    $script:PlanSchemaPath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/Schemas/plan.schema.json'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

Describe 'Deterministic normalized plans' {
    It 'produces the same canonical JSON and hash for repeated planning' {
        $first = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $second = New-AzureDataLabPlan $script:MinimalConfigurationPath

        $first.planHash | Should -BeExactly $second.planHash
        (Export-AzureDataLabPlan $first -Format Json) |
            Should -BeExactly (Export-AzureDataLabPlan $second -Format Json)
    }

    It 'matches the checked cross-platform minimal-plan hash' {
        $expectedHash = [System.IO.File]::ReadAllText(
            $script:MinimalPlanHashPath
        ).Trim()

        (New-AzureDataLabPlan $script:MinimalConfigurationPath).planHash |
            Should -BeExactly $expectedHash
    }

    It 'uses the RFC 8785 member ordering for the supported integer domain' {
        InModuleScope AzureDataLabToolkit {
            $value = [ordered]@{
                z     = 1
                a     = 'é'
                array = @(3, $true, $null)
            }

            ConvertTo-AdltCanonicalJson $value |
                Should -BeExactly '{"a":"é","array":[3,true,null],"z":1}'
        }
    }

    It 'rejects integers outside the interoperable RFC 8785 range' {
        InModuleScope AzureDataLabToolkit {
            ConvertTo-AdltCanonicalJson ([int64] 9007199254740991) |
                Should -Be '9007199254740991'
            {
                ConvertTo-AdltCanonicalJson ([uint64] 9007199254740992)
            } | Should -Throw -ExpectedMessage '*interoperable range*'
        }
    }

    It 'contains no timestamp, run ID, random ID, or local input path' {
        $planJson = Export-AzureDataLabPlan `
            (New-AzureDataLabPlan $script:MinimalConfigurationPath) `
            -Format Json

        $planJson | Should -Not -Match 'generatedAt|runIntentId|timestamp'
        $planJson | Should -Not -Match [regex]::Escape($script:RepositoryRoot)
    }

    It 'represents Azure-dependent facts as unverified' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
        foreach ($fact in $plan.unverifiedFacts.Values) {
            $fact.status | Should -Be 'unverified'
            $fact.resolvedBy | Should -Not -BeNullOrEmpty
        }
    }

    It 'records structured support evaluation and warning status' {
        $plan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -VmSecurityType standard

        $plan.target.planSupport | Should -Be 'supported-with-warning'
        $plan.target.deploymentStatus | Should -Be 'unavailable'
        $securityEvaluation = $plan.supportEvaluation |
            Where-Object axis -EQ 'securityType'
        $securityEvaluation.value | Should -Be 'standard'
        $securityEvaluation.plan | Should -Be 'supported-with-warning'
        $securityEvaluation.supported | Should -BeTrue
    }

    It 'advertises deployment only when every selected capability is available' {
        $canaryPath = Join-Path `
            $script:RepositoryRoot `
            'examples/sqlvm-first-canary.yaml'
        $plan = New-AzureDataLabPlan $canaryPath

        $plan.target.deploymentStatus | Should -Be 'available'
        @(
            $plan.supportEvaluation |
                Where-Object deployment -NE 'available'
        ).Count | Should -Be 0
    }

    It 'records versioned contributor and available PowerShell engine contracts' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath

        $plan.contracts.configurationSchemaVersion | Should -Be '1.0'
        $plan.contracts.planSchemaVersion | Should -Be '1.0'
        $plan.contracts.contributors.targetProvider.name | Should -Be 'sqlVm'
        $plan.contracts.contributors.capabilities.name |
            Should -Contain 'keyVault'
        $plan.contracts.contributors.capabilities.name |
            Should -Contain 'bastion'
        $plan.contracts.engine.name | Should -Be 'powershell'
        $plan.contracts.engine.contractVersion |
            Should -BeExactly 'sqlvm-first-canary/v1'
        $plan.contracts.engine.implementationStatus | Should -Be 'available'
    }

    It 'rejects an incomplete contributor contract through the plan schema' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $plan.contracts.contributors.targetProvider.Remove(
            'implementationVersion'
        )
        $schemaPath = Join-Path `
            $script:RepositoryRoot `
            'src/AzureDataLabToolkit/Schemas/plan.schema.json'

        Test-Json `
            -Json ($plan | ConvertTo-Json -Depth 100 -Compress) `
            -SchemaFile $schemaPath `
            -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'binds targeted acknowledgements and blockers to the plan hash contract' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath

        $plan.approval.acknowledgementPlanHashRequired | Should -BeTrue
        $plan.approval.requiredAcknowledgementIds |
            Should -Contain 'policy.licensing.authoritative-terms-required'
        $plan.approval.requiredAcknowledgementIds |
            Should -Contain 'policy.lifecycle.runtime-not-enforced'
        $plan.approval.blockingFindingIds |
            Should -Contain 'policy.credentials.external-secret-required'
        $plan.approval.blockingFindingIds |
            Should -Contain 'policy.cost.maximum-run-cost-required'

        $blocking = $plan.policyFindings |
            Where-Object id -EQ 'policy.credentials.external-secret-required'
        $blocking.effect | Should -Be 'resolve-before-deploy'
        $blocking.blocksDeployment | Should -BeTrue
    }

    It 'records bounded lifecycle intent without granting cleanup authority' {
        $plan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -Purpose canary `
            -CostEstimate `
            -MaximumRunCostMinorUnits 2500 `
            -PreauthorizeTeardown `
            -DeleteBackupShareOnTeardown

        $plan.decisions.lifecycle.purpose | Should -Be 'canary'
        $plan.decisions.lifecycle.maximumRuntimeMinutes | Should -Be 180
        $plan.decisions.lifecycle.timeToLiveMinutes | Should -Be 240
        $plan.decisions.lifecycle.expiryBehavior | Should -Be 'cleanup-only'
        $plan.decisions.cost.maximumRunCost.amountMinorUnits | Should -Be 2500
        $plan.approval.requiredAcknowledgementIds |
            Should -Contain 'policy.lifecycle.preauthorized-canary-teardown'
        $plan.approval.teardownRequiresSeparatePlan | Should -BeTrue
    }

    It 'changes the credential gate only after explicit password-generation opt-in' {
        $plan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -GeneratePassword
        $secretAction = $plan.actions |
            Where-Object id -EQ 'action.security.key-vault-secret.vm-admin'

        $plan.approval.blockingFindingIds |
            Should -Not -Contain 'policy.credentials.external-secret-required'
        $plan.approval.requiredAcknowledgementIds |
            Should -Contain 'policy.credentials.generated-password'
        $secretAction.operation | Should -Be 'ensure'
        $secretAction.mutation | Should -BeTrue
    }
}

Describe 'Ownership and idempotency contracts' {
    BeforeAll {
        $script:Plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
    }

    It 'declares intent without claiming observed ownership' {
        foreach ($resource in $script:Plan.resources) {
            $resource.ownership.intent | Should -BeIn @('create', 'reuse', 'observe')
            $resource.ownership.observedClassification | Should -Be 'unverified'
            $resource.ownership.collisionPolicy | Should -Be 'fail'
            $resource.ownership.replacePolicy | Should -Be 'forbidden'
            $resource.ownership.teardownIntent | Should -Not -BeNullOrEmpty
        }
    }

    It 'gives every action an idempotency and reconciliation contract' {
        foreach ($action in $script:Plan.actions) {
            $action.idempotencyKey | Should -Match '^adlt:v1:'
            $action.retryClass | Should -Be 'reconcile-before-retry'
            $action.reconciliation.beforeAttempt | Should -Be 'required'
            $action.reconciliation.afterAttempt | Should -Be 'required'
            $action.reconciliation.unknownState | Should -Be 'stop'
            if ($action.executionScope -eq 'offline') {
                $action.preconditions | Should -Not -Contain 'live-state-observed'
                $action.preconditions | Should -Contain 'local-input-contract-valid'
                $action.reconciliation.stateSource |
                    Should -Be 'local-artifact-state'
            }
            else {
                $action.preconditions | Should -Contain 'live-state-observed'
            }
        }
    }

    It 'rejects a corrupted offline execution contract' {
        $candidate = New-AzureDataLabPlan $script:BackupConfigurationPath
        $action = $candidate.actions |
            Where-Object id -EQ 'action.guest.mount-script.backups'
        $action.mutation = $true
        $action.reconciliation.stateSource = 'azure-control-plane'
        $module = Get-Module AzureDataLabToolkit

        {
            & $module {
                param($Plan)
                Assert-AdltPlanStructure -Plan $Plan
            } $candidate
        } | Should -Throw -ExpectedMessage '*cannot mutate*offline*'
        Test-Json `
            -Json ($candidate | ConvertTo-Json -Depth 100 -Compress) `
            -SchemaFile $script:PlanSchemaPath `
            -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'rejects a corrupted Azure execution contract' {
        $candidate = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $action = $candidate.actions |
            Where-Object id -EQ 'action.compute.virtual-machine.primary'
        $action.preconditions = @(
            $action.preconditions |
                Where-Object { $_ -ne 'ownership-established' }
        )
        $action.reconciliation.stateSource = 'guest-probe'
        $module = Get-Module AzureDataLabToolkit

        {
            & $module {
                param($Plan)
                Assert-AdltPlanStructure -Plan $Plan
            } $candidate
        } | Should -Throw -ExpectedMessage '*wrong reconciliation state source*'
        Test-Json `
            -Json ($candidate | ConvertTo-Json -Depth 100 -Compress) `
            -SchemaFile $script:PlanSchemaPath `
            -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'rejects a corrupted guest execution contract' {
        $candidate = New-AzureDataLabPlan $script:BackupConfigurationPath
        $action = $candidate.actions |
            Where-Object id -EQ 'action.guest.mount-script.stage.backups'
        $action.preconditions = @(
            $action.preconditions |
                Where-Object { $_ -ne 'live-state-observed' }
        )
        $action.reconciliation.stateSource = 'azure-control-plane'
        $module = Get-Module AzureDataLabToolkit

        {
            & $module {
                param($Plan)
                Assert-AdltPlanStructure -Plan $Plan
            } $candidate
        } | Should -Throw -ExpectedMessage '*wrong reconciliation state source*'
        Test-Json `
            -Json ($candidate | ConvertTo-Json -Depth 100 -Compress) `
            -SchemaFile $script:PlanSchemaPath `
            -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'scopes idempotency keys to the complete plan intent' {
        $otherPlan = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -Name 'different-lab'

        $script:Plan.intentHash | Should -Not -Be $otherPlan.intentHash
        $script:Plan.actions.idempotencyKey |
            Should -Not -Be $otherPlan.actions.idempotencyKey
    }

    It 'rejects desired resource mutation under the original intent and keys' {
        $candidate = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $resource = $candidate.resources |
            Where-Object id -EQ 'azure.compute.virtual-machine.primary'
        $resource.desiredProperties.osProfile.enableAutomaticUpdates = $false
        $module = Get-Module AzureDataLabToolkit

        & $module {
            param($Plan)
            $Plan.planHash = Get-AdltPlanHash -Plan $Plan
        } $candidate

        {
            & $module {
                param($Plan)
                Assert-AdltPlanContract -Plan $Plan
            } $candidate
        } | Should -Throw -ExpectedMessage '*intent hash verification failed*'
    }

    It 'rejects executable action mutation under the original intent and keys' {
        $candidate = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $action = $candidate.actions |
            Where-Object id -EQ 'action.compute.virtual-machine.primary'
        $action.mutation = $false
        $module = Get-Module AzureDataLabToolkit

        & $module {
            param($Plan)
            $Plan.planHash = Get-AdltPlanHash -Plan $Plan
        } $candidate

        {
            & $module {
                param($Plan)
                Assert-AdltPlanContract -Plan $Plan
            } $candidate
        } | Should -Throw -ExpectedMessage '*intent hash verification failed*'
    }

    It 'rejects sensitive values hidden under benign plan field names' {
        $sensitiveValues = @(
            'Password=NeverEchoThisValue!'
            'https://account.blob.core.windows.net/backups/db.bak?sv=2025-01-05&sp=r&sig=NeverEchoThisSignature'
            '-----BEGIN PRIVATE KEY----- NeverEchoThisKey'
            'Bearer NeverEchoThisBearerToken12345'
        )
        $module = Get-Module AzureDataLabToolkit

        foreach ($sensitiveValue in $sensitiveValues) {
            $candidate = New-AzureDataLabPlan `
                $script:MinimalConfigurationPath
            $resource = $candidate.resources |
                Where-Object id -EQ 'azure.compute.virtual-machine.primary'
            $resource.desiredProperties.notes = $sensitiveValue

            $message = {
                & $module {
                    param($Plan)
                    Assert-AdltPlanContract -Plan $Plan
                } $candidate
            } | Should -Throw -ExpectedMessage '*Sensitive value pattern*' `
                -PassThru
            $message.Exception.Message | Should -Not -Match 'NeverEchoThis'
        }
    }

    It 'accepts benign values in a completed plan intent' {
        $candidate = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $resource = $candidate.resources |
            Where-Object id -EQ 'azure.compute.virtual-machine.primary'
        $resource.desiredProperties.notes = (
            'Bearer authentication is documented at ' +
            'https://learn.microsoft.com/azure/azure-resource-manager/' +
            'management/resource-name-rules?view=azure-resource-manager. ' +
            'Resource /subscriptions/22222222-2222-4222-8222-222222222222/' +
            "resourceGroups/rg-adlt-test uses sha256:$('a' * 64)."
        )
        $module = Get-Module AzureDataLabToolkit

        {
            & $module {
                param($Plan)
                [void] (Set-AdltPlanIntentBinding -Plan $Plan)
                Assert-AdltPlanContract -Plan $Plan
            } $candidate
        } | Should -Not -Throw
    }

    It 'changes every action key when an active contributor contract changes' {
        $module = Get-Module AzureDataLabToolkit
        $comparison = & $module {
            param($ConfigurationPath)

            $descriptor = $script:AdltCapabilityPlanContributors['keyVault']
            $originalContractVersion = $descriptor.contractVersion
            try {
                $before = New-AzureDataLabPlan $ConfigurationPath
                $descriptor.contractVersion = '9.9'
                $after = New-AzureDataLabPlan $ConfigurationPath
            }
            finally {
                $descriptor.contractVersion = $originalContractVersion
            }

            [pscustomobject]@{
                BeforeIntentHash = $before.intentHash
                AfterIntentHash  = $after.intentHash
                BeforeKeys       = @($before.actions.idempotencyKey)
                AfterKeys        = @($after.actions.idempotencyKey)
            }
        } $script:MinimalConfigurationPath

        $comparison.BeforeIntentHash |
            Should -Not -BeExactly $comparison.AfterIntentHash
        $comparison.BeforeKeys |
            Should -Not -Be $comparison.AfterKeys
    }

    It 'keeps the hash suffix when long names produce storage accounts' {
        $first = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -Name 'abcdefghijklmnopqrst-alpha' `
            -EnableBackupShare
        $second = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -Name 'abcdefghijklmnopqrst-beta' `
            -EnableBackupShare
        $firstName = (
            $first.resources |
                Where-Object id -EQ 'azure.storage.account.backups'
        ).logicalName
        $secondName = (
            $second.resources |
                Where-Object id -EQ 'azure.storage.account.backups'
        ).logicalName

        $firstVaultName = (
            $first.resources |
                Where-Object id -EQ 'azure.security.key-vault.primary'
        ).logicalName
        $secondVaultName = (
            $second.resources |
                Where-Object id -EQ 'azure.security.key-vault.primary'
        ).logicalName

        $firstName | Should -Match '^adlt[a-z0-9]{1,8}[a-f0-9]{12}$'
        $firstName.Length | Should -BeLessOrEqual 24
        $firstName | Should -Not -BeExactly $secondName
        $firstVaultName | Should -Match '^adlt-[a-z0-9-]{1,6}-[a-f0-9]{12}$'
        $firstVaultName.Length | Should -BeLessOrEqual 24
        $firstVaultName | Should -Not -BeExactly $secondVaultName
    }

    It 'uses resource-group identity when generating globally unique names' {
        $first = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -Name 'same-lab' `
            -ResourceGroupName 'rg-one' `
            -EnableBackupShare
        $second = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -Name 'same-lab' `
            -ResourceGroupName 'RG-TWO' `
            -EnableBackupShare
        $sameResourceGroupDifferentCase = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -Name 'same-lab' `
            -ResourceGroupName 'RG-ONE' `
            -EnableBackupShare

        foreach ($resourceId in @(
                'azure.security.key-vault.primary',
                'azure.storage.account.backups'
            )) {
            $firstName = (
                $first.resources |
                    Where-Object id -EQ $resourceId
            ).logicalName
            $secondName = (
                $second.resources |
                    Where-Object id -EQ $resourceId
            ).logicalName
            $sameResourceGroupName = (
                $sameResourceGroupDifferentCase.resources |
                    Where-Object id -EQ $resourceId
            ).logicalName

            $firstName | Should -Not -BeExactly $secondName
            $firstName | Should -BeExactly $sameResourceGroupName
        }
    }

    It 'normalizes subscription identity when generating global names' {
        $lowercaseSubscriptionId = 'abcdefab-cdef-4abc-8def-abcdefabcdef'
        $uppercaseSubscriptionId = $lowercaseSubscriptionId.ToUpperInvariant()
        $first = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -SubscriptionId $lowercaseSubscriptionId `
            -EnableBackupShare
        $second = New-AzureDataLabPlan `
            $script:MinimalConfigurationPath `
            -SubscriptionId $uppercaseSubscriptionId `
            -EnableBackupShare

        foreach ($resourceId in @(
                'azure.security.key-vault.primary',
                'azure.storage.account.backups'
            )) {
            $firstName = (
                $first.resources |
                    Where-Object id -EQ $resourceId
            ).logicalName
            $secondName = (
                $second.resources |
                    Where-Object id -EQ $resourceId
            ).logicalName

            $firstName | Should -BeExactly $secondName
        }
    }

    It 'keeps deletion in a separately approved teardown plan' {
        $script:Plan.approval.destructiveActions | Should -BeNullOrEmpty
        $script:Plan.approval.teardownRequiresSeparatePlan | Should -BeTrue
        $script:Plan.resources.ownership.teardownIntent |
            Should -Contain 'delete-after-proof-and-approval'
    }

    It 'rejects duplicate semantic action IDs' {
        $candidate = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $candidate.actions += $candidate.actions[0]
        $module = Get-Module AzureDataLabToolkit

        {
            & $module {
                param($Plan)
                Assert-AdltPlanStructure -Plan $Plan
            } $candidate
        } | Should -Throw -ExpectedMessage '*duplicate action ID*'
    }

    It 'rejects missing and cyclic action dependencies' {
        $missing = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $missing.actions[0].dependsOn = @('action.does-not-exist')
        $module = Get-Module AzureDataLabToolkit

        {
            & $module {
                param($Plan)
                Assert-AdltPlanStructure -Plan $Plan
            } $missing
        } | Should -Throw -ExpectedMessage '*depends on unknown action*'

        $cyclic = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $cyclic.actions[0].dependsOn = @($cyclic.actions[1].id)
        $cyclic.actions[1].dependsOn = @($cyclic.actions[0].id)
        {
            & $module {
                param($Plan)
                Assert-AdltPlanStructure -Plan $Plan
            } $cyclic
        } | Should -Throw -ExpectedMessage '*contain a cycle*'
    }
}

Describe 'Backup-share plan contribution' {
    BeforeAll {
        $script:BackupPlan = New-AzureDataLabPlan $script:BackupConfigurationPath
    }

    It 'adds pinned dbatools as a derived conditional dependency' {
        $selection = $script:BackupPlan.catalogSelections |
            Where-Object id -EQ 'software.dbatools'

        $selection.version | Should -Be '2.8.2'
        $selection.deploymentReadiness | Should -Be 'blocked-pending-integrity'
        $script:BackupPlan.provenance['sqlVm.software.catalogIds'].derivation |
            Should -Be 'backup-share-requires-dbatools'
    }

    It 'keeps restore manual, preview-first, and replacement-disabled' {
        $action = $script:BackupPlan.actions |
            Where-Object id -EQ 'action.guest.restore-script.render.backups'

        $action.postconditions | Should -Contain 'manual-restore-required'
        $action.postconditions | Should -Contain 'preview-is-default'
        $action.postconditions | Should -Contain 'execute-switch-required'
        $action.postconditions | Should -Contain 'database-replacement-disabled'
        $action.mutation | Should -BeFalse
        $script:BackupPlan.decisions.guestExecution.automaticRestore | Should -BeFalse
        $script:BackupPlan.decisions.guestExecution.systemUserRestore | Should -BeFalse
        $script:BackupPlan.decisions.solutionPacks.sqlVmBackupRestore.secretStoreDecision.mode |
            Should -Be 'not-applicable'
        $script:BackupPlan.decisions.solutionPacks.sqlVmBackupRestore.secretStoreDecision.rationale |
            Should -Not -BeNullOrEmpty
    }

    It 'retains backup storage until a separate deletion approval' {
        $storageResources = @(
            $script:BackupPlan.resources |
                Where-Object id -Like 'azure.storage.*'
        )

        $storageResources.Count | Should -Be 2
        foreach ($resource in $storageResources) {
            $resource.ownership.teardownIntent |
                Should -Be 'retain-until-separately-approved'
        }
    }
}

Describe 'Plan export safety' {
    It 'renders JSON, Markdown, and standalone HTML' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath

        (Export-AzureDataLabPlan $plan -Format Json) | Should -Match '"planHash":'
        $markdown = Export-AzureDataLabPlan $plan -Format Markdown
        $markdown | Should -Match '# Azure Data Lab Plan'
        $markdown | Should -Match '## Policy findings'
        $html = Export-AzureDataLabPlan $plan -Format Html
        $html | Should -Match '<!doctype html>'
        $html | Should -Match 'Policy findings'
        $html | Should -Match 'policy.credentials.external-secret-required'
        $html |
            Should -Match 'template-deployment-authorization-proven-by-native-whatif'
        $html | Should -Match 'action.security.key-vault-secret.vm-admin'
        $html | Should -Match 'required acknowledgements'
        $html | Should -Not -Match '<script'
    }

    It 'refuses a tampered plan' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $plan.context.location = 'westus2'

        {
            Export-AzureDataLabPlan $plan -Format Json
        } | Should -Throw -ExpectedMessage '*Plan hash verification failed*'
    }

    It 'does not overwrite an existing output unless Force is explicit' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $path = Join-Path $TestDrive 'plan.html'
        Set-Content -LiteralPath $path -Value 'existing' -Encoding utf8NoBOM

        {
            Export-AzureDataLabPlan $plan -Format Html -Path $path
        } | Should -Throw -ExpectedMessage '*already exists*'

        Export-AzureDataLabPlan $plan -Format Html -Path $path -Force |
            Should -Be ([System.IO.Path]::GetFullPath($path))
        Get-Content -LiteralPath $path -Raw | Should -Match '<!doctype html>'
    }

    It 'honors PowerShell WhatIf without writing a file' {
        $plan = New-AzureDataLabPlan $script:MinimalConfigurationPath
        $path = Join-Path $TestDrive 'whatif.json'

        Export-AzureDataLabPlan $plan -Format Json -Path $path -WhatIf
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}
