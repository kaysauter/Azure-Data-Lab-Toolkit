function Find-AzureDataLabCatalogItem {
    <#
    .SYNOPSIS
    Searches the bundled offline software and sample-data catalogs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Id,

        [ValidateSet('software', 'sample-data')]
        [string] $CatalogType,

        [string[]] $Tag,

        [ValidateSet('windows', 'sql-server-2022', 'sql-server-2025')]
        [string] $Platform
    )

    $items = @(Get-AdltCatalogItem)
    if ($PSBoundParameters.ContainsKey('Id')) {
        $items = @($items | Where-Object { $_.id -ceq $Id })
    }
    if ($PSBoundParameters.ContainsKey('CatalogType')) {
        $items = @($items | Where-Object { $_.catalogType -ceq $CatalogType })
    }
    if ($PSBoundParameters.ContainsKey('Tag')) {
        foreach ($requiredTag in $Tag) {
            $items = @($items | Where-Object { @($_.tags) -contains $requiredTag })
        }
    }
    if ($PSBoundParameters.ContainsKey('Platform')) {
        $items = @($items | Where-Object { @($_.platforms) -contains $Platform })
    }

    foreach ($item in $items) {
        [pscustomobject]@{
            PSTypeName    = 'AzureDataLabToolkit.CatalogItem'
            Id            = $item.id
            CatalogType   = $item.catalogType
            DisplayName   = $item.displayName
            Version       = $item.version
            Tags          = @($item.tags)
            Platforms     = @($item.platforms)
            SourceUri     = $item.source.uri
            License       = $item.license.spdx
            LicenseUri    = $item.license.uri
            Integrity     = $item.integrity.status
            SupportStatus = $item.supportStatus
        }
    }
}
