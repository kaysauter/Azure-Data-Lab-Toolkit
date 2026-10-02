function Test-AzureDataLabAzureContext {
    <#
    .SYNOPSIS
    Verifies that the active process-scoped Azure context matches a plan.
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
        $inspection = Get-AdltAzureContextInspection -Plan $planDictionary
        $status = Get-AdltEvidenceAggregateStatus -Probes @($inspection.probes)

        return New-AdltEvidence `
            -RunId $RunId `
            -PlanHash $planDictionary.planHash `
            -IntentHash $planDictionary.intentHash `
            -Stage validate `
            -Status $status `
            -Probes @($inspection.probes) `
            -Payload ([ordered]@{
                expectedScope = [ordered]@{
                    cloud          = $planDictionary.context.cloud
                    tenantId       = $planDictionary.context.tenantId
                    subscriptionId = $planDictionary.context.subscriptionId
                }
                observedContext = $inspection.context
            }) `
            -StartedAt $startedAt `
            -CompletedAt ([datetimeoffset]::UtcNow)
    }
}
