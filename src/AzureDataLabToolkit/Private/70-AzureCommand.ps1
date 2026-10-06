$script:AdltAzureDefaultProfile = $null
$script:AdltAzureDefaultProfileIdentity = $null
$script:AdltAzureDefaultProfileTokenCache = $null
$script:AdltAzureTokenReadinessLease = $null
$script:AdltArmTokenAudience = 'https://management.azure.com/'
$script:AdltAzureTokenReadinessLeaseMaximumAge =
    [timespan]::FromMinutes(10)

function Clear-AdltAzureDefaultProfileBinding {
    [CmdletBinding()]
    param()

    $script:AdltAzureDefaultProfile = $null
    $script:AdltAzureDefaultProfileIdentity = $null
    $script:AdltAzureDefaultProfileTokenCache = $null
    $script:AdltAzureTokenReadinessLease = $null
}

function Test-AdltAzureContextIdentitySnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Expected,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Observed
    )

    foreach ($name in @(
        'cloud'
        'tenantId'
        'subscriptionId'
        'accountId'
        'accountType'
    )) {
        if (
            -not [string]::Equals(
                [string] $Expected[$name],
                [string] $Observed[$name],
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return $false
        }
    }
    return $true
}

function Get-AdltAzureContextTokenCache {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Context
    )

    if ($null -eq $Context) {
        return $null
    }
    $property = $Context.PSObject.Properties['TokenCache']
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-AdltAzureTokenReadinessLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [datetimeoffset] $AsOf = [datetimeoffset]::UtcNow
    )

    $lease = $script:AdltAzureTokenReadinessLease
    if ($lease -isnot [System.Collections.IDictionary]) {
        return [ordered]@{
            ready       = $false
            failureKind = 'reauthentication-required'
            expiresOn   = $null
        }
    }
    $identity = Get-AdltAzureContextIdentity -Context $Context
    $tokenCache = Get-AdltAzureContextTokenCache -Context $Context
    if (
        -not (
            Test-AdltAzureContextIdentitySnapshot `
                -Expected $lease.identity `
                -Observed $identity
        ) -or
        $null -eq $tokenCache -or
        -not [object]::ReferenceEquals($lease.tokenCache, $tokenCache) -or
        [string] $lease.audience -cne $script:AdltArmTokenAudience
    ) {
        return [ordered]@{
            ready       = $false
            failureKind = 'reauthentication-required'
            expiresOn   = $null
        }
    }

    try {
        $observedAt = ([datetimeoffset] $lease.observedAt).ToUniversalTime()
        $expiresOn = ([datetimeoffset] $lease.expiresOn).ToUniversalTime()
    }
    catch {
        return [ordered]@{
            ready       = $false
            failureKind = 'reauthentication-required'
            expiresOn   = $null
        }
    }
    $asOfUtc = $AsOf.ToUniversalTime()
    if (
        $observedAt -gt $asOfUtc.AddMinutes(1) -or
        $observedAt -lt $asOfUtc.Subtract(
            $script:AdltAzureTokenReadinessLeaseMaximumAge
        ) -or
        $expiresOn -le $observedAt -or
        $expiresOn -le $asOfUtc.Add(
            $script:AdltAzureTokenMinimumRemainingLifetime
        )
    ) {
        return [ordered]@{
            ready       = $false
            failureKind = 'reauthentication-required'
            expiresOn   = $expiresOn
        }
    }
    return [ordered]@{
        ready       = $true
        failureKind = $null
        expiresOn   = $expiresOn
    }
}

function Set-AdltAzureDefaultProfileBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [datetimeoffset] $TokenExpiresOn,

        [ValidateSet('https://management.azure.com/')]
        [string] $TokenAudience = 'https://management.azure.com/'
    )

    $identity = Get-AdltAzureContextIdentity -Context $Context
    if (
        [string]::IsNullOrWhiteSpace($identity.cloud) -or
        [string]::IsNullOrWhiteSpace($identity.tenantId) -or
        [string]::IsNullOrWhiteSpace($identity.subscriptionId)
    ) {
        throw 'The Azure default-profile binding has no complete identity.'
    }
    $tokenCache = Get-AdltAzureContextTokenCache -Context $Context
    $lease = $null
    if ($PSBoundParameters.ContainsKey('TokenExpiresOn')) {
        $observedAt = [datetimeoffset]::UtcNow
        $expiresOn = $TokenExpiresOn.ToUniversalTime()
        if (
            [string]::IsNullOrWhiteSpace([string] $identity.accountId) -or
            [string]::IsNullOrWhiteSpace([string] $identity.accountType) -or
            $null -eq $tokenCache -or
            $expiresOn -le $observedAt.Add(
                $script:AdltAzureTokenMinimumRemainingLifetime
            )
        ) {
            throw 'The Azure token-readiness lease is incomplete or expires too soon.'
        }
        $lease = [ordered]@{
            audience   = $TokenAudience
            identity   = $identity
            tokenCache = $tokenCache
            observedAt = $observedAt
            expiresOn  = $expiresOn
        }
    }

    $script:AdltAzureDefaultProfile = $Context
    $script:AdltAzureDefaultProfileIdentity = $identity
    $script:AdltAzureDefaultProfileTokenCache = $tokenCache
    $script:AdltAzureTokenReadinessLease = $lease
}

function Get-AdltBoundAzCommandParameter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Parameters
    )

    if ($Parameters.ContainsKey('DefaultProfile')) {
        throw 'Azure callers cannot override the verified default profile.'
    }
    if ($null -eq $script:AdltAzureDefaultProfile) {
        throw (
            'No verified Azure default profile is bound. Validate the exact ' +
            'process context before invoking Azure.'
        )
    }
    $currentIdentity = Get-AdltAzureContextIdentity `
        -Context $script:AdltAzureDefaultProfile
    $currentTokenCache = Get-AdltAzureContextTokenCache `
        -Context $script:AdltAzureDefaultProfile
    if (
        -not (
            Test-AdltAzureContextIdentitySnapshot `
                -Expected $script:AdltAzureDefaultProfileIdentity `
                -Observed $currentIdentity
        ) -or
        -not [object]::ReferenceEquals(
            $script:AdltAzureDefaultProfileTokenCache,
            $currentTokenCache
        )
    ) {
        Clear-AdltAzureDefaultProfileBinding
        throw 'The verified Azure default profile changed after binding.'
    }

    $boundParameters = @{}
    foreach ($name in $Parameters.Keys) {
        $boundParameters[$name] = $Parameters[$name]
    }
    $boundParameters.DefaultProfile =
        $script:AdltAzureDefaultProfile
    return $boundParameters
}

