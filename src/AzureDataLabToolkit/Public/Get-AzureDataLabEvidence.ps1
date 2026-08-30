function Get-AzureDataLabEvidence {
    <#
    .SYNOPSIS
    Reads and verifies one canonical Azure Data Lab evidence artifact.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $file = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
    if ($file.Length -gt 10MB) {
        throw 'Evidence artifacts larger than 10 MB are not accepted.'
    }

    $evidence = Read-AdltJsonFile -Path $resolvedPath
    Assert-AdltEvidence -Evidence $evidence
    return $evidence
}

