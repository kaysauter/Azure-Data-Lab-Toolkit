function Get-AdltForbiddenField {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [string] $Path = ''
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $keyText = [string] $key
            $childPath = if ([string]::IsNullOrEmpty($Path)) {
                $keyText
            }
            else {
                '{0}.{1}' -f $Path, $keyText
            }

            if (
                $keyText -match '^(password|secretValue|clientSecret|token|accessToken|refreshToken|connectionString|sasToken|accountKey|accessKey)$'
            ) {
                $childPath
            }

            Get-AdltForbiddenField -InputObject $InputObject[$key] -Path $childPath
        }
    }
    elseif ($InputObject -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $InputObject.Count; $index++) {
            Get-AdltForbiddenField -InputObject $InputObject[$index] -Path ('{0}[{1}]' -f $Path, $index)
        }
    }
}

function Test-AdltObjectAgainstSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $InputObject,

        [Parameter(Mandatory)]
        [string] $SchemaPath
    )

    $json = $InputObject | ConvertTo-Json -Depth 100 -Compress
    $validationErrors = @()
    $valid = $false

    try {
        $valid = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop
    }
    catch {
        $validationErrors += $_.Exception.Message
    }

    if (-not $valid -and $validationErrors.Count -eq 0) {
        $validationErrors += 'Configuration does not conform to the versioned JSON schema.'
    }

    [pscustomobject]@{
        Valid  = [bool] $valid
        Errors = @($validationErrors)
    }
}

function Assert-AdltTypedAzureResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $ConfigurationPath,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ProviderNamespace,

        [Parameter(Mandatory)]
        [string] $ResourceType
    )

    $pattern = (
        '^/subscriptions/(?<subscription>[0-9a-fA-F-]+)/resourceGroups/' +
        '(?<resourceGroup>[^/]+)/providers/{0}/{1}/(?<name>[^/]+)$'
    ) -f [regex]::Escape($ProviderNamespace), [regex]::Escape($ResourceType)
    $match = [regex]::Match(
        $ResourceId,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        throw (
            "{0} must be an exact {1}/{2} ARM resource ID." -f
                $ConfigurationPath,
                $ProviderNamespace,
                $ResourceType
        )
    }
    if (-not [string]::Equals(
        $match.Groups['subscription'].Value,
        $SubscriptionId,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$ConfigurationPath must belong to azure.subscriptionId."
    }

    return [ordered]@{
        subscriptionId    = $match.Groups['subscription'].Value
        resourceGroupName = $match.Groups['resourceGroup'].Value
        providerNamespace = $ProviderNamespace
        resourceType      = $ResourceType
        resourceName      = $match.Groups['name'].Value
    }
}

