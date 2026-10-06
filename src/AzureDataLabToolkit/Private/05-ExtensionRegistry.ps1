$script:AdltTargetPlanContributors = [ordered]@{}
$script:AdltCapabilityPlanContributors = [ordered]@{}
$script:AdltSolutionPackPlanContributors = [ordered]@{}

function New-AdltContributorDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('target', 'capability', 'solution-pack')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $ContractVersion,

        [Parameter(Mandatory)]
        [string[]] $SupportedSchemaVersions,

        [string[]] $TargetTypes = @(),

        [string[]] $ActivationPaths = @(),

        [string[]] $Dependencies = @(),

        [Parameter(Mandatory)]
        [string] $PlanFunctionName,

        [string] $ConfigurationFunctionName = '',

        [bool] $AlwaysActive = $false
    )

    return [ordered]@{
        kind                      = $Kind
        name                      = $Name
        contractVersion           = $ContractVersion
        implementationVersion     = $script:AzureDataLabToolkitVersion
        supportedSchemaVersions   = @($SupportedSchemaVersions)
        targetTypes               = @($TargetTypes)
        activationPaths           = @($ActivationPaths)
        dependencies              = @($Dependencies)
        planFunctionName          = $PlanFunctionName
        configurationFunctionName = $ConfigurationFunctionName
        alwaysActive              = $AlwaysActive
        source                    = 'bundled-module'
        integrity                 = 'covered-by-module-package'
    }
}

function Register-AdltTargetPlanContributor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-zA-Z0-9]{1,31}$')]
        [string] $TargetType,

        [Parameter(Mandatory)]
        [ValidatePattern('^New-Adlt[A-Za-z0-9]+Plan$')]
        [string] $FunctionName,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d+\.\d+$')]
        [string] $ContractVersion,

        [Parameter(Mandatory)]
        [string[]] $SupportedSchemaVersions
    )

    if ($script:AdltTargetPlanContributors.Contains($TargetType)) {
        throw "Target plan contributor '$TargetType' is already registered."
    }

    $script:AdltTargetPlanContributors[$TargetType] = New-AdltContributorDescriptor `
        -Kind target `
        -Name $TargetType `
        -ContractVersion $ContractVersion `
        -SupportedSchemaVersions $SupportedSchemaVersions `
        -TargetTypes @($TargetType) `
        -PlanFunctionName $FunctionName
}

function Register-AdltCapabilityPlanContributor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-zA-Z0-9-]{1,63}$')]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidatePattern('^Get-Adlt[A-Za-z0-9]+PlanFragment$')]
        [string] $FunctionName,

        [string] $ConfigurationFunctionName = '',

        [Parameter(Mandatory)]
        [ValidatePattern('^\d+\.\d+$')]
        [string] $ContractVersion,

        [Parameter(Mandatory)]
        [string[]] $SupportedSchemaVersions,

        [Parameter(Mandatory)]
        [string[]] $TargetTypes,

        [string[]] $ActivationPaths = @(),

        [string[]] $Dependencies = @(),

        [switch] $AlwaysActive
    )

    if ($script:AdltCapabilityPlanContributors.Contains($Name)) {
        throw "Capability plan contributor '$Name' is already registered."
    }
    if ($AlwaysActive -and $ActivationPaths.Count -gt 0) {
        throw "Capability plan contributor '$Name' cannot be always active and path activated."
    }
    if (-not $AlwaysActive -and $ActivationPaths.Count -eq 0) {
        throw "Capability plan contributor '$Name' must declare activation paths or AlwaysActive."
    }

    $script:AdltCapabilityPlanContributors[$Name] = New-AdltContributorDescriptor `
        -Kind capability `
        -Name $Name `
        -ContractVersion $ContractVersion `
        -SupportedSchemaVersions $SupportedSchemaVersions `
        -TargetTypes $TargetTypes `
        -ActivationPaths $ActivationPaths `
        -Dependencies $Dependencies `
        -PlanFunctionName $FunctionName `
        -ConfigurationFunctionName $ConfigurationFunctionName `
        -AlwaysActive ([bool] $AlwaysActive)
}

