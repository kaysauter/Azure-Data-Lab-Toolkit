$script:AdltAzureTokenMinimumRemainingLifetime = [timespan]::FromMinutes(10)

function Get-AdltNestedPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string[]] $Path
    )

    $current = $InputObject
    foreach ($name in $Path) {
        if ($null -eq $current) {
            return $null
        }

        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($name)) {
                return $null
            }
            $current = $current[$name]
            continue
        }

        $property = $current.PSObject.Properties[$name]
        if ($null -eq $property) {
            return $null
        }
        $current = $property.Value
    }

    return $current
}

function Get-AdltAzureContextIdentity {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Context
    )

    return [ordered]@{
        cloud            = [string] (Get-AdltNestedPropertyValue `
                -InputObject $Context `
                -Path @('Environment', 'Name'))
        tenantId         = [string] (Get-AdltNestedPropertyValue `
                -InputObject $Context `
                -Path @('Tenant', 'Id'))
        subscriptionId   = [string] (Get-AdltNestedPropertyValue `
                -InputObject $Context `
                -Path @('Subscription', 'Id'))
        subscriptionName = [string] (Get-AdltNestedPropertyValue `
                -InputObject $Context `
                -Path @('Subscription', 'Name'))
        accountId        = [string] (Get-AdltNestedPropertyValue `
                -InputObject $Context `
                -Path @('Account', 'Id'))
        accountType      = [string] (Get-AdltNestedPropertyValue `
                -InputObject $Context `
                -Path @('Account', 'Type'))
    }
}

function Test-AdltAzureContextIdentity {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Context,

        [Parameter(Mandatory)]
        [string] $Cloud,

        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    if ($null -eq $Context) {
        return $false
    }

    $identity = Get-AdltAzureContextIdentity -Context $Context
    foreach ($comparison in @(
            [ordered]@{
                observed = $identity.cloud
                expected = $Cloud
            }
            [ordered]@{
                observed = $identity.tenantId
                expected = $TenantId
            }
            [ordered]@{
                observed = $identity.subscriptionId
                expected = $SubscriptionId
            }
        )) {
        if (
            [string]::IsNullOrWhiteSpace([string] $comparison.observed) -or
            -not [string]::Equals(
                [string] $comparison.observed,
                [string] $comparison.expected,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return $false
        }
    }

    return $true
}

function Get-AdltAzureAccessTokenReadiness {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $AccessToken,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow,

        [timespan] $MinimumRemainingLifetime = $script:AdltAzureTokenMinimumRemainingLifetime
    )

    if ($MinimumRemainingLifetime -le [timespan]::Zero) {
        throw 'The token readiness margin must be greater than zero.'
    }

    if ($null -eq $AccessToken) {
        return [ordered]@{
            ready       = $false
            failureKind = 'missing-token'
            expiresOn   = $null
        }
    }

    $tokenValue = Get-AdltNestedPropertyValue `
        -InputObject $AccessToken `
        -Path @('Token')
    if ($tokenValue -isnot [System.Security.SecureString]) {
        return [ordered]@{
            ready       = $false
            failureKind = 'insecure-token'
            expiresOn   = $null
        }
    }

    $rawExpiry = Get-AdltNestedPropertyValue `
        -InputObject $AccessToken `
        -Path @('ExpiresOn')
    if ($null -eq $rawExpiry) {
        return [ordered]@{
            ready       = $false
            failureKind = 'invalid-expiry'
            expiresOn   = $null
        }
    }

    try {
        $expiresOn = ([datetimeoffset] $rawExpiry).ToUniversalTime()
    }
    catch {
        return [ordered]@{
            ready       = $false
            failureKind = 'invalid-expiry'
            expiresOn   = $null
        }
    }

    $minimumExpiry = $AsOf.ToUniversalTime().Add($MinimumRemainingLifetime)
    if ($expiresOn -le $minimumExpiry) {
        return [ordered]@{
            ready       = $false
            failureKind = 'token-expiring'
            expiresOn   = $expiresOn
        }
    }

    return [ordered]@{
        ready       = $true
        failureKind = $null
        expiresOn   = $expiresOn
    }
}

function ConvertTo-AdltAzureContextSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [AllowNull()]
        [object] $TokenExpiresOn
    )

    $identity = Get-AdltAzureContextIdentity -Context $Context
    $expiresAt = if ($null -ne $TokenExpiresOn) {
        ConvertTo-AdltUtcTimestamp `
            -Value ([datetimeoffset] $TokenExpiresOn)
    }
    else {
        $null
    }

    return [ordered]@{
        cloud            = $identity.cloud
        tenantId         = $identity.tenantId
        subscriptionId   = $identity.subscriptionId
        subscriptionName = $identity.subscriptionName
        accountType      = $identity.accountType
        tokenExpiresAt   = $expiresAt
        contextScope     = 'process'
    }
}

function Clear-AdltAzureProcessContext {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    Clear-AdltAzureDefaultProfileBinding
    try {
        [void] (Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Clear-AzContext' `
            -Parameters @{
                Scope       = 'Process'
                Force       = $true
                ErrorAction = 'Stop'
            })
        $remainingContext = Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Get-AzContext' `
            -Parameters @{ ErrorAction = 'Stop' }
        return $null -eq $remainingContext
    }
    catch {
        return $false
    }
}

