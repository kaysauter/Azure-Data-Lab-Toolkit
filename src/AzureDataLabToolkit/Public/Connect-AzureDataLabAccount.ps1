function Connect-AzureDataLabAccount {
    <#
    .SYNOPSIS
    Signs in interactively and selects an exact process-scoped Azure context.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $SubscriptionId,

        [ValidateSet('AzureCloud')]
        [string] $Environment = 'AzureCloud',

        [switch] $UseDeviceAuthentication
    )

    Clear-AdltAzureDefaultProfileBinding
    if (@(Microsoft.PowerShell.Core\Get-Module -Name 'Az.Accounts').Count -gt 0) {
        throw (
            'Az.Accounts is already loaded. Start a fresh PowerShell process ' +
            'before establishing the toolkit Azure context.'
        )
    }
    [System.Environment]::SetEnvironmentVariable(
        'Azure_Profile_Autosave',
        'false',
        [System.EnvironmentVariableTarget]::Process
    )
    try {
        [void] (Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Disable-AzContextAutosave' `
            -Parameters @{
                Scope       = 'Process'
                ErrorAction = 'Stop'
            })
    }
    catch {
        throw (
            'Azure sign-in was not started because process-only Az ' +
            'authentication could not be established safely.'
        )
    }
    if (-not (Clear-AdltAzureProcessContext)) {
        throw (
            'Azure sign-in was not started because the existing process ' +
            'context could not be cleared and verified safely.'
        )
    }

    $token = $null
    try {
        $connectParameters = @{
            Tenant                = $TenantId
            Subscription          = $SubscriptionId
            Environment           = $Environment
            Scope                 = 'Process'
            SkipContextPopulation = $true
            ErrorAction           = 'Stop'
        }
        if ($UseDeviceAuthentication.IsPresent) {
            $connectParameters.UseDeviceAuthentication = $true
        }
        [void] (Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Connect-AzAccount' `
            -Parameters $connectParameters)
        [void] (Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Set-AzContext' `
            -Parameters @{
                Tenant       = $TenantId
                Subscription = $SubscriptionId
                Scope        = 'Process'
                ErrorAction  = 'Stop'
            })

        $context = Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Get-AzContext' `
            -Parameters @{ ErrorAction = 'Stop' }
        if (
            -not (
                Test-AdltAzureContextIdentity `
                    -Context $context `
                    -Cloud $Environment `
                    -TenantId $TenantId `
                    -SubscriptionId $SubscriptionId
            )
        ) {
            throw 'Azure context validation failed.'
        }
        $authenticatedIdentity = Get-AdltAzureContextIdentity `
            -Context $context
        $authenticatedTokenCache = Get-AdltAzureContextTokenCache `
            -Context $context
        Set-AdltAzureDefaultProfileBinding -Context $context

        $token = Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Get-AzAccessToken' `
            -Parameters @{
                ResourceTypeName = 'Arm'
                TenantId        = $TenantId
                AsSecureString  = $true
                ErrorAction     = 'Stop'
            }
        $tokenReadiness = Get-AdltAzureAccessTokenReadiness `
            -AccessToken $token
        $token = $null
        if (-not $tokenReadiness.ready) {
            throw 'Azure token validation failed.'
        }

        $validatedContext = Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Get-AzContext' `
            -Parameters @{ ErrorAction = 'Stop' }
        if (
            -not (
                Test-AdltAzureContextIdentity `
                    -Context $validatedContext `
                    -Cloud $Environment `
                    -TenantId $TenantId `
                    -SubscriptionId $SubscriptionId
            ) -or
            -not (
                Test-AdltAzureContextIdentitySnapshot `
                    -Expected $authenticatedIdentity `
                    -Observed (
                        Get-AdltAzureContextIdentity `
                            -Context $validatedContext
                    )
            ) -or
            -not [object]::ReferenceEquals(
                $authenticatedTokenCache,
                (Get-AdltAzureContextTokenCache `
                    -Context $validatedContext)
            )
        ) {
            throw 'Azure context validation failed.'
        }
        Set-AdltAzureDefaultProfileBinding `
            -Context $validatedContext `
            -TokenExpiresOn $tokenReadiness.expiresOn `
            -TokenAudience $script:AdltArmTokenAudience

        return ConvertTo-AdltAzureContextSummary `
            -Context $validatedContext `
            -TokenExpiresOn $tokenReadiness.expiresOn
    }
    catch {
        $token = $null
        if (Clear-AdltAzureProcessContext) {
            throw (
                'Azure sign-in did not produce the requested secure process ' +
                'context. The process context was cleared.'
            )
        }
        throw (
            'Azure sign-in failed and the process context could not be ' +
            'cleared and verified safely. Close this PowerShell process ' +
            'before using Azure commands.'
        )
    }
    finally {
        $token = $null
    }
}
