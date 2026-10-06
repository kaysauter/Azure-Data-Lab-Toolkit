function Get-AdltDefaultStateRoot {
    [CmdletBinding()]
    param()

    if ($IsWindows) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is required to select the default state root.'
        }
        return Join-Path $env:LOCALAPPDATA 'AzureDataLabToolkit/state'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:XDG_STATE_HOME)) {
        return Join-Path $env:XDG_STATE_HOME 'azure-data-lab-toolkit'
    }
    if ([string]::IsNullOrWhiteSpace($HOME)) {
        throw 'HOME is required to select the default state root.'
    }

    return Join-Path $HOME '.local/state/azure-data-lab-toolkit'
}

function Test-AdltPathAtOrBelow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Boundary
    )

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $normalizedPath = [System.IO.Path]::TrimEndingDirectorySeparator(
        [System.IO.Path]::GetFullPath($Path)
    )
    $normalizedBoundary = [System.IO.Path]::TrimEndingDirectorySeparator(
        [System.IO.Path]::GetFullPath($Boundary)
    )
    if ($normalizedPath.Equals($normalizedBoundary, $comparison)) {
        return $true
    }

    $boundaryPrefix = '{0}{1}' -f
        $normalizedBoundary,
        [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($boundaryPrefix, $comparison)
}

function Get-AdltLocalStoreTrustBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $candidates = [System.Collections.Generic.List[object]]::new()
    $userProfile = [System.Environment]::GetFolderPath(
        [System.Environment+SpecialFolder]::UserProfile
    )
    if (
        -not [string]::IsNullOrWhiteSpace($userProfile) -and
        [System.IO.Directory]::Exists($userProfile) -and
        (Test-AdltPathAtOrBelow -Path $fullPath -Boundary $userProfile)
    ) {
        $candidates.Add([pscustomobject]@{
            Path = [System.IO.Path]::GetFullPath($userProfile)
            Kind = 'UserProfile'
        })
    }

    $temporaryRoots = [System.Collections.Generic.List[string]]::new()
    $temporaryRoots.Add([System.IO.Path]::GetTempPath())
    if (-not $IsWindows) {
        $temporaryRoots.Add('/tmp')
        $temporaryRoots.Add('/private/tmp')
    }
    foreach ($temporaryRoot in @($temporaryRoots | Select-Object -Unique)) {
        if (
            -not [string]::IsNullOrWhiteSpace($temporaryRoot) -and
            [System.IO.Directory]::Exists($temporaryRoot) -and
            (Test-AdltPathAtOrBelow -Path $fullPath -Boundary $temporaryRoot)
        ) {
            $candidates.Add([pscustomobject]@{
                Path = [System.IO.Path]::GetFullPath($temporaryRoot)
                Kind = 'PlatformTemp'
            })
        }
    }

    if ($candidates.Count -gt 0) {
        return $candidates |
            Sort-Object { $_.Path.Length } -Descending |
            Select-Object -First 1
    }

    return [pscustomobject]@{
        Path = [System.IO.Path]::GetPathRoot($fullPath)
        Kind = 'FileSystemRoot'
    }
}

function Get-AdltExistingPathChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Boundary
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullBoundary = [System.IO.Path]::GetFullPath($Boundary)
    $chain = [System.Collections.Generic.List[string]]::new()
    $currentPath = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        if (
            [System.IO.Directory]::Exists($currentPath) -or
            [System.IO.File]::Exists($currentPath)
        ) {
            $chain.Add($currentPath)
        }
        if (Test-AdltPathAtOrBelow -Path $fullBoundary -Boundary $currentPath) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent -or $parent.FullName -ceq $currentPath) {
            break
        }
        $currentPath = $parent.FullName
    }

    return @($chain.ToArray())[($chain.Count - 1)..0]
}

function Get-AdltCurrentUnixUserId {
    [CmdletBinding()]
    param()

    if ($IsWindows) {
        throw 'Unix user identity is unavailable on Windows.'
    }
    if ($null -eq ('AzureDataLabToolkitUnixIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

public static class AzureDataLabToolkitUnixIdentity
{
    [DllImport("libc")]
    public static extern uint geteuid();
}
'@
    }

    return [uint32] [AzureDataLabToolkitUnixIdentity]::geteuid()
}

function Get-AdltUnixPathOwnerId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $unixStat = $item.PSObject.Properties['UnixStat'].Value
    if ($null -eq $unixStat) {
        throw "Unix ownership metadata is unavailable for '$Path'."
    }
    return [uint32] $unixStat.UserId
}

function Assert-AdltUnixAncestorSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $PathChain,

        [Parameter(Mandatory)]
        [string] $BoundaryKind
    )

    $currentUserId = Get-AdltCurrentUnixUserId
    $currentUserBoundaryReached = $false
    $writeMask =
        [System.IO.UnixFileMode]::GroupWrite -bor
        [System.IO.UnixFileMode]::OtherWrite

    for ($index = 0; $index -lt $PathChain.Count; $index++) {
        $path = $PathChain[$index]
        $ownerId = Get-AdltUnixPathOwnerId -Path $path
        $mode = [System.IO.File]::GetUnixFileMode($path)
        $isBoundary = $index -eq 0

        if ($ownerId -eq $currentUserId) {
            $currentUserBoundaryReached = $true
        }
        elseif (
            $ownerId -ne 0 -or
            $currentUserBoundaryReached -or
            ($isBoundary -and $BoundaryKind -eq 'UserProfile')
        ) {
            throw "Run state path component '$path' has unexpected owner UID '$ownerId'."
        }

        if (($mode -band $writeMask) -ne 0) {
            $trustedSharedTemporaryBoundary =
                $isBoundary -and
                $BoundaryKind -eq 'PlatformTemp' -and
                ($mode -band [System.IO.UnixFileMode]::StickyBit) -ne 0
            if (-not $trustedSharedTemporaryBoundary) {
                throw "Run state path component '$path' is writable by non-owner identities."
            }
        }
    }
}