function Get-AdltAzureContextInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    Assert-AdltPlanContract -Plan $Plan
    $probes = [System.Collections.Generic.List[object]]::new()
    $context = $null
    $tokenExpiry = $null

    try {
        $context = Invoke-AdltAzCommand `
            -ModuleName 'Az.Accounts' `
            -CommandName 'Get-AzContext' `
            -Parameters @{ ErrorAction = 'Stop' }
    }
    catch {
        Clear-AdltAzureDefaultProfileBinding
        $probes.Add([ordered]@{
            probeId        = 'probe.azure.context'
            status         = 'fail'
            correlationIds = @()
            observedAt     = ConvertTo-AdltUtcTimestamp -Value ([datetimeoffset]::UtcNow)
            message        = 'The current Azure context could not be read.'
            payload        = [ordered]@{
                failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
            }
        })
    }

    if ($null -eq $context) {
        Clear-AdltAzureDefaultProfileBinding
        if ($probes.Count -eq 0) {
            $probes.Add([ordered]@{
                probeId        = 'probe.azure.context'
                status         = 'fail'
                correlationIds = @()
                observedAt     = ConvertTo-AdltUtcTimestamp -Value ([datetimeoffset]::UtcNow)
                message        = 'No Azure context is active in this PowerShell process.'
                payload        = [ordered]@{
                    failureKind = 'unauthenticated'
                }
            })
        }

        return [ordered]@{
            context = $null
            probes  = $probes.ToArray()
        }
    }

    $expected = $Plan.context
    $identity = Get-AdltAzureContextIdentity -Context $context
    $checks = @(
        [ordered]@{
            id       = 'probe.azure.context.cloud'
            expected = [string] $expected.cloud
            observed = $identity.cloud
        }
        [ordered]@{
            id       = 'probe.azure.context.tenant'
            expected = [string] $expected.tenantId
            observed = $identity.tenantId
        }
        [ordered]@{
            id       = 'probe.azure.context.subscription'
            expected = [string] $expected.subscriptionId
            observed = $identity.subscriptionId
        }
    )
    $contextMatches = $true
    foreach ($check in $checks) {
        $scopeMatches = (
            -not [string]::IsNullOrWhiteSpace($check.observed) -and
            [string]::Equals(
                $check.expected,
                $check.observed,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
        if (-not $scopeMatches) {
            $contextMatches = $false
        }
        $probes.Add([ordered]@{
            probeId        = $check.id
            status         = if ($scopeMatches) { 'pass' } else { 'fail' }
            correlationIds = @()
            observedAt     = ConvertTo-AdltUtcTimestamp -Value ([datetimeoffset]::UtcNow)
            message        = if ($scopeMatches) {
                'The active Azure context matches the approved plan.'
            }
            else {
                'The active Azure context does not match the approved plan.'
            }
            payload        = [ordered]@{
                expected = $check.expected
                observed = $check.observed
            }
        })
    }

    if ($contextMatches) {
        $tokenReadiness = Get-AdltAzureTokenReadinessLease `
            -Context $context
        if ($tokenReadiness.ready) {
            $tokenExpiry = $tokenReadiness.expiresOn
            $probes.Add([ordered]@{
                probeId        = 'probe.azure.context.arm-token'
                status         = 'pass'
                correlationIds = @()
                observedAt     = ConvertTo-AdltUtcTimestamp `
                    -Value ([datetimeoffset]::UtcNow)
                message        = (
                    'A previously verified ARM token remains within its ' +
                    'recorded process-scoped readiness window.'
                )
                payload        = [ordered]@{
                    expiresAt = ConvertTo-AdltUtcTimestamp `
                        -Value $tokenReadiness.expiresOn
                }
            })
        }
        else {
            Clear-AdltAzureDefaultProfileBinding
            $probes.Add([ordered]@{
                probeId        = 'probe.azure.context.arm-token'
                status         = 'fail'
                correlationIds = @()
                observedAt     = ConvertTo-AdltUtcTimestamp `
                    -Value ([datetimeoffset]::UtcNow)
                message        = (
                    'The process has no matching current ARM token-readiness ' +
                    'lease. Sign in again before continuing.'
                )
                payload        = [ordered]@{
                    failureKind = $tokenReadiness.failureKind
                }
            })
        }
    }
    else {
        Clear-AdltAzureDefaultProfileBinding
    }

    return [ordered]@{
        context = ConvertTo-AdltAzureContextSummary `
            -Context $context `
            -TokenExpiresOn $tokenExpiry
        probes  = $probes.ToArray()
    }
}

function Assert-AdltAzureContextReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $inspection = Get-AdltAzureContextInspection -Plan $Plan
    $status = Get-AdltEvidenceAggregateStatus -Probes @($inspection.probes)
    if ($status -ne 'pass') {
        Clear-AdltAzureDefaultProfileBinding
        throw 'The active Azure context is not ready for this plan. Run Connect-AzureDataLabAccount with the exact tenant and subscription.'
    }

    return $inspection.context
}

function Get-AdltCurrentInteractivePrincipalId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $context = Assert-AdltAzureContextReady -Plan $Plan
    if ([string] $context.accountType -cne 'User') {
        throw 'Azure mutation requires an interactive Azure user context.'
    }
    $principal = Invoke-AdltAzCommand `
        -ModuleName 'Az.Resources' `
        -CommandName 'Get-AzADUser' `
        -Parameters @{
            SignedIn    = $true
            ErrorAction = 'Stop'
        }
    $principalId = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $principal `
            -Name 'Id'
    )
    if ($principalId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'The signed-in Azure principal object ID is invalid.'
    }
    return $principalId.ToLowerInvariant()
}

function Assert-AdltAzureMutationPrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $ExpectedPrincipalId
    )

    $principalId = Get-AdltCurrentInteractivePrincipalId -Plan $Plan
    if ($principalId -cne $ExpectedPrincipalId.ToLowerInvariant()) {
        throw (
            'The current Azure user does not match the user who approved ' +
            'this protected operation.'
        )
    }
    return $principalId
}
