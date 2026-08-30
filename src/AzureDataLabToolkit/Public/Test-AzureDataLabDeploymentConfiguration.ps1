function Test-AzureDataLabDeploymentConfiguration {
    <#
    .SYNOPSIS
    Proves that a configuration is statically eligible for one deployment profile.

    .DESCRIPTION
    Runs schema and semantic validation twice, verifies deterministic plan and
    intent hashes, checks the versioned deployment-profile hash, and applies the
    same fail-closed static compiler contract used by deployment. Azure live
    preflight and native ARM What-If are still required before execution.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [System.Collections.IDictionary] $InputObject,

        [Alias('Profile')]
        [ValidatePattern('^[a-z0-9-]+/v[0-9]+$')]
        [string] $DeploymentProfileId = 'sqlvm-first-canary/v1'
    )

    process {
        try {
            $planParameters = @{}
            if ($PSCmdlet.ParameterSetName -eq 'Path') {
                $planParameters.Path = $Path
            }
            else {
                $planParameters.InputObject =
                    Copy-AdltValue -InputObject $InputObject
            }

            $firstPlan = New-AzureDataLabPlan @planParameters
            $secondPlan = New-AzureDataLabPlan @planParameters
            if (
                [string] $firstPlan.planHash -cne
                    [string] $secondPlan.planHash -or
                [string] $firstPlan.intentHash -cne
                    [string] $secondPlan.intentHash
            ) {
                throw 'Repeated planning did not produce identical immutable hashes.'
            }

            $profileContract =
                Assert-AdltSqlVmStaticDeploymentEligibility `
                    -Plan $firstPlan `
                    -ProfileId $DeploymentProfileId
            return [pscustomobject][ordered]@{
                PSTypeName = (
                    'AzureDataLabToolkit.' +
                    'DeploymentConfigurationValidation'
                )
                Eligible               = $true
                ProfileId              = $profileContract.id
                ProfileHash            = $profileContract.profileHash
                PlanHash               = $firstPlan.planHash
                IntentHash             = $firstPlan.intentHash
                RequiresAzurePreflight = $true
                RequiredLiveChecks     = @(
                    $profileContract.requiredLiveChecks
                )
                Errors                 = @()
                Warnings               = @($firstPlan.warnings)
            }
        }
        catch {
            return [pscustomobject][ordered]@{
                PSTypeName = (
                    'AzureDataLabToolkit.' +
                    'DeploymentConfigurationValidation'
                )
                Eligible               = $false
                ProfileId              = $DeploymentProfileId
                ProfileHash            = $null
                PlanHash               = $null
                IntentHash             = $null
                RequiresAzurePreflight = $true
                RequiredLiveChecks     = @()
                Errors                 = @($_.Exception.Message)
                Warnings               = @()
            }
        }
    }
}
