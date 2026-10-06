[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Build', 'Clean', 'Package', 'Test', 'All')]
    [string] $Task = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = $PSScriptRoot
$sourceModulePath = Join-Path $repositoryRoot 'src/AzureDataLabToolkit'
$moduleManifestPath = Join-Path $sourceModulePath 'AzureDataLabToolkit.psd1'
$outputPath = Join-Path $repositoryRoot 'out'
$testResultsPath = Join-Path $outputPath 'test-results'
$builtModulePath = Join-Path $outputPath 'module/AzureDataLabToolkit/0.1.0'
$packagePath = Join-Path $outputPath 'packages/AzureDataLabToolkit-0.1.0-alpha1.zip'
$analyzerSettingsPath = Join-Path $repositoryRoot 'PSScriptAnalyzerSettings.psd1'
$buildToolLockPath = Join-Path `
    $sourceModulePath `
    'Support/build-tools.lock.json'
$minimumCoveragePercent = 80
$buildProvenanceFileName = 'build-provenance.json'
$requiredBuildModules = [ordered]@{
    Pester              = '5.7.1'
    PSScriptAnalyzer    = '1.25.0'
}
$script:AdltStagedBuildToolIdentities = @{}

function ConvertTo-AdltBuildCanonicalJson {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) {
            return 'null'
        }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $keys = [string[]] @(
                $InputObject.Keys |
                    ForEach-Object { [string] $_ }
            )
            [System.Array]::Sort(
                $keys,
                [System.StringComparer]::Ordinal
            )
            $members = [System.Collections.Generic.List[string]]::new()
            foreach ($key in $keys) {
                $options = [System.Text.Json.JsonSerializerOptions]::new()
                $options.Encoder = (
                    [System.Text.Encodings.Web.JavaScriptEncoder]::
                        UnsafeRelaxedJsonEscaping
                )
                $encodedKey = (
                    [System.Text.Json.JsonSerializer]::Serialize(
                        $key,
                        $options
                    )
                )
                $encodedValue = ConvertTo-AdltBuildCanonicalJson `
                    -InputObject $InputObject[$key]
                $members.Add(('{0}:{1}' -f $encodedKey, $encodedValue))
            }
            return '{{{0}}}' -f ($members -join ',')
        }

        if ($InputObject -is [System.Collections.IList]) {
            $items = [System.Collections.Generic.List[string]]::new()
            foreach ($item in $InputObject) {
                $items.Add(
                    (ConvertTo-AdltBuildCanonicalJson -InputObject $item)
                )
            }
            return '[{0}]' -f ($items -join ',')
        }

        if ($InputObject -is [string] -or $InputObject -is [char]) {
            $options = [System.Text.Json.JsonSerializerOptions]::new()
            $options.Encoder = (
                [System.Text.Encodings.Web.JavaScriptEncoder]::
                    UnsafeRelaxedJsonEscaping
            )
            return [System.Text.Json.JsonSerializer]::Serialize(
                [string] $InputObject,
                $options
            )
        }

        throw (
            "Build canonicalization does not support type " +
            "'$($InputObject.GetType().FullName)'."
        )
    }
}

function Get-AdltBuildSha256Identifier {
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

function Get-AdltBuildFileSha256Identifier {
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

function Get-AdltBuildFileManifest {
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath
    )

    $provenancePath = Join-Path $ModulePath $buildProvenanceFileName
    $entries = [System.Collections.Generic.List[object]]::new()
    Get-ChildItem `
        -LiteralPath $ModulePath `
        -File `
        -Force `
        -Recurse |
        Where-Object { $_.FullName -cne $provenancePath } |
        ForEach-Object {
            $entries.Add(
                [ordered]@{
                    path = [System.IO.Path]::GetRelativePath(
                        $ModulePath,
                        $_.FullName
                    ).Replace(
                        [System.IO.Path]::DirectorySeparatorChar,
                        [char] '/'
                    )
                    digest = Get-AdltBuildFileSha256Identifier `
                        -Path $_.FullName
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

function Invoke-AdltBuildGit {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryPath,

        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $gitCommand = Get-Command `
        -Name git `
        -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $gitCommand) {
        return [ordered]@{
            exitCode = 127
            output   = @()
        }
    }

    $output = @(
        & $gitCommand.Source `
            -C $RepositoryPath `
            @Arguments 2>$null
    )
    return [ordered]@{
        exitCode = $LASTEXITCODE
        output   = @($output)
    }
}

function Get-AdltBuildSourceRevision {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $AggregateDigest,

        [Parameter()]
        [string] $RepositoryPath = $repositoryRoot,

        [Parameter()]
        [scriptblock] $GitInvoker = ${function:Invoke-AdltBuildGit}
    )

    $contentDerived = [ordered]@{
        revision = $AggregateDigest.Substring('sha256:'.Length)
        kind     = 'content-derived'
    }
    $gitMetadataPath = Join-Path $RepositoryPath '.git'
    if (-not (Test-Path -LiteralPath $gitMetadataPath)) {
        return $contentDerived
    }

    try {
        $topLevelResult = & $GitInvoker `
            -RepositoryPath $RepositoryPath `
            -Arguments @('rev-parse', '--show-toplevel')
        $revisionResult = & $GitInvoker `
            -RepositoryPath $RepositoryPath `
            -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
        $statusResult = & $GitInvoker `
            -RepositoryPath $RepositoryPath `
            -Arguments @(
                'status',
                '--porcelain=v1',
                '--untracked-files=all',
                '--ignore-submodules=none'
            )
        $ignoredPackageInputResult = & $GitInvoker `
            -RepositoryPath $RepositoryPath `
            -Arguments @(
                'ls-files',
                '--others',
                '--ignored',
                '--exclude-standard',
                '--',
                'src/AzureDataLabToolkit'
            )
        $confirmedRevisionResult = & $GitInvoker `
            -RepositoryPath $RepositoryPath `
            -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
        $topLevel = @($topLevelResult.output)
        $revision = @($revisionResult.output)
        $status = @($statusResult.output)
        $ignoredPackageInputs = @($ignoredPackageInputResult.output)
        $confirmedRevision = @($confirmedRevisionResult.output)
        if (
            [int] $topLevelResult.exitCode -eq 0 -and
            [int] $revisionResult.exitCode -eq 0 -and
            [int] $statusResult.exitCode -eq 0 -and
            [int] $ignoredPackageInputResult.exitCode -eq 0 -and
            [int] $confirmedRevisionResult.exitCode -eq 0 -and
            $topLevel.Count -eq 1 -and
            $revision.Count -eq 1 -and
            $status.Count -eq 0 -and
            $ignoredPackageInputs.Count -eq 0 -and
            $confirmedRevision.Count -eq 1 -and
            [System.IO.Path]::GetFullPath([string] $topLevel[0]) -ceq
                [System.IO.Path]::GetFullPath($RepositoryPath) -and
            [string] $revision[0] -cmatch
                '^(?:[a-f0-9]{40}|[a-f0-9]{64})$' -and
            [string] $confirmedRevision[0] -ceq [string] $revision[0]
        ) {
            return [ordered]@{
                revision = [string] $revision[0]
                kind     = 'git'
            }
        }
    }
    catch {
        return $contentDerived
    }

    return $contentDerived
}

