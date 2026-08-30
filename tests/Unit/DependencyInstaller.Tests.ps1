BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:InstallerPath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/Install-AzureDataLabToolkitDependencies.ps1'
    $script:LockPath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/Support/runtime-dependencies.lock.json'

    . $script:InstallerPath

    function Install-TestPSResource {
        [CmdletBinding(SupportsShouldProcess)]
        param(
            [string] $Name,
            [string] $Version,
            [string] $Repository,
            [string] $Scope,
            [switch] $SkipDependencyCheck,
            [switch] $Quiet,
            [switch] $Reinstall,
            [switch] $TrustRepository,
            [switch] $AcceptLicense,
            [switch] $AuthenticodeCheck
        )

        if ($PSCmdlet.ShouldProcess($Name, 'Record test install')) {
            $script:InstallCalls.Add(
                [pscustomobject]@{
                    Name                = $Name
                    Version             = $Version
                    Repository          = $Repository
                    Scope               = $Scope
                    SkipDependencyCheck = [bool] $SkipDependencyCheck
                    Quiet               = [bool] $Quiet
                    Reinstall           = [bool] $Reinstall
                    TrustRepository     = [bool] $TrustRepository
                    AcceptLicense       = [bool] $AcceptLicense
                    AuthenticodeCheck   = [bool] $AuthenticodeCheck
                }
            )
        }
    }

    function Get-TestPSResourceRepository {
        [CmdletBinding()]
        param(
            [string] $Name
        )

        return [pscustomobject]@{
            Name              = $Name
            Uri               = $script:RepositoryUri
            Trusted           = $script:RepositoryTrusted
            IsAllowedByPolicy = $script:RepositoryAllowed
        }
    }

    function Get-TestInstalledPSResource {
        [CmdletBinding()]
        param(
            [string] $Name,
            [string] $Version,
            [string] $Scope
        )

        return [pscustomobject]@{
            Name              = $Name
            Version           = $Version
            Repository        = $script:InstalledRepository
            Type              = 'Module'
            InstalledLocation = Join-Path $TestDrive $Name
            Scope             = $Scope
        }
    }
}

Describe 'Standalone dependency installer lock' {
    It 'parses as PowerShell 7.6 code' {
        $tokens = $null
        $parseErrors = $null
        [void] (
            [System.Management.Automation.Language.Parser]::ParseFile(
                $script:InstallerPath,
                [ref] $tokens,
                [ref] $parseErrors
            )
        )

        @($parseErrors) | Should -BeNullOrEmpty
    }

    It 'loads exactly the six expected locked dependencies' {
        $lock = Read-AdltDependencyInstallerLock `
            -Path $script:LockPath `
            -Repository PSGallery

        @($lock.dependencies).name | Should -BeExactly @(
            'Az.Accounts'
            'Az.Compute'
            'Az.KeyVault'
            'Az.Monitor'
            'Az.Resources'
            'powershell-yaml'
        )
        @($lock.dependencies).version | ForEach-Object {
            $_ | Should -Match '^\d+\.\d+\.\d+(?:\.\d+)?$'
            $_ | Should -Not -Match '[\[\]\(\),*]'
        }
    }

    It 'rejects a repository that differs from the reviewed lock source' {
        {
            Read-AdltDependencyInstallerLock `
                -Path $script:LockPath `
                -Repository InternalGallery
        } | Should -Throw "*entry 'Az.Accounts' is invalid*"
    }

    It 'rejects malformed or incomplete lock content' {
        $invalidPath = Join-Path $TestDrive 'invalid-lock.json'
        [System.IO.File]::WriteAllText(
            $invalidPath,
            '{"schemaVersion":"1.0","dependencies":[]}',
            [System.Text.UTF8Encoding]::new($false)
        )

        {
            Read-AdltDependencyInstallerLock `
                -Path $invalidPath `
                -Repository PSGallery
        } | Should -Throw '*invalid top-level contract*'
    }
}

