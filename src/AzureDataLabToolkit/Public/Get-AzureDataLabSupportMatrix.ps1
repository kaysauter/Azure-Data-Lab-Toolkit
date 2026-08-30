function Get-AzureDataLabSupportMatrix {
    <#
    .SYNOPSIS
    Returns the bundled SQL VM capability support matrix.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [System.Collections.IDictionary])]
    param(
        [ValidateSet('sqlVm')]
        [string] $TargetType = 'sqlVm',

        [switch] $Raw
    )

    $matrix = Read-AdltJsonFile -Path (
        Get-AdltDataPath -ChildPath ('Support/{0}-support-matrix.json' -f $TargetType.ToLowerInvariant())
    )
    $validation = Test-AdltObjectAgainstSchema `
        -InputObject $matrix `
        -SchemaPath (Get-AdltDataPath -ChildPath 'Schemas/support-matrix.schema.json')
    if (-not $validation.Valid) {
        throw "Support matrix '$TargetType' failed schema validation."
    }

    if ($Raw.IsPresent) {
        return $matrix
    }

    foreach ($axis in $matrix.axes.Keys) {
        foreach ($value in $matrix.axes[$axis].Keys) {
            [pscustomobject]@{
                PSTypeName = 'AzureDataLabToolkit.SupportMatrixEntry'
                TargetType = $matrix.targetType
                Axis       = $axis
                Value      = $value
                Plan       = $matrix.axes[$axis][$value].plan
                Deployment = $matrix.axes[$axis][$value].deployment
            }
        }
    }
}
