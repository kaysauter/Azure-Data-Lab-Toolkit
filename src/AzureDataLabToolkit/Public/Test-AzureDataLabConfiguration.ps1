function Test-AzureDataLabConfiguration {
    <#
    .SYNOPSIS
    Validates and resolves an Azure Data Lab YAML configuration offline.

    .DESCRIPTION
    Applies schema defaults, a selected template, YAML values, and semantic
    policy checks without authenticating to Azure or performing network calls.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [System.Collections.IDictionary] $InputObject,

        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
        [string] $Template
    )

    process {
        try {
            $resolveParameters = @{
                Overrides = [ordered]@{}
            }
            if ($PSCmdlet.ParameterSetName -eq 'Path') {
                $resolveParameters.Path = $Path
            }
            else {
                $resolveParameters.InputObject = $InputObject
            }
            if ($PSBoundParameters.ContainsKey('Template')) {
                $resolveParameters.Template = $Template
            }

            $resolution = Resolve-AdltConfiguration @resolveParameters
            $plan = New-AdltTargetPlan `
                -Configuration $resolution.Configuration `
                -Provenance $resolution.Provenance

            [pscustomobject]@{
                PSTypeName    = 'AzureDataLabToolkit.ConfigurationValidation'
                Valid         = $true
                SchemaVersion = $resolution.Configuration.schemaVersion
                Template      = $resolution.Template
                TargetType    = $resolution.Configuration.target.type
                PlanHash      = $plan.planHash
                Errors        = @()
                Warnings      = @($plan.warnings)
            }
        }
        catch {
            [pscustomobject]@{
                PSTypeName    = 'AzureDataLabToolkit.ConfigurationValidation'
                Valid         = $false
                SchemaVersion = $null
                Template      = $null
                TargetType    = $null
                PlanHash      = $null
                Errors        = @($_.Exception.Message)
                Warnings      = @()
            }
        }
    }
}