function Assert-AdltWindowsAncestorSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $PathChain,

        [Parameter(Mandatory)]
        [string] $BoundaryKind
    )

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) {
        throw 'The current Windows security identifier could not be resolved.'
    }
    $trustedSystemOwners = @(
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    )
    $currentUserBoundaryReached = $false
    $writeRights =
        [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership

    for ($index = 0; $index -lt $PathChain.Count; $index++) {
        $path = $PathChain[$index]
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $security = if ($item.PSIsContainer) {
            [System.IO.FileSystemAclExtensions]::GetAccessControl(
                [System.IO.DirectoryInfo]::new($path)
            )
        }
        else {
            [System.IO.FileSystemAclExtensions]::GetAccessControl(
                [System.IO.FileInfo]::new($path)
            )
        }
        $owner = $security.GetOwner(
            [System.Security.Principal.SecurityIdentifier]
        )
        if ($owner.Equals($identity.User)) {
            $currentUserBoundaryReached = $true
        }
        elseif (
            $currentUserBoundaryReached -or
            $trustedSystemOwners -notcontains $owner -or
            ($index -eq 0 -and $BoundaryKind -eq 'UserProfile')
        ) {
            throw "Run state path component '$path' has an unexpected Windows owner."
        }

        foreach ($rule in $security.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier]
        )) {
            $trustedIdentity =
                $rule.IdentityReference.Equals($identity.User) -or
                $trustedSystemOwners -contains $rule.IdentityReference
            if (
                -not $trustedIdentity -and
                $rule.AccessControlType -eq
                    [System.Security.AccessControl.AccessControlType]::Allow -and
                ($rule.FileSystemRights -band $writeRights) -ne 0
            ) {
                throw "Run state path component '$path' grants write access to another identity."
            }
        }
    }
}

function Assert-AdltLocalStorePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $boundary = Get-AdltLocalStoreTrustBoundary -Path $fullPath
    $pathChain = @(
        Get-AdltExistingPathChain `
            -Path $fullPath `
            -Boundary $boundary.Path
    )
    foreach ($currentPath in $pathChain) {
        $attributes = [System.IO.File]::GetAttributes($currentPath)
        if (
            ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne
            0
        ) {
            throw "Run state path component '$currentPath' cannot be a symbolic link or reparse point."
        }
    }
    if ($IsWindows) {
        Assert-AdltWindowsAncestorSecurity `
            -PathChain $pathChain `
            -BoundaryKind $boundary.Kind
    }
    else {
        Assert-AdltUnixAncestorSecurity `
            -PathChain $pathChain `
            -BoundaryKind $boundary.Kind
    }

    return $fullPath
}

function Set-AdltPrivatePathMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('Directory', 'File')]
        [string] $Type
    )

    if ($IsWindows) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $identity.User) {
            throw 'The current Windows security identifier could not be resolved.'
        }

        $inheritanceFlags = if ($Type -eq 'Directory') {
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        }
        else {
            [System.Security.AccessControl.InheritanceFlags]::None
        }
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity.User,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritanceFlags,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )

        if ($Type -eq 'Directory') {
            $security =
                [System.Security.AccessControl.DirectorySecurity]::new()
            $security.SetOwner($identity.User)
            $security.SetAccessRuleProtection($true, $false)
            [void] $security.AddAccessRule($rule)
            [System.IO.FileSystemAclExtensions]::SetAccessControl(
                [System.IO.DirectoryInfo]::new($Path),
                $security
            )
        }
        else {
            $security = [System.Security.AccessControl.FileSecurity]::new()
            $security.SetOwner($identity.User)
            $security.SetAccessRuleProtection($true, $false)
            [void] $security.AddAccessRule($rule)
            [System.IO.FileSystemAclExtensions]::SetAccessControl(
                [System.IO.FileInfo]::new($Path),
                $security
            )
        }
        return
    }

    $mode = if ($Type -eq 'Directory') {
        [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite -bor
            [System.IO.UnixFileMode]::UserExecute
    }
    else {
        [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite
    }
    [System.IO.File]::SetUnixFileMode($Path, $mode)
}

function Assert-AdltPrivatePathMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('Directory', 'File')]
        [string] $Type
    )

    if ($IsWindows) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $identity.User) {
            throw 'The current Windows security identifier could not be resolved.'
        }
        $security = if ($Type -eq 'Directory') {
            [System.IO.FileSystemAclExtensions]::GetAccessControl(
                [System.IO.DirectoryInfo]::new($Path)
            )
        }
        else {
            [System.IO.FileSystemAclExtensions]::GetAccessControl(
                [System.IO.FileInfo]::new($Path)
            )
        }
        if (-not $security.AreAccessRulesProtected) {
            throw "Run store entry '$Path' inherits Windows access rules."
        }
        if (
            -not $security.GetOwner(
                [System.Security.Principal.SecurityIdentifier]
            ).Equals($identity.User)
        ) {
            throw "Run store entry '$Path' is not owned by the current user."
        }

        $hasOwnerFullControl = $false
        foreach ($rule in $security.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier]
        )) {
            if (-not $rule.IdentityReference.Equals($identity.User)) {
                throw "Run store entry '$Path' grants access to another identity."
            }
            if (
                $rule.AccessControlType -eq
                    [System.Security.AccessControl.AccessControlType]::Allow -and
                ($rule.FileSystemRights -band
                    [System.Security.AccessControl.FileSystemRights]::FullControl
                ) -eq
                    [System.Security.AccessControl.FileSystemRights]::FullControl
            ) {
                $hasOwnerFullControl = $true
            }
        }
        if (-not $hasOwnerFullControl) {
            throw "Run store entry '$Path' does not grant owner full control."
        }
        return
    }

    $ownerId = Get-AdltUnixPathOwnerId -Path $Path
    $currentUserId = Get-AdltCurrentUnixUserId
    if ($ownerId -ne $currentUserId) {
        throw "Run store entry '$Path' is not owned by the current user."
    }
    $mode = [System.IO.File]::GetUnixFileMode($Path)
    $nonOwnerMask =
        [System.IO.UnixFileMode]::GroupRead -bor
        [System.IO.UnixFileMode]::GroupWrite -bor
        [System.IO.UnixFileMode]::GroupExecute -bor
        [System.IO.UnixFileMode]::OtherRead -bor
        [System.IO.UnixFileMode]::OtherWrite -bor
        [System.IO.UnixFileMode]::OtherExecute
    if (($mode -band $nonOwnerMask) -ne 0) {
        throw "Run store entry '$Path' is accessible by non-owner identities."
    }
}