function Register-AdltSolutionPackPlanContributor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-zA-Z0-9-]{1,63}$')]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidatePattern('^Get-Adlt[A-Za-z0-9]+PlanFragment$')]
        [string] $FunctionName,

        [Parameter(Mandatory)]
        [ValidatePattern('^Resolve-Adlt[A-Za-z0-9]+Configuration$')]
        [string] $ConfigurationFunctionName,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d+\.\d+$')]
        [string] $ContractVersion,

        [Parameter(Mandatory)]
        [string[]] $SupportedSchemaVersions,

        [Parameter(Mandatory)]
        [string[]] $TargetTypes,

        [Parameter(Mandatory)]
        [string[]] $ActivationPaths,

        [Parameter(Mandatory)]
        [string[]] $Dependencies
    )

    if ($script:AdltSolutionPackPlanContributors.Contains($Name)) {
        throw "Solution-pack plan contributor '$Name' is already registered."
    }

    $script:AdltSolutionPackPlanContributors[$Name] = New-AdltContributorDescriptor `
        -Kind solution-pack `
        -Name $Name `
        -ContractVersion $ContractVersion `
        -SupportedSchemaVersions $SupportedSchemaVersions `
        -TargetTypes $TargetTypes `
        -ActivationPaths $ActivationPaths `
        -Dependencies $Dependencies `
        -PlanFunctionName $FunctionName `
        -ConfigurationFunctionName $ConfigurationFunctionName
}

function Test-AdltContributorApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Descriptor,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    if ($Descriptor.supportedSchemaVersions -notcontains $Configuration.schemaVersion) {
        throw "Contributor '$($Descriptor.name)' does not support schema '$($Configuration.schemaVersion)'."
    }
    if (
        $Descriptor.targetTypes.Count -gt 0 -and
        $Descriptor.targetTypes -notcontains $Configuration.target.type
    ) {
        return $false
    }
    if ($Descriptor.alwaysActive) {
        return $true
    }
    if ($Descriptor.activationPaths.Count -eq 0) {
        return $false
    }

    foreach ($path in $Descriptor.activationPaths) {
        if ((Get-AdltPathValue -InputObject $Configuration -Path $path) -eq $true) {
            return $true
        }
    }

    return $false
}

function Invoke-AdltConfigurationContributor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance
    )

    foreach ($registry in @(
        $script:AdltCapabilityPlanContributors
        $script:AdltSolutionPackPlanContributors
    )) {
        $names = [string[]] @($registry.Keys)
        [System.Array]::Sort($names, [System.StringComparer]::Ordinal)

        foreach ($name in $names) {
            $descriptor = $registry[$name]
            if (
                -not [string]::IsNullOrWhiteSpace($descriptor.configurationFunctionName) -and
                (Test-AdltContributorApplication -Descriptor $descriptor -Configuration $Configuration)
            ) {
                $command = Get-Command `
                    -Name $descriptor.configurationFunctionName `
                    -CommandType Function `
                    -ErrorAction Stop
                & $command -Configuration $Configuration -Provenance $Provenance
            }
        }
    }
}

function Assert-AdltContributorGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    $selectedDescriptors = [ordered]@{}
    foreach ($registryEntry in @(
        [pscustomobject]@{
            Prefix   = 'capability'
            Registry = $script:AdltCapabilityPlanContributors
        }
        [pscustomobject]@{
            Prefix   = 'solution-pack'
            Registry = $script:AdltSolutionPackPlanContributors
        }
    )) {
        foreach ($name in $registryEntry.Registry.Keys) {
            $descriptor = $registryEntry.Registry[$name]
            if (Test-AdltContributorApplication -Descriptor $descriptor -Configuration $Configuration) {
                $selectedDescriptors['{0}:{1}' -f $registryEntry.Prefix, $name] = $descriptor
            }
        }
    }

    $catalogIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($catalogId in @(
        $Configuration.sqlVm.software.catalogIds
        $Configuration.sqlVm.sampleData.catalogIds
    )) {
        [void] $catalogIds.Add([string] $catalogId)
    }

    $remainingDependencies = [ordered]@{}
    foreach ($contributorId in $selectedDescriptors.Keys) {
        $dependencies = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        foreach ($dependency in @($selectedDescriptors[$contributorId].dependencies)) {
            $dependencyId = [string] $dependency
            if ($dependencyId -like 'catalog:*') {
                $catalogId = $dependencyId.Substring('catalog:'.Length)
                if (-not $catalogIds.Contains($catalogId)) {
                    throw "Contributor '$contributorId' requires unselected catalog item '$catalogId'."
                }
                continue
            }
            if ($dependencyId -like 'target:*') {
                $targetType = $dependencyId.Substring('target:'.Length)
                if ($targetType -ne $Configuration.target.type) {
                    throw "Contributor '$contributorId' requires target '$targetType'."
                }
                continue
            }
            if (
                $dependencyId -notlike 'capability:*' -and
                $dependencyId -notlike 'solution-pack:*'
            ) {
                throw "Contributor '$contributorId' has malformed dependency '$dependencyId'."
            }
            if (-not $selectedDescriptors.Contains($dependencyId)) {
                throw "Contributor '$contributorId' requires missing or inactive contributor '$dependencyId'."
            }
            if (-not $dependencies.Add($dependencyId)) {
                throw "Contributor '$contributorId' declares duplicate dependency '$dependencyId'."
            }
        }
        $remainingDependencies[$contributorId] = $dependencies
    }

    while ($remainingDependencies.Count -gt 0) {
        $ready = [string[]] @(
            $remainingDependencies.Keys |
                Where-Object { $remainingDependencies[$_].Count -eq 0 }
        )
        if ($ready.Count -eq 0) {
            throw 'Selected contributor dependencies contain a cycle.'
        }

        foreach ($readyId in $ready) {
            $remainingDependencies.Remove($readyId)
        }
        foreach ($dependencies in $remainingDependencies.Values) {
            foreach ($readyId in $ready) {
                [void] $dependencies.Remove($readyId)
            }
        }
    }
}

