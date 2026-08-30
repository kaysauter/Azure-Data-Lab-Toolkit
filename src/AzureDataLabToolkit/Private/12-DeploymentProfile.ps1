function Get-AdltDeploymentProfile {
    [CmdletBinding()]
    param(
        [ValidatePattern('^[a-z0-9-]+/v[0-9]+$')]
        [string] $Id = 'sqlvm-first-canary/v1'
    )

    $fileName = switch ($Id) {
        'sqlvm-first-canary/v1' { 'sqlvm-first-canary-v1.json' }
        default { throw "Unknown deployment profile '$Id'." }
    }
    $path = Get-AdltDataPath -ChildPath ('Profiles/{0}' -f $fileName)
    if (
        -not [System.IO.File]::Exists($path) -or
        ([System.IO.FileInfo] $path).Length -gt 256KB
    ) {
        throw "Deployment profile '$Id' is missing or exceeds 256 KiB."
    }
    $deploymentProfile = Read-AdltJsonFile -Path $path
    $validation = Test-AdltObjectAgainstSchema `
        -InputObject $deploymentProfile `
        -SchemaPath (
            Get-AdltDataPath `
                -ChildPath 'Schemas/deployment-profile.schema.json'
        )
    if (-not $validation.Valid) {
        throw "Deployment profile '$Id' failed schema validation."
    }
    if ([string] $deploymentProfile.id -cne $Id) {
        throw "Deployment profile file does not contain '$Id'."
    }

    $result = Copy-AdltValue -InputObject $deploymentProfile
    $result['profileHash'] = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $deploymentProfile
    )
    return $result
}

function Test-AdltEmptyProfileValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return $true
    }
    if ($Value -is [string]) {
        return [string]::IsNullOrWhiteSpace($Value)
    }
    if (
        $Value -is [System.Collections.IList] -and
        $Value -isnot [string]
    ) {
        return $Value.Count -eq 0
    }
    return $false
}

function Assert-AdltDeploymentProfileConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DeploymentProfile
    )

    foreach ($path in $DeploymentProfile.exactConfiguration.Keys) {
        $actual = Get-AdltPathValue `
            -InputObject $Configuration `
            -Path ([string] $path)
        $expected = $DeploymentProfile.exactConfiguration[$path]
        if (
            (ConvertTo-AdltCanonicalJson -InputObject $actual) -cne
            (ConvertTo-AdltCanonicalJson -InputObject $expected)
        ) {
            throw (
                "Deployment profile '$($DeploymentProfile.id)' requires " +
                "'$path' to equal " +
                "'$(ConvertTo-AdltCanonicalJson -InputObject $expected)'."
            )
        }
    }
    foreach ($pathValue in @($DeploymentProfile.requiredConfigurationPaths)) {
        $path = [string] $pathValue
        $value = Get-AdltPathValue `
            -InputObject $Configuration `
            -Path $path
        if (Test-AdltEmptyProfileValue -Value $value) {
            throw (
                "Deployment profile '$($DeploymentProfile.id)' requires " +
                "configuration path '$path'."
            )
        }
    }
    foreach ($pathValue in @($DeploymentProfile.emptyConfigurationPaths)) {
        $path = [string] $pathValue
        $value = Get-AdltPathValue `
            -InputObject $Configuration `
            -Path $path
        if (-not (Test-AdltEmptyProfileValue -Value $value)) {
            throw (
                "Deployment profile '$($DeploymentProfile.id)' requires " +
                "configuration path '$path' to be empty."
            )
        }
    }
    if (
        [int] $Configuration.lifecycle.timeToLiveMinutes -lt
        [int] $Configuration.lifecycle.maximumRuntimeMinutes
    ) {
        throw 'Deployment profile TTL must cover the complete maximum runtime.'
    }
}

function Assert-AdltDeploymentProfileBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [string] $ProfileId = 'sqlvm-first-canary/v1'
    )

    $binding = Get-AdltPathValue `
        -InputObject $Plan.configuration `
        -Path 'deploymentProfile'
    if ($binding -isnot [System.Collections.IDictionary]) {
        throw (
            "Deployment requires a versioned deploymentProfile binding " +
            "for '$ProfileId'."
        )
    }
    $deploymentProfile = Get-AdltDeploymentProfile -Id $ProfileId
    if ([string] $binding.id -cne [string] $deploymentProfile.id) {
        throw (
            "Configuration deployment profile '$($binding.id)' does not " +
            "match '$($deploymentProfile.id)'."
        )
    }
    if (
        [string] $binding.hash -cne
        [string] $deploymentProfile.profileHash
    ) {
        throw (
            "Configuration deployment profile hash is stale. Regenerate " +
            "the YAML with this module version."
        )
    }
    if (
        [string] $Plan.target.type -cne
            [string] $deploymentProfile.targetType -or
        [string] $Plan.configuration.template -cne
            [string] $deploymentProfile.template
    ) {
        throw 'Configuration target or template does not match its deployment profile.'
    }

    Assert-AdltDeploymentProfileConfiguration `
        -Configuration $Plan.configuration `
        -DeploymentProfile $deploymentProfile
    return $deploymentProfile
}

function Get-AdltStaticResolvedResourceMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $map = [ordered]@{}
    foreach ($resource in @(Get-AdltResolvedResourceIdSet -Plan $Plan)) {
        $map[[string] $resource.stableId] = [string] $resource.resourceId
    }
    return $map
}

function Assert-AdltSqlVmStaticDeploymentEligibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [string] $ProfileId = 'sqlvm-first-canary/v1'
    )

    $deploymentProfile = Assert-AdltDeploymentProfileBinding `
        -Plan $Plan `
        -ProfileId $ProfileId
    $resources = Get-AdltSqlVmArmResourceMap -Plan $Plan
    $actions = Get-AdltSqlVmArmActionMap -Plan $Plan
    $resolvedResourceIds = Get-AdltStaticResolvedResourceMap -Plan $Plan
    Assert-AdltSqlVmArmPlanProfile `
        -Plan $Plan `
        -Resources $resources `
        -Actions $actions `
        -ResolvedResourceIds $resolvedResourceIds
    return $deploymentProfile
}