function New-AdltPrivateDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ([System.IO.Directory]::Exists($Path)) {
        Assert-AdltPrivatePathMode -Path $Path -Type Directory
        return [System.IO.DirectoryInfo]::new($Path)
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $missingPaths = [System.Collections.Generic.List[string]]::new()
    $currentPath = $fullPath
    while (-not [System.IO.Directory]::Exists($currentPath)) {
        if ([System.IO.File]::Exists($currentPath)) {
            throw "Private directory path '$currentPath' is occupied by a file."
        }
        $missingPaths.Add($currentPath)
        $parent = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent) {
            throw "Private directory path '$fullPath' has no existing parent."
        }
        $currentPath = $parent.FullName
    }

    foreach ($missingPath in @($missingPaths.ToArray())[
        ($missingPaths.Count - 1)..0
    ]) {
        if ([System.IO.Directory]::Exists($missingPath)) {
            throw "Private directory path '$missingPath' appeared concurrently."
        }
        if ($IsWindows) {
            [void] [System.IO.Directory]::CreateDirectory($missingPath)
        }
        else {
            $mode =
                [System.IO.UnixFileMode]::UserRead -bor
                [System.IO.UnixFileMode]::UserWrite -bor
                [System.IO.UnixFileMode]::UserExecute
            [void] [System.IO.Directory]::CreateDirectory($missingPath, $mode)
        }
        Set-AdltPrivatePathMode -Path $missingPath -Type Directory
        Assert-AdltPrivatePathMode -Path $missingPath -Type Directory
    }

    [void] (Assert-AdltLocalStorePath -Path $fullPath)
    return [System.IO.DirectoryInfo]::new($fullPath)
}

function Open-AdltExclusiveFileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $FailureMessage
    )

    $lockPath = [System.IO.Path]::GetFullPath($Path)
    $parentPath = [System.IO.Path]::GetDirectoryName($lockPath)
    Assert-AdltLocalStoreEntry -Path $parentPath -Type Directory
    $stream = $null
    try {
        $lockExisted = [System.IO.File]::Exists($lockPath)
        if ($lockExisted) {
            Assert-AdltLocalStoreEntry -Path $lockPath -Type File
        }
        $options = [System.IO.FileStreamOptions]::new()
        $options.Mode = [System.IO.FileMode]::OpenOrCreate
        $options.Access = [System.IO.FileAccess]::ReadWrite
        $options.Share = [System.IO.FileShare]::None
        if (-not $IsWindows) {
            $options.UnixCreateMode =
                [System.IO.UnixFileMode]::UserRead -bor
                [System.IO.UnixFileMode]::UserWrite
        }
        $stream = [System.IO.FileStream]::new($lockPath, $options)
        if ($lockExisted) {
            Assert-AdltPrivatePathMode -Path $lockPath -Type File
        }
        else {
            Set-AdltPrivatePathMode -Path $lockPath -Type File
            Assert-AdltPrivatePathMode -Path $lockPath -Type File
        }
        return $stream
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        throw $FailureMessage
    }
}

function Open-AdltLocalRunLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath
    )

    return Open-AdltExclusiveFileLock `
        -Path (Join-Path $RunPath '.lock') `
        -FailureMessage (
            "Run state at '$RunPath' is locked by another process."
        )
}

function Open-AdltLocalRunOperationLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath
    )

    return Open-AdltExclusiveFileLock `
        -Path (Join-Path $RunPath '.operation.lock') `
        -FailureMessage (
            "Run '$RunPath' already has an active operation."
        )
}

function Open-AdltAzureScopeOperationLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Scope,

        [string] $LockRoot = (
            Join-Path (Get-AdltDefaultStateRoot) 'scope-locks'
        )
    )

    $normalizedScope = [ordered]@{
        cloud = ([string] $Scope.cloud).ToLowerInvariant()
        tenantId = ([string] $Scope.tenantId).ToLowerInvariant()
        subscriptionId =
            ([string] $Scope.subscriptionId).ToLowerInvariant()
        resourceGroupName =
            ([string] $Scope.resourceGroupName).ToLowerInvariant()
    }
    $scopeHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $normalizedScope
    )
    [void] (New-AdltPrivateDirectory -Path $LockRoot)
    return Open-AdltExclusiveFileLock `
        -Path (Join-Path $LockRoot (
            '{0}.lock' -f $scopeHash.Substring(7, 32)
        )) `
        -FailureMessage (
            "Azure scope '$($Scope.resourceGroupName)' already has an " +
            'active local operation.'
        )
}

