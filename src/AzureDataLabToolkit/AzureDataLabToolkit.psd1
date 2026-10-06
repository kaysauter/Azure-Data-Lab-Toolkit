@{
    RootModule           = 'AzureDataLabToolkit.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '4e98f616-0205-4df0-9241-d34915951423'
    Author               = 'Kay Sauter'
    CompanyName          = 'Community'
    Copyright            = '(c) 2026 Kay Sauter. All rights reserved.'
    Description          = 'Offline configuration, validation, and planning foundation for Azure Data Lab Toolkit.'
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
            ReleaseNotes = 'Introduces the installable offline configuration and deterministic planning foundation.'
        }
    }
}
