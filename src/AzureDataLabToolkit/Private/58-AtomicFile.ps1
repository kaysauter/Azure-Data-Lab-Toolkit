function Write-AdltAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Content,

        [switch] $Force,

        [switch] $Private
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($parentPath)) {
        throw "Output directory '$parentPath' does not exist."
    }

    if ([System.IO.File]::Exists($fullPath) -and -not $Force.IsPresent) {
        throw "Output file '$fullPath' already exists. Use -Force to replace it."
    }

    $temporaryPath = Join-Path -Path $parentPath -ChildPath (
        '.{0}.{1}.tmp' -f
            [System.IO.Path]::GetFileName($fullPath),
            [guid]::NewGuid().ToString('N')
    )
    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        if ($Private.IsPresent) {
            Set-AdltPrivatePathMode `
                -Path $temporaryPath `
                -Type File
        }
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [System.IO.File]::Move($temporaryPath, $fullPath, $Force.IsPresent)
        if ($Private.IsPresent) {
            Assert-AdltPrivatePathMode `
                -Path $fullPath `
                -Type File
        }
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }

    return $fullPath
}
