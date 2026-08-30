BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

Describe 'Azure Retail Prices command boundary' {
    BeforeEach {
        $script:Request = [ordered]@{
            schemaVersion = '1.0'
            kind          = 'AzureRetailPriceLookup'
            componentId   = 'cost.compute.virtual-machine.primary'
            componentKind = 'vm-compute'
            currency      = 'USD'
            unitOfMeasure = '1 Hour'
            selector      = [ordered]@{
                serviceName        = 'Virtual Machines'
                armRegionName      = 'westeurope'
                armSkuName         = 'Standard_D4s_v5'
                productNameContains = 'Windows'
            }
        }
    }

    It 'constructs a host-pinned primary consumption query' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            $uri = [uri] (Get-AdltRetailPriceRequestUri `
                -Request $Request)
            $uri.Scheme | Should -BeExactly 'https'
            $uri.Host | Should -BeExactly 'prices.azure.com'
            $decodedQuery = [uri]::UnescapeDataString($uri.Query)
            $decodedQuery | Should -Match "meterRegion='primary'"
            $decodedQuery | Should -Match (
                "serviceName eq 'Virtual Machines'"
            )
            $decodedQuery | Should -Match (
                "armSkuName eq 'Standard_D4s_v5'"
            )
            $decodedQuery | Should -Match (
                "contains\(productName, 'Windows'\)"
            )
            $decodedQuery | Should -Match "priceType eq 'Consumption'"
        }
    }

    It 'escapes apostrophes inside OData literals' {
        $script:Request.selector.productNameContains = "Kay's Windows"
        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            $uri = [uri] (Get-AdltRetailPriceRequestUri `
                -Request $Request)
            [uri]::UnescapeDataString($uri.Query) |
                Should -Match "Kay''s Windows"
        }
    }

    It 'rejects selector fields outside the allowlist' {
        $script:Request.selector.nextPage =
            'https://example.test/collect'
        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            {
                Get-AdltRetailPriceRequestUri -Request $Request
            } | Should -Throw '*not approved*'
        }
    }

    It 'rejects control characters and malformed request contracts' {
        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            {
                ConvertTo-AdltRetailPriceODataLiteral `
                    -Value "Virtual`nMachines"
            } | Should -Throw '*control characters*'

            $Request.kind = 'UnreviewedPriceLookup'
            {
                Get-AdltRetailPriceRequestUri -Request $Request
            } | Should -Throw '*request contract is invalid*'
        }
    }

    It 'requires both service and region selectors' {
        [void] $script:Request.selector.Remove('armRegionName')
        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            {
                Get-AdltRetailPriceRequestUri -Request $Request
            } | Should -Throw "*selector 'armRegionName' is required*"
        }
    }

    It 'rejects an Azure command outside the reviewed allowlist' {
        InModuleScope AzureDataLabToolkit {
            {
                Invoke-AdltAzCommand `
                    -ModuleName Az.Resources `
                    -CommandName Get-AzKeyVaultSecret
            } | Should -Throw '*is not approved by this engine*'
        }
    }

    It 'rejects an incomplete Azure default-profile identity' {
        InModuleScope AzureDataLabToolkit {
            Mock Get-AdltAzureContextIdentity {
                [ordered]@{
                    cloud = 'AzureCloud'
                    tenantId = ''
                    subscriptionId = ''
                }
            }

            {
                Set-AdltAzureDefaultProfileBinding `
                    -Context ([pscustomobject]@{})
            } | Should -Throw '*has no complete identity*'
        }
    }

    It 'classifies authentication and authorization failures' {
        InModuleScope AzureDataLabToolkit {
            $unauthenticated = [System.Management.Automation.ErrorRecord]::new(
                [System.UnauthorizedAccessException]::new(
                    '401 AuthenticationFailed'
                ),
                'AuthenticationFailed',
                [System.Management.Automation.ErrorCategory]::AuthenticationError,
                $null
            )
            $denied = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    '403 AuthorizationFailed'
                ),
                'AuthorizationFailed',
                [System.Management.Automation.ErrorCategory]::PermissionDenied,
                $null
            )

            Get-AdltAzureFailureKind -ErrorRecord $unauthenticated |
                Should -BeExactly 'unauthenticated'
            Get-AdltAzureFailureKind -ErrorRecord $denied |
                Should -BeExactly 'denied'
        }
    }

    It 'does not infer Azure failure kinds from free-form messages' {
        InModuleScope AzureDataLabToolkit {
            $ambiguous = [System.Management.Automation.ErrorRecord]::new(
                [System.TimeoutException]::new(
                    'Timeout while reading not-found-lab; see 404 guidance.'
                ),
                'RemoteCommandFailure',
                [System.Management.Automation.ErrorCategory]::OperationTimeout,
                $null
            )

            Get-AdltAzureFailureKind -ErrorRecord $ambiguous |
                Should -BeExactly 'unknown'
        }
    }

    It 'classifies only structured HTTP status and provider-code evidence' {
        InModuleScope AzureDataLabToolkit {
            $httpException =
                [System.InvalidOperationException]::new('Neutral failure.')
            $httpException |
                Add-Member `
                    -NotePropertyName Response `
                    -NotePropertyValue ([pscustomobject]@{
                        StatusCode =
                            [System.Net.HttpStatusCode]::NotFound
                    })
            $httpError =
                [System.Management.Automation.ErrorRecord]::new(
                    $httpException,
                    'RemoteCommandFailure',
                    [System.Management.Automation.ErrorCategory]::NotSpecified,
                    $null
                )
            $providerError =
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        'Neutral failure.'
                    ),
                    'RemoteCommandFailure',
                    [System.Management.Automation.ErrorCategory]::NotSpecified,
                    $null
                )
            $providerError.ErrorDetails =
                [System.Management.Automation.ErrorDetails]::new(
                    '{"error":{"code":"TooManyRequests"}}'
                )

            Get-AdltAzureFailureKind -ErrorRecord $httpError |
                Should -BeExactly 'absent'
            Get-AdltAzureFailureKind -ErrorRecord $providerError |
                Should -BeExactly 'throttled'
        }
    }

    It 'keeps conflicting structured failure evidence unknown' {
        InModuleScope AzureDataLabToolkit {
            $exception =
                [System.InvalidOperationException]::new('Neutral failure.')
            $exception |
                Add-Member `
                    -NotePropertyName Response `
                    -NotePropertyValue ([pscustomobject]@{
                        StatusCode =
                            [System.Net.HttpStatusCode]::InternalServerError
                    })
            $errorRecord =
                [System.Management.Automation.ErrorRecord]::new(
                    $exception,
                    'ResourceNotFound',
                    [System.Management.Automation.ErrorCategory]::NotSpecified,
                    $null
                )

            Get-AdltAzureFailureKind -ErrorRecord $errorRecord |
                Should -BeExactly 'unknown'
        }
    }

    It 'recognizes named nested status evidence and ignores malformed details' {
        InModuleScope AzureDataLabToolkit {
            $exception =
                [System.InvalidOperationException]::new('Neutral failure.')
            $exception |
                Add-Member `
                    -NotePropertyName RequestInformation `
                    -NotePropertyValue ([pscustomobject]@{
                        HttpStatusCode = 'Forbidden'
                        ErrorCode      = 'AuthorizationFailed'
                    })
            $errorRecord =
                [System.Management.Automation.ErrorRecord]::new(
                    $exception,
                    'RemoteCommandFailure',
                    [System.Management.Automation.ErrorCategory]::NotSpecified,
                    $null
                )
            $errorRecord.ErrorDetails =
                [System.Management.Automation.ErrorDetails]::new(
                    '{malformed-json'
                )

            Get-AdltAzureFailureKind -ErrorRecord $errorRecord |
                Should -BeExactly 'denied'
        }
    }

    It 'maps every approved named status and provider-code family' {
        InModuleScope AzureDataLabToolkit {
            $statusCases = @(
                @{ value = 'Unauthorized'; expected = 'unauthenticated' }
                @{ value = 'Forbidden'; expected = 'denied' }
                @{ value = 'NotFound'; expected = 'absent' }
                @{ value = 'Conflict'; expected = 'conflict' }
                @{ value = 'TooManyRequests'; expected = 'throttled' }
                @{ value = 'UnreviewedStatus'; expected = 'unknown' }
            )
            foreach ($case in $statusCases) {
                $exception = [System.InvalidOperationException]::new(
                    'Neutral failure.'
                )
                $exception |
                    Add-Member `
                        -NotePropertyName Status `
                        -NotePropertyValue $case.value
                $errorRecord =
                    [System.Management.Automation.ErrorRecord]::new(
                        $exception,
                        'RemoteCommandFailure',
                        [System.Management.Automation.ErrorCategory]::NotSpecified,
                        $null
                    )

                Get-AdltAzureFailureKind -ErrorRecord $errorRecord |
                    Should -BeExactly $case.expected
            }

            $codeCases = @(
                @{
                    value = 'InvalidAuthenticationToken'
                    expected = 'unauthenticated'
                }
                @{
                    value = 'ExpiredAuthenticationToken'
                    expected = 'unauthenticated'
                }
                @{ value = 'Forbidden'; expected = 'denied' }
                @{ value = 'ResourceGroupNotFound'; expected = 'absent' }
                @{ value = 'ParentResourceNotFound'; expected = 'absent' }
                @{ value = 'ResourceAlreadyExists'; expected = 'conflict' }
                @{ value = 'AlreadyExists'; expected = 'conflict' }
            )
            foreach ($case in $codeCases) {
                $errorRecord =
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new(
                            'Neutral failure.'
                        ),
                        $case.value,
                        [System.Management.Automation.ErrorCategory]::NotSpecified,
                        $null
                    )

                Get-AdltAzureFailureKind -ErrorRecord $errorRecord |
                    Should -BeExactly $case.expected
            }
        }
    }

    It 'classifies internal material drift through a structured conflict' {
        InModuleScope AzureDataLabToolkit {
            $errorRecord = New-AdltAzureConflictErrorRecord `
                -Message 'Material state differs.'

            Get-AdltAzureFailureKind -ErrorRecord $errorRecord |
                Should -BeExactly 'conflict'
            $errorRecord.Exception.Message |
                Should -BeExactly 'Material state differs.'
        }
    }

    It 'collects only approved same-host pages' {
        $script:CallCount = 0
        Mock Invoke-RestMethod -ModuleName AzureDataLabToolkit {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                return [pscustomobject]@{
                    Items = @([pscustomobject]@{ meterId = 'one' })
                    NextPageLink = (
                        'https://prices.azure.com/api/retail/prices?' +
                        '$skip=1'
                    )
                }
            }
            return [pscustomobject]@{
                Items = @([pscustomobject]@{ meterId = 'two' })
                NextPageLink = $null
            }
        }

        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            $result = Invoke-AdltAzureRetailPriceCommand `
                -Request $Request

            @($result.Items).meterId | Should -Be @('one', 'two')
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }

    It 'rejects a cross-host pagination link before requesting it' {
        Mock Invoke-RestMethod -ModuleName AzureDataLabToolkit {
            return [pscustomobject]@{
                Items = @()
                NextPageLink =
                    'https://example.test/api/retail/prices'
            }
        }

        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            {
                Invoke-AdltAzureRetailPriceCommand `
                    -Request $Request
            } | Should -Throw '*unapproved URI*'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }
    }

    It 'rejects cyclic pagination before a repeated request' {
        Mock Invoke-RestMethod -ModuleName AzureDataLabToolkit {
            return [pscustomobject]@{
                Items = @()
                NextPageLink = [string] $Uri
            }
        }

        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            {
                Invoke-AdltAzureRetailPriceCommand `
                    -Request $Request
            } | Should -Throw '*pagination contains a cycle*'
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }

    It 'rejects an empty Retail Prices response' {
        Mock Invoke-RestMethod -ModuleName AzureDataLabToolkit {
            return $null
        }

        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            {
                Invoke-AdltAzureRetailPriceCommand `
                    -Request $Request
            } | Should -Throw '*returned an empty response*'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }
    }

    It 'caps Retail Prices pagination at ten pages' {
        $script:Page = 0
        Mock Invoke-RestMethod -ModuleName AzureDataLabToolkit {
            $script:Page++
            return [pscustomobject]@{
                Items = @()
                NextPageLink = (
                    'https://prices.azure.com/api/retail/prices?' +
                    "page=$script:Page"
                )
            }
        }

        InModuleScope AzureDataLabToolkit -Parameters @{
            Request = $script:Request
        } {
            {
                Invoke-AdltAzureRetailPriceCommand `
                    -Request $Request
            } | Should -Throw '*exceeded the approved page limit*'
            Should -Invoke Invoke-RestMethod -Times 10 -Exactly
        }
    }
}
