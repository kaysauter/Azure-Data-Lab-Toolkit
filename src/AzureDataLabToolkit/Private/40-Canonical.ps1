function ConvertTo-AdltCanonicalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) {
            return 'null'
        }

        if ($InputObject -is [pscustomobject]) {
            $InputObject = ConvertTo-AdltDictionary -InputObject $InputObject
        }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $keys = [string[]] @($InputObject.Keys | ForEach-Object { [string] $_ })
            [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
            $members = [System.Collections.Generic.List[string]]::new()

            foreach ($key in $keys) {
                $options = [System.Text.Json.JsonSerializerOptions]::new()
                $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
                $encodedKey = [System.Text.Json.JsonSerializer]::Serialize($key, $options)
                $encodedValue = ConvertTo-AdltCanonicalJson -InputObject $InputObject[$key]
                $members.Add(('{0}:{1}' -f $encodedKey, $encodedValue))
            }

            return '{{{0}}}' -f ($members -join ',')
        }

        if ($InputObject -is [System.Collections.IList]) {
            $items = [System.Collections.Generic.List[string]]::new()
            foreach ($item in $InputObject) {
                $items.Add((ConvertTo-AdltCanonicalJson -InputObject $item))
            }

            return '[{0}]' -f ($items -join ',')
        }

        if ($InputObject -is [string] -or $InputObject -is [char]) {
            $options = [System.Text.Json.JsonSerializerOptions]::new()
            $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
            return [System.Text.Json.JsonSerializer]::Serialize([string] $InputObject, $options)
        }

        if ($InputObject -is [bool]) {
            return $InputObject.ToString().ToLowerInvariant()
        }

        if (
            $InputObject -is [byte] -or
            $InputObject -is [sbyte] -or
            $InputObject -is [int16] -or
            $InputObject -is [uint16] -or
            $InputObject -is [int32] -or
            $InputObject -is [uint32] -or
            $InputObject -is [int64] -or
            $InputObject -is [uint64]
        ) {
            $integerValue = [decimal] $InputObject
            if (
                $integerValue -lt [decimal] -9007199254740991 -or
                $integerValue -gt [decimal] 9007199254740991
            ) {
                throw 'Integer plan values must stay within the RFC 8785 interoperable range of +/-9007199254740991.'
            }

            return [System.Convert]::ToString($InputObject, [System.Globalization.CultureInfo]::InvariantCulture)
        }

        if ($InputObject -is [decimal] -or $InputObject -is [double] -or $InputObject -is [single]) {
            throw 'Plan values must use integers rather than floating-point numbers.'
        }

        throw "Type '$($InputObject.GetType().FullName)' is not supported by canonical plan serialization."
    }
}

function Get-AdltSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-AdltSha256Identifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    return 'sha256:{0}' -f (Get-AdltSha256 -Value $Value)
}

function Get-AdltDeterministicGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $characters = (Get-AdltSha256 -Value $Value).Substring(0, 32).ToCharArray()
    $characters[12] = '5'
    $variant = [Convert]::ToInt32([string] $characters[16], 16)
    $characters[16] = '89ab'[($variant -band 3)]
    $hex = -join $characters

    return '{0}-{1}-{2}-{3}-{4}' -f
        $hex.Substring(0, 8),
        $hex.Substring(8, 4),
        $hex.Substring(12, 4),
        $hex.Substring(16, 4),
        $hex.Substring(20, 12)
}

function Get-AdltArtifactHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Artifact,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9]*Hash$')]
        [string] $HashProperty
    )

    $hashInput = Copy-AdltValue -InputObject $Artifact
    if ($hashInput.Contains($HashProperty)) {
        $hashInput.Remove($HashProperty)
    }

    return Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $hashInput
    )
}

function Assert-AdltArtifactHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Artifact,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9]*Hash$')]
        [string] $HashProperty,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ArtifactName
    )

    if (-not $Artifact.Contains($HashProperty)) {
        throw "The supplied object is not a hashed $ArtifactName."
    }

    $actualHash = Get-AdltArtifactHash `
        -Artifact $Artifact `
        -HashProperty $HashProperty
    if ($actualHash -cne [string] $Artifact[$HashProperty]) {
        throw "$ArtifactName hash verification failed. The artifact has changed since it was created."
    }
}

function Get-AdltPlanHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    return Get-AdltArtifactHash -Artifact $Plan -HashProperty 'planHash'
}

function Assert-AdltPlanHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    Assert-AdltArtifactHash `
        -Artifact $Plan `
        -HashProperty 'planHash' `
        -ArtifactName 'Azure Data Lab plan'
}
