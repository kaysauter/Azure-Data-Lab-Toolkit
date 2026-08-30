Set-StrictMode -Version Latest

$script:AzureDataLabToolkitRoot = $PSScriptRoot
$script:AzureDataLabToolkitVersion = '0.1.0-alpha1'
$script:AzureDataLabToolkitSchemaVersion = '1.0'
$script:AzureDataLabToolkitMaximumYamlBytes = 1MB
$script:AzureDataLabToolkitMaximumJsonBytes = 16MB
$script:AzureDataLabToolkitMaximumEventLogBytes = 64MB
$script:AzureDataLabToolkitMaximumEventCount = 10000
$script:AzureDataLabToolkitMaximumEventLineChars = 2MB
$script:AzureDataLabToolkitMaximumEvidenceFiles = 1024
$script:AzureDataLabToolkitMaximumArtifactFiles = 16
$script:AzureDataLabToolkitScriptLockHash =
    'sha256:616f6ff914d36ba868f933f4e7d1e0a544663d6792332ac80dd6a0e6d7b141d4'
$script:AzureDataLabToolkitDependencyLockHash =
    'sha256:004a1cabd0f708547f9d3d839332f73798c43e45d06c19c3a1b7af9f83de7221'

$writeMask =
    [System.IO.UnixFileMode]::GroupWrite -bor
    [System.IO.UnixFileMode]::OtherWrite