Describe 'PSResourceGet bootstrap boundary' {
    AfterEach {
        Remove-Module `
            -Name Microsoft.PowerShell.PSResourceGet `
            -Force `
            -ErrorAction SilentlyContinue
    }

    It 'fails closed when the PowerShell-bundled trust root is absent' {
        $emptyHome = Join-Path $TestDrive 'empty-powershell-home'
        [void] (New-Item -ItemType Directory -Path $emptyHome)
        {
            Assert-AdltDependencyInstallerPSResourceGetTrust `
                -PowerShellHome $emptyHome
        } | Should -Throw
    }

    It 'accepts the exact reviewed PSResourceGet bundled with PowerShell' {
        $trusted = Assert-AdltDependencyInstallerPSResourceGetTrust

        $trusted.Name |
            Should -BeExactly 'Microsoft.PowerShell.PSResourceGet'
        $trusted.Version | Should -Be ([version] '1.2.0')
        $trusted.Guid |
            Should -Be ([guid] 'e4e0bda1-0703-44a5-b70d-8fe704cd0643')
        $trusted.ContentDigest | Should -BeExactly (
            'sha256:' +
            '61521954557a52d5f70ecb267f43fa582805ff3df91b022a575459014f57b73f'
        )
        [System.IO.Path]::GetFullPath($trusted.ModuleBase) |
            Should -BeExactly (
                [System.IO.Path]::GetFullPath(
                    (Join-Path `
                        $PSHOME `
                        'Modules/Microsoft.PowerShell.PSResourceGet')
                )
            )
    }

    It 'loads only the reviewed PowerShell-bundled command identities' {
        $commands = Get-AdltDependencyInstallerPSResourceGet

        @($commands.Keys) | Should -BeExactly @(
            'Install-PSResource'
            'Get-PSResourceRepository'
            'Get-InstalledPSResource'
        )
        foreach ($command in $commands.Values) {
            $command.CommandType | Should -Be 'Cmdlet'
            $command.Module.Version | Should -Be ([version] '1.2.0')
            [System.IO.Path]::GetFullPath($command.Module.ModuleBase) |
                Should -BeExactly (
                    [System.IO.Path]::GetFullPath(
                        (Join-Path `
                            $PSHOME `
                            'Modules/Microsoft.PowerShell.PSResourceGet')
                    )
                )
        }
    }

    It 'ignores a malicious earlier PSModulePath substitution' {
        $maliciousRoot = Join-Path $TestDrive 'user-modules'
        $maliciousVersionRoot = Join-Path `
            $maliciousRoot `
            'Microsoft.PowerShell.PSResourceGet/99.0.0'
        [void] (
            New-Item `
                -ItemType Directory `
                -Path $maliciousVersionRoot `
                -Force
        )
        [System.IO.File]::WriteAllText(
            (Join-Path `
                $maliciousVersionRoot `
                'Microsoft.PowerShell.PSResourceGet.psd1'),
            @'
@{
    RootModule = 'Microsoft.PowerShell.PSResourceGet.psm1'
    ModuleVersion = '99.0.0'
    GUID = '11111111-1111-1111-1111-111111111111'
    FunctionsToExport = '*'
}
'@,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            (Join-Path `
                $maliciousVersionRoot `
                'Microsoft.PowerShell.PSResourceGet.psm1'),
            "throw 'The malicious PSModulePath module was executed.'",
            [System.Text.UTF8Encoding]::new($false)
        )

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = (
                $maliciousRoot +
                [System.IO.Path]::PathSeparator +
                $originalModulePath
            )
            $normallyDiscovered = @(
                Get-Module `
                    -ListAvailable `
                    -Name Microsoft.PowerShell.PSResourceGet
            )[0]
            [System.IO.Path]::GetFullPath(
                $normallyDiscovered.ModuleBase
            ) | Should -BeExactly (
                [System.IO.Path]::GetFullPath($maliciousVersionRoot)
            )

            $commands = Get-AdltDependencyInstallerPSResourceGet

            foreach ($command in $commands.Values) {
                [System.IO.Path]::GetFullPath($command.Module.ModuleBase) |
                    Should -BeExactly (
                        [System.IO.Path]::GetFullPath(
                            (Join-Path `
                                $PSHOME `
                                'Modules/Microsoft.PowerShell.PSResourceGet')
                        )
                    )
            }
        }
        finally {
            $env:PSModulePath = $originalModulePath
        }
    }

    It 'rejects modified bootstrap content before import' {
        $testHome = Join-Path $TestDrive 'modified-powershell-home'
        $moduleBase = Join-Path `
            $testHome `
            'Modules/Microsoft.PowerShell.PSResourceGet'
        [void] (New-Item -ItemType Directory -Path $moduleBase -Force)
        $manifestPath = Join-Path `
            $moduleBase `
            'Microsoft.PowerShell.PSResourceGet.psd1'
        $binaryPath = Join-Path `
            $moduleBase `
            'Microsoft.PowerShell.PSResourceGet.dll'
        [System.IO.File]::WriteAllText(
            $manifestPath,
            @'
@{
    RootModule = './Microsoft.PowerShell.PSResourceGet.dll'
    ModuleVersion = '1.2.0'
    GUID = 'e4e0bda1-0703-44a5-b70d-8fe704cd0643'
    Author = 'Microsoft Corporation'
    CompanyName = 'Microsoft Corporation'
}
'@,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllBytes(
            $binaryPath,
            [byte[]] @(1, 2, 3, 4)
        )
        $reviewed = Get-AdltDependencyInstallerContentDigest `
            -ModuleBase $moduleBase
        $trustRoot = [ordered]@{
            Name          = 'Microsoft.PowerShell.PSResourceGet'
            Version       = [version] '1.2.0'
            Guid          =
                [guid] 'e4e0bda1-0703-44a5-b70d-8fe704cd0643'
            Manifest      = 'Microsoft.PowerShell.PSResourceGet.psd1'
            FileCount     = $reviewed.FileCount
            ContentDigest = $reviewed.Digest
        }

        {
            Assert-AdltDependencyInstallerPSResourceGetTrust `
                -PowerShellHome $testHome `
                -TrustRoot $trustRoot
        } | Should -Not -Throw

        [System.IO.File]::WriteAllBytes(
            $binaryPath,
            [byte[]] @(4, 3, 2, 1)
        )
        {
            Assert-AdltDependencyInstallerPSResourceGetTrust `
                -PowerShellHome $testHome `
                -TrustRoot $trustRoot
        } | Should -Throw '*does not match the reviewed bootstrap trust root*'
    }

    It 'requires explicit per-command trust for an untrusted repository' {
        $script:RepositoryUri =
            'https://www.powershellgallery.com/api/v2'
        $script:RepositoryTrusted = $false
        $script:RepositoryAllowed = $true
        $lock = Read-AdltDependencyInstallerLock `
            -Path $script:LockPath `
            -Repository PSGallery
        $command = Get-Command Get-TestPSResourceRepository

        {
            Get-AdltDependencyInstallerRepository `
                -Command $command `
                -Name PSGallery `
                -Lock $lock
        } | Should -Throw '*Pass -TrustRepository*'

        {
            Get-AdltDependencyInstallerRepository `
                -Command $command `
                -Name PSGallery `
                -Lock $lock `
                -TrustRepository
        } | Should -Not -Throw
    }

    It 'rejects a registered repository with a different source URI' {
        $script:RepositoryUri = 'https://packages.example.test/api/v2'
        $script:RepositoryTrusted = $true
        $script:RepositoryAllowed = $true
        $lock = Read-AdltDependencyInstallerLock `
            -Path $script:LockPath `
            -Repository PSGallery

        {
            Get-AdltDependencyInstallerRepository `
                -Command (
                    Get-Command Get-TestPSResourceRepository
                ) `
                -Name PSGallery `
                -Lock $lock
        } | Should -Throw '*unexpected source URI*'
    }

    It 'rejects installed metadata from a different repository' {
        $script:InstalledRepository = 'InternalGallery'
        $lock = Read-AdltDependencyInstallerLock `
            -Path $script:LockPath `
            -Repository PSGallery

        {
            Get-AdltInstalledDependencyRecord `
                -Lock $lock `
                -Command (
                    Get-Command Get-TestInstalledPSResource
                ) `
                -Repository PSGallery `
                -Scope CurrentUser
        } | Should -Throw "*Az.Accounts*unexpected source*"
    }

    It 'contains no repository trust mutation commands' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:InstallerPath,
            [ref] $tokens,
            [ref] $parseErrors
        )
        $commands = @(
            $ast.FindAll(
                {
                    param($Node)
                    $Node -is
                        [System.Management.Automation.Language.CommandAst]
                },
                $true
            ) |
                ForEach-Object { $_.GetCommandName() }
        )

        $commands | Should -Not -Contain 'Set-PSResourceRepository'
        $commands | Should -Not -Contain 'Register-PSResourceRepository'
        $commands | Should -Not -Contain 'Unregister-PSResourceRepository'
        $commands | Should -Not -Contain 'Reset-PSResourceRepository'
    }
}

