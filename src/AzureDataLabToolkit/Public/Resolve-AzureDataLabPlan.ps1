function Resolve-AzureDataLabPlan {
    <#
    .SYNOPSIS
    Resolves Azure-dependent SQL VM facts without changing Azure resources.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $Plan,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId
    )

    process {
        $startedAt = [datetimeoffset]::UtcNow
        $planDictionary = ConvertTo-AdltDictionary -InputObject $Plan
        $resolution = Invoke-AdltLiveResolution -Plan $planDictionary
        $status = Get-AdltEvidenceAggregateStatus -Probes @($resolution.probes)

        return New-AdltEvidence `
            -RunId $RunId `
            -PlanHash $planDictionary.planHash `
            -IntentHash $planDictionary.intentHash `
            -Stage live-resolution `
            -Status $status `
            -Probes @($resolution.probes) `
            -Payload ([ordered]@{
                context           = $resolution.context
                providerStates    = @($resolution.providerStates)
                imageResolution   = $resolution.imageResolution
                skuResolution     = $resolution.skuResolution
                keyVaultResolution = $resolution.keyVaultResolution
                secretMetadata     = $resolution.secretMetadata
                diagnosticResolution = $resolution.diagnosticResolution
                principalObjectId = $resolution.principalObjectId
                principalType     = $resolution.principalType
                requiredAuthorizations = @(
                    $resolution.requiredAuthorizations
                )
                resources         = @($resolution.resources)
                resolvedPolicyFindingIds = @(
                    $resolution.resolvedPolicyFindingIds
                )
            }) `
            -StartedAt $startedAt `
            -CompletedAt ([datetimeoffset]::UtcNow)
    }
}