function Write-AdltPrivateAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Content,

        [switch] $Force
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($parentPath)) {
        throw "Output directory '$parentPath' does not exist."
    }
    if ([System.IO.File]::Exists($fullPath) -and -not $Force.IsPresent) {
        throw "Output file '$fullPath' already exists."
    }

    $temporaryPath = Join-Path $parentPath (
        '.{0}.{1}.tmp' -f
            [System.IO.Path]::GetFileName($fullPath),
            [guid]::NewGuid().ToString('N')
    )
    $stream = $null
    try {
        $options = [System.IO.FileStreamOptions]::new()
        $options.Mode = [System.IO.FileMode]::CreateNew
        $options.Access = [System.IO.FileAccess]::Write
        $options.Share = [System.IO.FileShare]::None
        if (-not $IsWindows) {
            $options.UnixCreateMode =
                [System.IO.UnixFileMode]::UserRead -bor
                [System.IO.UnixFileMode]::UserWrite
        }
        $stream = [System.IO.FileStream]::new($temporaryPath, $options)
        Set-AdltPrivatePathMode -Path $temporaryPath -Type File
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        [System.IO.File]::Move(
            $temporaryPath,
            $fullPath,
            $Force.IsPresent
        )
        Set-AdltPrivatePathMode -Path $fullPath -Type File
        return $fullPath
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Write-AdltRunEventLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $RunEvent,

        [switch] $Create
    )

    Assert-AdltRunEvent -RunEvent $RunEvent
    $line = '{0}{1}' -f
        (ConvertTo-AdltCanonicalJson -InputObject $RunEvent),
        "`n"
    if ($Create.IsPresent) {
        [void] (Write-AdltPrivateAtomicText -Path $Path -Content $line)
        return
    }
    if (-not [System.IO.File]::Exists($Path)) {
        throw "Run event log '$Path' does not exist."
    }

    $currentLength = ([System.IO.FileInfo]::new($Path)).Length
    if (
        $currentLength -gt
            $script:AzureDataLabToolkitMaximumEventLogBytes -or
        $currentLength + [System.Text.Encoding]::UTF8.GetByteCount($line) -gt
            $script:AzureDataLabToolkitMaximumEventLogBytes
    ) {
        throw 'Run event log exceeds its maximum protected size.'
    }
    $currentContent = [System.IO.File]::ReadAllText($Path)
    if (-not $currentContent.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        throw 'Run event log ends with an incomplete or truncated record.'
    }
    [void] (Write-AdltPrivateAtomicText `
        -Path $Path `
        -Content ($currentContent + $line) `
        -Force)
}

function Read-AdltRunEventLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Run event log '$Path' does not exist."
    }
    $logItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (
        $logItem.Length -gt
            $script:AzureDataLabToolkitMaximumEventLogBytes -or
        ($logItem.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'Run event log is linked or exceeds its maximum protected size.'
    }

    $logStream = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        if ($logStream.Length -eq 0) {
            throw 'Run event log is empty.'
        }
        [void] $logStream.Seek(-1, [System.IO.SeekOrigin]::End)
        if ($logStream.ReadByte() -ne 10) {
            throw 'Run event log ends with an incomplete or truncated record.'
        }
    }
    finally {
        $logStream.Dispose()
    }

    $events = [System.Collections.Generic.List[object]]::new()
    $expectedSequence = 1
    $previousHash = $null
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (
            $events.Count -ge
                $script:AzureDataLabToolkitMaximumEventCount -or
            $line.Length -gt
                $script:AzureDataLabToolkitMaximumEventLineChars
        ) {
            throw 'Run event log exceeds its protected record limits.'
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw 'Run event logs cannot contain blank or truncated records.'
        }
        try {
            $runEvent = ConvertTo-AdltDictionary -InputObject (
                $line | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
            )
        }
        catch {
            throw 'Run event log contains invalid or truncated JSON.'
        }

        Assert-AdltRunEvent -RunEvent $runEvent
        if ([int] $runEvent.sequence -ne $expectedSequence) {
            throw "Run event sequence must be contiguous at '$expectedSequence'."
        }
        if ($expectedSequence -eq 1 -and $null -ne $runEvent.previousEventHash) {
            throw 'The first run event cannot reference a previous event.'
        }
        if (
            $expectedSequence -gt 1 -and
            $runEvent.previousEventHash -cne $previousHash
        ) {
            throw 'Run event hash chain verification failed.'
        }

        $events.Add($runEvent)
        $previousHash = [string] $runEvent.eventHash
        $expectedSequence++
    }

    if ($events.Count -eq 0) {
        throw 'Run event log is empty.'
    }
    return $events.ToArray()
}

function ConvertFrom-AdltRunEventLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $RunEvents
    )

    $state = $null
    foreach ($runEvent in $RunEvents) {
        $state = Invoke-AdltRunEventProjection `
            -State $state `
            -RunEvent (ConvertTo-AdltDictionary -InputObject $runEvent)
    }
    return $state
}

function Assert-AdltLocalStoreEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('Directory', 'File')]
        [string] $Type
    )

    $exists = if ($Type -eq 'Directory') {
        [System.IO.Directory]::Exists($Path)
    }
    else {
        [System.IO.File]::Exists($Path)
    }
    if (-not $exists) {
        throw "Required run store $($Type.ToLowerInvariant()) '$Path' does not exist."
    }

    $attributes = [System.IO.File]::GetAttributes($Path)
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Run store entry '$Path' cannot be a symbolic link or reparse point."
    }
    Assert-AdltPrivatePathMode -Path $Path -Type $Type
}

function Get-AdltEvidenceFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence
    )

    return '{0:D4}-{1}-{2}.json' -f
        [int] $Evidence.sequence,
        [string] $Evidence.stage,
        $Evidence.evidenceHash.Substring(7, 12)
}

function Resolve-AdltPendingRunEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $EvidencePath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    foreach ($temporaryFile in @(
        Get-ChildItem -LiteralPath $EvidencePath -File -Force |
            Where-Object {
                $_.Name -match
                    '^\..+\.json\.pending\.[0-9a-f]{32}\.tmp$'
            }
    )) {
        Assert-AdltLocalStoreEntry -Path $temporaryFile.FullName -Type File
        [System.IO.File]::Delete($temporaryFile.FullName)
    }

    foreach ($pendingFile in @(
        Get-ChildItem `
            -LiteralPath $EvidencePath `
            -Filter '*.json.pending' `
            -File `
            -Force
    )) {
        Assert-AdltLocalStoreEntry -Path $pendingFile.FullName -Type File
        $evidence = Read-AdltJsonFile -Path $pendingFile.FullName
        Assert-AdltEvidence -Evidence $evidence
        if (
            $evidence.runId -cne $State.runId -or
            $evidence.planHash -cne $State.planHash -or
            $evidence.intentHash -cne $State.intentHash
        ) {
            throw "Pending evidence '$($pendingFile.Name)' does not match the run binding."
        }

        $reference = @(
            $State.evidenceReferences |
                Where-Object {
                    $_.stage -ceq $evidence.stage -and
                    $_.evidenceHash -ceq $evidence.evidenceHash
                }
        )
        if ($reference.Count -eq 0) {
            [System.IO.File]::Delete($pendingFile.FullName)
            continue
        }
        if ($reference.Count -ne 1) {
            throw "Pending evidence '$($pendingFile.Name)' has ambiguous references."
        }

        $finalPath = Join-Path `
            $EvidencePath `
            (Get-AdltEvidenceFileName -Evidence $evidence)
        if ([System.IO.File]::Exists($finalPath)) {
            throw "Pending evidence '$($pendingFile.Name)' collides with an existing artifact."
        }
        [System.IO.File]::Move($pendingFile.FullName, $finalPath, $false)
        Set-AdltPrivatePathMode -Path $finalPath -Type File
    }
}

function Get-AdltVerifiedRunEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $EvidencePath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    Assert-AdltLocalStoreEntry -Path $EvidencePath -Type Directory
    Resolve-AdltPendingRunEvidence `
        -EvidencePath $EvidencePath `
        -State $State
    $files = @(
        Get-ChildItem -LiteralPath $EvidencePath -File -Force |
            Sort-Object Name
    )
    if (
        $files.Count -gt
            $script:AzureDataLabToolkitMaximumEvidenceFiles
    ) {
        throw 'Run evidence directory exceeds its protected file limit.'
    }
    if ($files.Count -eq 0) {
        throw 'The run evidence directory is empty.'
    }

    $evidenceBySequence = [System.Collections.Generic.List[object]]::new()
    $hashes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $eventIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($file in $files) {
        Assert-AdltLocalStoreEntry -Path $file.FullName -Type File
        if ($file.Extension -cne '.json') {
            throw "Unrecognized evidence file '$($file.Name)' is not allowed."
        }

        $evidence = Read-AdltJsonFile -Path $file.FullName
        Assert-AdltEvidence -Evidence $evidence
        if (
            $evidence.runId -cne $State.runId -or
            $evidence.planHash -cne $State.planHash -or
            $evidence.intentHash -cne $State.intentHash
        ) {
            throw "Evidence '$($file.Name)' does not match the run binding."
        }
        if (-not $hashes.Add([string] $evidence.evidenceHash)) {
            throw "Duplicate evidence '$($evidence.evidenceHash)' was found."
        }
        if (-not $eventIds.Add([string] $evidence.eventId)) {
            throw "Duplicate evidence event '$($evidence.eventId)' was found."
        }
        $evidenceBySequence.Add($evidence)
    }

    $orderedEvidence = @(
        $evidenceBySequence.ToArray() |
            Sort-Object { [int] $_.sequence }
    )
    if ($orderedEvidence.Count -ne @($State.evidenceReferences).Count) {
        throw 'Evidence files and authoritative evidence references do not match.'
    }

    $previousEvidenceHash = $null
    for ($index = 0; $index -lt $orderedEvidence.Count; $index++) {
        $evidence = $orderedEvidence[$index]
        $reference = @($State.evidenceReferences)[$index]
        if ([int] $evidence.sequence -ne $index) {
            throw "Evidence sequence must be contiguous at '$index'."
        }
        if ($index -eq 0 -and $evidence.stage -cne 'plan') {
            throw 'The first evidence artifact must be plan evidence.'
        }
        if ($index -eq 0 -and $null -ne $evidence.previousEventHash) {
            throw 'The first evidence artifact cannot reference previous evidence.'
        }
        if (
            $index -gt 0 -and
            $evidence.previousEventHash -cne $previousEvidenceHash
        ) {
            throw 'Evidence hash chain verification failed.'
        }
        if (
            $reference.stage -cne $evidence.stage -or
            $reference.evidenceHash -cne $evidence.evidenceHash
        ) {
            throw 'Evidence file does not match its authoritative reference.'
        }
        $previousEvidenceHash = [string] $evidence.evidenceHash
    }

    return $orderedEvidence
}

function Set-AdltPrivateRunStoreMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath
    )

    Assert-AdltPrivatePathMode -Path $RunPath -Type Directory
    $evidencePath = Join-Path $RunPath 'evidence'
    $artifactPath = Join-Path $RunPath 'artifacts'
    Assert-AdltPrivatePathMode -Path $evidencePath -Type Directory
    Assert-AdltPrivatePathMode -Path $artifactPath -Type Directory
    foreach ($fileName in @(
        '.lock',
        '.operation.lock',
        'plan.json',
        'events.ndjson',
        'snapshot.json'
    )) {
        $filePath = Join-Path $RunPath $fileName
        if ([System.IO.File]::Exists($filePath)) {
            Assert-AdltPrivatePathMode -Path $filePath -Type File
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $evidencePath -File -Force) {
        Assert-AdltPrivatePathMode -Path $file.FullName -Type File
    }
    foreach ($file in Get-ChildItem -LiteralPath $artifactPath -File -Force) {
        Assert-AdltPrivatePathMode -Path $file.FullName -Type File
    }
}

function Get-AdltVerifiedLocalRunContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath
    )

    $stateRoot = [System.IO.Directory]::GetParent($RunPath)
    if ($null -eq $stateRoot) {
        throw "Run path '$RunPath' does not have a protected state root."
    }
    Assert-AdltLocalStoreEntry -Path $stateRoot.FullName -Type Directory
    Assert-AdltLocalStoreEntry -Path $RunPath -Type Directory
    $planPath = Join-Path $RunPath 'plan.json'
    $snapshotPath = Join-Path $RunPath 'snapshot.json'
    $eventLogPath = Join-Path $RunPath 'events.ndjson'
    Assert-AdltLocalStoreEntry -Path $planPath -Type File
    Assert-AdltLocalStoreEntry -Path $eventLogPath -Type File

    $plan = Read-AdltJsonFile -Path $planPath
    Assert-AdltPlanContract -Plan $plan
    $events = @(Read-AdltRunEventLog -Path $eventLogPath)
    Assert-AdltInitialRunStateSeedBinding `
        -Seed $events[0].data.state `
        -Plan $plan `
        -RunEvent $events[0]
    $replayed = ConvertFrom-AdltRunEventLog -RunEvents $events

    if ($replayed.mode -cne 'local') {
        throw 'A protected local run store requires state mode local.'
    }
    if (
        [int] $replayed.generation -ne 0 -or
        @($events | Where-Object { [int] $_.generation -ne 0 }).Count -gt 0
    ) {
        throw 'A protected local run store requires generation zero.'
    }
    if (
        $replayed.planHash -cne $plan.planHash -or
        $replayed.intentHash -cne $plan.intentHash
    ) {
        throw 'Run event state does not match the immutable plan binding.'
    }
    $tailEvent = $events[-1]
    if (
        $tailEvent.runId -cne $replayed.runId -or
        $tailEvent.planHash -cne $replayed.planHash -or
        $tailEvent.intentHash -cne $replayed.intentHash
    ) {
        throw 'Run event tail does not match the run binding.'
    }

    $evidence = @(Get-AdltVerifiedRunEvidence `
        -EvidencePath (Join-Path $RunPath 'evidence') `
        -State $replayed)
    $artifacts = @(Get-AdltVerifiedRunArtifact `
        -ArtifactPath (Join-Path $RunPath 'artifacts') `
        -State $replayed `
        -Events $events)

    if ([System.IO.File]::Exists($snapshotPath)) {
        Assert-AdltLocalStoreEntry -Path $snapshotPath -Type File
        $snapshot = Read-AdltJsonFile -Path $snapshotPath
        Assert-AdltRunState -State $snapshot
        if (
            $snapshot.runId -cne $replayed.runId -or
            $snapshot.planHash -cne $replayed.planHash -or
            $snapshot.intentHash -cne $replayed.intentHash -or
            $snapshot.mode -cne 'local' -or
            [int] $snapshot.generation -ne 0
        ) {
            throw 'Run snapshot does not match the authoritative run binding.'
        }
    }
    else {
        $snapshot = $null
    }

    if (
        $null -eq $snapshot -or
        $snapshot.stateHash -cne $replayed.stateHash
    ) {
        [void] (Write-AdltPrivateAtomicText `
            -Path $snapshotPath `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $replayed) `
            -Force)
    }

    return [pscustomobject]@{
        Plan      = $plan
        State     = $replayed
        Replayed  = $replayed
        Events    = $events
        Evidence  = $evidence
        Artifacts = $artifacts
        TailEvent = $tailEvent
    }
}

