function Get-AdltCatalogItem {
    [CmdletBinding()]
    param()

    $catalogPath = Get-AdltDataPath -ChildPath 'Catalogs'
    $itemsById = [ordered]@{}

    foreach ($file in Get-ChildItem -LiteralPath $catalogPath -Filter '*.json' -File | Sort-Object -Property Name) {
        $catalog = Read-AdltJsonFile -Path $file.FullName
        $catalogValidation = Test-AdltObjectAgainstSchema `
            -InputObject $catalog `
            -SchemaPath (Get-AdltDataPath -ChildPath 'Schemas/catalog.schema.json')
        if (-not $catalogValidation.Valid) {
            throw "Catalog '$($file.Name)' failed schema validation."
        }

        if ($catalog.schemaVersion -ne '1.0' -or $catalog.kind -ne 'AzureDataLabCatalog') {
            throw "Catalog '$($file.Name)' does not use the supported catalog contract."
        }

        foreach ($item in @($catalog.items)) {
            $id = [string] $item.id
            if ([string]::IsNullOrWhiteSpace($id)) {
                throw "Catalog '$($file.Name)' contains an item without an ID."
            }

            if ($itemsById.Contains($id)) {
                throw "Duplicate catalog item ID '$id'."
            }

            if ([string]::IsNullOrWhiteSpace([string] $item.version)) {
                throw "Catalog item '$id' must pin an exact version."
            }

            if ([string] $item.source.uri -notmatch '^https://') {
                throw "Catalog item '$id' must use an HTTPS source URI."
            }

            if ([string]::IsNullOrWhiteSpace([string] $item.license.spdx)) {
                throw "Catalog item '$id' must declare an SPDX license identifier."
            }

            if (
                $item.integrity.status -eq 'verified' -and
                (
                    -not $item.integrity.Contains('digest') -or
                    [string] $item.integrity.digest -notmatch '^[a-f0-9]{64}$'
                )
            ) {
                throw "Catalog item '$id' cannot claim verified integrity without a SHA-256 digest."
            }

            $item.catalogType = $catalog.catalogType
            $itemsById[$id] = $item
        }
    }

    $ids = [string[]] @($itemsById.Keys)
    [System.Array]::Sort($ids, [System.StringComparer]::Ordinal)
    foreach ($id in $ids) {
        $itemsById[$id]
    }
}

function Get-AdltCatalogContractSet {
    [CmdletBinding()]
    param()

    $catalogPath = Get-AdltDataPath -ChildPath 'Catalogs'
    $contracts = foreach (
        $file in Get-ChildItem -LiteralPath $catalogPath -Filter '*.json' -File |
            Sort-Object -Property Name
    ) {
        $catalog = Read-AdltJsonFile -Path $file.FullName
        $catalogValidation = Test-AdltObjectAgainstSchema `
            -InputObject $catalog `
            -SchemaPath (Get-AdltDataPath -ChildPath 'Schemas/catalog.schema.json')
        if (-not $catalogValidation.Valid) {
            throw "Catalog '$($file.Name)' failed schema validation."
        }

        [ordered]@{
            catalogType  = $catalog.catalogType
            schemaVersion = $catalog.schemaVersion
            revision     = Get-AdltSha256Identifier -Value (
                ConvertTo-AdltCanonicalJson -InputObject $catalog
            )
        }
    }

    return @($contracts)
}

function Resolve-AdltCatalogSelection {
    [CmdletBinding()]
    param(
        [string[]] $SoftwareIds = @(),

        [string[]] $SampleDataIds = @(),

        [Parameter(Mandatory)]
        [string] $TargetType,

        [Parameter(Mandatory)]
        [string] $Platform,

        [Parameter(Mandatory)]
        [string] $SqlServerVersion
    )

    $catalog = [ordered]@{}
    foreach ($item in Get-AdltCatalogItem) {
        $catalog[[string] $item.id] = $item
    }

    $selections = [System.Collections.Generic.List[object]]::new()
    $requested = [System.Collections.Generic.List[object]]::new()

    foreach ($id in @($SoftwareIds)) {
        $requested.Add([pscustomobject]@{ Id = [string] $id; ExpectedType = 'software' })
    }

    foreach ($id in @($SampleDataIds)) {
        $requested.Add([pscustomobject]@{ Id = [string] $id; ExpectedType = 'sample-data' })
    }

    $requestedIds = [string[]] @($requested | ForEach-Object { $_.Id } | Select-Object -Unique)
    [System.Array]::Sort($requestedIds, [System.StringComparer]::Ordinal)

    foreach ($id in $requestedIds) {
        $request = $requested | Where-Object Id -CEQ $id | Select-Object -First 1
        if (-not $catalog.Contains($id)) {
            throw "Unknown catalog item '$id'. Use Find-AzureDataLabCatalogItem to discover exact IDs."
        }

        $item = $catalog[$id]
        if ($item.catalogType -ne $request.ExpectedType) {
            throw "Catalog item '$id' cannot be used as '$($request.ExpectedType)'."
        }
        if (@($item.compatibility.targetTypes) -notcontains $TargetType) {
            throw "Catalog item '$id' is not compatible with target '$TargetType'."
        }
        if ($item.catalogType -eq 'software' -and @($item.platforms) -notcontains $Platform) {
            throw "Catalog item '$id' is not compatible with platform '$Platform'."
        }
        if (
            $item.catalogType -eq 'sample-data' -and
            @($item.platforms) -notcontains ('sql-server-{0}' -f $SqlServerVersion)
        ) {
            throw "Catalog item '$id' is not compatible with SQL Server '$SqlServerVersion'."
        }

        $selections.Add([ordered]@{
            id                  = $item.id
            catalogType         = $item.catalogType
            displayName         = $item.displayName
            version             = $item.version
            publisher           = $item.publisher
            home                = $item.home
            attribution         = $item.attribution
            source              = $item.source
            license             = $item.license
            integrity           = $item.integrity
            privileges          = $item.privileges
            sensitivity         = $item.sensitivity
            compatibility       = $item.compatibility
            probes              = @($item.probes)
            supportStatus       = $item.supportStatus
            deploymentReadiness = if (
                $item.integrity.status -eq 'verified' -and
                $item.integrity.Contains('digest') -and
                [string] $item.integrity.digest -match '^[a-f0-9]{64}$'
            ) {
                'ready'
            }
            else {
                'blocked-pending-integrity'
            }
        })
    }

    return , $selections.ToArray()
}
