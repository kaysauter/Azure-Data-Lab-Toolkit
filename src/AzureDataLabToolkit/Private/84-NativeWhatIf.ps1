function New-AdltSqlVmArmParameterDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation
    )

    $reference = $Compilation.parameterReference
    if (
        [string] $reference.keyVaultResourceId -notmatch
            '^/subscriptions/[0-9a-fA-F-]{36}/' -or
        [string] $reference.secretName -notmatch
            '^[A-Za-z0-9-]{1,127}$' -or
        [string] $reference.secretVersion -notmatch
            '^[0-9a-fA-F]{32}$'
    ) {
        throw 'The ARM compilation does not contain a pinned Key Vault parameter reference.'
    }

    return [ordered]@{
        '$schema' = (
            'https://schema.management.azure.com/schemas/' +
            '2019-04-01/deploymentParameters.json#'
        )
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            vmAdministratorPassword = [ordered]@{
                reference = [ordered]@{
                    keyVault = [ordered]@{
                        id = [string] $reference.keyVaultResourceId
                    }
                    secretName = [string] $reference.secretName
                    secretVersion = [string] $reference.secretVersion
                }
            }
        }
    }
}

function Get-AdltSqlVmNativeWhatIfExpectedChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [Parameter(Mandatory)]
        [object[]] $CustomResults
    )

    $customByStableId = Get-AdltDictionaryByProperty `
        -Items $CustomResults `
        -PropertyName stableId `
        -ArtifactName 'Custom WhatIf result set'
    $expected =
        [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    foreach ($bindingValue in @($Compilation.resourceBindings)) {
        $binding = ConvertTo-AdltDictionary -InputObject $bindingValue
        if ([string] $binding.disposition -cne 'deploy') {
            continue
        }
        $stableId = [string] $binding.stableId
        if (-not $customByStableId.ContainsKey($stableId)) {
            throw "Custom WhatIf results omit compiled resource '$stableId'."
        }
        $classification = [string] (
            $customByStableId[$stableId].classification
        )
        $allowedChangeTypes = switch ($classification) {
            'create' { @('Create') }
            'no-change' { @('NoChange') }
            default {
                throw (
                    "Compiled resource '$stableId' has unsafe custom " +
                    "classification '$classification'."
                )
            }
        }
        if (-not $expected.TryAdd(
            [string] $binding.resourceId,
            [ordered]@{
                stableId          = $stableId
                allowedChangeTypes = $allowedChangeTypes
            }
        )) {
            throw "Compiled resource ID '$($binding.resourceId)' is duplicated."
        }
    }

    $deployment = $Compilation.template.resources |
        Where-Object type -CEQ 'Microsoft.Resources/deployments' |
        Select-Object -First 1
    if ($null -eq $deployment) {
        throw 'The SQL VM compilation lacks its nested resource-group deployment.'
    }
    $resourceGroupBinding = @(
        $Compilation.resourceBindings |
            Where-Object {
                [string] (
                    Get-AdltObjectPropertyValue `
                        -InputObject $_ `
                        -Name 'stableId'
                ) -ceq 'azure.resource-group.primary'
            }
    )
    $resourceGroupId = if ($resourceGroupBinding.Count -eq 1) {
        [string] (
            Get-AdltObjectPropertyValue `
                -InputObject $resourceGroupBinding[0] `
                -Name 'resourceId'
        )
    }
    else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($resourceGroupId)) {
        throw 'The SQL VM compilation lacks a resource-group binding.'
    }
    $nestedDeploymentId = '{0}/providers/Microsoft.Resources/deployments/{1}' -f
        $resourceGroupId.TrimEnd('/'),
        [string] $deployment.name
    if (-not $expected.TryAdd(
        $nestedDeploymentId,
        [ordered]@{
            stableId = 'engine.subscription.nested-deployment'
            allowedChangeTypes = @(
                'Deploy'
                'Create'
                'NoChange'
            )
        }
    )) {
        throw 'The nested deployment ID collides with a planned resource.'
    }

    return $expected
}

function Get-AdltNativeWhatIfResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Change
    )

    $resourceId = [string] (
        Get-AdltObjectPropertyValue `
            -InputObject $Change `
            -Name 'FullyQualifiedResourceId'
    )
    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        $scope = [string] (
            Get-AdltObjectPropertyValue -InputObject $Change -Name 'Scope'
        )
        $relativeResourceId = [string] (
            Get-AdltObjectPropertyValue `
                -InputObject $Change `
                -Name 'RelativeResourceId'
        )
        if (
            -not [string]::IsNullOrWhiteSpace($scope) -and
            -not [string]::IsNullOrWhiteSpace($relativeResourceId)
        ) {
            $resourceId = '{0}/{1}' -f
                $scope.TrimEnd('/'),
                $relativeResourceId.TrimStart('/')
        }
    }
    if ($resourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/') {
        throw 'Native ARM WhatIf returned a non-ARM or incomplete resource ID.'
    }
    return $resourceId
}

function Get-AdltNativeWhatIfResultHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Status,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Changes,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Diagnostics,

        [Parameter(Mandatory)]
        [int] $PotentialChangeCount,

        [Parameter(Mandatory)]
        [string] $ChangesHash,

        [AllowNull()]
        [string] $FailureKind
    )

    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
            nativeStatus               = $Status
            nativeChanges              = $Changes
            nativeDiagnostics          = $Diagnostics
            nativePotentialChangeCount = $PotentialChangeCount
            nativeChangesHash          = $ChangesHash
            nativeFailureKind          = $FailureKind
        })
    )
}

function ConvertTo-AdltNativeWhatIfResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    $diagnostics = [System.Collections.Generic.List[object]]::new()
    foreach ($diagnostic in @(
        Get-AdltObjectPropertyValue `
            -InputObject $Result `
            -Name 'Diagnostics'
    )) {
        $diagnostics.Add([ordered]@{
            level = [string] (
                Get-AdltObjectPropertyValue `
                    -InputObject $diagnostic `
                    -Name 'Level'
            )
            code = [string] (
                Get-AdltObjectPropertyValue `
                    -InputObject $diagnostic `
                    -Name 'Code'
            )
            target = [string] (
                Get-AdltObjectPropertyValue `
                    -InputObject $diagnostic `
                    -Name 'Target'
            )
        })
    }
    $errorResponse = Get-AdltObjectPropertyValue `
        -InputObject $Result `
        -Name 'Error'
    if ($null -ne $errorResponse) {
        $diagnostics.Add([ordered]@{
            level = 'Error'
            code = [string] (
                Get-AdltObjectPropertyValue `
                    -InputObject $errorResponse `
                    -Name 'Code'
            )
            target = [string] (
                Get-AdltObjectPropertyValue `
                    -InputObject $errorResponse `
                    -Name 'Target'
            )
        })
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    $resourceIds =
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    foreach ($change in @(
        Get-AdltObjectPropertyValue -InputObject $Result -Name 'Changes'
    )) {
        $resourceId = Get-AdltNativeWhatIfResourceId -Change $change
        if (-not $resourceIds.Add($resourceId)) {
            throw "Native ARM WhatIf returned duplicate resource ID '$resourceId'."
        }
        $unsupportedReason = [string] (
            Get-AdltObjectPropertyValue `
                -InputObject $change `
                -Name 'UnsupportedReason'
        )
        if (-not [string]::IsNullOrWhiteSpace($unsupportedReason)) {
            $diagnostics.Add([ordered]@{
                level  = 'Error'
                code   = 'UnsupportedChange'
                target = $resourceId
            })
        }
        $changes.Add([ordered]@{
            resourceId = $resourceId
            changeType = [string] (
                Get-AdltObjectPropertyValue `
                    -InputObject $change `
                    -Name 'ChangeType'
            )
        })
    }

    $normalizedChanges = @(
        $changes.ToArray() |
            Sort-Object resourceId, changeType
    )
    $normalizedDiagnostics = @(
        $diagnostics.ToArray() |
            Sort-Object level, code, target
    )
    $normalized = [ordered]@{
        status = [string] (
            Get-AdltObjectPropertyValue -InputObject $Result -Name 'Status'
        )
        changes = $normalizedChanges
        diagnostics = $normalizedDiagnostics
        potentialChangeCount = @(
            Get-AdltObjectPropertyValue `
                -InputObject $Result `
                -Name 'PotentialChanges'
        ).Count
    }
    $normalized.changesHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $normalized.changes
    )
    $normalized.resultHash = Get-AdltNativeWhatIfResultHash `
        -Status $normalized.status `
        -Changes @($normalized.changes) `
        -Diagnostics @($normalized.diagnostics) `
        -PotentialChangeCount $normalized.potentialChangeCount `
        -ChangesHash $normalized.changesHash `
        -FailureKind $null
    return $normalized
}

function Assert-AdltNativeWhatIfChangeSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $NativeResult,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, object]] $ExpectedChanges
    )

    if (
        [string] $NativeResult.status -cne 'Succeeded' -or
        [int] $NativeResult.potentialChangeCount -ne 0 -or
        @($NativeResult.diagnostics).Count -ne 0
    ) {
        throw 'Native ARM WhatIf did not complete without diagnostics or potential changes.'
    }
    if (@($NativeResult.changes).Count -ne $ExpectedChanges.Count) {
        throw 'Native ARM WhatIf change IDs do not exactly match the compiled deployment.'
    }
    $observedIds =
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    foreach ($change in @($NativeResult.changes)) {
        $resourceId = [string] $change.resourceId
        if (
            -not $observedIds.Add($resourceId) -or
            -not $ExpectedChanges.ContainsKey($resourceId)
        ) {
            throw "Native ARM WhatIf returned unexpected resource '$resourceId'."
        }
        if (
            [string] $change.changeType -notin
                @($ExpectedChanges[$resourceId].allowedChangeTypes)
        ) {
            throw (
                "Native ARM WhatIf change '$($change.changeType)' is not " +
                "safe for '$resourceId'."
            )
        }
    }
    if ($observedIds.Count -ne $ExpectedChanges.Count) {
        throw 'Native ARM WhatIf did not return every compiled deployment resource.'
    }
}

function Invoke-AdltSqlVmNativeWhatIf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Compilation,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId,

        [Parameter(Mandatory)]
        [object[]] $CustomResults
    )

    [void] (Assert-AdltAzureContextReady -Plan $Plan)
    $expectedChanges = Get-AdltSqlVmNativeWhatIfExpectedChange `
        -Compilation $Compilation `
        -CustomResults $CustomResults
    $parameterDocument = New-AdltSqlVmArmParameterDocument `
        -Compilation $Compilation
    $parameterJson = ConvertTo-AdltCanonicalJson `
        -InputObject $parameterDocument
    $parameterReferenceHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson `
            -InputObject $Compilation.parameterReference
    )
    $deploymentName = 'adlt-whatif-{0}-{1}' -f
        $RunId.Replace('-', '').Substring(0, 8).ToLowerInvariant(),
        ([string] $Plan.planHash).Substring(7, 12)
    $scope = '/subscriptions/{0}' -f [string] $Plan.context.subscriptionId
    $temporaryDirectory = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ('adlt-whatif-{0}' -f [guid]::NewGuid().ToString('N'))
    $parameterPath = Join-Path $temporaryDirectory 'parameters.json'

    try {
        [void] (New-AdltPrivateDirectory -Path $temporaryDirectory)
        [void] (Write-AdltPrivateAtomicText `
            -Path $parameterPath `
            -Content $parameterJson)
        Assert-AdltPrivatePathMode -Path $parameterPath -Type File
        $parameterFileHash = Get-AdltFileSha256Identifier `
            -Path $parameterPath
        $invocation = [ordered]@{
            scope                  = $scope
            deploymentName         = $deploymentName
            location               = [string] $Plan.context.location
            validationLevel        = 'Provider'
            resultFormat           = 'ResourceIdOnly'
            templateHash           = [string] $Compilation.templateHash
            executionArtifactDigest =
                [string] $Compilation.executionArtifactDigest
            parameterReferenceHash = $parameterReferenceHash
            parameterFileHash      = $parameterFileHash
        }
        $invocationHash = Get-AdltSha256Identifier -Value (
            ConvertTo-AdltCanonicalJson -InputObject $invocation
        )
        $templateObject = $Compilation.template |
            ConvertTo-Json -Depth 100 -Compress |
            ConvertFrom-Json -AsHashtable -Depth 100
        $result = Invoke-AdltAzCommand `
            -ModuleName 'Az.Resources' `
            -CommandName 'Get-AzDeploymentWhatIfResult' `
            -Parameters @{
                Name                        = $deploymentName
                Location                    = [string] $Plan.context.location
                TemplateObject              = $templateObject
                TemplateParameterFile       = $parameterPath
                ResultFormat                = 'ResourceIdOnly'
                ValidationLevel             = 'Provider'
                SkipTemplateParameterPrompt = $true
                ErrorAction                 = 'Stop'
            }
        $native = ConvertTo-AdltNativeWhatIfResult -Result $result
        Assert-AdltNativeWhatIfChangeSet `
            -NativeResult $native `
            -ExpectedChanges $expectedChanges

        return [ordered]@{
            scope                  = $scope
            deploymentName         = $deploymentName
            validationLevel        = 'Provider'
            resultFormat           = 'ResourceIdOnly'
            executionArtifactDigest =
                [string] $Compilation.executionArtifactDigest
            templateHash           = [string] $Compilation.templateHash
            parameterReferenceHash = $parameterReferenceHash
            parameterFileHash      = $parameterFileHash
            invocationHash         = $invocationHash
            nativeStatus           = [string] $native.status
            nativeChanges          = @($native.changes)
            nativeDiagnostics      = @($native.diagnostics)
            nativePotentialChangeCount =
                [int] $native.potentialChangeCount
            nativeChangesHash      = [string] $native.changesHash
            nativeWhatIfResultHash = [string] $native.resultHash
            nativeFailureKind      = $null
        }
    }
    finally {
        if ([System.IO.File]::Exists($parameterPath)) {
            [System.IO.File]::Delete($parameterPath)
        }
        if ([System.IO.Directory]::Exists($temporaryDirectory)) {
            [System.IO.Directory]::Delete($temporaryDirectory, $false)
        }
    }
}