function Get-AdltContributorContractSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    $targetDescriptor = $script:AdltTargetPlanContributors[$Configuration.target.type]
    $result = [ordered]@{
        targetProvider = [ordered]@{
            name                  = $targetDescriptor.name
            contractVersion       = $targetDescriptor.contractVersion
            implementationVersion = $targetDescriptor.implementationVersion
            source                = $targetDescriptor.source
            integrity             = $targetDescriptor.integrity
        }
        capabilities = @()
        solutionPacks = @()
    }

    foreach ($registryEntry in @(
        [pscustomobject]@{
            Property = 'capabilities'
            Registry = $script:AdltCapabilityPlanContributors
        }
        [pscustomobject]@{
            Property = 'solutionPacks'
            Registry = $script:AdltSolutionPackPlanContributors
        }
    )) {
        $contracts = foreach ($name in @($registryEntry.Registry.Keys | Sort-Object)) {
            $descriptor = $registryEntry.Registry[$name]
            if (Test-AdltContributorApplication -Descriptor $descriptor -Configuration $Configuration) {
                [ordered]@{
                    name                  = $descriptor.name
                    contractVersion       = $descriptor.contractVersion
                    implementationVersion = $descriptor.implementationVersion
                    source                = $descriptor.source
                    integrity             = $descriptor.integrity
                }
            }
        }
        $result[$registryEntry.Property] = @($contracts)
    }

    return $result
}

function New-AdltTargetPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance
    )

    $targetType = [string] $Configuration.target.type
    if (-not $script:AdltTargetPlanContributors.Contains($targetType)) {
        throw "No target plan contributor is registered for '$targetType'."
    }

    $descriptor = $script:AdltTargetPlanContributors[$targetType]
    if ($descriptor.supportedSchemaVersions -notcontains $Configuration.schemaVersion) {
        throw "Target contributor '$targetType' does not support schema '$($Configuration.schemaVersion)'."
    }

    Assert-AdltContributorGraph -Configuration $Configuration

    $command = Get-Command -Name $descriptor.planFunctionName -CommandType Function -ErrorAction Stop
    return & $command -Configuration $Configuration -Provenance $Provenance
}

function Get-AdltRegisteredPlanFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Registry,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Names,

        [Parameter(Mandatory)]
        [string] $PlanIntentHash
    )

    $contributorNames = [string[]] @($Registry.Keys)
    [System.Array]::Sort($contributorNames, [System.StringComparer]::Ordinal)

    foreach ($name in $contributorNames) {
        $descriptor = $Registry[$name]
        if (-not (Test-AdltContributorApplication -Descriptor $descriptor -Configuration $Configuration)) {
            continue
        }

        $command = Get-Command -Name $descriptor.planFunctionName -CommandType Function -ErrorAction Stop
        & $command `
            -Configuration $Configuration `
            -Names $Names `
            -PlanIntentHash $PlanIntentHash
    }
}

function Get-AdltCapabilityPlanFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Names,

        [Parameter(Mandatory)]
        [string] $PlanIntentHash
    )

    Get-AdltRegisteredPlanFragment `
        -Registry $script:AdltCapabilityPlanContributors `
        -Configuration $Configuration `
        -Names $Names `
        -PlanIntentHash $PlanIntentHash
}

function Get-AdltSolutionPackPlanFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Names,

        [Parameter(Mandatory)]
        [string] $PlanIntentHash
    )

    Get-AdltRegisteredPlanFragment `
        -Registry $script:AdltSolutionPackPlanContributors `
        -Configuration $Configuration `
        -Names $Names `
        -PlanIntentHash $PlanIntentHash
}
