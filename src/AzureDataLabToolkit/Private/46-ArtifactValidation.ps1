function Assert-AdltArtifactContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Artifact,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedKind,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z][A-Za-z0-9]*Hash$')]
        [string] $HashProperty,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SchemaFileName
    )

    if (-not $Artifact.Contains('kind') -or $Artifact.kind -cne $ExpectedKind) {
        throw "Artifact kind must be '$ExpectedKind'."
    }

    $forbiddenFields = @(Get-AdltForbiddenField -InputObject $Artifact)
    if ($forbiddenFields.Count -gt 0) {
        throw "Secret values are forbidden in artifacts. Remove field '$($forbiddenFields[0])'."
    }
    $sensitiveValues = @(Get-AdltSensitiveValueFinding -InputObject $Artifact)
    if ($sensitiveValues.Count -gt 0) {
        throw (
            "Sensitive value pattern '$($sensitiveValues[0].kind)' is forbidden in artifacts at '$($sensitiveValues[0].path)'."
        )
    }

    $schemaPath = Get-AdltDataPath -ChildPath ('Schemas/{0}' -f $SchemaFileName)
    $validation = Test-AdltObjectAgainstSchema `
        -InputObject $Artifact `
        -SchemaPath $schemaPath
    if (-not $validation.Valid) {
        throw "$ExpectedKind schema validation failed: $($validation.Errors -join ' ')"
    }

    Assert-AdltArtifactHash `
        -Artifact $Artifact `
        -HashProperty $HashProperty `
        -ArtifactName $ExpectedKind
}
