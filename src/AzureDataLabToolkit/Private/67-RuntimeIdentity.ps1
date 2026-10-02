$script:AzureDataLabToolkitBuildProvenanceRequired = $false

function Get-AdltFileSha256Identifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash($stream)
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    return 'sha256:{0}' -f (
        [System.Convert]::ToHexString($bytes).ToLowerInvariant()
    )
}

function Get-AdltRuntimeFileManifest {
    [CmdletBinding()]
    param()

    $provenanceFileName = 'build-provenance.json'
    $reparsePoints = @(
        Get-ChildItem `
            -LiteralPath $script:AzureDataLabToolkitRoot `
            -Force `
            -Recurse |
            Where-Object {
                ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) `
                    -ne 0
            }
    )
    if ($reparsePoints.Count -gt 0) {
        throw 'Runtime module verification does not permit reparse points.'
    }

    $provenancePath = Join-Path `
        $script:AzureDataLabToolkitRoot `
        $provenanceFileName
    $entries = [System.Collections.Generic.List[object]]::new()
    Get-ChildItem `
        -LiteralPath $script:AzureDataLabToolkitRoot `
        -File `
        -Force `
        -Recurse |
        Where-Object { $_.FullName -cne $provenancePath } |
        ForEach-Object {
            $entries.Add(
                [ordered]@{
                    path = [System.IO.Path]::GetRelativePath(
                        $script:AzureDataLabToolkitRoot,
                        $_.FullName
                    ).Replace(
                        [System.IO.Path]::DirectorySeparatorChar,
                        [char] '/'
                    )
                    digest = Get-AdltFileSha256Identifier -Path $_.FullName
                }
            )
        }
    $entries.Sort(
        [System.Comparison[object]] {
            param($Left, $Right)

            return [System.StringComparer]::Ordinal.Compare(
                [string] $Left.path,
                [string] $Right.path
            )
        }
    )
    return @($entries.ToArray())
}

function Assert-AdltBuildProvenanceShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance
    )

    $requiredProperties = @(
        'aggregateDigest'
        'canonicalization'
        'files'
        'moduleVersion'
        'schemaVersion'
        'selfHash'
        'sourceRevision'
        'sourceRevisionKind'
    )
    $actualProperties = @(
        $Provenance.Keys |
            ForEach-Object { [string] $_ } |
            Sort-Object
    )
    if (
        (ConvertTo-AdltCanonicalJson -InputObject $actualProperties) -cne
            (ConvertTo-AdltCanonicalJson -InputObject $requiredProperties)
    ) {
        throw 'Build provenance has an invalid property set.'
    }
    if (
        [string] $Provenance.schemaVersion -cne '1.0' -or
        [string] $Provenance.canonicalization -cne 'rfc8785' -or
        [string] $Provenance.moduleVersion -cne
            $script:AzureDataLabToolkitVersion -or
        [string] $Provenance.aggregateDigest -cnotmatch
            '^sha256:[a-f0-9]{64}$' -or
        [string] $Provenance.selfHash -cnotmatch
            '^sha256:[a-f0-9]{64}$'
    ) {
        throw 'Build provenance metadata is invalid.'
    }
    if (
        [string] $Provenance.sourceRevisionKind -cnotin @(
            'git',
            'content-derived'
        )
    ) {
        throw 'Build provenance source revision kind is invalid.'
    }
    if (
        [string] $Provenance.sourceRevisionKind -ceq 'git' -and
        [string] $Provenance.sourceRevision -cnotmatch
            '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'
    ) {
        throw 'Build provenance Git revision is invalid.'
    }
    if (
        [string] $Provenance.sourceRevisionKind -ceq 'content-derived' -and
        (
            [string] $Provenance.sourceRevision -cnotmatch
                '^[a-f0-9]{64}$' -or
            [string] $Provenance.sourceRevision -cne
                ([string] $Provenance.aggregateDigest).Substring(
                    'sha256:'.Length
                )
        )
    ) {
        throw 'Build provenance content-derived revision is invalid.'
    }
    if (
        $Provenance.files -isnot [System.Collections.IList] -or
        @($Provenance.files).Count -eq 0
    ) {
        throw 'Build provenance file manifest is empty or invalid.'
    }

    $previousPath = $null
    $pathSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in @($Provenance.files)) {
        if ($entry -is [pscustomobject]) {
            $entry = ConvertTo-AdltDictionary -InputObject $entry
        }
        if ($entry -isnot [System.Collections.IDictionary]) {
            throw 'Build provenance contains an invalid file entry.'
        }
        $entryProperties = @(
            $entry.Keys |
                ForEach-Object { [string] $_ } |
                Sort-Object
        )
        if (
            (ConvertTo-AdltCanonicalJson -InputObject $entryProperties) -cne
                '["digest","path"]' -or
            [string] $entry.path -cnotmatch '^[^/\\]+(?:/[^/\\]+)*$' -or
            @([string] $entry.path -split '/') -contains '..' -or
            @([string] $entry.path -split '/') -contains '.' -or
            [string] $entry.path -ceq 'build-provenance.json' -or
            [string] $entry.digest -cnotmatch '^sha256:[a-f0-9]{64}$'
        ) {
            throw 'Build provenance contains an invalid file entry.'
        }
        if (
            $null -ne $previousPath -and
            [System.StringComparer]::Ordinal.Compare(
                $previousPath,
                [string] $entry.path
            ) -ge 0
        ) {
            throw 'Build provenance file paths are not uniquely sorted.'
        }
        if (-not $pathSet.Add([string] $entry.path)) {
            throw 'Build provenance contains duplicate file paths.'
        }
        $previousPath = [string] $entry.path
    }
}

