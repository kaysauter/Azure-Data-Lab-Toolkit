function New-AzureDataLabRun {
    <#
    .SYNOPSIS
    Creates a protected local run ledger for a verified offline plan.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $Plan,

        [string] $StateRoot = (Get-AdltDefaultStateRoot)
    )

    process {
        $planDictionary = ConvertTo-AdltDictionary -InputObject $Plan
        return New-AdltLocalRunStore `
            -Plan $planDictionary `
            -StateRoot $StateRoot
    }
}

