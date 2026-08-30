function Get-AzureDataLabRun {
    <#
    .SYNOPSIS
    Reads a local run after verifying its plan, state, and event hash chain.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId,

        [string] $StateRoot = (Get-AdltDefaultStateRoot)
    )

    return Get-AdltLocalRunStore -StateRoot $StateRoot -RunId $RunId
}