function New-AdltBuildProvenance {
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath,

        [Parameter()]
        [string] $RepositoryPath = $repositoryRoot,

        [Parameter()]
        [scriptblock] $GitInvoker = ${function:Invoke-AdltBuildGit}
    )

    $manifestPath = Join-Path $ModulePath 'AzureDataLabToolkit.psd1'
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $moduleVersion = [string] $manifest.ModuleVersion
    $prerelease = [string] $manifest.PrivateData.PSData.Prerelease
    if (-not [string]::IsNullOrWhiteSpace($prerelease)) {
        $moduleVersion = '{0}-{1}' -f $moduleVersion, $prerelease
    }

    $files = @(Get-AdltBuildFileManifest -ModulePath $ModulePath)
    $aggregateDigest = Get-AdltBuildSha256Identifier -Value (
        ConvertTo-AdltBuildCanonicalJson -InputObject $files
    )
    $source = Get-AdltBuildSourceRevision `
        -AggregateDigest $aggregateDigest `
        -RepositoryPath $RepositoryPath `
        -GitInvoker $GitInvoker
    $provenance = [ordered]@{
        schemaVersion      = '1.0'
        canonicalization   = 'rfc8785'
        sourceRevision     = $source.revision
        sourceRevisionKind = $source.kind
        moduleVersion      = $moduleVersion
        files              = $files
        aggregateDigest    = $aggregateDigest
    }
    $provenance.selfHash = Get-AdltBuildSha256Identifier -Value (
        ConvertTo-AdltBuildCanonicalJson -InputObject $provenance
    )

    $provenancePath = Join-Path $ModulePath $buildProvenanceFileName
    [System.IO.File]::WriteAllText(
        $provenancePath,
        (ConvertTo-AdltBuildCanonicalJson -InputObject $provenance),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Test-AdltBuildProvenance {
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath,

        [Parameter()]
        [ValidatePattern('^(?:[a-f0-9]{40}|[a-f0-9]{64})$')]
        [string] $ExpectedSourceRevision,

        [Parameter()]
        [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
        [string] $ExpectedModuleVersion,

        [switch] $RequireGit
    )

    $fullModulePath = [System.IO.Path]::GetFullPath($ModulePath)
    $provenancePath = Join-Path `
        $fullModulePath `
        $buildProvenanceFileName
    $provenanceItem = Get-Item `
        -LiteralPath $provenancePath `
        -Force `
        -ErrorAction Stop
    if (
        $provenanceItem.PSIsContainer -or
        $provenanceItem.Length -lt 1 -or
        $provenanceItem.Length -gt 16MB -or
        ($provenanceItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'Build provenance is missing, linked, empty, or oversized.'
    }

    $provenance = [System.IO.File]::ReadAllText($provenancePath) |
        ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate
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
        $provenance.Keys |
            ForEach-Object { [string] $_ } |
            Sort-Object
    )
    if (
        ($actualProperties -join "`n") -cne
            (($requiredProperties | Sort-Object) -join "`n") -or
        [string] $provenance.schemaVersion -cne '1.0' -or
        [string] $provenance.canonicalization -cne 'rfc8785' -or
        [string] $provenance.aggregateDigest -cnotmatch
            '^sha256:[a-f0-9]{64}$' -or
        [string] $provenance.selfHash -cnotmatch
            '^sha256:[a-f0-9]{64}$' -or
        [string] $provenance.moduleVersion -cnotmatch
            '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$' -or
        [string] $provenance.sourceRevisionKind -cnotin @(
            'content-derived'
            'git'
        ) -or
        $provenance.files -isnot [System.Collections.IList]
    ) {
        throw 'Build provenance contract is invalid.'
    }

    $sourceRevision = [string] $provenance.sourceRevision
    if (
        (
            [string] $provenance.sourceRevisionKind -ceq 'git' -and
            $sourceRevision -cnotmatch
                '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'
        ) -or
        (
            [string] $provenance.sourceRevisionKind -ceq
                'content-derived' -and
            $sourceRevision -cnotmatch '^[a-f0-9]{64}$'
        ) -or
        (
            $RequireGit.IsPresent -and
            [string] $provenance.sourceRevisionKind -cne 'git'
        ) -or
        (
            $PSBoundParameters.ContainsKey('ExpectedSourceRevision') -and
            $sourceRevision -cne $ExpectedSourceRevision
        ) -or
        (
            $PSBoundParameters.ContainsKey('ExpectedModuleVersion') -and
            [string] $provenance.moduleVersion -cne
                $ExpectedModuleVersion
        )
    ) {
        throw 'Build provenance source or version binding is invalid.'
    }

    $recordedFiles = @($provenance.files)
    if ($recordedFiles.Count -lt 1 -or $recordedFiles.Count -gt 20000) {
        throw 'Build provenance file manifest is invalid.'
    }
    $previousPath = $null
    foreach ($entry in $recordedFiles) {
        if ($entry -isnot [System.Collections.IDictionary]) {
            throw 'Build provenance file manifest is invalid.'
        }
        $entryProperties = @(
            $entry.Keys |
                ForEach-Object { [string] $_ } |
                Sort-Object
        )
        $path = [string] $entry.path
        if (
            ($entryProperties -join "`n") -cne "digest`npath" -or
            [string] $entry.digest -cnotmatch
                '^sha256:[a-f0-9]{64}$' -or
            [string]::IsNullOrWhiteSpace($path) -or
            [System.IO.Path]::IsPathRooted($path) -or
            $path -match '(^|/)\.\.?(/|$)' -or
            $path -match '[\u0000-\u001f\u007f]' -or
            (
                $null -ne $previousPath -and
                [System.StringComparer]::Ordinal.Compare(
                    $previousPath,
                    $path
                ) -ge 0
            )
        ) {
            throw 'Build provenance file manifest is invalid.'
        }
        $previousPath = $path
    }

    $actualFiles = @(Get-AdltBuildFileManifest -ModulePath $fullModulePath)
    $recordedFilesJson = ConvertTo-AdltBuildCanonicalJson `
        -InputObject $recordedFiles
    $actualFilesJson = ConvertTo-AdltBuildCanonicalJson `
        -InputObject $actualFiles
    $actualAggregateDigest = Get-AdltBuildSha256Identifier `
        -Value $actualFilesJson
    if (
        $recordedFilesJson -cne $actualFilesJson -or
        [string] $provenance.aggregateDigest -cne $actualAggregateDigest
    ) {
        throw 'Build provenance does not match the complete module content.'
    }

    $unsignedProvenance = [ordered]@{
        schemaVersion      = [string] $provenance.schemaVersion
        canonicalization   = [string] $provenance.canonicalization
        sourceRevision     = $sourceRevision
        sourceRevisionKind = [string] $provenance.sourceRevisionKind
        moduleVersion      = [string] $provenance.moduleVersion
        files              = $recordedFiles
        aggregateDigest    = [string] $provenance.aggregateDigest
    }
    $actualSelfHash = Get-AdltBuildSha256Identifier -Value (
        ConvertTo-AdltBuildCanonicalJson -InputObject $unsignedProvenance
    )
    if ([string] $provenance.selfHash -cne $actualSelfHash) {
        throw 'Build provenance self hash is invalid.'
    }

    $manifestPath = Join-Path `
        $fullModulePath `
        'AzureDataLabToolkit.psd1'
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $manifestVersion = [string] $manifest.ModuleVersion
    $manifestPrerelease = [string] $manifest.PrivateData.PSData.Prerelease
    if (-not [string]::IsNullOrWhiteSpace($manifestPrerelease)) {
        $manifestVersion = '{0}-{1}' -f
            $manifestVersion,
            $manifestPrerelease
    }
    if ($manifestVersion -cne [string] $provenance.moduleVersion) {
        throw 'Build provenance does not match the packaged manifest version.'
    }

    return [ordered]@{
        sourceRevision     = $sourceRevision
        sourceRevisionKind = [string] $provenance.sourceRevisionKind
        moduleVersion      = [string] $provenance.moduleVersion
        aggregateDigest    = $actualAggregateDigest
        selfHash           = $actualSelfHash
        fileCount          = $actualFiles.Count
    }
}

function Set-AdltBuiltModuleProvenanceRequirement {
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath
    )

    $runtimeIdentityPath = Join-Path `
        $ModulePath `
        'Private/67-RuntimeIdentity.ps1'
    $developmentMarker = (
        '$script:AzureDataLabToolkitBuildProvenanceRequired = $false'
    )
    $packageMarker = (
        '$script:AzureDataLabToolkitBuildProvenanceRequired = $true'
    )
    $content = [System.IO.File]::ReadAllText($runtimeIdentityPath)
    $firstMarker = $content.IndexOf(
        $developmentMarker,
        [System.StringComparison]::Ordinal
    )
    $lastMarker = $content.LastIndexOf(
        $developmentMarker,
        [System.StringComparison]::Ordinal
    )
    if ($firstMarker -lt 0 -or $firstMarker -ne $lastMarker) {
        throw (
            'The runtime provenance requirement marker is missing or ' +
            'ambiguous.'
        )
    }

    $content = $content.Replace(
        $developmentMarker,
        $packageMarker,
        [System.StringComparison]::Ordinal
    )
    [System.IO.File]::WriteAllText(
        $runtimeIdentityPath,
        $content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Update-AdltBuiltModuleScriptLock {
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath
    )

    $lockPath = Join-Path `
        $ModulePath `
        'Support/module-scripts.lock.json'
    $lock = [System.IO.File]::ReadAllText($lockPath) |
        ConvertFrom-Json -AsHashtable -Depth 8 -NoEnumerate
    if (
        $lock.kind -cne 'AzureDataLabModuleScriptLock' -or
        @($lock.files).Count -eq 0
    ) {
        throw 'The built module script lock contract is invalid.'
    }
    foreach ($entry in @($lock.files)) {
        $scriptPath = Join-Path `
            $ModulePath `
            ([string] $entry.path)
        if (-not [System.IO.File]::Exists($scriptPath)) {
            throw "Built module script '$($entry.path)' is missing."
        }
        $entry.sha256 = (
            Get-FileHash `
                -LiteralPath $scriptPath `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
    [System.IO.File]::WriteAllText(
        $lockPath,
        ($lock | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )
    $lockHash = (
        Get-FileHash `
            -LiteralPath $lockPath `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $modulePath = Join-Path `
        $ModulePath `
        'AzureDataLabToolkit.psm1'
    $content = [System.IO.File]::ReadAllText($modulePath)
    $pattern = (
        "(?m)(\`$script:AzureDataLabToolkitScriptLockHash\s*=\s*" +
        "\r?\n\s*'sha256:)[a-f0-9]{64}(')"
    )
    $markerMatches = [regex]::Matches($content, $pattern)
    if ($markerMatches.Count -ne 1) {
        throw 'The built module script-lock hash marker is ambiguous.'
    }
    $content = [regex]::Replace(
        $content,
        $pattern,
        ('${1}' + $lockHash + '${2}')
    )
    [System.IO.File]::WriteAllText(
        $modulePath,
        $content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-AdltBuildToolLock {
    param(
        [Parameter()]
        [string] $Path = $buildToolLockPath
    )

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Build-tool lock '$Path' is missing."
    }
    $lock = [System.IO.File]::ReadAllText($Path) |
        ConvertFrom-Json -AsHashtable -Depth 10 -NoEnumerate
    $requiredLockProperties = @(
        'buildTools'
        'contentDigestAlgorithm'
        'kind'
        'schemaVersion'
    )
    $actualLockProperties = @(
        $lock.Keys |
            ForEach-Object { [string] $_ } |
            Sort-Object
    )
    if (
        ($actualLockProperties -join "`n") -cne
            (($requiredLockProperties | Sort-Object) -join "`n") -or
        [string] $lock.schemaVersion -cne '1.0' -or
        [string] $lock.kind -cne 'AzureDataLabBuildToolLock' -or
        [string] $lock.contentDigestAlgorithm -cne
            'sha256-rfc8785-file-manifest-v1'
    ) {
        throw 'Build-tool lock contract is invalid.'
    }

    $requiredEntryProperties = @(
        'author'
        'contentDigest'
        'fileCount'
        'guid'
        'name'
        'packageUri'
        'source'
        'totalSizeBytes'
        'version'
    )
    $entries = @($lock.buildTools)
    $expectedNames = @($requiredBuildModules.Keys)
    if ($entries.Count -ne $expectedNames.Count) {
        throw 'Build-tool lock does not contain the expected modules.'
    }

    $actualNames = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        $actualProperties = @(
            $entry.Keys |
                ForEach-Object { [string] $_ } |
                Sort-Object
        )
        $name = [string] $entry.name
        $validGuid = [guid]::Empty
        $validFileCount = 0
        $validTotalSize = [int64] 0
        $guidParsed = [guid]::TryParse(
            [string] $entry.guid,
            [ref] $validGuid
        )
        $fileCountParsed = [int]::TryParse(
            [string] $entry.fileCount,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref] $validFileCount
        )
        $totalSizeParsed = [int64]::TryParse(
            [string] $entry.totalSizeBytes,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref] $validTotalSize
        )
        $expectedPackageUri = (
            'https://www.powershellgallery.com/api/v2/package/{0}/{1}' -f
                $name,
                [string] $entry.version
        )
        if (
            ($actualProperties -join "`n") -cne
                (($requiredEntryProperties | Sort-Object) -join "`n") -or
            $name -cnotmatch '^[A-Za-z][A-Za-z0-9.-]{0,127}$' -or
            [string] $entry.version -cnotmatch
                '^\d+\.\d+\.\d+(?:\.\d+)?$' -or
            -not $guidParsed -or
            $validGuid -eq [guid]::Empty -or
            [string]::IsNullOrWhiteSpace([string] $entry.author) -or
            [string] $entry.source -cne 'PSGallery' -or
            [string] $entry.packageUri -cne $expectedPackageUri -or
            [string] $entry.contentDigest -cnotmatch
                '^sha256:[a-f0-9]{64}$' -or
            -not $fileCountParsed -or
            $validFileCount -lt 1 -or
            $validFileCount -gt 20000 -or
            -not $totalSizeParsed -or
            $validTotalSize -lt 1 -or
            $validTotalSize -gt 2GB
        ) {
            throw "Build-tool lock entry '$name' is invalid."
        }
        $actualNames.Add($name)
    }
    if (
        ($actualNames.ToArray() -join "`n") -cne
            ($expectedNames -join "`n")
    ) {
        throw 'Build-tool lock does not contain the expected modules.'
    }
    return $lock
}

