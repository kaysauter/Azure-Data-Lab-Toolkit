@{
    RootModule           = 'AzureDataLabToolkit.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '4e98f616-0205-4df0-9241-d34915951423'
    Author               = 'Kay Sauter'
    CompanyName          = 'Community'
    Copyright            = '(c) 2026 Kay Sauter. All rights reserved.'
    Description          = 'Plans, deploys, probes, and tears down SQL Server on Azure VM labs from versioned YAML. Alpha: it has never run against live Azure.'
    PowerShellVersion    = '7.6'
    CompatiblePSEditions = @('Core')

    FunctionsToExport = @(
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

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Azure', 'Data', 'Lab', 'SQLServer', 'Planning')
            LicenseUri   = 'https://github.com/kaysauter/Azure-Data-Lab-Toolkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/kaysauter/Azure-Data-Lab-Toolkit'
            Prerelease   = 'alpha1'
            ReleaseNotes = 'First alpha prerelease. Nothing in it has run against live Azure. See https://github.com/kaysauter/Azure-Data-Lab-Toolkit/releases/tag/v0.1.0-alpha1.'
        }
    }
}
