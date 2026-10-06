function Get-AdltAzureResourceRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource,

        [Parameter(Mandatory)]
        [string] $ResourceId
    )

    try {
        $observed = if ($Resource.type -eq 'Microsoft.Resources/resourceGroups') {
            Invoke-AdltAzCommand `
                -ModuleName 'Az.Resources' `
                -CommandName 'Get-AzResourceGroup' `
                -Parameters @{
                    Name        = [string] $Resource.logicalName
                    ErrorAction = 'Stop'
                }
        }
        else {
            Invoke-AdltAzCommand `
                -ModuleName 'Az.Resources' `
                -CommandName 'Get-AzResource' `
                -Parameters @{
                    ResourceId      = $ResourceId
                    ApiVersion      = [string] $Resource.apiVersion
                    ExpandProperties = $true
                    ErrorAction     = 'Stop'
                }
        }

        if ($null -eq $observed) {
            return [ordered]@{
                status      = 'unknown'
                failureKind = 'empty-response'
                observed    = $null
            }
        }
        return [ordered]@{
            status      = 'present'
            failureKind = $null
            observed    = $observed
        }
    }
    catch {
        $failureKind = Get-AdltAzureFailureKind -ErrorRecord $_
        return [ordered]@{
            status      = if ($failureKind -eq 'absent') { 'absent' } else { $failureKind }
            failureKind = $failureKind
            observed    = $null
        }
    }
}

function ConvertTo-AdltTagDictionary {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Tags
    )

    if ($null -eq $Tags) {
        return @{}
    }

    $dictionary = @{}
    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($key in $Tags.Keys) {
            $dictionary[[string] $key] = [string] $Tags[$key]
        }
    }
    else {
        foreach ($property in $Tags.PSObject.Properties) {
            $dictionary[[string] $property.Name] = [string] $property.Value
        }
    }
    return $dictionary
}

function Get-AdltObservedTagSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Observed
    )

    if ($Observed.PSObject.Properties.Name -contains 'Tags') {
        return ConvertTo-AdltTagDictionary -Tags $Observed.Tags
    }
    if ($Observed.PSObject.Properties.Name -contains 'ResourceGroupName') {
        return @{}
    }
    return @{}
}

function Get-AdltWhatIfClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Resource,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ReadResult,

        [Parameter(Mandatory)]
        [string] $RunId
    )

    if ($ReadResult.status -eq 'denied') {
        return 'denied'
    }
    if ($ReadResult.status -notin @('present', 'absent')) {
        return 'unverified'
    }

    $plannedOwnership = [string] $Resource.ownership.expectedClassification
    if ($ReadResult.status -eq 'absent') {
        if ($plannedOwnership -eq 'owned') {
            return 'create'
        }
        return 'conflict'
    }
    if ($plannedOwnership -in @('reused', 'external')) {
        return 'reuse'
    }

    $tags = Get-AdltObservedTagSet -Observed $ReadResult.observed
    $requiredTags = @{
        'adlt-run-id'       = $RunId
        'adlt-stable-id'    = [string] $Resource.id
        'adlt-ownership'    = 'owned'
    }
    foreach ($key in $requiredTags.Keys) {
        if (
            -not $tags.ContainsKey($key) -or
            $tags[$key] -cne $requiredTags[$key]
        ) {
            return 'conflict'
        }
    }

    $desiredHash = Get-AdltDesiredResourceHash -Resource $Resource
    if (
        $tags.ContainsKey('adlt-desired-hash') -and
        $tags['adlt-desired-hash'] -ceq $desiredHash
    ) {
        return 'no-change'
    }

    return 'update'
}

function Get-AdltWhatIfStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Classifications
    )

    if ('conflict' -in $Classifications) {
        return 'fail'
    }
    if ('denied' -in $Classifications) {
        return 'denied'
    }
    if ('unverified' -in $Classifications) {
        return 'unverified'
    }
    if ('update' -in $Classifications) {
        return 'warning'
    }
    return 'pass'
}