function Invoke-AdltAzCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'Az.Accounts',
            'Az.Resources',
            'Az.Compute',
            'Az.Monitor'
        )]
        [string] $ModuleName,

        [Parameter(Mandatory)]
        [string] $CommandName,

        [hashtable] $Parameters = @{}
    )

    $allowedCommands = @{
        'Az.Accounts' = @(
            'Clear-AzContext'
            'Connect-AzAccount'
            'Disable-AzContextAutosave'
            'Disconnect-AzAccount'
            'Get-AzAccessToken'
            'Get-AzContext'
            'Set-AzContext'
        )
        'Az.Resources' = @(
            'Get-AzADUser'
            'Get-AzDeployment'
            'Get-AzDeploymentWhatIfResult'
            'Get-AzResource'
            'Get-AzResourceGroup'
            'Get-AzResourceProvider'
            'New-AzDeployment'
            'Remove-AzResource'
        )
        'Az.Compute' = @(
            'Get-AzComputeResourceSku'
            'Get-AzVM'
            'Get-AzVMImage'
        )
        'Az.Monitor' = @(
            'Get-AzDiagnosticSetting'
        )
    }
    if (
        -not $allowedCommands.ContainsKey($ModuleName) -or
        $CommandName -notin $allowedCommands[$ModuleName]
    ) {
        throw "Azure command '$ModuleName/$CommandName' is not approved by this engine."
    }
    if ($CommandName -eq 'Get-AzDeploymentWhatIfResult') {
        $requiredParameters = [ordered]@{
            Name                        = $null
            Location                    = $null
            TemplateObject              = $null
            TemplateParameterFile       = $null
            ResultFormat                = 'ResourceIdOnly'
            ValidationLevel             = 'Provider'
            SkipTemplateParameterPrompt = $true
            ErrorAction                 = 'Stop'
        }
        Assert-AdltExactValueSet `
            -Actual @($Parameters.Keys) `
            -Expected @($requiredParameters.Keys) `
            -Name 'Native ARM WhatIf command parameters'
        foreach ($parameterName in @(
            'Name'
            'Location'
            'TemplateObject'
            'TemplateParameterFile'
        )) {
            if ($null -eq $Parameters[$parameterName]) {
                throw (
                    "Native ARM WhatIf parameter '$parameterName' is required."
                )
            }
        }
        foreach ($parameterName in @(
            'ResultFormat'
            'ValidationLevel'
            'SkipTemplateParameterPrompt'
            'ErrorAction'
        )) {
            if (
                [string] $Parameters[$parameterName] -cne
                [string] $requiredParameters[$parameterName]
            ) {
                throw (
                    "Native ARM WhatIf parameter '$parameterName' must use " +
                    "the approved fail-closed value."
                )
            }
        }
    }
    if ($CommandName -eq 'New-AzDeployment') {
        $requiredParameters = [ordered]@{
            Name                        = $null
            Location                    = $null
            TemplateObject              = $null
            TemplateParameterFile       = $null
            ValidationLevel             = 'Provider'
            SkipTemplateParameterPrompt = $true
            DeploymentDebugLogLevel     = 'None'
            Confirm                     = $false
            ErrorAction                 = 'Stop'
        }
        Assert-AdltExactValueSet `
            -Actual @($Parameters.Keys) `
            -Expected @($requiredParameters.Keys) `
            -Name 'ARM deployment command parameters'
        foreach ($parameterName in @(
            'Name'
            'Location'
            'TemplateObject'
            'TemplateParameterFile'
        )) {
            if ($null -eq $Parameters[$parameterName]) {
                throw "ARM deployment parameter '$parameterName' is required."
            }
        }
        foreach ($parameterName in @(
            'ValidationLevel'
            'SkipTemplateParameterPrompt'
            'DeploymentDebugLogLevel'
            'Confirm'
            'ErrorAction'
        )) {
            if (
                [string] $Parameters[$parameterName] -cne
                [string] $requiredParameters[$parameterName]
            ) {
                throw (
                    "ARM deployment parameter '$parameterName' must use " +
                    'the approved value.'
                )
            }
        }
    }
    if ($CommandName -eq 'Get-AzDeployment') {
        Assert-AdltExactValueSet `
            -Actual @($Parameters.Keys) `
            -Expected @('Name', 'ErrorAction') `
            -Name 'ARM deployment recovery query parameters'
        if (
            [string] $Parameters.Name -notmatch
                '^adlt-deploy-[a-f0-9]{8}-[a-f0-9]{12}$' -or
            [string] $Parameters.ErrorAction -cne 'Stop'
        ) {
            throw 'ARM deployment recovery query is not approved.'
        }
    }
    if ($CommandName -eq 'Get-AzVM') {
        Assert-AdltExactValueSet `
            -Actual @($Parameters.Keys) `
            -Expected @(
                'ResourceGroupName'
                'Name'
                'Status'
                'ErrorAction'
            ) `
            -Name 'VM instance-view query parameters'
        if (
            [string]::IsNullOrWhiteSpace(
                [string] $Parameters.ResourceGroupName
            ) -or
            [string]::IsNullOrWhiteSpace([string] $Parameters.Name) -or
            -not [bool] $Parameters.Status -or
            [string] $Parameters.ErrorAction -cne 'Stop'
        ) {
            throw 'VM instance-view query is not approved.'
        }
    }
    if ($CommandName -eq 'Get-AzResourceGroup') {
        Assert-AdltExactValueSet `
            -Actual @($Parameters.Keys) `
            -Expected @('Name', 'ErrorAction') `
            -Name 'Resource-group query parameters'
        if (
            [string]::IsNullOrWhiteSpace([string] $Parameters.Name) -or
            [string] $Parameters.ErrorAction -cne 'Stop'
        ) {
            throw 'Resource-group query is not approved.'
        }
    }
    if ($CommandName -eq 'Get-AzADUser') {
        Assert-AdltExactValueSet `
            -Actual @($Parameters.Keys) `
            -Expected @('SignedIn', 'ErrorAction') `
            -Name 'Signed-in principal query parameters'
        if (
            -not [bool] $Parameters.SignedIn -or
            [string] $Parameters.ErrorAction -cne 'Stop'
        ) {
            throw 'Signed-in principal query is not approved.'
        }
    }
    if ($CommandName -eq 'Get-AzAccessToken') {
        Assert-AdltExactValueSet `
            -Actual @($Parameters.Keys) `
            -Expected @(
                'ResourceTypeName'
                'TenantId'
                'AsSecureString'
                'ErrorAction'
            ) `
            -Name 'ARM access-token query parameters'
        if (
            [string] $Parameters.ResourceTypeName -cne 'Arm' -or
            [string] $Parameters.TenantId -notmatch
                '^[0-9a-fA-F-]{36}$' -or
            -not [bool] $Parameters.AsSecureString -or
            [string] $Parameters.ErrorAction -cne 'Stop'
        ) {
            throw 'ARM access-token query parameters are not approved.'
        }
    }
    if ($CommandName -eq 'Get-AzResource') {
        $resourceIdQuery = @(
            $Parameters.Keys |
                Where-Object {
                    $_ -in @(
                        'ResourceId'
                        'ApiVersion'
                        'ExpandProperties'
                        'ErrorAction'
                    )
                }
        ).Count -eq 4 -and $Parameters.Count -eq 4
        $resourceGroupQuery = @(
            $Parameters.Keys |
                Where-Object {
                    $_ -in @(
                        'ResourceGroupName'
                        'ExpandProperties'
                        'ErrorAction'
                    )
                }
        ).Count -eq 3 -and $Parameters.Count -eq 3
        if (-not $resourceIdQuery -and -not $resourceGroupQuery) {
            throw 'Azure resource query parameters are not approved.'
        }
        if (
            -not [bool] $Parameters.ExpandProperties -or
            [string] $Parameters.ErrorAction -cne 'Stop'
        ) {
            throw 'Azure resource query must expand properties and fail closed.'
        }
        if (
            $resourceIdQuery -and
            (
                [string]::IsNullOrWhiteSpace(
                    [string] $Parameters.ResourceId
                ) -or
                [string]::IsNullOrWhiteSpace(
                    [string] $Parameters.ApiVersion
                )
            )
        ) {
            throw 'Azure resource ID query is incomplete.'
        }
        if (
            $resourceGroupQuery -and
            [string]::IsNullOrWhiteSpace(
                [string] $Parameters.ResourceGroupName
            )
        ) {
            throw 'Azure resource-group inventory query is incomplete.'
        }
    }
    if ($CommandName -eq 'Remove-AzResource') {
        Assert-AdltExactValueSet `
            -Actual @($Parameters.Keys) `
            -Expected @(
                'ResourceId'
                'ApiVersion'
                'Force'
                'Confirm'
                'ErrorAction'
            ) `
            -Name 'Exact resource deletion parameters'
        if (
            [string] $Parameters.ResourceId -notmatch
                '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/' -or
            [string] $Parameters.ApiVersion -notmatch
                '^\d{4}-\d{2}-\d{2}(?:-preview)?$' -or
            -not [bool] $Parameters.Force -or
            [bool] $Parameters.Confirm -or
            [string] $Parameters.ErrorAction -cne 'Stop'
        ) {
            throw 'Exact resource deletion parameters are not approved.'
        }
    }

    $dependency = Import-AdltVerifiedRuntimeDependency -Name $ModuleName
    $command = $dependency.Module.ExportedCommands[$CommandName]
    $modulePathComparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (
        $null -eq $command -or
        $command.CommandType -ne
            [System.Management.Automation.CommandTypes]::Cmdlet -or
        [string] $command.ModuleName -cne $ModuleName -or
        ([string] $command.Module.Guid).ToLowerInvariant() -cne
            [string] $dependency.Identity.guid -or
        [string] $command.Module.Version -cne
            [string] $dependency.Identity.version -or
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath($command.Module.ModuleBase),
            [string] $dependency.Identity.moduleBase,
            $modulePathComparison
        )
    ) {
        throw (
            "Azure command '$ModuleName/$CommandName' was not exported by " +
            'the locked module manifest.'
        )
    }

    $contextManagementCommands = @(
        'Clear-AzContext'
        'Connect-AzAccount'
        'Disable-AzContextAutosave'
        'Disconnect-AzAccount'
        'Get-AzContext'
        'Set-AzContext'
    )
    $invocationParameters = if (
        $CommandName -in $contextManagementCommands
    ) {
        $Parameters
    }
    else {
        Get-AdltBoundAzCommandParameter -Parameters $Parameters
    }

    return & $command @invocationParameters
}