function Get-AdltVerifiedRuntimeModuleContent {
    [CmdletBinding()]
    param()

    $provenancePath = Join-Path `
        $script:AzureDataLabToolkitRoot `
        'build-provenance.json'
    $actualFiles = @(Get-AdltRuntimeFileManifest)
    $aggregateDigest = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $actualFiles
    )
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
        if ($script:AzureDataLabToolkitBuildProvenanceRequired) {
            throw 'The packaged module build provenance is missing.'
        }
        return [ordered]@{
            module = [ordered]@{
                name         = 'AzureDataLabToolkit'
                version      = $script:AzureDataLabToolkitVersion
                digest       = $aggregateDigest
                revisionKind = 'content-derived'
            }
            sourceRevision = $aggregateDigest.Substring('sha256:'.Length)
        }
    }

    $provenanceFile = Get-Item -LiteralPath $provenancePath -Force
    if ($provenanceFile.Length -gt 2MB) {
        throw 'Build provenance exceeds the verification size limit.'
    }
    try {
        $provenance = [System.IO.File]::ReadAllText($provenancePath) |
            ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    }
    catch {
        throw 'Build provenance is not valid JSON.'
    }
    Assert-AdltBuildProvenanceShape -Provenance $provenance

    $hashInput = Copy-AdltValue -InputObject $provenance
    [void] $hashInput.Remove('selfHash')
    $expectedSelfHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $hashInput
    )
    if ([string] $provenance.selfHash -cne $expectedSelfHash) {
        throw 'Build provenance self-hash verification failed.'
    }

    $expectedAggregateDigest = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject @($provenance.files)
    )
    if (
        [string] $provenance.aggregateDigest -cne
            $expectedAggregateDigest
    ) {
        throw 'Build provenance aggregate digest verification failed.'
    }
    if (
        (ConvertTo-AdltCanonicalJson -InputObject @($provenance.files)) -cne
            (ConvertTo-AdltCanonicalJson -InputObject $actualFiles)
    ) {
        throw (
            'Runtime module files do not match the verified build ' +
            'provenance manifest.'
        )
    }

    return [ordered]@{
        module = [ordered]@{
            name         = 'AzureDataLabToolkit'
            version      = $script:AzureDataLabToolkitVersion
            digest       = [string] $provenance.aggregateDigest
            revisionKind = [string] $provenance.sourceRevisionKind
        }
        sourceRevision = [string] $provenance.sourceRevision
    }
}

function Get-AdltRuntimeModuleIdentity {
    [CmdletBinding()]
    param()

    return (Get-AdltVerifiedRuntimeModuleContent).module
}

function Get-AdltRuntimeDependencySet {
    [CmdletBinding()]
    param()

    return @(
        foreach ($lockEntry in @(
            (Get-AdltRuntimeDependencyLock).dependencies
        )) {
            $identity = Get-AdltVerifiedRuntimeDependency `
                -Name ([string] $lockEntry.name)
            [ordered]@{
                name             = [string] $identity.name
                version          = [string] $identity.version
                guid             = [string] $identity.guid
                author           = [string] $identity.author
                source           = [string] $identity.source
                packageDigest    = [string] $identity.packageDigest
                contentDigest    = [string] $identity.contentDigest
                manifestPathHash = [string] $identity.manifestPathHash
            }
        }
    )
}

function Get-AdltRuntimeIdentity {
    [CmdletBinding()]
    param()

    $verifiedContent = Get-AdltVerifiedRuntimeModuleContent
    return [ordered]@{
        module       = $verifiedContent.module
        commit       = $verifiedContent.sourceRevision
        powershell   = [ordered]@{
            version = [string] $PSVersionTable.PSVersion
            edition = [string] $PSVersionTable.PSEdition
        }
        dependencies = @(Get-AdltRuntimeDependencySet)
    }
}

function Assert-AdltRuntimeAuthorizationBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Authorization
    )

    $runtime = Get-AdltRuntimeIdentity
    if (
        (ConvertTo-AdltCanonicalJson -InputObject $Authorization.module) -cne
            (ConvertTo-AdltCanonicalJson -InputObject $runtime.module) -or
        [string] $Authorization.commit -cne [string] $runtime.commit -or
        (ConvertTo-AdltCanonicalJson -InputObject $Authorization.runtime) -cne
            (ConvertTo-AdltCanonicalJson -InputObject ([ordered]@{
                powershell   = $runtime.powershell
                dependencies = $runtime.dependencies
            }))
    ) {
        throw 'Execution authorization runtime identity does not match the executing module.'
    }
}