function Get-AdltBuildToolContentIdentity {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $Module,

        [Parameter()]
        [ValidateRange(1, 20000)]
        [int] $MaximumFileCount = 20000,

        [Parameter()]
        [ValidateRange(1, 2GB)]
        [int64] $MaximumTotalSizeBytes = 2GB
    )

    $root = [System.IO.Path]::GetFullPath($Module.ModuleBase)
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (
        -not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "Build tool '$($Module.Name)' has a linked module root."
    }

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $pendingDirectories =
        [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($root)
    $itemCount = 0
    $totalSize = [int64] 0
    while ($pendingDirectories.Count -gt 0) {
        $directoryPath = $pendingDirectories.Pop()
        foreach (
            $itemPath in
                [System.IO.Directory]::EnumerateFileSystemEntries(
                    $directoryPath
                )
        ) {
            $itemCount++
            if ($itemCount -gt 25000) {
                throw (
                    "Build tool '$($Module.Name)' has an excessive item " +
                    'count.'
                )
            }
            $item = Get-Item `
                -LiteralPath $itemPath `
                -Force `
                -ErrorAction Stop
            if (
                ($item.Attributes -band
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0
            ) {
                throw (
                    "Build tool '$($Module.Name)' contains a reparse point."
                )
            }
            if ($item -is [System.IO.DirectoryInfo]) {
                $pendingDirectories.Push($item.FullName)
                continue
            }
            if ($item -isnot [System.IO.FileInfo]) {
                throw (
                    "Build tool '$($Module.Name)' contains a non-file item."
                )
            }
            $relativePath = [System.IO.Path]::GetRelativePath(
                $root,
                $item.FullName
            ).Replace(
                [System.IO.Path]::DirectorySeparatorChar,
                [char] '/'
            )
            if ($relativePath -ceq 'PSGetModuleInfo.xml') {
                continue
            }
            if (
                $item.Length -lt 1 -or
                $files.Count -ge $MaximumFileCount -or
                $totalSize -gt
                    ($MaximumTotalSizeBytes - [int64] $item.Length)
            ) {
                throw (
                    "Build tool '$($Module.Name)' has an excessive or " +
                    'non-regular file set.'
                )
            }
            $totalSize += [int64] $item.Length
            $files.Add($item)
        }
    }
    if (
        $files.Count -lt 1 -or
        $files.Count -gt $MaximumFileCount -or
        $totalSize -lt 1 -or
        $totalSize -gt $MaximumTotalSizeBytes
    ) {
        throw "Build tool '$($Module.Name)' has an excessive file set."
    }

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $caseInsensitivePaths =
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
        $relativePath = [System.IO.Path]::GetRelativePath(
            $root,
            $fullPath
        ).Replace(
            [System.IO.Path]::DirectorySeparatorChar,
            [char] '/'
        )
        if (
            -not $fullPath.StartsWith($rootPrefix, $comparison) -or
            [System.IO.Path]::IsPathRooted($relativePath) -or
            $relativePath -match '(^|/)\.\.?(/|$)' -or
            $relativePath -match '[\u0000-\u001f\u007f]' -or
            -not $caseInsensitivePaths.Add($relativePath)
        ) {
            throw "Build tool '$($Module.Name)' has an unsafe file path."
        }
        $lengthBeforeHash = [int64] $file.Length
        $digest = Get-AdltBuildFileSha256Identifier -Path $fullPath
        $lengthAfterHash = [int64] (
            Get-Item `
                -LiteralPath $fullPath `
                -Force `
                -ErrorAction Stop
        ).Length
        if ($lengthAfterHash -ne $lengthBeforeHash) {
            throw "Build tool '$($Module.Name)' changed while it was hashed."
        }
        $entries.Add(
            [ordered]@{
                path   = $relativePath
                digest = $digest
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
    return [ordered]@{
        contentDigest = Get-AdltBuildSha256Identifier -Value (
            ConvertTo-AdltBuildCanonicalJson `
                -InputObject @($entries.ToArray())
        )
        fileCount     = $files.Count
        totalSizeBytes = $totalSize
    }
}

function Get-AdltVerifiedBuildTool {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter()]
        [System.Management.Automation.PSModuleInfo[]] $Candidates
    )

    $lock = Get-AdltBuildToolLock
    $lockEntries = @(
        $lock.buildTools |
            Where-Object { [string] $_.name -ceq $Name }
    )
    if ($lockEntries.Count -ne 1) {
        throw "Build tool '$Name' is not uniquely locked."
    }
    $entry = $lockEntries[0]
    if (-not $PSBoundParameters.ContainsKey('Candidates')) {
        $specification = @{
            ModuleName      = [string] $entry.name
            RequiredVersion = [string] $entry.version
            Guid            = [guid] $entry.guid
        }
        $Candidates = @(
            Get-Module `
                -ListAvailable `
                -FullyQualifiedName $specification
        )
    }
    $exactCandidates = @(
        $Candidates |
            Where-Object {
                [string] $_.Name -ceq [string] $entry.name -and
                [string] $_.Version -ceq [string] $entry.version -and
                ([string] $_.Guid).ToLowerInvariant() -ceq
                    ([string] $entry.guid).ToLowerInvariant()
            }
    )
    if ($exactCandidates.Count -ne 1) {
        throw (
            "Build tool '$Name' must resolve to exactly one locked " +
            'module manifest.'
        )
    }

    $module = $exactCandidates[0]
    if ([string] $module.Author -cne [string] $entry.author) {
        throw "Build tool '$Name' has an unexpected author."
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
        throw "Build tool '$Name' has a linked module manifest."
    }
    $content = Get-AdltBuildToolContentIdentity `
        -Module $module `
        -MaximumFileCount ([int] $entry.fileCount) `
        -MaximumTotalSizeBytes ([int64] $entry.totalSizeBytes)
    if (
        [string] $content.contentDigest -cne
            [string] $entry.contentDigest -or
        [int] $content.fileCount -ne [int] $entry.fileCount -or
        [int64] $content.totalSizeBytes -ne
            [int64] $entry.totalSizeBytes
    ) {
        throw (
            "Build tool '$Name' does not match its reviewed complete " +
            'content identity.'
        )
    }
    return [ordered]@{
        name         = [string] $entry.name
        version      = [string] $entry.version
        guid         = ([string] $entry.guid).ToLowerInvariant()
        author       = [string] $entry.author
        contentDigest = [string] $content.contentDigest
        fileCount    = [int] $content.fileCount
        totalSizeBytes = [int64] $content.totalSizeBytes
        manifestPath = $manifestPath
        manifestRelativePath = [System.IO.Path]::GetRelativePath(
            [System.IO.Path]::GetFullPath($module.ModuleBase),
            $manifestPath
        )
        moduleBase   = [System.IO.Path]::GetFullPath($module.ModuleBase)
    }
}

function Copy-AdltVerifiedBuildTool {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Identity
    )

    $stagingParent = Join-Path $outputPath 'verified-build-tools'
    [void] (New-Item `
        -ItemType Directory `
        -Path $stagingParent `
        -Force)
    $stagingRoot = Join-Path `
        $stagingParent `
        ([System.IO.Path]::GetRandomFileName())
    [void] (New-Item -ItemType Directory -Path $stagingRoot)

    foreach (
        $sourceItem in
            Get-ChildItem `
                -LiteralPath ([string] $Identity.moduleBase) `
                -Force `
                -ErrorAction Stop
    ) {
        Copy-Item `
            -LiteralPath $sourceItem.FullName `
            -Destination $stagingRoot `
            -Recurse `
            -Force
    }

    if (-not $IsWindows) {
        foreach (
            $directory in
                @(
                    Get-Item -LiteralPath $stagingRoot -Force
                    Get-ChildItem `
                        -LiteralPath $stagingRoot `
                        -Directory `
                        -Force `
                        -Recurse
                )
        ) {
            [System.IO.File]::SetUnixFileMode(
                $directory.FullName,
                (
                    [System.IO.UnixFileMode]::UserRead -bor
                    [System.IO.UnixFileMode]::UserWrite -bor
                    [System.IO.UnixFileMode]::UserExecute
                )
            )
        }
        foreach (
            $file in
                Get-ChildItem `
                    -LiteralPath $stagingRoot `
                    -File `
                    -Force `
                    -Recurse
        ) {
            [System.IO.File]::SetUnixFileMode(
                $file.FullName,
                (
                    [System.IO.UnixFileMode]::UserRead -bor
                    [System.IO.UnixFileMode]::UserWrite
                )
            )
        }
    }

    $stagedManifestPath = Join-Path `
        $stagingRoot `
        ([string] $Identity.manifestRelativePath)
    $stagedModule = Test-ModuleManifest `
        -Path $stagedManifestPath `
        -ErrorAction Stop
    if (
        [string] $stagedModule.Name -cne [string] $Identity.name -or
        [string] $stagedModule.Version -cne [string] $Identity.version -or
        ([string] $stagedModule.Guid).ToLowerInvariant() -cne
            [string] $Identity.guid -or
        [string] $stagedModule.Author -cne [string] $Identity.author
    ) {
        throw "Staged build tool '$($Identity.name)' metadata is invalid."
    }
    $stagedContent = Get-AdltBuildToolContentIdentity `
        -Module $stagedModule `
        -MaximumFileCount ([int] $Identity.fileCount) `
        -MaximumTotalSizeBytes ([int64] $Identity.totalSizeBytes)
    if (
        [string] $stagedContent.contentDigest -cne
            [string] $Identity.contentDigest -or
        [int] $stagedContent.fileCount -ne [int] $Identity.fileCount -or
        [int64] $stagedContent.totalSizeBytes -ne
            [int64] $Identity.totalSizeBytes
    ) {
        throw (
            "Staged build tool '$($Identity.name)' does not match its " +
            'reviewed complete content identity.'
        )
    }
    return [ordered]@{
        name         = [string] $Identity.name
        version      = [string] $Identity.version
        guid         = [string] $Identity.guid
        author       = [string] $Identity.author
        manifestPath = [System.IO.Path]::GetFullPath($stagedManifestPath)
        moduleBase   = [System.IO.Path]::GetFullPath($stagingRoot)
    }
}

function Import-AdltBuildModule {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $sourceIdentity = Get-AdltVerifiedBuildTool -Name $Name
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    foreach ($loadedModule in @(Get-Module -Name $Name)) {
        $loadedBase = [System.IO.Path]::GetFullPath(
            $loadedModule.ModuleBase
        )
        $approvedLoadedBases =
            [System.Collections.Generic.List[string]]::new()
        $approvedLoadedBases.Add([string] $sourceIdentity.moduleBase)
        if ($script:AdltStagedBuildToolIdentities.ContainsKey($Name)) {
            $approvedLoadedBases.Add(
                [string] (
                    $script:AdltStagedBuildToolIdentities[$Name]
                ).moduleBase
            )
        }
        $approvedPath = @(
            $approvedLoadedBases |
                Where-Object {
                    [string]::Equals(
                        $_,
                        $loadedBase,
                        $comparison
                    )
                }
        ).Count -eq 1
        if (
            -not $approvedPath -or
            [string] $loadedModule.Version -cne
                $sourceIdentity.version -or
            ([string] $loadedModule.Guid).ToLowerInvariant() -cne
                $sourceIdentity.guid
        ) {
            throw (
                "A conflicting build tool '$Name' is already loaded from " +
                'an unapproved identity.'
            )
        }
    }
    Remove-Module -Name $Name -Force -ErrorAction SilentlyContinue
    $identity = Copy-AdltVerifiedBuildTool -Identity $sourceIdentity
    Import-Module `
        -Name $identity.manifestPath `
        -Force `
        -ErrorAction Stop
    $loaded = @(
        Get-Module -Name $Name |
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
        throw "Build tool '$Name' did not load from its locked manifest."
    }
    $script:AdltStagedBuildToolIdentities[$Name] = $identity
}

function Invoke-AdltClean {
    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Recurse -Force
    }
}

function Test-AdltParser {
    $parseFailures = [System.Collections.Generic.List[string]]::new()
    $sourceFiles = Get-ChildItem `
        -LiteralPath $repositoryRoot `
        -Include '*.ps1', '*.psm1', '*.psd1' `
        -File `
        -Recurse |
        Where-Object { $_.FullName -notlike "$outputPath*" }

    foreach ($sourceFile in $sourceFiles) {
        $tokens = $null
        $parseErrors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseFile(
            $sourceFile.FullName,
            [ref] $tokens,
            [ref] $parseErrors
        )

        foreach ($parseError in @($parseErrors)) {
            $parseFailures.Add(
                '{0}:{1}: {2}' -f
                    $sourceFile.FullName,
                    $parseError.Extent.StartLineNumber,
                    $parseError.Message
            )
        }
    }

    if ($parseFailures.Count -gt 0) {
        throw "PowerShell parser failures:`n$($parseFailures -join [Environment]::NewLine)"
    }
}

function Invoke-AdltAnalyze {
    Import-AdltBuildModule -Name PSScriptAnalyzer
    Test-AdltParser

    $analysisResults = @(
        Invoke-ScriptAnalyzer `
            -Path $sourceModulePath `
            -Recurse `
            -Settings $analyzerSettingsPath
    )
    if ($analysisResults.Count -gt 0) {
        $messages = $analysisResults | ForEach-Object {
            '{0}:{1} [{2}] {3}' -f $_.ScriptPath, $_.Line, $_.RuleName, $_.Message
        }
        throw "PSScriptAnalyzer findings:`n$($messages -join [Environment]::NewLine)"
    }

    Test-ModuleManifest -Path $moduleManifestPath -ErrorAction Stop | Out-Null

    foreach ($jsonFile in Get-ChildItem -LiteralPath $sourceModulePath -Filter '*.json' -File -Recurse) {
        [void] ([System.IO.File]::ReadAllText($jsonFile.FullName) | ConvertFrom-Json -Depth 100)
    }
}

function Invoke-AdltTest {
    Import-AdltBuildModule -Name Pester
    New-Item -ItemType Directory -Path $testResultsPath -Force | Out-Null

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $repositoryRoot 'tests/Unit'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Detailed'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = Join-Path $testResultsPath 'pester.xml'
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.CoveragePercentTarget = $minimumCoveragePercent
    $configuration.CodeCoverage.Path = @(
        Join-Path $sourceModulePath '*.psm1'
        Join-Path $sourceModulePath '**/*.ps1'
    )
    $configuration.CodeCoverage.OutputFormat = 'JaCoCo'
    $configuration.CodeCoverage.OutputPath = Join-Path $testResultsPath 'coverage.xml'

    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Pester test(s) failed."
    }
    if ($result.CodeCoverage.CoveragePercent -lt $minimumCoveragePercent) {
        throw (
            'Command coverage {0:N2}% is below the required {1:N2}%.' -f
                $result.CodeCoverage.CoveragePercent,
                $minimumCoveragePercent
        )
    }
}

function Invoke-AdltBuild {
    if (Test-Path -LiteralPath $builtModulePath) {
        Remove-Item -LiteralPath $builtModulePath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $builtModulePath -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceModulePath '*') -Destination $builtModulePath -Recurse -Force
    Set-AdltBuiltModuleProvenanceRequirement `
        -ModulePath $builtModulePath
    Update-AdltBuiltModuleScriptLock `
        -ModulePath $builtModulePath

    $builtManifest = Join-Path $builtModulePath 'AzureDataLabToolkit.psd1'
    $builtProvenance = Join-Path `
        $builtModulePath `
        $buildProvenanceFileName
    if (Test-Path -LiteralPath $builtProvenance) {
        Remove-Item -LiteralPath $builtProvenance -Force
    }
    New-AdltBuildProvenance -ModulePath $builtModulePath
    [void] (Test-AdltBuildProvenance -ModulePath $builtModulePath)

    Test-ModuleManifest -Path $builtManifest -ErrorAction Stop |
        Out-Null
    $manifestData = Import-PowerShellDataFile -LiteralPath $builtManifest
    $expectedCommands = @(
        $manifestData.FunctionsToExport |
            Sort-Object -Unique
    )

    Remove-Module AzureDataLabToolkit -ErrorAction SilentlyContinue
    Import-Module $builtManifest -Force -ErrorAction Stop
    try {
        $commands = @(
            Get-Command `
                -Module AzureDataLabToolkit `
                -CommandType Function |
                Select-Object -ExpandProperty Name |
                Sort-Object -Unique
        )
        $difference = @(
            Compare-Object `
                -ReferenceObject $expectedCommands `
                -DifferenceObject $commands `
                -CaseSensitive
        )
        if ($difference.Count -gt 0) {
            throw (
                'Built module exports do not match FunctionsToExport in ' +
                'the built manifest.'
            )
        }
    }
    finally {
        Remove-Module AzureDataLabToolkit -ErrorAction SilentlyContinue
    }
}

function Invoke-AdltPackage {
    Invoke-AdltBuild
    $packageDirectory = Split-Path -Path $packagePath -Parent
    New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null

    if (Test-Path -LiteralPath $packagePath) {
        Remove-Item -LiteralPath $packagePath -Force
    }

    Compress-Archive `
        -Path (Join-Path $outputPath 'module/AzureDataLabToolkit') `
        -DestinationPath $packagePath `
        -CompressionLevel Optimal
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

switch ($Task) {
    'Clean' {
        Invoke-AdltClean
    }
    'Analyze' {
        Invoke-AdltAnalyze
    }
    'Test' {
        Invoke-AdltTest
    }
    'Build' {
        Invoke-AdltBuild
    }
    'Package' {
        Invoke-AdltPackage
    }
    'All' {
        Invoke-AdltClean
        Invoke-AdltAnalyze
        Invoke-AdltTest
        Invoke-AdltPackage
    }
}
