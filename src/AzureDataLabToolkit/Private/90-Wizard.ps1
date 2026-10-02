function Get-AdltWizardCatalogData {
    [CmdletBinding()]
    param()

    return @(
        foreach ($itemValue in @(Get-AdltCatalogItem)) {
            $item = ConvertTo-AdltDictionary -InputObject $itemValue
            [ordered]@{
                id        = [string] $item.id
                type      = if (
                    [string] $item.id -like 'software.*'
                ) {
                    'software'
                }
                else {
                    'sample-data'
                }
                name      = [string] $item.displayName
                version   = [string] $item.version
                publisher = [string] $item.publisher
                tags      = @($item.tags | Sort-Object)
                status    = if (
                    [string] $item.supportStatus -ceq 'metadata-only'
                ) {
                    'planning-only'
                }
                else {
                    [string] $item.supportStatus
                }
            }
        }
    )
}

function New-AdltWizardDataScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DeploymentProfileContract
    )

    $payload = [ordered]@{
        profile = Copy-AdltValue -InputObject $DeploymentProfileContract
        catalog = @(Get-AdltWizardCatalogData)
    }
    return (
        '"use strict";' + [Environment]::NewLine +
        'window.AzureDataLabWizardData = ' +
        (ConvertTo-AdltCanonicalJson -InputObject $payload) +
        ';' + [Environment]::NewLine
    )
}

function New-AdltConfigurationWizardBundle {
    [CmdletBinding()]
    param(
        [string] $ProfileId = 'sqlvm-first-canary/v1'
    )

    $deploymentProfileContract =
        Get-AdltDeploymentProfile -Id $ProfileId
    $sourceRoot = Get-AdltDataPath -ChildPath 'Wizard'
    $requiredFiles = @(
        'index.html'
        'wizard.css'
        'wizard-core.js'
        'wizard.js'
    )
    foreach ($fileName in $requiredFiles) {
        $sourcePath = Join-Path $sourceRoot $fileName
        if (-not [System.IO.File]::Exists($sourcePath)) {
            throw "Configuration wizard asset '$fileName' is missing."
        }
    }

    $bundleRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ('adlt-wizard-{0}' -f [guid]::NewGuid().ToString('N'))
    [void] [System.IO.Directory]::CreateDirectory($bundleRoot)
    Set-AdltPrivatePathMode -Path $bundleRoot -Type Directory
    try {
        foreach ($fileName in $requiredFiles) {
            $destinationPath = Join-Path $bundleRoot $fileName
            [System.IO.File]::Copy(
                (Join-Path $sourceRoot $fileName),
                $destinationPath,
                $false
            )
            Set-AdltPrivatePathMode -Path $destinationPath -Type File
        }
        $dataPath = Join-Path $bundleRoot 'wizard-data.js'
        [void] (Write-AdltPrivateAtomicText `
            -Path $dataPath `
            -Content (
                New-AdltWizardDataScript `
                    -DeploymentProfileContract $deploymentProfileContract
            ))
        Set-AdltPrivatePathMode -Path $dataPath -Type File
    }
    catch {
        [System.IO.Directory]::Delete($bundleRoot, $true)
        throw
    }

    return [pscustomobject][ordered]@{
        Root        = $bundleRoot
        IndexPath   = Join-Path $bundleRoot 'index.html'
        ProfileId   = $deploymentProfileContract.id
        ProfileHash = $deploymentProfileContract.profileHash
    }
}
