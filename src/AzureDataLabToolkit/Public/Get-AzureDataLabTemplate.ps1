function Get-AzureDataLabTemplate {
    <#
    .SYNOPSIS
    Lists or reads the YAML templates bundled with the module.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [string])]
    param(
        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
        [string] $Name,

        [switch] $AsYaml
    )

    $templatePath = Get-AdltDataPath -ChildPath 'Templates'
    $files = @(Get-ChildItem -LiteralPath $templatePath -Filter '*.yaml' -File | Sort-Object -Property Name)
    if ($PSBoundParameters.ContainsKey('Name')) {
        $files = @($files | Where-Object BaseName -CEQ $Name)
        if ($files.Count -eq 0) {
            throw "Unknown Azure Data Lab template '$Name'."
        }
    }

    foreach ($file in $files) {
        if ($AsYaml.IsPresent) {
            [System.IO.File]::ReadAllText($file.FullName)
            continue
        }

        $template = Read-AdltYamlFile -Path $file.FullName
        [pscustomobject]@{
            PSTypeName = 'AzureDataLabToolkit.Template'
            Name       = $file.BaseName
            TargetType = $template.target.type
            Engine     = $template.engine.type
            Path       = $file.FullName
        }
    }
}