function Get-AdltAzureFailureKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $statusValues = [System.Collections.Generic.List[object]]::new()
    $codeValues = [System.Collections.Generic.List[string]]::new()
    $exception = $ErrorRecord.Exception
    for ($depth = 0; $null -ne $exception -and $depth -lt 8; $depth++) {
        foreach ($path in @(
            'Status'
            'StatusCode'
            'Response.StatusCode'
            'RequestInformation.HttpStatusCode'
        )) {
            $value = Get-AdltNestedPropertyValue `
                -InputObject $exception `
                -Path ([string[]] $path.Split('.'))
            if ($null -ne $value) {
                $statusValues.Add($value)
            }
        }
        foreach ($path in @(
            'Code'
            'ErrorCode'
            'Body.Code'
            'Response.Body.Code'
            'RequestInformation.ErrorCode'
        )) {
            $value = [string] (Get-AdltNestedPropertyValue `
                    -InputObject $exception `
                    -Path ([string[]] $path.Split('.')))
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $codeValues.Add($value)
            }
        }
        $exception = $exception.InnerException
    }

    $errorDetails = [string] (Get-AdltNestedPropertyValue `
            -InputObject $ErrorRecord `
            -Path @('ErrorDetails', 'Message'))
    if (
        -not [string]::IsNullOrWhiteSpace($errorDetails) -and
        $errorDetails.Length -le 65536
    ) {
        try {
            $details = $errorDetails | ConvertFrom-Json -AsHashtable
            foreach ($path in @(
                'code'
                'error.code'
            )) {
                $value = [string] (Get-AdltNestedPropertyValue `
                        -InputObject $details `
                        -Path ([string[]] $path.Split('.')))
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $codeValues.Add($value)
                }
            }
        }
        catch {
            $null = $_
        }
    }

    $fullyQualifiedCode = (
        [string] $ErrorRecord.FullyQualifiedErrorId -split ',',
        2
    )[0].Trim()
    if (-not [string]::IsNullOrWhiteSpace($fullyQualifiedCode)) {
        $codeValues.Add($fullyQualifiedCode)
    }

    $kinds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $hasUnknownStatus = $false
    foreach ($statusValue in $statusValues) {
        $numericStatus = $null
        try {
            $numericStatus = [int] $statusValue
        }
        catch {
            $numericStatus = switch (
                ([string] $statusValue).Trim().ToLowerInvariant()
            ) {
                'unauthorized' { 401 }
                'forbidden' { 403 }
                'notfound' { 404 }
                'conflict' { 409 }
                'toomanyrequests' { 429 }
                default { $null }
            }
        }
        $kind = switch ($numericStatus) {
            401 { 'unauthenticated' }
            403 { 'denied' }
            404 { 'absent' }
            409 { 'conflict' }
            429 { 'throttled' }
            default { $null }
        }
        if ($null -eq $kind) {
            $hasUnknownStatus = $true
        }
        else {
            [void] $kinds.Add($kind)
        }
    }

    foreach ($codeValue in $codeValues) {
        $kind = switch ($codeValue.Trim().ToLowerInvariant()) {
            'authenticationfailed' { 'unauthenticated' }
            'invalidauthenticationtoken' { 'unauthenticated' }
            'expiredauthenticationtoken' { 'unauthenticated' }
            'authorizationfailed' { 'denied' }
            'forbidden' { 'denied' }
            'resourcenotfound' { 'absent' }
            'resourcegroupnotfound' { 'absent' }
            'parentresourcenotfound' { 'absent' }
            'conflict' { 'conflict' }
            'resourcealreadyexists' { 'conflict' }
            'alreadyexists' { 'conflict' }
            'toomanyrequests' { 'throttled' }
            default { $null }
        }
        if ($null -ne $kind) {
            [void] $kinds.Add($kind)
        }
    }

    if (-not $hasUnknownStatus -and $kinds.Count -eq 1) {
        return @($kinds)[0]
    }
    return 'unknown'
}

