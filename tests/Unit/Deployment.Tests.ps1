BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

Describe 'Protected ARM deployment command' {
    BeforeEach {
        $script:ParameterPath = $null
        $script:ParameterPrivate = $false
        $script:ParameterDocument = $null
        Mock Assert-AdltAzureContextReady `
            -ModuleName AzureDataLabToolkit {
            [ordered]@{}
        }
        Mock Assert-AdltAzureMutationPrincipal `
            -ModuleName AzureDataLabToolkit {
            '55555555-5555-4555-8555-555555555555'
        }
        Mock Assert-AdltSqlVmDeploymentTargetAbsence `
            -ModuleName AzureDataLabToolkit
        Mock Assert-AdltDeploymentMutationLease `
            -ModuleName AzureDataLabToolkit
    }

    It 'uses an owner-only, reference-only parameter file and removes it' {
        Mock Invoke-AdltAzCommand -ModuleName AzureDataLabToolkit {
            param($ModuleName, $CommandName, $Parameters)

            $script:ParameterPath =
                [string] $Parameters.TemplateParameterFile
            $script:ParameterDocument = Get-Content `
                -LiteralPath $script:ParameterPath `
                -Raw |
                ConvertFrom-Json -AsHashtable -Depth 100
            if (-not $IsWindows) {
                $mode = [System.IO.File]::GetUnixFileMode(
                    $script:ParameterPath
                )
                $nonOwner =
                    [System.IO.UnixFileMode]::GroupRead -bor
                    [System.IO.UnixFileMode]::GroupWrite -bor
                    [System.IO.UnixFileMode]::GroupExecute -bor
                    [System.IO.UnixFileMode]::OtherRead -bor
                    [System.IO.UnixFileMode]::OtherWrite -bor
                    [System.IO.UnixFileMode]::OtherExecute
                $script:ParameterPrivate =
                    ($mode -band $nonOwner) -eq 0
            }
            else {
                $script:ParameterPrivate = $true
            }
            [pscustomobject]@{
                DeploymentName =
                    $Parameters.Name
                Id = (
                    '/subscriptions/22222222-2222-4222-8222-' +
                    '222222222222/providers/Microsoft.Resources/' +
                    "deployments/$($Parameters.Name)"
                )
                CorrelationId =
                    '99999999-9999-4999-8999-999999999999'
                Location = $Parameters.Location
                ProvisioningState = 'Succeeded'
                Outputs = @{}
            }
        }

        InModuleScope AzureDataLabToolkit {
            $reference = [ordered]@{
                keyVaultResourceId = (
                    '/subscriptions/22222222-2222-4222-8222-' +
                    '222222222222/resourceGroups/rg-control/' +
                    'providers/Microsoft.KeyVault/vaults/kv-control'
                )
                secretName = 'vm-admin-password'
                secretVersion =
                    '0123456789abcdef0123456789abcdef'
            }
            $compilation = [ordered]@{
                parameterReference = $reference
                template = [ordered]@{
                    '$schema' = (
                        'https://schema.management.azure.com/' +
                        'schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
                    )
                    contentVersion = '1.0.0.0'
                    resources = @()
                }
            }
            $parameterHash = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject (
                    New-AdltSqlVmArmParameterDocument `
                        -Compilation $compilation
                )
            )
            $record = [ordered]@{
                operationId =
                    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                authorization = [ordered]@{
                    approval = [ordered]@{
                        approver = [ordered]@{
                            id = '55555555-5555-4555-8555-555555555555'
                        }
                    }
                }
                deployment = [ordered]@{
                    scope = (
                        '/subscriptions/22222222-2222-4222-' +
                        '8222-222222222222'
                    )
                    name = 'adlt-deploy-aaaaaaaa-0123456789ab'
                    location = 'switzerlandnorth'
                    parameterFileHash = $parameterHash
                }
            }
            $plan = [ordered]@{
                context = [ordered]@{
                    subscriptionId =
                        '22222222-2222-4222-8222-222222222222'
                    location = 'switzerlandnorth'
                }
            }

            $result = Invoke-AdltSqlVmDeployment `
                -Plan $plan `
                -Compilation $compilation `
                -ExecutionRecord $record `
                -MutationLease ([ordered]@{})

            $result.provisioningState | Should -BeExactly 'Succeeded'
        }

        $script:ParameterPrivate | Should -BeTrue
        $script:ParameterDocument.parameters.Keys |
            Should -Be @('vmAdministratorPassword')
        $script:ParameterDocument.parameters.
            vmAdministratorPassword.reference.secretVersion |
            Should -BeExactly (
                '0123456789abcdef0123456789abcdef'
            )
        $script:ParameterDocument |
            ConvertTo-Json -Depth 20 |
            Should -Not -Match '(?i)secretValue|passwordValue'
        Test-Path -LiteralPath $script:ParameterPath |
            Should -BeFalse
        Should -Invoke Invoke-AdltAzCommand `
            -ModuleName AzureDataLabToolkit `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $CommandName -eq 'New-AzDeployment' -and
                $Parameters.ValidationLevel -eq 'Provider' -and
                $Parameters.DeploymentDebugLogLevel -eq 'None' -and
                -not $Parameters.Confirm
            }
        Should -Invoke Assert-AdltDeploymentMutationLease `
            -ModuleName AzureDataLabToolkit `
            -Times 2 `
            -Exactly
    }

    It 'rejects mutation command parameters that enable debug logging' {
        InModuleScope AzureDataLabToolkit {
            {
                Invoke-AdltAzCommand `
                    -ModuleName Az.Resources `
                    -CommandName New-AzDeployment `
                    -Parameters @{
                        Name =
                            'adlt-deploy-aaaaaaaa-0123456789ab'
                        Location = 'switzerlandnorth'
                        TemplateObject = @{}
                        TemplateParameterFile =
                            '/tmp/parameters.json'
                        ValidationLevel = 'Provider'
                        SkipTemplateParameterPrompt = $true
                        DeploymentDebugLogLevel =
                            'RequestContent'
                        Confirm = $false
                        ErrorAction = 'Stop'
                    }
            } | Should -Throw '*approved value*'
        }
    }
}

Describe 'Deployment mutation lease' {
    It 'rejects an expired authorization at the final ARM boundary' {
        InModuleScope AzureDataLabToolkit {
            $approvedAt = [datetimeoffset]::UtcNow.AddMinutes(-11)
            $expiresAt = $approvedAt.AddMinutes(10)
            $record = [ordered]@{
                authorization = [ordered]@{
                    authorizationHash = "sha256:$('a' * 64)"
                    approval = [ordered]@{
                        approvedAt = ConvertTo-AdltUtcTimestamp `
                            -Value $approvedAt
                        approver = [ordered]@{
                            id = '55555555-5555-4555-8555-555555555555'
                        }
                    }
                    expiresAt = ConvertTo-AdltUtcTimestamp `
                        -Value $expiresAt
                }
            }
            $lease = New-AdltDeploymentMutationLease `
                -ExecutionRecord $record

            {
                Assert-AdltDeploymentMutationLease `
                    -Lease $lease `
                    -ExecutionRecord $record `
                    -AsOf $expiresAt
            } | Should -Throw '*not currently valid*'
        }
    }
}

Describe 'Final create-only deployment target gate' {
    It 'requires every planned and generated target to remain absent' {
        InModuleScope AzureDataLabToolkit {
            Mock Get-AdltSqlVmArmResourceMap {
                @{
                    'azure.compute.virtual-machine.primary' = [ordered]@{
                        type = 'Microsoft.Compute/virtualMachines'
                        apiVersion = '2024-03-01'
                        logicalName = 'vm-canary'
                    }
                }
            }
            Mock Get-AdltAzureResourceRead {
                [ordered]@{
                    status = 'absent'
                    failureKind = 'absent'
                    observed = $null
                }
            }
            $compilation = [ordered]@{
                resourceBindings = @(
                    [ordered]@{
                        stableId =
                            'azure.compute.virtual-machine.primary'
                        resourceId = (
                            '/subscriptions/22222222-2222-4222-8222-' +
                            '222222222222/resourceGroups/rg-canary/' +
                            'providers/Microsoft.Compute/' +
                            'virtualMachines/vm-canary'
                        )
                        disposition = 'deploy'
                    }
                )
                expectedGeneratedResources = @(
                    [ordered]@{
                        stableId = 'engine.compute.managed-disk.os'
                        resourceId = (
                            '/subscriptions/22222222-2222-4222-8222-' +
                            '222222222222/resourceGroups/rg-canary/' +
                            'providers/Microsoft.Compute/disks/vm-canary-os'
                        )
                        resourceType = 'Microsoft.Compute/disks'
                    }
                )
            }

            {
                Assert-AdltSqlVmDeploymentTargetAbsence `
                    -Plan ([ordered]@{}) `
                    -Compilation $compilation
            } | Should -Not -Throw
            Should -Invoke Get-AdltAzureResourceRead `
                -Times 2 `
                -Exactly
        }
    }

    It 'blocks when any target is present or unreadable' {
        InModuleScope AzureDataLabToolkit {
            Mock Get-AdltSqlVmArmResourceMap {
                @{
                    'azure.compute.virtual-machine.primary' = [ordered]@{
                        type = 'Microsoft.Compute/virtualMachines'
                        apiVersion = '2024-03-01'
                        logicalName = 'vm-canary'
                    }
                }
            }
            Mock Get-AdltAzureResourceRead {
                [ordered]@{
                    status = 'present'
                    failureKind = $null
                    observed = [pscustomobject]@{}
                }
            }
            $compilation = [ordered]@{
                resourceBindings = @(
                    [ordered]@{
                        stableId =
                            'azure.compute.virtual-machine.primary'
                        resourceId = (
                            '/subscriptions/22222222-2222-4222-8222-' +
                            '222222222222/resourceGroups/rg-canary/' +
                            'providers/Microsoft.Compute/' +
                            'virtualMachines/vm-canary'
                        )
                        disposition = 'deploy'
                    }
                )
                expectedGeneratedResources = @()
            }

            {
                Assert-AdltSqlVmDeploymentTargetAbsence `
                    -Plan ([ordered]@{}) `
                    -Compilation $compilation
            } | Should -Throw '*no longer provably absent*'
        }
    }
}
