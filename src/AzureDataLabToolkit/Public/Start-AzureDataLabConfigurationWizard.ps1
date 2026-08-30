function Start-AzureDataLabConfigurationWizard {
    <#
    .SYNOPSIS
    Opens the offline browser-based YAML configuration wizard.

    .DESCRIPTION
    Stages a self-contained HTML, CSS, and JavaScript bundle in a private
    temporary directory. The wizard performs no network requests and never
    accepts a password, token, or secret value.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Alias('Profile')]
        [ValidatePattern('^[a-z0-9-]+/v[0-9]+$')]
        [string] $DeploymentProfileId = 'sqlvm-first-canary/v1',

        [switch] $NoLaunch
    )

    $bundle = New-AdltConfigurationWizardBundle `
        -ProfileId $DeploymentProfileId
    $uri = [uri]::new([System.IO.Path]::GetFullPath($bundle.IndexPath))
    $launched = $false
    if (-not $NoLaunch.IsPresent) {
        if ($PSCmdlet.ShouldProcess(
            $uri.AbsoluteUri,
            'Open the offline Azure Data Lab configuration wizard'
        )) {
            Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop
            $launched = $true
        }
    }

    return [pscustomobject][ordered]@{
        PSTypeName  = 'AzureDataLabToolkit.ConfigurationWizard'
        Status      = if ($launched) { 'launched' } else { 'ready' }
        ProfileId   = $bundle.ProfileId
        ProfileHash = $bundle.ProfileHash
        Path        = $bundle.IndexPath
        Uri         = $uri.AbsoluteUri
        NetworkMode = 'offline'
    }
}
