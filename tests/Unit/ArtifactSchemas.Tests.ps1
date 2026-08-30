BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:SchemaRoot = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/Schemas'
    $script:RunStateSchemaPath = Join-Path `
        $script:SchemaRoot `
        'run-state.schema.json'
    $script:EvidenceSchemaPath = Join-Path `
        $script:SchemaRoot `
        'evidence.schema.json'
    $script:TeardownPlanSchemaPath = Join-Path `
        $script:SchemaRoot `
        'teardown-plan.schema.json'
    $script:ExecutionAuthorizationSchemaPath = Join-Path `
        $script:SchemaRoot `
        'execution-authorization.schema.json'

    $script:HashA = "sha256:$('a' * 64)"
    $script:HashB = "sha256:$('b' * 64)"
    $script:HashC = "sha256:$('c' * 64)"
    $script:HashD = "sha256:$('d' * 64)"
    $script:ResourceId =
        '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-adlt-test/providers/Microsoft.Compute/virtualMachines/vm-adlt-test'
    $script:ResourceGroupId =
        '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-adlt-test'
    $script:RetainedResourceId =
        '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-shared/providers/Microsoft.KeyVault/vaults/kv-adlt-test'

    function New-TestScope {
        return [ordered]@{
            cloud             = 'AzureCloud'
            tenantId          = '11111111-1111-4111-8111-111111111111'
            subscriptionId    = '22222222-2222-4222-8222-222222222222'
            resourceGroupName = 'rg-adlt-test'
            location          = 'switzerlandnorth'
        }
    }

    function New-TestRunState {
        return [ordered]@{
            schemaVersion     = '1.0'
            kind              = 'AzureDataLabRunState'
            canonicalization  = 'rfc8785'
            runId             = '33333333-3333-4333-8333-333333333333'
            planHash          = $script:HashA
            intentHash        = $script:HashB
            mode              = 'local'
            generation        = 0
            status            = 'planned'
            scope             = New-TestScope
            resourceLedger    = @(
                [ordered]@{
                    stableId  = 'azure.compute.virtual-machine.primary'
                    resourceId = $script:ResourceId
                    plannedOwnership = 'owned'
                    observedOwnership = 'owned'
                    status    = 'present'
                }
            )
            eventReferences   = @(
                [ordered]@{
                    sequence  = 0
                    eventHash = $script:HashC
                }
            )
            evidenceReferences = @(
                [ordered]@{
                    stage        = 'plan'
                    evidenceHash = $script:HashD
                }
            )
            createdAt          = '2026-07-28T09:30:00Z'
            updatedAt          = '2026-07-28T09:31:00.123Z'
            expiresAt          = '2026-07-28T13:30:00Z'
            stateHash          = $script:HashA
        }
    }

    function New-TestEvidence {
        return [ordered]@{
            schemaVersion    = '1.0'
            kind             = 'AzureDataLabEvidence'
            canonicalization = 'rfc8785'
            eventId          = '44444444-4444-4444-8444-444444444444'
            sequence         = 1
            previousEventHash = $script:HashA
            runId            = '33333333-3333-4333-8333-333333333333'
            planHash         = $script:HashA
            intentHash       = $script:HashB
            stage            = 'probe'
            status           = 'pass'
            correlationIds   = @('azure-request-0001')
            probes           = @(
                [ordered]@{
                    probeId       = 'probe.compute.vm-agent'
                    status        = 'pass'
                    correlationIds = @('azure-request-0001')
                    observedAt    = '2026-07-28T09:31:00Z'
                    message       = 'The VM agent reported ready.'
                    payload       = [ordered]@{
                        attempt = 1
                        ready   = $true
                    }
                }
            )
            redactions       = @(
                [ordered]@{
                    path           = '/payload/source'
                    classification = 'private-content'
                    reason         = 'policy'
                    replacement    = '[REDACTED]'
                }
            )
            payload          = [ordered]@{
                attempt = 1
                nested  = [ordered]@{
                    count  = 2
                    values = @('ready', 1, $true, $null)
                }
            }
            startedAt        = '2026-07-28T09:30:00Z'
            completedAt      = '2026-07-28T09:31:00Z'
            evidenceHash     = $script:HashC
        }
    }

    function New-TestTeardownPlan {
        return [ordered]@{
            schemaVersion      = '1.0'
            kind               = 'AzureDataLabTeardownPlan'
            canonicalization   = 'rfc8785'
            runId              = '33333333-3333-4333-8333-333333333333'
            scope              = New-TestScope
            sourcePlanHash     = $script:HashA
            intentHash         = $script:HashB
            observedStateEvidenceHash = $script:HashC
            resourceGroupId    = $script:ResourceGroupId
            strategy           = 'exact-resource-ids'
            retainResourceGroup = $true
            freshInventoryRequired = $true
            plannedOwnedResourceIds = @($script:ResourceId)
            futureOwnedResourceIds = @()
            ownershipProofRequiredResourceIds = @(
                $script:ResourceGroupId
                $script:ResourceId
            )
            retainedResourceIds = @(
                $script:ResourceGroupId
                $script:RetainedResourceId
            )
            blockers           = @()
            createdAt          = '2026-07-28T09:31:00Z'
            expiresAt          = '2026-07-28T10:31:00Z'
            teardownPlanHash   = $script:HashD
        }
    }

    function New-TestExecutionAuthorization {
        return [ordered]@{
            schemaVersion              = '1.0'
            kind                       = 'AzureDataLabExecutionAuthorization'
            canonicalization           = 'rfc8785'
            operation                  = 'deploy'
            runId                      = '33333333-3333-4333-8333-333333333333'
            planHash                   = $script:HashA
            intentHash                 = $script:HashB
            liveResolutionEvidenceHash = $script:HashC
            whatIfEvidenceHash         = $script:HashD
            costEvidenceHash           = $script:HashA
            teardownPlanHash           = $script:HashB
            executionArtifactDigest    = $script:HashD
            module                     = [ordered]@{
                name    = 'AzureDataLabToolkit'
                version = '0.1.0-alpha1'
                digest  = $script:HashC
            }
            commit                     = 'a' * 40
            engine                     = [ordered]@{
                name                  = 'powershell'
                contractVersion       = '1.0'
                implementationVersion = '0.1.0-alpha1'
                digest                = $script:HashD
            }
            runtime                    = [ordered]@{
                powershell   = [ordered]@{
                    version = '7.5.2'
                    edition = 'Core'
                }
                dependencies = @(
                    [ordered]@{
                        name             = 'Az.Accounts'
                        version          = '5.3.1'
                        guid             =
                            '17a2feff-488b-47f9-8729-e2cec094624c'
                        author           = 'Microsoft Corporation'
                        source           = 'PSGallery'
                        packageDigest    = $script:HashA
                        contentDigest    = $script:HashB
                        manifestPathHash = $script:HashC
                    }
                )
            }
            scope                      = New-TestScope
            stateBinding               = [ordered]@{
                stateHash     = $script:HashA
                generation    = 3
                eventSequence = 7
                eventHash     = $script:HashC
            }
            permittedActionIds         = @(
                'action.compute.virtual-machine.primary'
            )
            permittedResourceIds       = @($script:ResourceId)
            approval                   = [ordered]@{
                approver = [ordered]@{
                    type = 'user'
                    id   = '55555555-5555-4555-8555-555555555555'
                }
                mechanism = 'interactive'
                approvedAt = '2026-07-28T09:25:00Z'
                recordId   = 'interactive:approval-0001'
            }
            createdAt                  = '2026-07-28T09:25:00Z'
            expiresAt                  = '2026-07-28T10:25:00Z'
            maximumCost               = [ordered]@{
                amountMinorUnits = 25000
                currency         = 'CHF'
            }
            maximumRuntimeMinutes      = 240
            acknowledgementIds         = @(
                'policy.catalog.integrity-unverified'
            )
            authorizationHash          = $script:HashA
        }
    }

    function Test-ArtifactSchema {
        param(
            [Parameter(Mandatory)]
            [System.Collections.IDictionary] $Artifact,

            [Parameter(Mandatory)]
            [string] $SchemaPath
        )

        return Test-Json `
            -Json ($Artifact | ConvertTo-Json -Depth 100 -Compress) `
            -SchemaFile $SchemaPath `
            -ErrorAction SilentlyContinue
    }
}

Describe 'Phase-one artifact schema acceptance' {
    It 'accepts a minimal run state' {
        Test-ArtifactSchema `
            -Artifact (New-TestRunState) `
            -SchemaPath $script:RunStateSchemaPath |
            Should -BeTrue
    }

    It 'accepts a minimal evidence event' {
        Test-ArtifactSchema `
            -Artifact (New-TestEvidence) `
            -SchemaPath $script:EvidenceSchemaPath |
            Should -BeTrue
    }

    It 'accepts a deterministic teardown plan' {
        Test-ArtifactSchema `
            -Artifact (New-TestTeardownPlan) `
            -SchemaPath $script:TeardownPlanSchemaPath |
            Should -BeTrue
    }

    It 'accepts a fully bound execution authorization' {
        Test-ArtifactSchema `
            -Artifact (New-TestExecutionAuthorization) `
            -SchemaPath $script:ExecutionAuthorizationSchemaPath |
            Should -BeTrue
    }
}

Describe 'Artifact schema rejection boundaries' {
    It 'rejects secret-like extra properties on every fixed envelope' {
        $cases = @(
            @{
                Artifact = New-TestRunState
                Schema   = $script:RunStateSchemaPath
            }
            @{
                Artifact = New-TestEvidence
                Schema   = $script:EvidenceSchemaPath
            }
            @{
                Artifact = New-TestTeardownPlan
                Schema   = $script:TeardownPlanSchemaPath
            }
            @{
                Artifact = New-TestExecutionAuthorization
                Schema   = $script:ExecutionAuthorizationSchemaPath
            }
        )

        foreach ($case in $cases) {
            $case.Artifact.Add('password', 'must-not-be-stored')
            Test-ArtifactSchema `
                -Artifact $case.Artifact `
                -SchemaPath $case.Schema |
                Should -BeFalse
        }
    }

    It 'rejects every forbidden evidence payload field name at the schema boundary' {
        $forbiddenNames = @(
            'password'
            'secretValue'
            'clientSecret'
            'token'
            'accessToken'
            'refreshToken'
            'connectionString'
            'sasToken'
            'accountKey'
            'accessKey'
        )

        foreach ($forbiddenName in $forbiddenNames) {
            $evidence = New-TestEvidence
            $evidence.payload.Add(
                $forbiddenName,
                'must-not-be-stored'
            )

            Test-ArtifactSchema `
                -Artifact $evidence `
                -SchemaPath $script:EvidenceSchemaPath |
                Should -BeFalse
        }
    }

    It 'rejects malformed hashes in every artifact' {
        $cases = @(
            @{
                Artifact = New-TestRunState
                Property = 'planHash'
                Schema   = $script:RunStateSchemaPath
            }
            @{
                Artifact = New-TestEvidence
                Property = 'evidenceHash'
                Schema   = $script:EvidenceSchemaPath
            }
            @{
                Artifact = New-TestTeardownPlan
                Property = 'teardownPlanHash'
                Schema   = $script:TeardownPlanSchemaPath
            }
            @{
                Artifact = New-TestExecutionAuthorization
                Property = 'authorizationHash'
                Schema   = $script:ExecutionAuthorizationSchemaPath
            }
        )

        foreach ($case in $cases) {
            $case.Artifact[$case.Property] = 'sha256:ABC123'
            Test-ArtifactSchema `
                -Artifact $case.Artifact `
                -SchemaPath $case.Schema |
                Should -BeFalse
        }
    }

    It 'rejects unknown run, evidence, and probe statuses' {
        $runState = New-TestRunState
        $runState.status = 'almost-done'
        Test-ArtifactSchema `
            -Artifact $runState `
            -SchemaPath $script:RunStateSchemaPath |
            Should -BeFalse

        $evidence = New-TestEvidence
        $evidence.status = 'skipped'
        Test-ArtifactSchema `
            -Artifact $evidence `
            -SchemaPath $script:EvidenceSchemaPath |
            Should -BeFalse

        $probeEvidence = New-TestEvidence
        $probeEvidence.probes[0].status = 'not-applicable'
        Test-ArtifactSchema `
            -Artifact $probeEvidence `
            -SchemaPath $script:EvidenceSchemaPath |
            Should -BeFalse
    }

    It 'rejects malformed and non-UTC timestamps' {
        $runState = New-TestRunState
        $runState.createdAt = '2026-07-28 09:30:00'
        Test-ArtifactSchema `
            -Artifact $runState `
            -SchemaPath $script:RunStateSchemaPath |
            Should -BeFalse

        $evidence = New-TestEvidence
        $evidence.completedAt = '2026-07-28T11:31:00+02:00'
        Test-ArtifactSchema `
            -Artifact $evidence `
            -SchemaPath $script:EvidenceSchemaPath |
            Should -BeFalse

        $authorization = New-TestExecutionAuthorization
        $authorization.expiresAt = '2026-07-28T10:25:00'
        Test-ArtifactSchema `
            -Artifact $authorization `
            -SchemaPath $script:ExecutionAuthorizationSchemaPath |
            Should -BeFalse
    }

    It 'rejects unknown properties on exact Azure scopes' {
        $cases = @(
            @{
                Artifact = New-TestRunState
                Schema   = $script:RunStateSchemaPath
            }
            @{
                Artifact = New-TestTeardownPlan
                Schema   = $script:TeardownPlanSchemaPath
            }
            @{
                Artifact = New-TestExecutionAuthorization
                Schema   = $script:ExecutionAuthorizationSchemaPath
            }
        )

        foreach ($case in $cases) {
            $case.Artifact.scope.Add('managementGroupId', 'not-permitted')
            Test-ArtifactSchema `
                -Artifact $case.Artifact `
                -SchemaPath $case.Schema |
                Should -BeFalse
        }
    }

    It 'rejects every missing execution authorization binding' {
        $requiredBindings = @(
            'operation'
            'planHash'
            'intentHash'
            'liveResolutionEvidenceHash'
            'whatIfEvidenceHash'
            'costEvidenceHash'
            'teardownPlanHash'
            'module'
            'commit'
            'engine'
            'scope'
            'permittedActionIds'
            'permittedResourceIds'
            'approval'
            'createdAt'
            'expiresAt'
            'maximumCost'
            'maximumRuntimeMinutes'
            'acknowledgementIds'
            'authorizationHash'
        )

        foreach ($binding in $requiredBindings) {
            $authorization = New-TestExecutionAuthorization
            $authorization.Remove($binding)

            Test-ArtifactSchema `
                -Artifact $authorization `
                -SchemaPath $script:ExecutionAuthorizationSchemaPath |
                Should -BeFalse
        }
    }
}
