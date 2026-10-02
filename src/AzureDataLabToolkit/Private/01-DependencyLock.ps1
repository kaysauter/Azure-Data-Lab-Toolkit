$script:AdltRuntimeDependencyLock = $null

function Get-AdltDependencyStringHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return 'sha256:{0}' -f (
        [System.Convert]::ToHexString($hash).ToLowerInvariant()
    )
}

function Get-AdltDependencyFileHash {
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
        $hash = [System.Security.Cryptography.SHA256]::HashData($stream)
    }
    finally {
        $stream.Dispose()
    }
    return 'sha256:{0}' -f (
        [System.Convert]::ToHexString($hash).ToLowerInvariant()
    )
}

function ConvertTo-AdltDependencyManifestJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Entries
    )

    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.Encoder = (
        [System.Text.Encodings.Web.JavaScriptEncoder]::
            UnsafeRelaxedJsonEscaping
    )
    $members = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        $digest = [System.Text.Json.JsonSerializer]::Serialize(
            [string] $entry.digest,
            $options
        )
        $path = [System.Text.Json.JsonSerializer]::Serialize(
            [string] $entry.path,
            $options
        )
        $members.Add(
            ('{{"digest":{0},"path":{1}}}' -f $digest, $path)
        )
    }
    return '[{0}]' -f ($members -join ',')
}

function Get-AdltRuntimeDependencyLock {
    [CmdletBinding()]
    param()

    if ($null -ne $script:AdltRuntimeDependencyLock) {
        return $script:AdltRuntimeDependencyLock
    }

    $path = Join-Path `
        $script:AzureDataLabToolkitRoot `
        'Support/runtime-dependencies.lock.json'
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (
        $item.PSIsContainer -or
        $item.Length -gt 64KB -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'Runtime dependency lock is missing, linked, or oversized.'
    }
    $lock = Read-AdltJsonFile -Path $path
    $requiredTopLevel = @(
        'contentDigestAlgorithm'
        'dependencies'
        'kind'
        'schemaVersion'
    )
    $actualTopLevel = @(
        $lock.Keys |
            ForEach-Object { [string] $_ } |
            Sort-Object
    )
    if (
        ($actualTopLevel -join "`n") -cne
            (($requiredTopLevel | Sort-Object) -join "`n") -or
        [string] $lock.schemaVersion -cne '1.0' -or
        [string] $lock.kind -cne 'AzureDataLabRuntimeDependencyLock' -or
        [string] $lock.contentDigestAlgorithm -cne
            'sha256-rfc8785-file-manifest-v1' -or
        $lock.dependencies -isnot [System.Collections.IList] -or
        @($lock.dependencies).Count -lt 1 -or
        @($lock.dependencies).Count -gt 32
    ) {
        throw 'Runtime dependency lock has an invalid top-level contract.'
    }

    $requiredDependencyProperties = @(
        'author'
        'contentDigest'
        'fileCount'
        'guid'
        'name'
        'packageDigest'
        'packageUri'
        'source'
        'version'
    )
    $names = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $previousName = $null
    foreach ($dependency in @($lock.dependencies)) {
        if ($dependency -isnot [System.Collections.IDictionary]) {
            throw 'Runtime dependency lock contains a non-object entry.'
        }
        $actualProperties = @(
            $dependency.Keys |
                ForEach-Object { [string] $_ } |
                Sort-Object
        )
        $name = [string] $dependency.name
        if (
            ($actualProperties -join "`n") -cne
                (($requiredDependencyProperties | Sort-Object) -join "`n") -or
            $name -cnotmatch '^[A-Za-z][A-Za-z0-9.-]{0,127}$' -or
            [string] $dependency.version -cnotmatch
                '^\d+\.\d+\.\d+(?:\.\d+)?$' -or
            [string] $dependency.guid -cnotmatch
                '^[0-9a-fA-F-]{36}$' -or
            [string]::IsNullOrWhiteSpace([string] $dependency.author) -or
            [string] $dependency.source -cne 'PSGallery' -or
            [string] $dependency.packageUri -cne (
                'https://www.powershellgallery.com/api/v2/package/{0}/{1}' -f
                    $name,
                    [string] $dependency.version
            ) -or
            [string] $dependency.packageDigest -cnotmatch
                '^sha256:[a-f0-9]{64}$' -or
            [string] $dependency.contentDigest -cnotmatch
                '^sha256:[a-f0-9]{64}$' -or
            [int] $dependency.fileCount -lt 1 -or
            [int] $dependency.fileCount -gt 20000 -or
            -not $names.Add($name) -or
            (
                $null -ne $previousName -and
                [System.StringComparer]::Ordinal.Compare(
                    $previousName,
                    $name
                ) -ge 0
            )
        ) {
            throw "Runtime dependency lock entry '$name' is invalid."
        }
        $previousName = $name
    }

    $script:AdltRuntimeDependencyLock = $lock
    return $script:AdltRuntimeDependencyLock
}

function Get-AdltLockedRuntimeDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $lockMatches = @(
        (Get-AdltRuntimeDependencyLock).dependencies |
            Where-Object { [string] $_.name -ceq $Name }
    )
    if ($lockMatches.Count -ne 1) {
        throw "Runtime dependency '$Name' is not uniquely locked."
    }
    return $lockMatches[0]
}

function Get-AdltRuntimeDependencyContentIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $Module,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $LockEntry
    )

    $root = [System.IO.Path]::GetFullPath($Module.ModuleBase)
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (
        -not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "Runtime dependency '$($LockEntry.name)' has a linked module root."
    }
    $reparsePoints = @(
        Get-ChildItem -LiteralPath $root -Force -Recurse |
            Where-Object {
                ($_.Attributes -band
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0
            }
    )
    if ($reparsePoints.Count -gt 0) {
        throw "Runtime dependency '$($LockEntry.name)' contains a reparse point."
    }

    $files = @(
        Get-ChildItem -LiteralPath $root -File -Force -Recurse |
            Where-Object {
                [System.IO.Path]::GetRelativePath(
                    $root,
                    $_.FullName
                ).Replace(
                    [System.IO.Path]::DirectorySeparatorChar,
                    [char] '/'
                ) -cne 'PSGetModuleInfo.xml'
            }
    )
    if (
        $files.Count -ne [int] $LockEntry.fileCount -or
        $files.Count -gt 20000 -or
        [int64] (
            $files |
                Measure-Object -Property Length -Sum
        ).Sum -gt 2GB
    ) {
        throw "Runtime dependency '$($LockEntry.name)' file set is invalid."
    }

    $caseInsensitivePaths =
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $relativePath = [System.IO.Path]::GetRelativePath(
            $root,
            $file.FullName
        ).Replace(
            [System.IO.Path]::DirectorySeparatorChar,
            [char] '/'
        )
        if (
            $relativePath -match '(^|/)\.\.?(/|$)' -or
            $relativePath -match '[\u0000-\u001f\u007f]' -or
            -not $caseInsensitivePaths.Add($relativePath)
        ) {
            throw "Runtime dependency '$($LockEntry.name)' has an unsafe file path."
        }
        $entries.Add(
            [ordered]@{
                path   = $relativePath
                digest = Get-AdltDependencyFileHash -Path $file.FullName
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
    $contentDigest = Get-AdltDependencyStringHash -Value (
        ConvertTo-AdltDependencyManifestJson `
            -Entries @($entries.ToArray())
    )
    if ($contentDigest -cne [string] $LockEntry.contentDigest) {
        throw (
            "Runtime dependency '$($LockEntry.name)' does not match its " +
            'reviewed package content digest.'
        )
    }
    return [ordered]@{
        contentDigest = $contentDigest
        fileCount     = $files.Count
    }
}

function Get-AdltVerifiedRuntimeDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $lockEntry = Get-AdltLockedRuntimeDependency -Name $Name
    $specification = @{
        ModuleName      = [string] $lockEntry.name
        RequiredVersion = [string] $lockEntry.version
        Guid            = [guid] $lockEntry.guid
    }
    $candidates = @(
        Get-Module `
            -ListAvailable `
            -FullyQualifiedName $specification |
            Where-Object {
                [string] $_.Name -ceq [string] $lockEntry.name -and
                [string] $_.Version -ceq [string] $lockEntry.version -and
                [string] $_.Guid -ceq [string] $lockEntry.guid
            }
    )
    if ($candidates.Count -ne 1) {
        throw (
            "Runtime dependency '$Name' must resolve to exactly one locked " +
            'module manifest.'
        )
    }
    $module = $candidates[0]
    if ([string] $module.Author -cne [string] $lockEntry.author) {
        throw "Runtime dependency '$Name' has an unexpected author."
    }
    $manifestPath = [System.IO.Path]::GetFullPath($module.Path)
    $manifestItem = Get-Item `
        -LiteralPath $manifestPath `
        -Force `
        -ErrorAction Stop
    if (
        $manifestItem.PSIsContainer -or
        ($manifestItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "Runtime dependency '$Name' has a linked module manifest."
    }
    $content = Get-AdltRuntimeDependencyContentIdentity `
        -Module $module `
        -LockEntry $lockEntry
    $normalizedPath = $manifestPath.Replace(
        [System.IO.Path]::DirectorySeparatorChar,
        [char] '/'
    )
    return [ordered]@{
        name            = [string] $lockEntry.name
        version         = [string] $lockEntry.version
        guid            = ([string] $lockEntry.guid).ToLowerInvariant()
        author          = [string] $lockEntry.author
        source          = [string] $lockEntry.source
        packageDigest   = [string] $lockEntry.packageDigest
        contentDigest   = [string] $content.contentDigest
        manifestPathHash = Get-AdltDependencyStringHash -Value $normalizedPath
        manifestPath    = $manifestPath
        moduleBase      = [System.IO.Path]::GetFullPath($module.ModuleBase)
    }
}

function Import-AdltVerifiedRuntimeDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    $identity = Get-AdltVerifiedRuntimeDependency -Name $Name
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    foreach ($loadedModule in @(Get-Module -Name $identity.name)) {
        if (
            -not [string]::Equals(
                [System.IO.Path]::GetFullPath($loadedModule.ModuleBase),
                $identity.moduleBase,
                $comparison
            ) -or
            [string] $loadedModule.Version -cne $identity.version -or
            ([string] $loadedModule.Guid).ToLowerInvariant() -cne
                $identity.guid
        ) {
            throw (
                "A conflicting '$($identity.name)' module is already loaded " +
                'from an unapproved identity.'
            )
        }
    }

    Microsoft.PowerShell.Core\Import-Module `
        -Name $identity.manifestPath `
        -ErrorAction Stop
    $loaded = @(
        Get-Module -Name $identity.name |
            Where-Object {
                [string]::Equals(
                    [System.IO.Path]::GetFullPath($_.ModuleBase),
                    $identity.moduleBase,
                    $comparison
                ) -and
                [string] $_.Version -ceq $identity.version -and
                ([string] $_.Guid).ToLowerInvariant() -ceq $identity.guid
            }
    )
    if ($loaded.Count -ne 1) {
        throw "Runtime dependency '$Name' did not load from its locked manifest."
    }
    return [pscustomobject]@{
        Module   = $loaded[0]
        Identity = $identity
    }
}

[void] (Import-AdltVerifiedRuntimeDependency -Name 'powershell-yaml')