function Assert-AdltLocalMutationGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $CurrentGeneration,

        [AllowNull()]
        [Nullable[int]] $RequestedGeneration
    )

    if ($null -eq $RequestedGeneration) {
        return $CurrentGeneration
    }
    $requestedValue = [int] $RequestedGeneration
    if ($requestedValue -lt $CurrentGeneration) {
        throw "Run generation regression from '$CurrentGeneration' to '$requestedValue' is not allowed."
    }
    if ($requestedValue -gt $CurrentGeneration) {
        throw "Run generation '$requestedValue' does not match current generation '$CurrentGeneration'."
    }
    return $requestedValue
}

function Assert-AdltLocalMutationNotExpired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [datetimeoffset] $OccurredAt,

        [switch] $Cleanup
    )

    $expiresAt = [datetimeoffset]::Parse(
        [string] $State.expiresAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if ($OccurredAt -ge $expiresAt -and -not $Cleanup.IsPresent) {
        throw "Run '$($State.runId)' is expired; only cleanup transitions are allowed."
    }
}

function Add-AdltLocalRunEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence,

        [Parameter(Mandatory)]
        [ValidateSet('interactive-user', 'oidc', 'managed-identity', 'toolkit')]
        [string] $ActorType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [switch] $RebindGeneratedEvidence,

        [AllowNull()]
        [Nullable[int]] $Generation,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $fullRunPath = Assert-AdltLocalStorePath -Path $RunPath
    Assert-AdltLocalStoreEntry -Path $fullRunPath -Type Directory
    $lock = Open-AdltLocalRunLock -RunPath $fullRunPath
    $evidenceFilePath = $null
    $pendingEvidencePath = $null
    $eventAppended = $false
    try {
        $context = Get-AdltVerifiedLocalRunContext -RunPath $fullRunPath
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath
        $cleanupEvidence = $Evidence.stage -in @(
            'deploy'
            'teardown'
            'cleanup-proof'
        )
        Assert-AdltLocalMutationNotExpired `
            -State $context.State `
            -OccurredAt $OccurredAt `
            -Cleanup:$cleanupEvidence
        $eventGeneration = Assert-AdltLocalMutationGeneration `
            -CurrentGeneration ([int] $context.State.generation) `
            -RequestedGeneration $Generation

        if ($RebindGeneratedEvidence.IsPresent) {
            $Evidence = New-AdltChainedEvidence `
                -Evidence $Evidence `
                -Sequence @($context.Evidence).Count `
                -PreviousEvidenceHash $context.Evidence[-1].evidenceHash
        }
        Assert-AdltEvidence -Evidence $Evidence
        if (
            $Evidence.runId -cne $context.State.runId -or
            $Evidence.planHash -cne $context.State.planHash -or
            $Evidence.intentHash -cne $context.State.intentHash
        ) {
            throw 'Evidence does not match the exact run, plan, and intent binding.'
        }
        if (
            @($context.Evidence).evidenceHash -contains
                $Evidence.evidenceHash -or
            @($context.Evidence).eventId -contains $Evidence.eventId
        ) {
            throw "Evidence '$($Evidence.evidenceHash)' is already attached."
        }

        $expectedEvidenceSequence = @($context.Evidence).Count
        $previousEvidenceHash = [string] $context.Evidence[-1].evidenceHash
        if ([int] $Evidence.sequence -ne $expectedEvidenceSequence) {
            throw "Evidence sequence must continue at '$expectedEvidenceSequence'."
        }
        if ($Evidence.previousEventHash -cne $previousEvidenceHash) {
            throw 'Evidence previousEventHash does not continue the evidence chain.'
        }

        $evidenceFileName = Get-AdltEvidenceFileName -Evidence $Evidence
        $evidenceFilePath = Join-Path `
            (Join-Path $fullRunPath 'evidence') `
            $evidenceFileName
        $pendingEvidencePath = '{0}.pending' -f $evidenceFilePath
        [void] (Write-AdltPrivateAtomicText `
            -Path $pendingEvidencePath `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $Evidence))

        $runEvent = New-AdltRunEvent `
            -RunId $context.State.runId `
            -PlanHash $context.State.planHash `
            -IntentHash $context.State.intentHash `
            -Sequence ($context.Events.Count + 1) `
            -Generation $eventGeneration `
            -PreviousEventHash $context.TailEvent.eventHash `
            -EventType evidence-attached `
            -ActorType $ActorType `
            -ActorId $ActorId `
            -Data ([ordered]@{
                evidence = [ordered]@{
                    stage        = $Evidence.stage
                    evidenceHash = $Evidence.evidenceHash
                }
            }) `
            -OccurredAt $OccurredAt
        Write-AdltRunEventLog `
            -Path (Join-Path $fullRunPath 'events.ndjson') `
            -RunEvent $runEvent
        $eventAppended = $true
        [System.IO.File]::Move(
            $pendingEvidencePath,
            $evidenceFilePath,
            $false
        )
        $pendingEvidencePath = $null
        Set-AdltPrivatePathMode -Path $evidenceFilePath -Type File

        $state = Invoke-AdltRunEventProjection `
            -State $context.Replayed `
            -RunEvent $runEvent
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $fullRunPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
            -Force)
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath

        return [pscustomobject]@{
            RunId       = $state.runId
            StatePath   = $fullRunPath
            State       = $state
            Evidence    = Copy-AdltValue -InputObject $Evidence
            RunEvent    = $runEvent
            EvidencePath = $evidenceFilePath
        }
    }
    catch {
        if (
            -not $eventAppended -and
            -not [string]::IsNullOrWhiteSpace($pendingEvidencePath) -and
            [System.IO.File]::Exists($pendingEvidencePath)
        ) {
            [System.IO.File]::Delete($pendingEvidencePath)
        }
        throw
    }
    finally {
        $lock.Dispose()
    }
}

function Add-AdltLocalRunStatusTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [string] $Status,

        [Parameter(Mandatory)]
        [ValidateSet('interactive-user', 'oidc', 'managed-identity', 'toolkit')]
        [string] $ActorType,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [AllowNull()]
        [Nullable[int]] $Generation,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $fullRunPath = Assert-AdltLocalStorePath -Path $RunPath
    Assert-AdltLocalStoreEntry -Path $fullRunPath -Type Directory
    $lock = Open-AdltLocalRunLock -RunPath $fullRunPath
    try {
        $context = Get-AdltVerifiedLocalRunContext -RunPath $fullRunPath
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath
        $isCleanup = Test-AdltCleanupRunStatus -Status $Status
        Assert-AdltLocalMutationNotExpired `
            -State $context.State `
            -OccurredAt $OccurredAt `
            -Cleanup:$isCleanup
        Assert-AdltRunStatusTransition `
            -CurrentStatus ([string] $context.State.status) `
            -NextStatus $Status
        $eventGeneration = Assert-AdltLocalMutationGeneration `
            -CurrentGeneration ([int] $context.State.generation) `
            -RequestedGeneration $Generation
        $eventType = if ($isCleanup) {
            'cleanup-status-changed'
        }
        else {
            'status-changed'
        }

        $runEvent = New-AdltRunEvent `
            -RunId $context.State.runId `
            -PlanHash $context.State.planHash `
            -IntentHash $context.State.intentHash `
            -Sequence ($context.Events.Count + 1) `
            -Generation $eventGeneration `
            -PreviousEventHash $context.TailEvent.eventHash `
            -EventType $eventType `
            -ActorType $ActorType `
            -ActorId $ActorId `
            -Data ([ordered]@{ status = $Status }) `
            -OccurredAt $OccurredAt
        Write-AdltRunEventLog `
            -Path (Join-Path $fullRunPath 'events.ndjson') `
            -RunEvent $runEvent
        $state = Invoke-AdltRunEventProjection `
            -State $context.Replayed `
            -RunEvent $runEvent
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $fullRunPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
            -Force)
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath

        return [pscustomobject]@{
            RunId     = $state.runId
            StatePath = $fullRunPath
            State     = $state
            RunEvent  = $runEvent
        }
    }
    finally {
        $lock.Dispose()
    }
}

function Add-AdltLocalPreflightBlockedEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RunPath,

        [Parameter(Mandatory)]
        [ValidateSet(
            'live-resolution',
            'what-if',
            'cost',
            'teardown-preview'
        )]
        [string] $Stage,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ActorId,

        [datetimeoffset] $OccurredAt = [datetimeoffset]::UtcNow
    )

    $fullRunPath = Assert-AdltLocalStorePath -Path $RunPath
    Assert-AdltLocalStoreEntry -Path $fullRunPath -Type Directory
    $lock = Open-AdltLocalRunLock -RunPath $fullRunPath
    try {
        $context = Get-AdltVerifiedLocalRunContext -RunPath $fullRunPath
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath
        Assert-AdltLocalMutationNotExpired `
            -State $context.State `
            -OccurredAt $OccurredAt
        Assert-AdltRunStatusTransition `
            -CurrentStatus ([string] $context.State.status) `
            -NextStatus blocked

        $runEvent = New-AdltRunEvent `
            -RunId $context.State.runId `
            -PlanHash $context.State.planHash `
            -IntentHash $context.State.intentHash `
            -Sequence ($context.Events.Count + 1) `
            -Generation ([int] $context.State.generation) `
            -PreviousEventHash $context.TailEvent.eventHash `
            -EventType preflight-blocked `
            -ActorType toolkit `
            -ActorId $ActorId `
            -Data ([ordered]@{
                status = 'blocked'
                stage  = $Stage
            }) `
            -OccurredAt $OccurredAt
        Write-AdltRunEventLog `
            -Path (Join-Path $fullRunPath 'events.ndjson') `
            -RunEvent $runEvent
        $state = Invoke-AdltRunEventProjection `
            -State $context.Replayed `
            -RunEvent $runEvent
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $fullRunPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state) `
            -Force)
        Set-AdltPrivateRunStoreMode -RunPath $fullRunPath

        return [pscustomobject]@{
            RunId     = $state.runId
            StatePath = $fullRunPath
            State     = $state
            RunEvent  = $runEvent
        }
    }
    finally {
        $lock.Dispose()
    }
}

function New-AdltLocalRunStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan,

        [Parameter(Mandatory)]
        [string] $StateRoot,

        [datetimeoffset] $CreatedAt = [datetimeoffset]::UtcNow
    )

    Assert-AdltPlanContract -Plan $Plan
    $rootPath = Assert-AdltLocalStorePath -Path $StateRoot
    [void] (New-AdltPrivateDirectory -Path $rootPath)

    $runId = [guid]::NewGuid().ToString()
    $runPath = Join-Path $rootPath $runId
    if ([System.IO.Directory]::Exists($runPath)) {
        throw "Run state path '$runPath' already exists."
    }
    [void] (New-AdltPrivateDirectory -Path $runPath)

    $lock = $null
    try {
        $lock = Open-AdltLocalRunLock -RunPath $runPath
        $planEvidence = New-AdltEvidence `
            -RunId $runId `
            -PlanHash $Plan.planHash `
            -IntentHash $Plan.intentHash `
            -Stage plan `
            -Status pass `
            -Payload ([ordered]@{
                resourceCount              = @($Plan.resources).Count
                actionCount                = @($Plan.actions).Count
                blockingFindingIds         = @($Plan.approval.blockingFindingIds)
                requiredAcknowledgementIds = @(
                    $Plan.approval.requiredAcknowledgementIds
                )
            }) `
            -StartedAt $createdAt `
            -CompletedAt $createdAt
        $seed = New-AdltInitialRunStateSeed `
            -Plan $Plan `
            -RunId $runId `
            -PlanEvidence $planEvidence `
            -CreatedAt $createdAt
        $runEvent = New-AdltRunEvent `
            -RunId $runId `
            -PlanHash $Plan.planHash `
            -IntentHash $Plan.intentHash `
            -Sequence 1 `
            -Generation 0 `
            -EventType run-created `
            -ActorType toolkit `
            -ActorId 'AzureDataLabToolkit' `
            -Data ([ordered]@{ state = $seed }) `
            -OccurredAt $createdAt
        Assert-AdltInitialRunStateSeedBinding `
            -Seed $seed `
            -Plan $Plan `
            -RunEvent $runEvent
        $state = Invoke-AdltRunEventProjection `
            -State $null `
            -RunEvent $runEvent

        $evidencePath = Join-Path $runPath 'evidence'
        $artifactPath = Join-Path $runPath 'artifacts'
        [void] (New-AdltPrivateDirectory -Path $evidencePath)
        [void] (New-AdltPrivateDirectory -Path $artifactPath)

        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $runPath 'plan.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $Plan))

        Write-AdltRunEventLog `
            -Path (Join-Path $runPath 'events.ndjson') `
            -RunEvent $runEvent `
            -Create
        $evidenceFile = '0000-plan-{0}.json' -f
            $planEvidence.evidenceHash.Substring(7, 12)
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $evidencePath $evidenceFile) `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $planEvidence))
        [void] (Write-AdltPrivateAtomicText `
            -Path (Join-Path $runPath 'snapshot.json') `
            -Content (ConvertTo-AdltCanonicalJson -InputObject $state))

        return [pscustomobject]@{
            RunId     = $runId
            StatePath = $runPath
            State     = $state
        }
    }
    catch {
        if ($null -ne $lock) {
            $lock.Dispose()
            $lock = $null
        }
        if ([System.IO.Directory]::Exists($runPath)) {
            [System.IO.Directory]::Delete($runPath, $true)
        }
        throw
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}

function Get-AdltLocalRunStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $StateRoot,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId
    )

    $rootPath = Assert-AdltLocalStorePath -Path $StateRoot
    Assert-AdltLocalStoreEntry -Path $rootPath -Type Directory
    $runPath = Assert-AdltLocalStorePath -Path (Join-Path $rootPath $RunId)
    if (-not [System.IO.Directory]::Exists($runPath)) {
        throw "Run '$RunId' does not exist in '$rootPath'."
    }

    $lock = Open-AdltLocalRunLock -RunPath $runPath
    try {
        $context = Get-AdltVerifiedLocalRunContext -RunPath $runPath
        Set-AdltPrivateRunStoreMode -RunPath $runPath

        return [pscustomobject]@{
            RunId     = $RunId
            StatePath = $runPath
            State     = $context.State
        }
    }
    finally {
        $lock.Dispose()
    }
}
