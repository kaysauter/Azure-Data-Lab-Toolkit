function Get-AdltSqlVmImageMatrix {
    [CmdletBinding()]
    param()

    $matrixPath = Get-AdltDataPath -ChildPath 'Support/sqlvm-image-matrix.json'
    $matrix = Read-AdltJsonFile -Path $matrixPath
    $validation = Test-AdltObjectAgainstSchema `
        -InputObject $matrix `
        -SchemaPath (
            Get-AdltDataPath -ChildPath 'Schemas/sqlvm-image-matrix.schema.json'
        )
    if (-not $validation.Valid) {
        throw 'The SQL VM image matrix failed schema validation.'
    }

    return $matrix
}

function Get-AdltSqlVmImageReference {
    <#
    .SYNOPSIS
    Resolves the marketplace image for a SQL VM configuration, failing closed.

    .DESCRIPTION
    The marketplace keeps one image per operating-system, SQL-version, and
    edition combination, so the offer fuses the Windows Server version with the
    SQL Server version and the sku carries the edition. Only the combinations
    recorded in Support/sqlvm-image-matrix.json exist; anything else throws
    rather than compiling to an image reference Azure would reject.

    The returned version is deliberately 'unresolved'. Live resolution pins the
    immutable version later and verifies the triple against the marketplace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [System.Collections.IDictionary] $Matrix
    )

    if ($null -eq $Matrix) {
        $Matrix = Get-AdltSqlVmImageMatrix
    }

    $platform = [string] $Configuration.sqlVm.platform
    $sqlServerVersion = [string] $Configuration.sqlVm.sqlServerVersion
    $sqlEdition = [string] $Configuration.sqlVm.sqlEdition
    $windowsServerVersion = [string] (
        Get-AdltPathValue `
            -InputObject $Configuration `
            -Path 'sqlVm.windowsServerVersion'
    )

    $candidates = @(
        $Matrix.images |
            Where-Object {
                [string] $_.platform -ceq $platform -and
                [string] $_.sqlServerVersion -ceq $sqlServerVersion -and
                [string] $_.sqlEdition -ceq $sqlEdition -and
                (
                    [string]::IsNullOrEmpty($windowsServerVersion) -or
                    [string] $_.windowsServerVersion -ceq $windowsServerVersion
                )
            }
    )

    if ($candidates.Count -eq 0) {
        throw (
            'No reviewed SQL VM marketplace image matches platform ' +
            "'$platform', SQL Server '$sqlServerVersion', edition " +
            "'$sqlEdition'. Add a reviewed entry to " +
            'Support/sqlvm-image-matrix.json only after confirming the offer ' +
            'and sku exist in the marketplace.'
        )
    }
    if ($candidates.Count -ne 1) {
        throw (
            'The SQL VM image matrix is ambiguous for platform ' +
            "'$platform', SQL Server '$sqlServerVersion', edition " +
            "'$sqlEdition'."
        )
    }

    $image = $candidates[0]
    return [pscustomobject]@{
        Publisher            = [string] $Matrix.publisher
        Offer                = [string] $image.offer
        Sku                  = [string] $image.sku
        SqlImageOffer        = [string] $image.sqlImageOffer
        SqlImageSku          = [string] $image.sqlImageSku
        WindowsServerVersion = [string] $image.windowsServerVersion
        LicenseCharge        = [string] $image.licenseCharge
    }
}

function New-AdltSqlVmImageReferenceProperty {
    <#
    .SYNOPSIS
    Builds the plan's imageReference desired-property block from a resolved
    marketplace image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Image
    )

    return [ordered]@{
        publisher       = [string] $Image.Publisher
        offer           = [string] $Image.Offer
        sku             = [string] $Image.Sku
        version         = 'unresolved'
        sourceAlias     = 'latest'
        resolutionStage = 'what-if'
    }
}
