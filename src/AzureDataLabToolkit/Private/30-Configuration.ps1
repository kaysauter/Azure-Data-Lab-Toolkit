function Get-AdltSchemaDefault {
    [CmdletBinding()]
    param()

    return [ordered]@{
        schemaVersion = '1.0'
        kind          = 'AzureDataLab'
        template      = 'sqlvm-secure'
        metadata      = [ordered]@{
            name        = 'sqlvm-lab'
            description = ''
            purpose     = 'lab'
        }
        target        = [ordered]@{
            type = 'sqlVm'
        }
        azure         = [ordered]@{
            cloud         = 'AzureCloud'
            location      = 'switzerlandnorth'
            authentication = [ordered]@{
                mode         = 'interactive-user'
                contextScope = 'process'
            }
            resourceGroup = [ordered]@{
                mode = 'create'
                name = 'rg-adlt-sqlvm-lab'
            }
        }
        engine        = [ordered]@{
            type = 'powershell'
        }
        security      = [ordered]@{
            vmManagedIdentity        = 'system-assigned'
            secretStore              = [ordered]@{
                mode = 'deploy-key-vault'
            }
            administrativeAccess     = [ordered]@{
                mode = 'deploy-bastion'
                sku  = 'basic'
            }
            vmAdministratorCredential = [ordered]@{
                source           = 'key-vault-secret'
                secretName       = 'vm-admin-password'
                allowShellOutput = $false
            }
            containsSensitiveData     = $false
        }
        cost          = [ordered]@{
            estimateRequested = $false
            budget            = [ordered]@{
                currency = 'USD'
            }
        }
        lifecycle     = [ordered]@{
            maximumRuntimeMinutes = 180
            timeToLiveMinutes      = 240
            expiryBehavior         = 'cleanup-only'
            teardown = [ordered]@{
                mode                   = 'explicit'
                strategy               = 'exact-resource-ids'
                retainResourceGroup    = $true
                freshInventoryRequired = $true
                retainBackupShare      = $true
            }
        }
        capabilities  = [ordered]@{
            backupShare = [ordered]@{
                enabled        = $false
                driveLetter    = 'S'
                quotaGiB       = 100
                authentication = 'managed-identity-smb-oauth'
                networkAccess  = 'private-endpoint'
            }
        }
        solutionPacks = [ordered]@{
            sqlVmBackupRestore = [ordered]@{
                enabled                 = $false
                restoreMode             = 'local-staging'
                replaceExistingDatabase = $false
            }
        }
        sqlVm         = [ordered]@{
            platform        = 'windows'
            sqlServerVersion = '2022'
            compute  = [ordered]@{
                vmSize           = 'Standard_D4s_v5'
                securityType      = 'trustedLaunch'
                encryptionAtHost  = $true
            }
            network  = [ordered]@{
                vmPublicIp = $false
            }
            software = [ordered]@{
                catalogIds = @()
            }
            sampleData = [ordered]@{
                catalogIds = @()
            }
        }
    }
}

function Get-AdltTemplateObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
        [string] $Name
    )

    $templatePath = Get-AdltDataPath -ChildPath ('Templates/{0}.yaml' -f $Name)
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Unknown Azure Data Lab template '$Name'."
    }

    return Read-AdltYamlFile -Path $templatePath
}

function Get-AdltBearerTokenFinding {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [string] $Path = '$'
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            Get-AdltBearerTokenFinding `
                -InputObject $InputObject[$key] `
                -Path ('{0}.{1}' -f $Path, [string] $key)
        }
        return
    }
    if (
        $InputObject -is [System.Collections.IList] -and
        $InputObject -isnot [string]
    ) {
        for ($index = 0; $index -lt $InputObject.Count; $index++) {
            Get-AdltBearerTokenFinding `
                -InputObject $InputObject[$index] `
                -Path ('{0}[{1}]' -f $Path, $index)
        }
        return
    }
    if (
        $InputObject -is [string] -and
        [regex]::IsMatch(
            $InputObject,
            (
                '(?i)(?:^|\s)Bearer\s+' +
                '(?=[A-Za-z0-9._~+/=-]{20,}(?:\s|$))' +
                '(?=[A-Za-z0-9._~+/=-]*[0-9._~+/=-])' +
                '[A-Za-z0-9._~+/=-]+(?:\s|$)'
            )
        )
    ) {
        [ordered]@{
            path = $Path
            kind = 'bearer-token'
        }
    }
}

