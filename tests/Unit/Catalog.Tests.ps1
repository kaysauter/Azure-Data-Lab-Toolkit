BeforeAll {
    $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
    $script:ModulePath = Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

Describe 'Metadata-only catalogs' {
    It 'returns exact IDs and versions without resolving latest at runtime' {
        $items = @(Find-AzureDataLabCatalogItem)

        $items.Count | Should -BeGreaterOrEqual 3
        $items.Id | Should -Contain 'software.dbatools'
        $items.Id | Should -Contain 'software.git-for-windows'
        $items.Id | Should -Contain 'sample-data.adventureworks-2022'
        $items.Version | Should -Not -Contain 'latest'
        $items.Version | Should -Not -Contain 'unresolved'
    }

    It 'requires HTTPS source and license links for every item' {
        foreach ($item in Find-AzureDataLabCatalogItem) {
            $item.SourceUri | Should -Match '^https://'
            $item.License | Should -Not -BeNullOrEmpty
            $item.LicenseUri | Should -Match '^https://'
            $item.SupportStatus | Should -Be 'metadata-only'
        }
    }

    It 'uses tags for discovery and returns exact IDs' {
        $restoreItems = @(Find-AzureDataLabCatalogItem -Tag restore)
        $restoreItems.Count | Should -Be 1
        $restoreItems[0].Id | Should -Be 'software.dbatools'
    }

    It 'rejects a verified-integrity claim without a digest' {
        $catalogPath = Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit/Catalogs/software.json'
        $schemaPath = Join-Path $script:RepositoryRoot 'src/AzureDataLabToolkit/Schemas/catalog.schema.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -Depth 100
        $catalog.items[0].integrity.status = 'verified'

        Test-Json `
            -Json ($catalog | ConvertTo-Json -Depth 100 -Compress) `
            -SchemaFile $schemaPath `
            -ErrorAction SilentlyContinue |
            Should -BeFalse
    }
}

Describe 'SQL VM support matrix' {
    It 'advertises plan support separately from deployment availability' {
        $matrix = Get-AzureDataLabSupportMatrix -Raw
        $matrix.contractStatus | Should -Be 'implemented'
        $matrix.deploymentStatus | Should -Be 'available'
        $matrix.guarantees.offlinePlan | Should -BeTrue
        $matrix.guarantees.azureMutation | Should -BeFalse
        $matrix.guarantees.automaticRestore | Should -BeFalse
    }

    It 'keeps unsupported capabilities explicit' {
        $entries = @(Get-AzureDataLabSupportMatrix)
        ($entries | Where-Object { $_.Axis -eq 'engine' -and $_.Value -eq 'bicep' }).Plan |
            Should -Be 'unsupported'
        ($entries | Where-Object { $_.Axis -eq 'securityType' -and $_.Value -eq 'confidentialVm' }).Deployment |
            Should -Be 'research'
    }
}
