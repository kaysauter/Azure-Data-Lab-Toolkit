function ConvertTo-AdltUtcTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetimeoffset] $Value
    )

    return $Value.ToUniversalTime().ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffZ',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-AdltEvidenceAggregateStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Probes
    )

    if ($Probes.Count -eq 0) {
        return $null
    }

    $ranking = [ordered]@{
        pass       = 1
        warning    = 2
        unverified = 3
        denied     = 4
        fail       = 5
    }
    $highest = $Probes |
        ForEach-Object { [string] $_.status } |
        Sort-Object { $ranking[$_] } -Descending |
        Select-Object -First 1

    return $highest
}

function New-AdltEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $RunId,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $PlanHash,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $IntentHash,

        [Parameter(Mandatory)]
        [ValidateSet(
            'validate',
            'plan',
            'live-resolution',
            'what-if',
            'cost',
            'authorization',
            'deploy',
            'probe',
            'shutdown',
            'resume',
            'teardown-preview',
            'teardown',
            'cleanup-proof',
            'report'
        )]
        [string] $Stage,

        [Parameter(Mandatory)]
        [ValidateSet('pass', 'fail', 'warning', 'denied', 'unverified')]
        [string] $Status,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Sequence = 0,

        [AllowNull()]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $PreviousEventHash,

        [string[]] $CorrelationIds = @(),

        [object[]] $Probes = @(),

        [object[]] $Redactions = @(),

        [System.Collections.IDictionary] $Payload = [ordered]@{},

        [datetimeoffset] $StartedAt = [datetimeoffset]::UtcNow,

        [datetimeoffset] $CompletedAt = [datetimeoffset]::UtcNow
    )

    if ($CompletedAt -lt $StartedAt) {
        throw 'Evidence completedAt cannot be earlier than startedAt.'
    }

    $probeDictionaries = @(
        $Probes |
            ForEach-Object { ConvertTo-AdltDictionary -InputObject $_ }
    )
    if ($Stage -eq 'probe') {
        $aggregateStatus = Get-AdltEvidenceAggregateStatus `
            -Probes $probeDictionaries
        if ($null -eq $aggregateStatus) {
            throw 'Probe evidence requires at least one probe result.'
        }
        if ($Status -cne $aggregateStatus) {
            throw "Probe evidence status '$Status' must match aggregate probe status '$aggregateStatus'."
        }
    }

    $evidence = [ordered]@{
        schemaVersion     = '1.0'
        kind              = 'AzureDataLabEvidence'
        canonicalization  = 'rfc8785'
        eventId           = [guid]::NewGuid().ToString()
        sequence          = $Sequence
        previousEventHash = if ([string]::IsNullOrWhiteSpace($PreviousEventHash)) {
            $null
        }
        else {
            $PreviousEventHash
        }
        runId             = $RunId
        planHash           = $PlanHash
        intentHash         = $IntentHash
        stage              = $Stage
        status             = $Status
        correlationIds     = @($CorrelationIds | Sort-Object -Unique)
        probes             = $probeDictionaries
        redactions         = @(
            $Redactions |
                ForEach-Object { ConvertTo-AdltDictionary -InputObject $_ }
        )
        payload            = Copy-AdltValue -InputObject $Payload
        startedAt          = ConvertTo-AdltUtcTimestamp -Value $StartedAt
        completedAt        = ConvertTo-AdltUtcTimestamp -Value $CompletedAt
    }

    $forbiddenFields = @(Get-AdltForbiddenField -InputObject $evidence)
    if ($forbiddenFields.Count -gt 0) {
        throw "Secret values are forbidden in evidence. Remove field '$($forbiddenFields[0])'."
    }
    $sensitiveValues = @(Get-AdltSensitiveValueFinding -InputObject $evidence)
    if ($sensitiveValues.Count -gt 0) {
        throw (
            "Sensitive value pattern '$($sensitiveValues[0].kind)' is forbidden in evidence at '$($sensitiveValues[0].path)'."
        )
    }

    # Canonicalization is also the fail-closed type check for payload values.
    [void] (ConvertTo-AdltCanonicalJson -InputObject $evidence)
    Assert-AdltEvidencePayloadContract -Evidence $evidence
    $evidence.evidenceHash = Get-AdltArtifactHash `
        -Artifact $evidence `
        -HashProperty 'evidenceHash'
    Assert-AdltArtifactContract `
        -Artifact $evidence `
        -ExpectedKind 'AzureDataLabEvidence' `
        -HashProperty 'evidenceHash' `
        -SchemaFileName 'evidence.schema.json'

    return $evidence
}

function Assert-AdltEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence
    )

    Assert-AdltArtifactContract `
        -Artifact $Evidence `
        -ExpectedKind 'AzureDataLabEvidence' `
        -HashProperty 'evidenceHash' `
        -SchemaFileName 'evidence.schema.json'

    $startedAt = [datetimeoffset]::Parse(
        [string] $Evidence.startedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $completedAt = [datetimeoffset]::Parse(
        [string] $Evidence.completedAt,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if ($completedAt -lt $startedAt) {
        throw 'Evidence completedAt cannot be earlier than startedAt.'
    }

    if ($Evidence.stage -eq 'probe') {
        $aggregateStatus = Get-AdltEvidenceAggregateStatus `
            -Probes @($Evidence.probes)
        if ($Evidence.status -cne $aggregateStatus) {
            throw 'Probe evidence aggregate status verification failed.'
        }
    }
    Assert-AdltEvidencePayloadContract -Evidence $Evidence
}