$supportPath = [System.IO.Path]::Combine($PSScriptRoot, 'Support')
$scriptLockPath = [System.IO.Path]::Combine(
    $supportPath,
    'module-scripts.lock.json'
)
$dependencyLockPath = [System.IO.Path]::Combine(
    $supportPath,
    'runtime-dependencies.lock.json'
)
$supportItem = [System.IO.DirectoryInfo]::new($supportPath)
$scriptLockItem = [System.IO.FileInfo]::new($scriptLockPath)
$dependencyLockItem = [System.IO.FileInfo]::new($dependencyLockPath)
if (
    -not $supportItem.Exists -or
    ($supportItem.Attributes -band
        [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
    -not $scriptLockItem.Exists -or
    $scriptLockItem.Length -gt 256KB -or
    ($scriptLockItem.Attributes -band
        [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
    -not $dependencyLockItem.Exists -or
    $dependencyLockItem.Length -gt 256KB -or
    ($dependencyLockItem.Attributes -band
        [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
    (
        -not $IsWindows -and
        (
            (
                [System.IO.File]::GetUnixFileMode(
                    $supportItem.FullName
                ) -band $writeMask
            ) -ne 0 -or
            (
                [System.IO.File]::GetUnixFileMode(
                    $scriptLockItem.FullName
                ) -band $writeMask
            ) -ne 0 -or
            (
                [System.IO.File]::GetUnixFileMode(
                    $dependencyLockItem.FullName
                ) -band $writeMask
            ) -ne 0
        )
    )
) {
    throw (
        'The module trust locks are missing, linked, oversized, or ' +
        'writable by another user.'
    )
}
$scriptLockBytes = [System.IO.File]::ReadAllBytes(
    $scriptLockItem.FullName
)
$actualScriptLockHash = 'sha256:{0}' -f (
    [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            $scriptLockBytes
        )
    ).ToLowerInvariant()
)
if (
    $actualScriptLockHash -cne
        $script:AzureDataLabToolkitScriptLockHash
) {
    throw 'The module script lock digest is invalid.'
}
$dependencyLockBytes = [System.IO.File]::ReadAllBytes(
    $dependencyLockItem.FullName
)
$actualDependencyLockHash = 'sha256:{0}' -f (
    [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            $dependencyLockBytes
        )
    ).ToLowerInvariant()
)
if (
    $actualDependencyLockHash -cne
        $script:AzureDataLabToolkitDependencyLockHash
) {
    throw 'The runtime dependency lock digest is invalid.'
}
$scriptLockText = [System.Text.UTF8Encoding]::new(
    $false,
    $true
).GetString($scriptLockBytes)
$scriptLock = $scriptLockText |
    Microsoft.PowerShell.Utility\ConvertFrom-Json `
        -AsHashtable `
        -Depth 8 `
        -NoEnumerate
if (
    $scriptLock -isnot [System.Collections.IDictionary] -or
    $scriptLock.Count -ne 3 -or
    -not $scriptLock.Contains('schemaVersion') -or
    -not $scriptLock.Contains('kind') -or
    -not $scriptLock.Contains('files') -or
    $scriptLock.schemaVersion -cne '1.0' -or
    $scriptLock.kind -cne 'AzureDataLabModuleScriptLock' -or
    $scriptLock.files -isnot [System.Collections.IList]
) {
    throw 'The module script lock contract is invalid.'
}

$moduleRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$comparison = if ($IsWindows) {
    [System.StringComparison]::OrdinalIgnoreCase
}
else {
    [System.StringComparison]::Ordinal
}
$pathComparer = if ($IsWindows) {
    [System.StringComparer]::OrdinalIgnoreCase
}
else {
    [System.StringComparer]::Ordinal
}
$actualRelativePaths =
    [System.Collections.Generic.HashSet[string]]::new(
        $pathComparer
    )
foreach ($folder in @(
    'Private'
    'Providers'
    'Capabilities'
    'SolutionPacks'
    'Public'
)) {
    $folderPath = [System.IO.Path]::Combine($moduleRoot, $folder)
    if (-not [System.IO.Directory]::Exists($folderPath)) {
        throw "Module script folder '$folder' is missing."
    }
    foreach ($directoryPath in @(
        $folderPath
        [System.IO.Directory]::EnumerateDirectories(
            $folderPath,
            '*',
            [System.IO.SearchOption]::AllDirectories
        )
    )) {
        $directoryItem = [System.IO.DirectoryInfo]::new(
            [string] $directoryPath
        )
        if (
            ($directoryItem.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (
                -not $IsWindows -and
                (
                    [System.IO.File]::GetUnixFileMode(
                        $directoryItem.FullName
                    ) -band $writeMask
                ) -ne 0
            )
        ) {
            throw "Module script directory '$folder' is linked or writable by another user."
        }
    }
    foreach ($filePath in [System.IO.Directory]::EnumerateFiles(
        $folderPath,
        '*.ps1',
        [System.IO.SearchOption]::AllDirectories
    )) {
        $relativePath = [System.IO.Path]::GetRelativePath(
            $moduleRoot,
            $filePath
        ).Replace(
            [System.IO.Path]::DirectorySeparatorChar,
            '/'
        )
        if (-not $actualRelativePaths.Add($relativePath)) {
            throw "Module script '$relativePath' was enumerated twice."
        }
    }
}

$verifiedScripts =
    [System.Collections.Generic.List[object]]::new()
$lockedRelativePaths =
    [System.Collections.Generic.HashSet[string]]::new(
        $pathComparer
    )
foreach ($entry in @($scriptLock.files)) {
    if (
        $entry -isnot [System.Collections.IDictionary] -or
        $entry.Count -ne 2 -or
        -not $entry.Contains('path') -or
        -not $entry.Contains('sha256') -or
        [string] $entry.path -cnotmatch
            '^(Private|Providers|Capabilities|SolutionPacks|Public)/[A-Za-z0-9._/-]+\.ps1$' -or
        [string] $entry.path -match '(^|/)\.\.?(/|$)' -or
        [string] $entry.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        -not $lockedRelativePaths.Add([string] $entry.path)
    ) {
        throw 'The module script lock contains an invalid entry.'
    }
    $fullPath = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine(
            $moduleRoot,
            ([string] $entry.path).Replace(
                '/',
                [System.IO.Path]::DirectorySeparatorChar
            )
        )
    )
    if (
        -not $fullPath.StartsWith(
            "$moduleRoot$([System.IO.Path]::DirectorySeparatorChar)",
            $comparison
        )
    ) {
        throw 'A locked module script escapes the module root.'
    }
    $fileItem = [System.IO.FileInfo]::new($fullPath)
    if (
        -not $fileItem.Exists -or
        ($fileItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (
            -not $IsWindows -and
            (
                [System.IO.File]::GetUnixFileMode($fileItem.FullName) -band
                    $writeMask
            ) -ne 0
        )
    ) {
        throw "Locked module script '$($entry.path)' is missing, linked, or writable by another user."
    }
    if ($fileItem.Length -gt 2MB) {
        throw "Locked module script '$($entry.path)' is oversized."
    }
    $scriptBytes = [System.IO.File]::ReadAllBytes($fileItem.FullName)
    $actualHash = [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            $scriptBytes
        )
    ).ToLowerInvariant()
    if ($actualHash -cne [string] $entry.sha256) {
        throw "Locked module script '$($entry.path)' failed content verification."
    }
    $verifiedScripts.Add([pscustomobject]@{
        Path     = [string] $entry.path
        FullPath = $fileItem.FullName
        Text     = [System.Text.UTF8Encoding]::new(
            $false,
            $true
        ).GetString($scriptBytes)
    })
}
if (
    $lockedRelativePaths.Count -ne $actualRelativePaths.Count -or
    @(
        $actualRelativePaths |
            Where-Object {
                -not $lockedRelativePaths.Contains($_)
            }
    ).Count -ne 0
) {
    throw 'The module contains an unexpected or unlocked script.'
}

foreach ($verifiedScript in $verifiedScripts) {
    try {
        $tokens = $null
        $parseErrors = $null
        $scriptAst =
            [System.Management.Automation.Language.Parser]::ParseInput(
                [string] $verifiedScript.Text,
                [string] $verifiedScript.FullPath,
                [ref] $tokens,
                [ref] $parseErrors
            )
        if (@($parseErrors).Count -ne 0) {
            throw 'The verified script contains a parse error.'
        }
        . $scriptAst.GetScriptBlock()
    }
    catch {
        throw "Locked module script '$($verifiedScript.Path)' failed during load."
    }
}

Export-ModuleMember -Function @(
    'Connect-AzureDataLabAccount'
    'Export-AzureDataLabEvidence'
    'Export-AzureDataLabPlan'
    'Find-AzureDataLabCatalogItem'
    'Get-AzureDataLabEvidence'
    'Get-AzureDataLabRun'
    'Get-AzureDataLabSupportMatrix'
    'Get-AzureDataLabTemplate'
    'Invoke-AzureDataLabPreflight'
    'New-AzureDataLabPlan'
    'New-AzureDataLabRun'
    'Resolve-AzureDataLabPlan'
    'Resolve-AzureDataLabDeployment'
    'Resolve-AzureDataLabTeardown'
    'Resume-AzureDataLabDeployment'
    'Resume-AzureDataLabTeardown'
    'Start-AzureDataLabConfigurationWizard'
    'Start-AzureDataLabDeployment'
    'Start-AzureDataLabTeardown'
    'Test-AzureDataLabAzureContext'
    'Test-AzureDataLabConfiguration'
    'Test-AzureDataLabDeployment'
    'Test-AzureDataLabDeploymentConfiguration'
    'Test-AzureDataLabWhatIf'
)