function Assert-AdltSemanticConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    $resourceGroup = $Configuration.azure.resourceGroup
    $resourceGroupId = if ($resourceGroup.Contains('resourceId')) {
        [string] $resourceGroup.resourceId
    }
    else {
        ''
    }
    if ($resourceGroup.mode -eq 'reuse') {
        if ([string]::IsNullOrWhiteSpace($resourceGroupId)) {
            throw 'azure.resourceGroup.resourceId is required when mode is reuse.'
        }

        $resourceGroupMatch = [regex]::Match(
            $resourceGroupId,
            '^/subscriptions/([^/]+)/resourceGroups/([^/]+)$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $resourceGroupMatch.Success) {
            throw 'azure.resourceGroup.resourceId must be an exact resource-group ARM ID when mode is reuse.'
        }

        $resourceGroupSubscriptionId = $resourceGroupMatch.Groups[1].Value
        $resourceGroupName = $resourceGroupMatch.Groups[2].Value
        if (-not [string]::Equals(
            $resourceGroupSubscriptionId,
            [string] $Configuration.azure.subscriptionId,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'azure.resourceGroup.resourceId must belong to azure.subscriptionId.'
        }
        if (-not [string]::Equals(
            $resourceGroupName,
            [string] $resourceGroup.name,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'azure.resourceGroup.resourceId must identify azure.resourceGroup.name.'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($resourceGroupId)) {
        throw 'azure.resourceGroup.resourceId cannot be set when mode is create.'
    }

    if (
        [int] $Configuration.lifecycle.timeToLiveMinutes -lt
        [int] $Configuration.lifecycle.maximumRuntimeMinutes
    ) {
        throw 'lifecycle.timeToLiveMinutes must be greater than or equal to lifecycle.maximumRuntimeMinutes.'
    }

    if (
        $Configuration.cost.Contains('maximumRunCost') -and
        $Configuration.cost.maximumRunCost.currency -cne
        $Configuration.cost.budget.currency
    ) {
        throw 'cost.maximumRunCost.currency must match cost.budget.currency.'
    }

    if ($Configuration.lifecycle.teardown.mode -eq 'preauthorized-canary') {
        if ($Configuration.metadata.purpose -ne 'canary') {
            throw "lifecycle.teardown.mode 'preauthorized-canary' requires metadata.purpose 'canary'."
        }
        if ($resourceGroup.mode -ne 'create') {
            throw "A preauthorized canary must create and own its resource group."
        }
        if ([bool] $Configuration.security.containsSensitiveData) {
            throw 'A preauthorized canary cannot contain sensitive data.'
        }
        if (-not [bool] $Configuration.cost.estimateRequested) {
            throw 'A preauthorized canary requires cost.estimateRequested to be true.'
        }
        if (-not $Configuration.cost.Contains('maximumRunCost')) {
            throw 'A preauthorized canary requires cost.maximumRunCost.'
        }
        if ([bool] $Configuration.lifecycle.teardown.retainBackupShare) {
            throw 'A preauthorized canary cannot retain its backup share.'
        }
    }

    $secretStore = $Configuration.security.secretStore
    if (
        $secretStore.mode -eq 'reuse-key-vault' -and
        [string]::IsNullOrWhiteSpace([string] $secretStore.resourceId)
    ) {
        throw 'security.secretStore.resourceId is required when mode is reuse-key-vault.'
    }
    if ($secretStore.mode -eq 'reuse-key-vault') {
        [void] (Assert-AdltTypedAzureResourceId `
            -ResourceId ([string] $secretStore.resourceId) `
            -ConfigurationPath 'security.secretStore.resourceId' `
            -SubscriptionId ([string] $Configuration.azure.subscriptionId) `
            -ProviderNamespace 'Microsoft.KeyVault' `
            -ResourceType 'vaults')
        if (
            -not $secretStore.Contains('diagnosticDestinationResourceId') -or
            [string]::IsNullOrWhiteSpace(
                [string] $secretStore.diagnosticDestinationResourceId
            )
        ) {
            throw (
                'security.secretStore.diagnosticDestinationResourceId is ' +
                'required when mode is reuse-key-vault.'
            )
        }
        [void] (Assert-AdltTypedAzureResourceId `
            -ResourceId (
                [string] $secretStore.diagnosticDestinationResourceId
            ) `
            -ConfigurationPath (
                'security.secretStore.diagnosticDestinationResourceId'
            ) `
            -SubscriptionId ([string] $Configuration.azure.subscriptionId) `
            -ProviderNamespace 'Microsoft.OperationalInsights' `
            -ResourceType 'workspaces')
    }
    elseif (
        $secretStore.mode -eq 'deploy-key-vault' -and
        (
            $secretStore.Contains('resourceId') -or
            $secretStore.Contains('diagnosticDestinationResourceId')
        )
    ) {
        throw (
            'Existing Key Vault resource and diagnostic destination IDs ' +
            'cannot be set when mode is deploy-key-vault.'
        )
    }

    if (
        $secretStore.mode -in @('approved-external-store', 'not-applicable') -and
        [string]::IsNullOrWhiteSpace([string] $secretStore.rationale)
    ) {
        throw "security.secretStore.rationale is required when mode is '$($secretStore.mode)'."
    }

    $administrativeAccess = $Configuration.security.administrativeAccess
    if (
        $administrativeAccess.mode -eq 'reuse-bastion' -and
        [string]::IsNullOrWhiteSpace([string] $administrativeAccess.resourceId)
    ) {
        throw 'security.administrativeAccess.resourceId is required when mode is reuse-bastion.'
    }
    if ($administrativeAccess.mode -eq 'reuse-bastion') {
        [void] (Assert-AdltTypedAzureResourceId `
            -ResourceId ([string] $administrativeAccess.resourceId) `
            -ConfigurationPath 'security.administrativeAccess.resourceId' `
            -SubscriptionId ([string] $Configuration.azure.subscriptionId) `
            -ProviderNamespace 'Microsoft.Network' `
            -ResourceType 'bastionHosts')
        if (
            -not $administrativeAccess.Contains('rationale') -or
            [string]::IsNullOrWhiteSpace([string] $administrativeAccess.rationale)
        ) {
            throw 'security.administrativeAccess.rationale is required when mode is reuse-bastion.'
        }
    }
    elseif (
        $administrativeAccess.mode -eq 'deploy-bastion' -and
        $administrativeAccess.Contains('resourceId')
    ) {
        throw 'security.administrativeAccess.resourceId cannot be set when mode is deploy-bastion.'
    }
    elseif (
        $administrativeAccess.mode -eq 'opt-out' -and
        $administrativeAccess.Contains('resourceId')
    ) {
        throw 'security.administrativeAccess.resourceId cannot be set when mode is opt-out.'
    }

    if (
        $administrativeAccess.mode -eq 'opt-out' -and
        [string]::IsNullOrWhiteSpace([string] $administrativeAccess.rationale)
    ) {
        throw 'security.administrativeAccess.rationale is required when mode is opt-out.'
    }

    $credential = $Configuration.security.vmAdministratorCredential
    if ($credential.allowShellOutput -and $credential.source -ne 'generate-during-deployment') {
        throw 'Shell password output can only be requested with generate-during-deployment credentials.'
    }
    $secretVersion = if ($credential.Contains('secretVersion')) {
        [string] $credential.secretVersion
    }
    else {
        ''
    }
    if (
        $secretStore.mode -eq 'reuse-key-vault' -and
        $credential.source -eq 'key-vault-secret' -and
        [string]::IsNullOrWhiteSpace($secretVersion)
    ) {
        throw (
            'security.vmAdministratorCredential.secretVersion is required ' +
            'when reusing a Key Vault secret.'
        )
    }
    if (
        $credential.source -eq 'generate-during-deployment' -and
        -not [string]::IsNullOrWhiteSpace($secretVersion)
    ) {
        throw (
            'security.vmAdministratorCredential.secretVersion cannot be set ' +
            'when the credential is generated during deployment.'
        )
    }
    if (
        $credential.source -eq 'key-vault-secret' -and
        $secretStore.mode -ne 'reuse-key-vault' -and
        -not [string]::IsNullOrWhiteSpace($secretVersion)
    ) {
        throw (
            'security.vmAdministratorCredential.secretVersion can only be ' +
            'set when reusing a Key Vault.'
        )
    }

    if ($Configuration.sqlVm.network.vmPublicIp) {
        throw 'SQL VM public IP addresses are outside the first secure support profile.'
    }

    $diskEncryptionSetId = Get-AdltPathValue `
        -InputObject $Configuration `
        -Path 'sqlVm.compute.diskEncryptionSetId'
    if (-not [string]::IsNullOrWhiteSpace([string] $diskEncryptionSetId)) {
        [void] (Assert-AdltTypedAzureResourceId `
            -ResourceId ([string] $diskEncryptionSetId) `
            -ConfigurationPath 'sqlVm.compute.diskEncryptionSetId' `
            -SubscriptionId ([string] $Configuration.azure.subscriptionId) `
            -ProviderNamespace 'Microsoft.Compute' `
            -ResourceType 'diskEncryptionSets')
    }
}
