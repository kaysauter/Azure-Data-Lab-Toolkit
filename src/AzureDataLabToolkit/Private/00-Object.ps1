function ConvertTo-AdltDictionary {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) {
            return $null
        }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $result[[string] $key] = ConvertTo-AdltDictionary -InputObject $InputObject[$key]
            }

            return $result
        }

        if (
            $InputObject -is [System.Collections.IList] -and
            $InputObject -isnot [string]
        ) {
            $items = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $InputObject) {
                $items.Add((ConvertTo-AdltDictionary -InputObject $item))
            }

            return , $items.ToArray()
        }

        if (
            $InputObject -is [string] -or
            $InputObject -is [char] -or
            $InputObject -is [bool] -or
            $InputObject.GetType().IsPrimitive -or
            $InputObject -is [decimal] -or
            $InputObject -is [datetime] -or
            $InputObject -is [datetimeoffset] -or
            $InputObject -is [guid]
        ) {
            return $InputObject
        }

        if ($InputObject -is [pscustomobject]) {
            $result = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-AdltDictionary -InputObject $property.Value
            }

            return $result
        }

        return $InputObject
    }
}

function Copy-AdltValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    return ConvertTo-AdltDictionary -InputObject $InputObject
}

function Get-AdltLeafEntry {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [string] $Path = ''
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $childPath = if ([string]::IsNullOrEmpty($Path)) {
                [string] $key
            }
            else {
                '{0}.{1}' -f $Path, $key
            }

            Get-AdltLeafEntry -InputObject $InputObject[$key] -Path $childPath
        }

        return
    }

    [pscustomobject]@{
        Path  = $Path
        Value = $InputObject
    }
}

function Merge-AdltDictionary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Target,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Source
    )

    foreach ($key in $Source.Keys) {
        $sourceValue = $Source[$key]
        $targetContainsKey = $Target.Contains($key)

        if (
            $sourceValue -is [System.Collections.IDictionary] -and
            $targetContainsKey -and
            $Target[$key] -is [System.Collections.IDictionary]
        ) {
            Merge-AdltDictionary -Target $Target[$key] -Source $sourceValue
            continue
        }

        $Target[$key] = Copy-AdltValue -InputObject $sourceValue
    }
}

function Set-AdltPathValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [AllowNull()]
        [object] $Value
    )

    $segments = $Path.Split('.')
    $cursor = $Target

    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $segment = $segments[$index]
        if (-not $cursor.Contains($segment)) {
            $cursor[$segment] = [ordered]@{}
        }

        if ($cursor[$segment] -isnot [System.Collections.IDictionary]) {
            throw "Cannot set '$Path' because '$segment' is not an object."
        }

        $cursor = $cursor[$segment]
    }

    $cursor[$segments[-1]] = Copy-AdltValue -InputObject $Value
}

function Get-AdltPathValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $cursor = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($cursor -isnot [System.Collections.IDictionary] -or -not $cursor.Contains($segment)) {
            return $null
        }

        $cursor = $cursor[$segment]
    }

    return $cursor
}

function Get-AdltObjectPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals(
                [string] $key,
                $Name,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                return $InputObject[$key]
            }
        }
        return $null
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ([string]::Equals(
            [string] $property.Name,
            $Name,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $property.Value
        }
    }
    return $null
}

function Get-AdltObjectPathValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $cursor = $InputObject
    foreach ($segment in $Path.Split('.')) {
        $cursor = Get-AdltObjectPropertyValue `
            -InputObject $cursor `
            -Name $segment
        if ($null -eq $cursor) {
            return $null
        }
    }
    return $cursor
}

function Add-AdltProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Source,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SourceName
    )

    foreach ($entry in Get-AdltLeafEntry -InputObject $Source) {
        if (-not [string]::IsNullOrWhiteSpace($entry.Path)) {
            $Provenance[$entry.Path] = [ordered]@{
                source     = $SourceName
                derivation = 'direct'
            }
        }
    }
}

function Get-AdltValueType {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [System.Collections.IDictionary]) {
        return 'object'
    }
    if ($Value -is [System.Collections.IList]) {
        return 'array'
    }
    if ($Value -is [bool]) {
        return 'boolean'
    }
    if (
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    ) {
        return 'integer'
    }
    if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        return 'number'
    }

    return 'string'
}

function Complete-AdltProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    foreach ($entry in Get-AdltLeafEntry -InputObject $Configuration) {
        if (-not $Provenance.Contains($entry.Path)) {
            $Provenance[$entry.Path] = [ordered]@{
                source     = 'unknown'
                derivation = 'unresolved'
            }
        }

        $Provenance[$entry.Path].value = Copy-AdltValue -InputObject $entry.Value
        $Provenance[$entry.Path].type = Get-AdltValueType -Value $entry.Value
        $Provenance[$entry.Path].validation = 'schema-valid'
    }
}

function Set-AdltDerivedValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance,

        [Parameter(Mandatory)]
        [string] $Path,

        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Rule
    )

    Set-AdltPathValue -Target $Configuration -Path $Path -Value $Value
    $Provenance[$Path] = [ordered]@{
        source     = 'derived'
        derivation = $Rule
    }
}

function ConvertTo-AdltSlug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [ValidateRange(1, 80)]
        [int] $MaximumLength = 40
    )

    $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $slug = $slug -replace '-+', '-'
    $slug = $slug.Trim('-')

    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw 'The supplied value cannot be converted to a resource-name slug.'
    }

    if ($slug.Length -gt $MaximumLength) {
        $slug = $slug.Substring(0, $MaximumLength).TrimEnd('-')
    }

    return $slug
}

function Get-AdltDataPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ChildPath
    )

    return Join-Path -Path $script:AzureDataLabToolkitRoot -ChildPath $ChildPath
}

function Read-AdltJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (
        $item.PSIsContainer -or
        $item.Length -gt $script:AzureDataLabToolkitMaximumJsonBytes -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "JSON file '$Path' is linked, oversized, or not a regular file."
    }
    $content = [System.IO.File]::ReadAllText($item.FullName)
    return ConvertTo-AdltDictionary -InputObject (
        $content |
            ConvertFrom-Json `
                -Depth 100 `
                -DateKind String `
                -ErrorAction Stop
    )
}
