function Test-AzureDataLabDeployment {
    <#
    .SYNOPSIS
    Verifies the exact deployed SQL VM resource set and advances a run to running.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('StatePath')]
        [string] $RunPath
    )

    process {
        $preliminary = Get-AdltVerifiedLocalRunContext `
            -RunPath $RunPath
        $scopeLock = Open-AdltAzureScopeOperationLock `
            -Scope $preliminary.State.scope
        $operationLock = $null
        try {
            $operationLock = Open-AdltLocalRunOperationLock `
                -RunPath $RunPath
            $context = Get-AdltVerifiedLocalRunContext `
                -RunPath $RunPath
            if (
                $context.Plan.planHash -cne
                    $preliminary.Plan.planHash -or
                (ConvertTo-AdltCanonicalJson `
                    -InputObject $context.State.scope) -cne
                (ConvertTo-AdltCanonicalJson `
                    -InputObject $preliminary.State.scope)
            ) {
                throw 'The protected run changed while acquiring probe locks.'
            }
            return Invoke-AdltPostDeploymentProbe -RunPath $RunPath
        }
        finally {
            if ($null -ne $operationLock) {
                $operationLock.Dispose()
            }
            $scopeLock.Dispose()
        }
    }
}
