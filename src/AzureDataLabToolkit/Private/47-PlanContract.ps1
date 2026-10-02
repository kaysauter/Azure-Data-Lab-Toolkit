function Assert-AdltPlanContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    Assert-AdltSecretFreeBoundary -InputObject $Plan -Boundary plan
    Assert-AdltPlanHash -Plan $Plan
    $validation = Test-AdltObjectAgainstSchema `
        -InputObject $Plan `
        -SchemaPath (Get-AdltDataPath -ChildPath 'Schemas/plan.schema.json')
    if (-not $validation.Valid) {
        throw "Azure Data Lab plan schema validation failed: $($validation.Errors -join ' ')"
    }
    Assert-AdltPlanStructure -Plan $Plan

    $intent = Get-AdltCanonicalPlanIntentPayload -Plan $Plan
    $expectedIntentHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $intent
    )
    if ($Plan.intentHash -cne $expectedIntentHash) {
        throw 'Azure Data Lab plan intent hash verification failed.'
    }

    foreach ($action in @($Plan.actions)) {
        $expectedKey = 'adlt:v1:{0}:{1}' -f $expectedIntentHash, $action.id
        if ($action.idempotencyKey -cne $expectedKey) {
            throw "Action '$($action.id)' is not bound to the verified plan intent."
        }
    }
}