Describe 'Exact dependency installation' {
    BeforeEach {
        $script:InstallCalls =
            [System.Collections.Generic.List[object]]::new()
        $script:Lock = Read-AdltDependencyInstallerLock `
            -Path $script:LockPath `
            -Repository PSGallery
        $script:InstallCommand = Get-Command Install-TestPSResource
    }

    It 'installs every dependency at its exact locked version' {
        $count = Install-AdltLockedDependencySet `
            -Lock $script:Lock `
            -Command $script:InstallCommand `
            -Repository PSGallery `
            -Scope CurrentUser `
            -Confirm:$false

        $count | Should -Be 6
        $script:InstallCalls.Count | Should -Be 6
        for ($index = 0; $index -lt 6; $index++) {
            $call = $script:InstallCalls[$index]
            $dependency = @($script:Lock.dependencies)[$index]
            $call.Name | Should -BeExactly $dependency.name
            $call.Version | Should -BeExactly $dependency.version
            $call.Repository | Should -BeExactly 'PSGallery'
            $call.Scope | Should -BeExactly 'CurrentUser'
            $call.SkipDependencyCheck | Should -BeTrue
            $call.Quiet | Should -BeTrue
            $call.Reinstall | Should -BeFalse
            $call.TrustRepository | Should -BeFalse
            $call.AcceptLicense | Should -BeFalse
            $call.AuthenticodeCheck | Should -BeFalse
        }
    }

    It 'passes only explicit reinstall and trust-related switches' {
        [void] (
            Install-AdltLockedDependencySet `
                -Lock $script:Lock `
                -Command $script:InstallCommand `
                -Repository PSGallery `
                -Scope AllUsers `
                -Reinstall `
                -TrustRepository `
                -AcceptLicense `
                -AuthenticodeCheck `
                -Confirm:$false
        )

        foreach ($call in $script:InstallCalls) {
            $call.Scope | Should -BeExactly 'AllUsers'
            $call.Reinstall | Should -BeTrue
            $call.TrustRepository | Should -BeTrue
            $call.AcceptLicense | Should -BeTrue
            $call.AuthenticodeCheck | Should -BeTrue
        }
    }

    It 'does not install during WhatIf' {
        $count = Install-AdltLockedDependencySet `
            -Lock $script:Lock `
            -Command $script:InstallCommand `
            -Repository PSGallery `
            -Scope CurrentUser `
            -WhatIf

        $count | Should -Be 0
        $script:InstallCalls | Should -BeNullOrEmpty
    }
}

Describe 'Post-install content verification' {
    It 'imports the shipped module from the manifest directory' {
        $manifestPath = Join-Path `
            $script:RepositoryRoot `
            'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
        try {
            $module = Import-AdltDependencyInstallerModule `
                -ManifestPath $manifestPath

            $module.Name | Should -BeExactly 'AzureDataLabToolkit'
            [System.IO.Path]::GetFullPath($module.ModuleBase) |
                Should -BeExactly (
                    [System.IO.Path]::GetFullPath(
                        (Split-Path $manifestPath -Parent)
                    )
                )
        }
        finally {
            Remove-Module `
                -Name AzureDataLabToolkit `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'invokes the module content verifier for every lock entry' {
        $lock = Read-AdltDependencyInstallerLock `
            -Path $script:LockPath `
            -Repository PSGallery
        $locations = [ordered]@{}
        $installed = [ordered]@{}
        foreach ($dependency in @($lock.dependencies)) {
            $location = Join-Path $TestDrive $dependency.name
            $locations[$dependency.name] = $location
            $installed[$dependency.name] = [pscustomobject]@{
                InstalledLocation = $location
            }
        }

        $verificationModule = New-Module `
            -Name DependencyInstallerVerificationDouble `
            -ArgumentList $lock, $locations `
            -ScriptBlock {
                param($LockedDependencies, $ModuleLocations)

                $script:LockedDependencies = $LockedDependencies
                $script:ModuleLocations = $ModuleLocations
                $script:VerificationCalls =
                    [System.Collections.Generic.List[string]]::new()

                function Get-AdltRuntimeDependencyLock {
                    return $script:LockedDependencies
                }

                function Get-AdltVerifiedRuntimeDependency {
                    param([string] $Name)

                    $script:VerificationCalls.Add($Name)
                    $entry = @(
                        $script:LockedDependencies.dependencies |
                            Where-Object {
                                [string] $_.name -ceq $Name
                            }
                    )[0]
                    return [ordered]@{
                        name          = [string] $entry.name
                        version       = [string] $entry.version
                        guid          = (
                            [string] $entry.guid
                        ).ToLowerInvariant()
                        author        = [string] $entry.author
                        source        = [string] $entry.source
                        packageDigest = [string] $entry.packageDigest
                        contentDigest = [string] $entry.contentDigest
                        moduleBase    = [string] $script:ModuleLocations[$Name]
                    }
                }
            }

        $result = @(
            Test-AdltInstalledDependencyContent `
                -Module $verificationModule `
                -Lock $lock `
                -Installed $installed
        )
        $calls = @(
            & $verificationModule {
                return @($script:VerificationCalls)
            }
        )

        $result.Count | Should -Be 6
        @($result).Verified | Should -Not -Contain $false
        $calls | Should -BeExactly @($lock.dependencies).name
    }

    It 'fails when verified content resolves outside the installed location' {
        $lock = Read-AdltDependencyInstallerLock `
            -Path $script:LockPath `
            -Repository PSGallery
        $installed = [ordered]@{}
        foreach ($dependency in @($lock.dependencies)) {
            $installed[$dependency.name] = [pscustomobject]@{
                InstalledLocation = Join-Path `
                    $TestDrive `
                    $dependency.name
            }
        }
        $verificationModule = New-Module `
            -Name DependencyInstallerLocationMismatchDouble `
            -ArgumentList $lock `
            -ScriptBlock {
                param($LockedDependencies)

                $script:LockedDependencies = $LockedDependencies

                function Get-AdltRuntimeDependencyLock {
                    return $script:LockedDependencies
                }

                function Get-AdltVerifiedRuntimeDependency {
                    param([string] $Name)

                    $entry = @(
                        $script:LockedDependencies.dependencies |
                            Where-Object {
                                [string] $_.name -ceq $Name
                            }
                    )[0]
                    return [ordered]@{
                        name          = [string] $entry.name
                        version       = [string] $entry.version
                        guid          = (
                            [string] $entry.guid
                        ).ToLowerInvariant()
                        author        = [string] $entry.author
                        source        = [string] $entry.source
                        packageDigest = [string] $entry.packageDigest
                        contentDigest = [string] $entry.contentDigest
                        moduleBase    = Join-Path '/different' $Name
                    }
                }
            }

        {
            Test-AdltInstalledDependencyContent `
                -Module $verificationModule `
                -Lock $lock `
                -Installed $installed
        } | Should -Throw '*failed reviewed content verification*'
    }

    It 'propagates a failure from the existing content-lock verifier' {
        $lock = Read-AdltDependencyInstallerLock `
            -Path $script:LockPath `
            -Repository PSGallery
        $installed = [ordered]@{}
        foreach ($dependency in @($lock.dependencies)) {
            $installed[$dependency.name] = [pscustomobject]@{
                InstalledLocation = Join-Path `
                    $TestDrive `
                    $dependency.name
            }
        }
        $verificationModule = New-Module `
            -Name DependencyInstallerDigestFailureDouble `
            -ArgumentList $lock `
            -ScriptBlock {
                param($LockedDependencies)

                $script:LockedDependencies = $LockedDependencies

                function Get-AdltRuntimeDependencyLock {
                    return $script:LockedDependencies
                }

                function Get-AdltVerifiedRuntimeDependency {
                    param([string] $Name)

                    throw (
                        "reviewed package content digest mismatch for '$Name'"
                    )
                }
            }

        {
            Test-AdltInstalledDependencyContent `
                -Module $verificationModule `
                -Lock $lock `
                -Installed $installed
        } | Should -Throw '*reviewed package content digest mismatch*'
    }
}