function ConvertTo-AdltRetailPriceODataLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 256)]
        [string] $Value
    )

    if ($Value -match '[\u0000-\u001f\u007f]') {
        throw 'Azure Retail Prices filter values cannot contain control characters.'
    }

    return "'{0}'" -f $Value.Replace("'", "''")
}

function Get-AdltRetailPriceRequestUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Request
    )

    Assert-AdltExactValueSet `
        -Actual @($Request.Keys) `
        -Expected @(
            'schemaVersion'
            'kind'
            'componentId'
            'componentKind'
            'currency'
            'unitOfMeasure'
            'selector'
        ) `
        -Name 'Azure Retail Prices request fields'
    if (
        $Request.schemaVersion -cne '1.0' -or
        $Request.kind -cne 'AzureRetailPriceLookup' -or
        [string] $Request.currency -notmatch '^[A-Z]{3}$' -or
        $Request.selector -isnot [System.Collections.IDictionary]
    ) {
        throw 'The Azure Retail Prices request contract is invalid.'
    }

    $allowedSelectorFields = @(
        'accessTier'
        'allocationMethod'
        'armRegionName'
        'armSkuName'
        'imageOffer'
        'imagePublisher'
        'imageSku'
        'imageVersion'
        'meterName'
        'productNameContains'
        'redundancy'
        'serviceName'
        'sizeGiB'
        'skuName'
        'storageType'
    )
    foreach ($field in @($Request.selector.Keys)) {
        if ([string] $field -notin $allowedSelectorFields) {
            throw "Azure Retail Prices selector '$field' is not approved."
        }
    }
    foreach ($field in @('serviceName', 'armRegionName')) {
        if (
            -not $Request.selector.Contains($field) -or
            [string]::IsNullOrWhiteSpace([string] $Request.selector[$field])
        ) {
            throw "Azure Retail Prices selector '$field' is required."
        }
    }

    $filterClauses = [System.Collections.Generic.List[string]]::new()
    foreach ($field in @(
        'serviceName'
        'armRegionName'
        'armSkuName'
        'skuName'
        'meterName'
    )) {
        if (
            $Request.selector.Contains($field) -and
            -not [string]::IsNullOrWhiteSpace(
                [string] $Request.selector[$field]
            )
        ) {
            $literal = ConvertTo-AdltRetailPriceODataLiteral `
                -Value ([string] $Request.selector[$field])
            $filterClauses.Add(('{0} eq {1}' -f $field, $literal))
        }
    }
    if (
        $Request.selector.Contains('productNameContains') -and
        -not [string]::IsNullOrWhiteSpace(
            [string] $Request.selector.productNameContains
        )
    ) {
        $filterClauses.Add(
            'contains(productName, {0})' -f (
                ConvertTo-AdltRetailPriceODataLiteral `
                    -Value ([string] $Request.selector.productNameContains)
            )
        )
    }
    $filterClauses.Add("priceType eq 'Consumption'")

    $currencyLiteral = ConvertTo-AdltRetailPriceODataLiteral `
        -Value ([string] $Request.currency)
    $query = @(
        'api-version=2021-10-01-preview'
        'currencyCode={0}' -f [uri]::EscapeDataString($currencyLiteral)
        'meterRegion={0}' -f [uri]::EscapeDataString("'primary'")
        '$filter={0}' -f [uri]::EscapeDataString(
            [string]::Join(' and ', $filterClauses)
        )
    )
    return 'https://prices.azure.com/api/retail/prices?{0}' -f (
        [string]::Join('&', $query)
    )
}

function Assert-AdltRetailPricePageUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Uri
    )

    $parsed = $null
    if (
        $Uri.Length -gt 16384 -or
        -not [uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref] $parsed) -or
        $parsed.Scheme -cne 'https' -or
        $parsed.Host -cne 'prices.azure.com' -or
        $parsed.AbsolutePath.TrimEnd('/') -cne '/api/retail/prices' -or
        -not [string]::IsNullOrEmpty($parsed.UserInfo) -or
        -not [string]::IsNullOrEmpty($parsed.Fragment) -or
        -not $parsed.IsDefaultPort
    ) {
        throw 'Azure Retail Prices pagination returned an unapproved URI.'
    }
}

function Invoke-AdltAzureRetailPriceCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Request
    )

    $nextPage = Get-AdltRetailPriceRequestUri -Request $Request
    $seenPages = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $items = [System.Collections.Generic.List[object]]::new()
    for ($page = 0; $page -lt 10; $page++) {
        Assert-AdltRetailPricePageUri -Uri $nextPage
        if (-not $seenPages.Add($nextPage)) {
            throw 'Azure Retail Prices pagination contains a cycle.'
        }

        $response = Invoke-RestMethod `
            -Uri $nextPage `
            -Method Get `
            -Headers @{ Accept = 'application/json' } `
            -MaximumRedirection 0 `
            -MaximumRetryCount 2 `
            -RetryIntervalSec 2 `
            -TimeoutSec 30 `
            -ErrorAction Stop
        if ($null -eq $response) {
            throw 'Azure Retail Prices returned an empty response.'
        }
        foreach ($item in @(Get-AdltRetailPriceRow -Response $response)) {
            $items.Add($item)
        }

        $nextPageProperty = $response.PSObject.Properties |
            Where-Object Name -In @('NextPageLink', 'nextPageLink') |
            Select-Object -First 1
        if (
            $null -eq $nextPageProperty -or
            [string]::IsNullOrWhiteSpace([string] $nextPageProperty.Value)
        ) {
            return [ordered]@{ Items = @($items.ToArray()) }
        }
        $nextPage = [string] $nextPageProperty.Value
    }

    throw 'Azure Retail Prices pagination exceeded the approved page limit.'
}
