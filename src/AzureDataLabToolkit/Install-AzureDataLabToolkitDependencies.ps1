#Requires -Version 7.6

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidatePattern('^[A-Za-z][A-Za-z0-9._-]{0,127}$')]
    [string] $Repository = 'PSGallery',

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [switch] $Reinstall,

    [switch] $TrustRepository,

    [switch] $AcceptLicense,

    [switch] $AuthenticodeCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AdltDependencyInstallerPSResourceGetTrust = [ordered]@{
    Name           = 'Microsoft.PowerShell.PSResourceGet'
    Version        = [version] '1.2.0'
    Guid           = [guid] 'e4e0bda1-0703-44a5-b70d-8fe704cd0643'
    Manifest       = 'Microsoft.PowerShell.PSResourceGet.psd1'
    PackageUri     = (
        'https://www.powershellgallery.com/api/v2/package/' +
        'Microsoft.PowerShell.PSResourceGet/1.2.0'
    )
    PackageDigest  = (
        'sha256:' +
        '90e4c97b2f5ecf8c7d4730ca3b7028739e2b7665ded27249390483f73be71944'
    )
    # The bundled tree is not byte-identical across PowerShell builds: the
    # Windows bundle carries a signed catalogue (.signature.p7s) that the
    # Linux and macOS bundles do not, so file counts and digests differ by
    # platform. Each entry below is a separately reviewed content identity for
    # the same module version and GUID. Verification still requires an exact
    # match against exactly one reviewed entry, so an unreviewed build fails
    # closed; adding a platform is a deliberate review step, not a relaxation.
    ReviewedContent = @(
        [ordered]@{
            Description   = 'PowerShell 7.6 on macOS (Homebrew)'
            FileCount     = 45
            ContentDigest = (
                'sha256:' +
                '61521954557a52d5f70ecb267f43fa582805ff3df91b022a575459014f57b73f'
            )
        }
        [ordered]@{
            Description   = 'PowerShell 7.6 on macOS (GitHub hosted runner)'
            FileCount     = 45
            ContentDigest = (
                'sha256:' +
                '1bf9524d1fe46dbbfaa1a918ea8794b7a0c3979295d07003c006e409f3f2404a'
            )
        }
        [ordered]@{
            Description   = 'PowerShell 7.6 on Ubuntu 24.04'
            FileCount     = 45
            ContentDigest = (
                'sha256:' +
                '0008b7643d3ab690399a72ffd10a99a6bbfb591e329f1873f3eda69c57c52b38'
            )
        }
    )
}
$script:AdltDependencyInstallerNames = @(
    'Az.Accounts'
    'Az.Compute'
    'Az.KeyVault'
    'Az.Monitor'
    'Az.Resources'
    'powershell-yaml'
)

function Test-AdltDependencyInstallerPropertySet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Value,

        [Parameter(Mandatory)]
        [string[]] $Expected
    )

    $actualNames = [string[]] @(
        $Value.Keys |
            ForEach-Object { [string] $_ }
    )
    [System.Array]::Sort(
        $actualNames,
        [System.StringComparer]::Ordinal
    )
    $expectedNames = [string[]] @($Expected)
    [System.Array]::Sort(
        $expectedNames,
        [System.StringComparer]::Ordinal
    )
    return (
        ($actualNames -join "`n") -ceq
            ($expectedNames -join "`n")
    )
}