function Assert-AdltSecretFreeBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $InputObject,

        [Parameter(Mandatory)]
        [ValidateSet('configuration', 'plan')]
        [string] $Boundary
    )

    $forbiddenFields = @(Get-AdltForbiddenField -InputObject $InputObject)
    if ($forbiddenFields.Count -gt 0) {
        throw "Secret values are forbidden in $Boundary. Remove field '$($forbiddenFields[0])' and use a secret reference."
    }

    $sensitiveValues = @(
        Get-AdltSensitiveValueFinding -InputObject $InputObject
    )
    if ($sensitiveValues.Count -eq 0) {
        $sensitiveValues = @(
            Get-AdltBearerTokenFinding -InputObject $InputObject
        )
    }
    if ($sensitiveValues.Count -gt 0) {
        throw (
            "Sensitive value pattern '$($sensitiveValues[0].kind)' is forbidden in $Boundary at '$($sensitiveValues[0].path)'."
        )
    }
}

function Resolve-AdltConfiguration {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = 'InputObject')]
        [System.Collections.IDictionary] $InputObject,

        [string] $Template,

        [System.Collections.IDictionary] $Overrides = [ordered]@{}
    )

    $userConfiguration = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        Read-AdltYamlFile -Path $Path
    }
    else {
        ConvertTo-AdltDictionary -InputObject $InputObject
    }

    Assert-AdltSecretFreeBoundary `
        -InputObject $userConfiguration `
        -Boundary configuration

    foreach ($requiredKey in @('schemaVersion', 'kind', 'metadata', 'target', 'azure')) {
        if (-not $userConfiguration.Contains($requiredKey)) {
            throw "Configuration must define top-level property '$requiredKey'."
        }
    }

    if ($userConfiguration.schemaVersion -ne '1.0') {
        throw "Unsupported configuration schema version '$($userConfiguration.schemaVersion)'."
    }

    if ($userConfiguration.kind -ne 'AzureDataLab') {
        throw "Configuration kind must be 'AzureDataLab'."
    }

    $templateName = if ($PSBoundParameters.ContainsKey('Template')) {
        $Template
    }
    elseif ($userConfiguration.Contains('template')) {
        [string] $userConfiguration.template
    }
    else {
        'sqlvm-secure'
    }

    $defaults = Get-AdltSchemaDefault
    $templateConfiguration = Get-AdltTemplateObject -Name $templateName
    $resolved = Copy-AdltValue -InputObject $defaults
    $provenance = [ordered]@{}

    Add-AdltProvenance -Provenance $provenance -Source $defaults -SourceName 'schema-default'
    Merge-AdltDictionary -Target $resolved -Source $templateConfiguration
    Add-AdltProvenance -Provenance $provenance -Source $templateConfiguration -SourceName ('template:{0}' -f $templateName)
    Merge-AdltDictionary -Target $resolved -Source $userConfiguration
    Add-AdltProvenance -Provenance $provenance -Source $userConfiguration -SourceName 'yaml'

    $templateSource = if ($PSBoundParameters.ContainsKey('Template')) {
        'flag:template'
    }
    elseif ($userConfiguration.Contains('template')) {
        'yaml'
    }
    else {
        'schema-default'
    }
    Set-AdltPathValue -Target $resolved -Path 'template' -Value $templateName
    $provenance.template = [ordered]@{
        source     = $templateSource
        derivation = 'selected-template'
    }

    foreach ($pathKey in $Overrides.Keys) {
        Set-AdltPathValue -Target $resolved -Path ([string] $pathKey) -Value $Overrides[$pathKey]
        $provenance[[string] $pathKey] = [ordered]@{
            source     = ('flag:{0}' -f $pathKey)
            derivation = 'direct'
        }
    }

    $maximumRunCost = Get-AdltPathValue `
        -InputObject $resolved `
        -Path 'cost.maximumRunCost'
    if (
        $maximumRunCost -is [System.Collections.IDictionary] -and
        -not $maximumRunCost.Contains('currency')
    ) {
        Set-AdltDerivedValue `
            -Configuration $resolved `
            -Provenance $provenance `
            -Path 'cost.maximumRunCost.currency' `
            -Value $resolved.cost.budget.currency `
            -Rule 'inherit-budget-currency'
    }

    Invoke-AdltConfigurationContributor `
        -Configuration $resolved `
        -Provenance $provenance

    Assert-AdltSecretFreeBoundary `
        -InputObject $resolved `
        -Boundary configuration

    $schemaPath = Get-AdltDataPath -ChildPath 'Schemas/configuration.schema.json'
    $resolvedValidation = Test-AdltObjectAgainstSchema -InputObject $resolved -SchemaPath $schemaPath
    if (-not $resolvedValidation.Valid) {
        throw "Resolved configuration schema validation failed: $($resolvedValidation.Errors -join ' ')"
    }

    Assert-AdltSemanticConfiguration -Configuration $resolved
    Complete-AdltProvenance -Provenance $provenance -Configuration $resolved

    [pscustomobject]@{
        Configuration = $resolved
        Provenance     = $provenance
        Template       = $templateName
    }
}