function Read-AdltDependencyInstallerLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Repository
    )

    $lockItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (
        $lockItem.PSIsContainer -or
        $lockItem.Length -gt 64KB -or
        ($lockItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'Runtime dependency lock is missing, linked, or oversized.'
    }

    try {
        $lock = [System.IO.File]::ReadAllText($lockItem.FullName) |
            ConvertFrom-Json -AsHashtable -Depth 20 -NoEnumerate
    }
    catch {
        throw 'Runtime dependency lock is not valid JSON.'
    }
    if (
        $lock -isnot [System.Collections.IDictionary] -or
        -not (
            Test-AdltDependencyInstallerPropertySet `
                -Value $lock `
                -Expected @(
                    'contentDigestAlgorithm'
                    'dependencies'
                    'kind'
                    'schemaVersion'
                )
        ) -or
        [string] $lock.schemaVersion -cne '1.0' -or
        [string] $lock.kind -cne
            'AzureDataLabRuntimeDependencyLock' -or
        [string] $lock.contentDigestAlgorithm -cne
            'sha256-rfc8785-file-manifest-v1' -or
        $lock.dependencies -isnot [System.Collections.IList] -or
        @($lock.dependencies).Count -ne
            $script:AdltDependencyInstallerNames.Count
    ) {
        throw 'Runtime dependency lock has an invalid top-level contract.'
    }

    $entryProperties = @(
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
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($dependency in @($lock.dependencies)) {
        if (
            $dependency -isnot [System.Collections.IDictionary] -or
            -not (
                Test-AdltDependencyInstallerPropertySet `
                    -Value $dependency `
                    -Expected $entryProperties
            )
        ) {
            throw 'Runtime dependency lock contains an invalid entry.'
        }

        $name = [string] $dependency.name
        $version = [string] $dependency.version
        $guidValue = [guid]::Empty
        $validGuid = [guid]::TryParse(
            [string] $dependency.guid,
            [ref] $guidValue
        )
        $expectedPackageUri = (
            'https://www.powershellgallery.com/api/v2/package/{0}/{1}' -f
                $name,
                $version
        )
        $validFileCount = $false
        try {
            $fileCount = [int] $dependency.fileCount
            $validFileCount = (
                $fileCount -ge 1 -and
                $fileCount -le 20000
            )
        }
        catch {
            $validFileCount = $false
        }

        if (
            $name -cnotmatch '^[A-Za-z][A-Za-z0-9.-]{0,127}$' -or
            $version -cnotmatch '^\d+\.\d+\.\d+(?:\.\d+)?$' -or
            -not $validGuid -or
            $guidValue -eq [guid]::Empty -or
            [string]::IsNullOrWhiteSpace(
                [string] $dependency.author
            ) -or
            [string] $dependency.source -cne $Repository -or
            [string] $dependency.packageUri -cne
                $expectedPackageUri -or
            [string] $dependency.packageDigest -cnotmatch
                '^sha256:[a-f0-9]{64}$' -or
            [string] $dependency.contentDigest -cnotmatch
                '^sha256:[a-f0-9]{64}$' -or
            -not $validFileCount
        ) {
            throw "Runtime dependency lock entry '$name' is invalid."
        }
        $names.Add($name)
    }

    if (
        ($names.ToArray() -join "`n") -cne
            ($script:AdltDependencyInstallerNames -join "`n")
    ) {
        throw 'Runtime dependency lock does not contain the expected modules.'
    }

    return $lock
}

function Test-AdltDependencyInstallerBroadWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemInfo] $Item
    )

    if (-not $IsWindows) {
        $mode = [System.IO.File]::GetUnixFileMode($Item.FullName)
        $broadWrite = (
            [System.IO.UnixFileMode]::GroupWrite -bor
            [System.IO.UnixFileMode]::OtherWrite
        )
        return (($mode -band $broadWrite) -ne 0)
    }

    $broadSids = @(
        'S-1-1-0'
        'S-1-5-11'
        'S-1-5-32-545'
    )
    # Only atomic write rights may appear in this mask. Modify and FullControl
    # are composites that also carry ReadPermissions and Synchronize, so
    # including them makes a read-only ACE test positive and flags every
    # standard PowerShell installation as broadly writable. A Modify or
    # FullControl ACE is still caught here because it contains these bits.
    $writeRights = (
        [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    $acl = if ($Item.PSIsContainer) {
        [System.IO.FileSystemAclExtensions]::GetAccessControl(
            [System.IO.DirectoryInfo] $Item
        )
    }
    else {
        [System.IO.FileSystemAclExtensions]::GetAccessControl(
            [System.IO.FileInfo] $Item
        )
    }
    # Use the .NET API rather than the Access property: Access is added by the
    # Microsoft.PowerShell.Security type data, so it is absent in a session
    # that has not loaded it and StrictMode then makes reading it throw.
    # Requesting SecurityIdentifier rules also avoids translating each
    # identity, which fails for orphaned SIDs.
    $rules = $acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    )
    foreach ($rule in $rules) {
        if (
            $rule.AccessControlType -eq
                [System.Security.AccessControl.AccessControlType]::Allow -and
            ($rule.FileSystemRights -band $writeRights) -ne 0 -and
            $broadSids -contains [string] $rule.IdentityReference.Value
        ) {
            return $true
        }
    }
    return $false
}

function Get-AdltDependencyInstallerContentDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleBase
    )

    $baseItem = Get-Item -LiteralPath $ModuleBase -Force -ErrorAction Stop
    if (
        -not $baseItem.PSIsContainer -or
        ($baseItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'The trusted PSResourceGet module directory is missing or linked.'
    }

    $directories = @(
        $baseItem
        Get-ChildItem `
            -LiteralPath $baseItem.FullName `
            -Directory `
            -Recurse `
            -Force `
            -ErrorAction Stop
    )
    foreach ($directory in $directories) {
        if (
            ($directory.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Test-AdltDependencyInstallerBroadWrite -Item $directory)
        ) {
            throw (
                'The trusted PSResourceGet module tree contains a linked or ' +
                "broadly writable directory: '$($directory.FullName)'."
            )
        }
    }

    $files = @(
        Get-ChildItem `
            -LiteralPath $baseItem.FullName `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop
    )
    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        if (
            ($file.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Test-AdltDependencyInstallerBroadWrite -Item $file)
        ) {
            throw (
                'The trusted PSResourceGet module tree contains a linked or ' +
                "broadly writable file: '$($file.FullName)'."
            )
        }
        $relativePath = $file.FullName.Substring(
            $baseItem.FullName.Length + 1
        ).Replace(
            [System.IO.Path]::DirectorySeparatorChar,
            '/'
        )
        if (
            [string]::IsNullOrWhiteSpace($relativePath) -or
            $relativePath.StartsWith(
                '/',
                [System.StringComparison]::Ordinal
            ) -or
            @($relativePath.Split('/')) -contains '..'
        ) {
            throw 'The trusted PSResourceGet module tree has an unsafe path.'
        }
        $stream = [System.IO.File]::Open(
            $file.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            $fileHash = [System.Convert]::ToHexString(
                [System.Security.Cryptography.SHA256]::HashData($stream)
            ).ToLowerInvariant()
        }
        finally {
            $stream.Dispose()
        }
        $rows.Add(('{0}  {1}' -f $fileHash, $relativePath))
    }

    $orderedRows = [string[]] $rows.ToArray()
    [System.Array]::Sort(
        $orderedRows,
        [System.StringComparer]::Ordinal
    )
    $payload = $orderedRows -join "`n"
    $digestBytes = [System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes($payload)
    )
    return [pscustomobject]@{
        FileCount = $files.Count
        Digest    = (
            'sha256:' +
            [System.Convert]::ToHexString(
                $digestBytes
            ).ToLowerInvariant()
        )
    }
}

function Assert-AdltDependencyInstallerPSResourceGetTrust {
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $PowerShellHome = $PSHOME,

        [System.Collections.IDictionary] $TrustRoot =
            $script:AdltDependencyInstallerPSResourceGetTrust
    )

    $moduleBase = [System.IO.Path]::GetFullPath(
        (Join-Path `
            $PowerShellHome `
            "Modules/$($TrustRoot.Name)")
    )
    $expectedParent = [System.IO.Path]::GetFullPath(
        (Join-Path $PowerShellHome 'Modules')
    )
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (
        -not $moduleBase.StartsWith(
            $expectedParent + [System.IO.Path]::DirectorySeparatorChar,
            $comparison
        )
    ) {
        throw 'The trusted PSResourceGet path escapes the PowerShell home.'
    }

    foreach ($anchorPath in @($PowerShellHome, $expectedParent)) {
        $anchor = Get-Item `
            -LiteralPath $anchorPath `
            -Force `
            -ErrorAction Stop
        if (
            -not $anchor.PSIsContainer -or
            ($anchor.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Test-AdltDependencyInstallerBroadWrite -Item $anchor)
        ) {
            throw (
                'The PowerShell bootstrap path is missing, linked, or ' +
                "broadly writable: '$anchorPath'."
            )
        }
    }

    $manifestPath = Join-Path $moduleBase ([string] $TrustRoot.Manifest)
    $manifestItem = Get-Item `
        -LiteralPath $manifestPath `
        -Force `
        -ErrorAction Stop
    if (
        $manifestItem.PSIsContainer -or
        ($manifestItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Test-AdltDependencyInstallerBroadWrite -Item $manifestItem)
    ) {
        throw 'The trusted PSResourceGet manifest is missing, linked, or broadly writable.'
    }

    $content = Get-AdltDependencyInstallerContentDigest `
        -ModuleBase $moduleBase
    $matchedContent = @(
        $TrustRoot.ReviewedContent |
            Where-Object {
                [int] $_.FileCount -eq [int] $content.FileCount -and
                [string] $_.ContentDigest -ceq [string] $content.Digest
            }
    )
    if ($matchedContent.Count -ne 1) {
        throw (
            'The PowerShell-bundled PSResourceGet content does not match ' +
            'the reviewed bootstrap trust root. Observed ' +
            "$($content.FileCount) files with digest $($content.Digest) " +
            "at '$moduleBase'. Add a reviewed entry only after auditing " +
            'that exact content.'
        )
    }

    $manifest = Import-PowerShellDataFile `
        -LiteralPath $manifestItem.FullName `
        -ErrorAction Stop
    if (
        [string] $manifest.ModuleVersion -cne
            ([version] $TrustRoot.Version).ToString() -or
        [guid] $manifest.GUID -ne [guid] $TrustRoot.Guid -or
        [string] $manifest.RootModule -cne
            './Microsoft.PowerShell.PSResourceGet.dll' -or
        [string] $manifest.Author -cne 'Microsoft Corporation' -or
        [string] $manifest.CompanyName -cne 'Microsoft Corporation'
    ) {
        throw (
            'The PowerShell-bundled PSResourceGet manifest identity does ' +
            'not match the bootstrap trust root.'
        )
    }

    return [pscustomobject]@{
        Name         = [string] $TrustRoot.Name
        Version      = [version] $TrustRoot.Version
        Guid         = [guid] $TrustRoot.Guid
        ManifestPath = $manifestItem.FullName
        ModuleBase   = $moduleBase
        ContentDigest = [string] $content.Digest
    }
}

function Get-AdltDependencyInstallerPSResourceGet {
    [CmdletBinding()]
    param()

    $trusted = Assert-AdltDependencyInstallerPSResourceGetTrust
    $pathComparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $loadedByName = @(
        Get-Module -Name $trusted.Name -ErrorAction SilentlyContinue
    )
    foreach ($existing in $loadedByName) {
        if (
            $existing.Version -ne $trusted.Version -or
            $existing.Guid -ne $trusted.Guid -or
            -not [string]::Equals(
                [System.IO.Path]::GetFullPath($existing.ModuleBase),
                [System.IO.Path]::GetFullPath($trusted.ModuleBase),
                $pathComparison
            )
        ) {
            throw (
                'An untrusted PSResourceGet module is already loaded. ' +
                'Start a clean PowerShell process and try again.'
            )
        }
    }

    $loadedCandidates = @(
        Microsoft.PowerShell.Core\Import-Module `
            -Name $trusted.ManifestPath `
            -Force `
            -PassThru `
            -ErrorAction Stop |
            Where-Object {
                $_.Name -ceq $trusted.Name -and
                $_.Version -eq $trusted.Version -and
                $_.Guid -eq $trusted.Guid -and
                [string]::Equals(
                    [System.IO.Path]::GetFullPath($_.ModuleBase),
                    [System.IO.Path]::GetFullPath($trusted.ModuleBase),
                    $pathComparison
                )
            }
    )
    if ($loadedCandidates.Count -ne 1) {
        throw 'Microsoft.PowerShell.PSResourceGet did not load uniquely.'
    }

    $loaded = $loadedCandidates[0]
    $requiredParameters = [ordered]@{
        'Install-PSResource' = @(
            'AcceptLicense'
            'AuthenticodeCheck'
            'Confirm'
            'ErrorAction'
            'Name'
            'Quiet'
            'Reinstall'
            'Repository'
            'Scope'
            'SkipDependencyCheck'
            'TrustRepository'
            'Version'
        )
        'Get-PSResourceRepository' = @(
            'ErrorAction'
            'Name'
        )
        'Get-InstalledPSResource' = @(
            'ErrorAction'
            'Name'
            'Scope'
            'Version'
        )
    }
    $commands = [ordered]@{}
    foreach ($commandName in $requiredParameters.Keys) {
        if (-not $loaded.ExportedCommands.ContainsKey($commandName)) {
            throw (
                "Microsoft.PowerShell.PSResourceGet does not export " +
                "'$commandName'."
            )
        }
        $command = $loaded.ExportedCommands[$commandName]
        if (
            $command.CommandType -ne
                [System.Management.Automation.CommandTypes]::Cmdlet -or
            $command.Module.Name -cne $loaded.Name -or
            $command.Module.Version -ne $loaded.Version -or
            $command.Module.Guid -ne $loaded.Guid -or
            -not [string]::Equals(
                [System.IO.Path]::GetFullPath(
                    $command.Module.ModuleBase
                ),
                [System.IO.Path]::GetFullPath($loaded.ModuleBase),
                $pathComparison
            )
        ) {
            throw (
                "Microsoft.PowerShell.PSResourceGet command '$commandName' " +
                'has an unexpected identity.'
            )
        }
        foreach ($parameterName in $requiredParameters[$commandName]) {
            if (-not $command.Parameters.ContainsKey($parameterName)) {
                throw (
                    "Microsoft.PowerShell.PSResourceGet command " +
                    "'$commandName' is missing parameter '$parameterName'."
                )
            }
        }
        $commands[$commandName] = $command
    }

    return $commands
}

function Get-AdltDependencyInstallerRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo] $Command,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Lock,

        [switch] $TrustRepository
    )

    $repositories = @(
        & $Command -Name $Name -ErrorAction Stop
    )
    if (
        $repositories.Count -ne 1 -or
        [string] $repositories[0].Name -cne $Name
    ) {
        throw "PSResource repository '$Name' is not uniquely registered."
    }

    $packageMarker = '/package/'
    $repositoryUris = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($dependency in @($Lock.dependencies)) {
        $packageUri = [string] $dependency.packageUri
        $markerIndex = $packageUri.IndexOf(
            $packageMarker,
            [System.StringComparison]::Ordinal
        )
        if ($markerIndex -lt 1) {
            throw 'Runtime dependency lock has an invalid package URI.'
        }
        [void] $repositoryUris.Add(
            $packageUri.Substring(0, $markerIndex).TrimEnd('/')
        )
    }
    if ($repositoryUris.Count -ne 1) {
        throw 'Runtime dependency lock references multiple package sources.'
    }
    $expectedUri = @($repositoryUris)[0]
    $actualUri = ([uri] $repositories[0].Uri).AbsoluteUri.TrimEnd('/')
    if ($actualUri -cne $expectedUri) {
        throw "PSResource repository '$Name' has an unexpected source URI."
    }
    if (
        $repositories[0].PSObject.Properties.Name -contains
            'IsAllowedByPolicy' -and
        -not [bool] $repositories[0].IsAllowedByPolicy
    ) {
        throw "PSResource repository '$Name' is blocked by policy."
    }
    if (
        -not [bool] $repositories[0].Trusted -and
        -not $TrustRepository
    ) {
        throw (
            "PSResource repository '$Name' is not trusted. Pass " +
            '-TrustRepository to trust only these install commands.'
        )
    }

    return $repositories[0]
}

function Install-AdltLockedDependencySet {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Lock,

        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo] $Command,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Repository,

        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string] $Scope,

        [switch] $Reinstall,

        [switch] $TrustRepository,

        [switch] $AcceptLicense,

        [switch] $AuthenticodeCheck
    )

    $installedCount = 0
    foreach ($dependency in @($Lock.dependencies)) {
        $name = [string] $dependency.name
        $version = [string] $dependency.version
        $target = '{0} {1} from {2} ({3})' -f
            $name,
            $version,
            $Repository,
            $Scope
        if (-not $PSCmdlet.ShouldProcess($target, 'Install locked module')) {
            continue
        }

        $parameters = @{
            Name                = $name
            Version             = $version
            Repository          = $Repository
            Scope               = $Scope
            SkipDependencyCheck = $true
            Quiet               = $true
            Confirm             = $false
            ErrorAction         = 'Stop'
        }
        if ($Reinstall) {
            $parameters.Reinstall = $true
        }
        if ($TrustRepository) {
            $parameters.TrustRepository = $true
        }
        if ($AcceptLicense) {
            $parameters.AcceptLicense = $true
        }
        if ($AuthenticodeCheck) {
            $parameters.AuthenticodeCheck = $true
        }

        [void] (& $Command @parameters)
        $installedCount++
    }
    return $installedCount
}

function Get-AdltInstalledDependencyRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Lock,

        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo] $Command,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Repository,

        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string] $Scope
    )

    $installed = [ordered]@{}
    foreach ($dependency in @($Lock.dependencies)) {
        $name = [string] $dependency.name
        $version = [string] $dependency.version
        $installedMatches = @(
            & $Command `
                -Name $name `
                -Version $version `
                -Scope $Scope `
                -ErrorAction Stop |
                Where-Object {
                    [string] $_.Name -ceq $name -and
                    [string] $_.Version -ceq $version
                }
        )
        if ($installedMatches.Count -ne 1) {
            throw (
                "Installed dependency '$name' does not resolve uniquely at " +
                "locked version '$version' in scope '$Scope'."
            )
        }
        if ([string] $installedMatches[0].Repository -cne $Repository) {
            throw "Installed dependency '$name' has an unexpected source."
        }
        if ([string] $installedMatches[0].Type -cne 'Module') {
            throw "Installed dependency '$name' is not a module."
        }
        $location = [string] $installedMatches[0].InstalledLocation
        if ([string]::IsNullOrWhiteSpace($location)) {
            throw "Installed dependency '$name' has no installation path."
        }
        $installed[$name] = [pscustomobject]@{
            Name              = $name
            Version           = $version
            Repository        = $Repository
            InstalledLocation = [System.IO.Path]::GetFullPath($location)
        }
    }
    return $installed
}

function Import-AdltDependencyInstallerModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ManifestPath
    )

    $manifestItem = Get-Item `
        -LiteralPath $ManifestPath `
        -Force `
        -ErrorAction Stop
    if (
        $manifestItem.PSIsContainer -or
        ($manifestItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'AzureDataLabToolkit module manifest is missing or linked.'
    }

    $manifest = Import-PowerShellDataFile `
        -LiteralPath $manifestItem.FullName `
        -ErrorAction Stop
    $expectedModuleBase = [System.IO.Path]::GetFullPath(
        $manifestItem.DirectoryName
    )
    $modules = @(
        Microsoft.PowerShell.Core\Import-Module `
            -Name $manifestItem.FullName `
            -Force `
            -PassThru `
            -ErrorAction Stop |
            Where-Object {
                $_.Name -ceq 'AzureDataLabToolkit' -and
                $_.Guid -eq [guid] $manifest.GUID -and
                $_.Version -eq [version] $manifest.ModuleVersion -and
                [System.IO.Path]::GetFullPath($_.ModuleBase) -ceq
                    $expectedModuleBase
            }
    )
    if ($modules.Count -ne 1) {
        throw 'The local AzureDataLabToolkit module did not load uniquely.'
    }
    return $modules[0]
}

function Test-AdltInstalledDependencyContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSModuleInfo] $Module,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Lock,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Installed
    )

    $verified = @(
        & $Module {
            foreach (
                $dependency in @(
                    (Get-AdltRuntimeDependencyLock).dependencies
                )
            ) {
                [pscustomobject] (
                    Get-AdltVerifiedRuntimeDependency `
                        -Name ([string] $dependency.name)
                )
            }
        }
    )
    if ($verified.Count -ne @($Lock.dependencies).Count) {
        throw 'Runtime dependency verification did not cover every lock entry.'
    }

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $result = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt @($Lock.dependencies).Count; $index++) {
        $dependency = @($Lock.dependencies)[$index]
        $identity = $verified[$index]
        $name = [string] $dependency.name
        if (
            [string] $identity.name -cne $name -or
            [string] $identity.version -cne
                [string] $dependency.version -or
            [string] $identity.guid -cne
                ([string] $dependency.guid).ToLowerInvariant() -or
            [string] $identity.author -cne
                [string] $dependency.author -or
            [string] $identity.source -cne
                [string] $dependency.source -or
            [string] $identity.packageDigest -cne
                [string] $dependency.packageDigest -or
            [string] $identity.contentDigest -cne
                [string] $dependency.contentDigest -or
            -not $Installed.Contains($name) -or
            -not [string]::Equals(
                [System.IO.Path]::GetFullPath(
                    [string] $identity.moduleBase
                ),
                [System.IO.Path]::GetFullPath(
                    [string] $Installed[$name].InstalledLocation
                ),
                $comparison
            )
        ) {
            throw (
                "Installed dependency '$name' failed reviewed content " +
                'verification.'
            )
        }
        $result.Add(
            [pscustomobject]@{
                Name       = $name
                Version    = [string] $identity.version
                Repository = [string] $identity.source
                Verified   = $true
            }
        )
    }
    return @($result.ToArray())
}

function Invoke-AdltDependencyInstaller {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [ValidatePattern('^[A-Za-z][A-Za-z0-9._-]{0,127}$')]
        [string] $Repository = 'PSGallery',

        [ValidateSet('CurrentUser', 'AllUsers')]
        [string] $Scope = 'CurrentUser',

        [switch] $Reinstall,

        [switch] $TrustRepository,

        [switch] $AcceptLicense,

        [switch] $AuthenticodeCheck
    )

    $lockPath = Join-Path `
        $PSScriptRoot `
        'Support/runtime-dependencies.lock.json'
    $lock = Read-AdltDependencyInstallerLock `
        -Path $lockPath `
        -Repository $Repository
    $commands = Get-AdltDependencyInstallerPSResourceGet
    [void] (
        Get-AdltDependencyInstallerRepository `
            -Command $commands['Get-PSResourceRepository'] `
            -Name $Repository `
            -Lock $lock `
            -TrustRepository:$TrustRepository
    )

    $installParameters = @{
        Lock              = $lock
        Command           = $commands['Install-PSResource']
        Repository        = $Repository
        Scope             = $Scope
        Reinstall         = $Reinstall
        TrustRepository   = $TrustRepository
        AcceptLicense     = $AcceptLicense
        AuthenticodeCheck = $AuthenticodeCheck
        Confirm           = (
            $PSBoundParameters.ContainsKey('Confirm') -and
            [bool] $PSBoundParameters.Confirm
        )
    }
    if ($WhatIfPreference) {
        $installParameters.WhatIf = $true
    }
    $installedCount = Install-AdltLockedDependencySet @installParameters
    if ($installedCount -ne @($lock.dependencies).Count) {
        return [pscustomobject]@{
            Status     = 'planned'
            Repository = $Repository
            Scope      = $Scope
            Count      = @($lock.dependencies).Count
        }
    }

    $installed = Get-AdltInstalledDependencyRecord `
        -Lock $lock `
        -Command $commands['Get-InstalledPSResource'] `
        -Repository $Repository `
        -Scope $Scope
    $moduleManifestPath = Join-Path `
        $PSScriptRoot `
        'AzureDataLabToolkit.psd1'
    $module = Import-AdltDependencyInstallerModule `
        -ManifestPath $moduleManifestPath
    return @(
        Test-AdltInstalledDependencyContent `
            -Module $module `
            -Lock $lock `
            -Installed $installed
    )
}

if ($MyInvocation.InvocationName -cne '.') {
    Invoke-AdltDependencyInstaller @PSBoundParameters
}
