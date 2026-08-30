function ConvertTo-AdltPlanMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('# Azure Data Lab Plan: {0}' -f $Plan.configuration.metadata.name))
    $lines.Add('')
    $lines.Add(('- Plan hash: `{0}`' -f $Plan.planHash))
    $lines.Add(('- Target: `{0}`' -f $Plan.target.type))
    $lines.Add(('- Engine: `{0}`' -f $Plan.configuration.engine.type))
    $lines.Add(('- Azure location: `{0}`' -f $Plan.context.location))
    $lines.Add(('- Deployment status: `{0}`' -f $Plan.target.deploymentStatus))
    $lines.Add(('- Blocking findings: `{0}`' -f $Plan.approval.blockingFindingIds.Count))
    $lines.Add(('- Required acknowledgements: `{0}`' -f $Plan.approval.requiredAcknowledgementIds.Count))
    $lines.Add('')
    $lines.Add('## Decisions')
    $lines.Add('')
    $lines.Add(('| Decision | Value |'))
    $lines.Add(('| --- | --- |'))
    $lines.Add(('| Secret store | `{0}` |' -f $Plan.decisions.secretStore.mode))
    $lines.Add(('| Administrative access | `{0}` |' -f $Plan.decisions.administrativeAccess.mode))
    $lines.Add(('| VM security type | `{0}` |' -f $Plan.decisions.computeSecurity.securityType))
    $lines.Add(('| Encryption at host | `{0}` |' -f $Plan.decisions.diskProtection.encryptionAtHost))
    $lines.Add(('| Sensitive data | `{0}` |' -f $Plan.decisions.dataSensitivity.containsSensitiveData))
    $lines.Add(('| Cost estimate requested | `{0}` |' -f $Plan.decisions.cost.estimateRequested))
    $lines.Add(('| Backup share | `{0}` |' -f $Plan.decisions.backupShare.enabled))
    $lines.Add('')
    $lines.Add('## Resources')
    $lines.Add('')
    $lines.Add('| ID | Type | API version | Logical name | Ownership | Intent |')
    $lines.Add('| --- | --- | --- | --- | --- | --- |')
    foreach ($resource in $Plan.resources) {
        $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` |' -f
            $resource.id,
            $resource.type,
            $resource.apiVersion,
            $resource.logicalName,
            $resource.ownership.expectedClassification,
            $resource.ownership.intent))
    }
    $lines.Add('')
    $lines.Add('### Resource desired state')
    $lines.Add('')
    foreach ($resource in $Plan.resources) {
        $externalResourceId = if ($null -eq $resource.externalResourceId) {
            'None'
        }
        else {
            '`{0}`' -f $resource.externalResourceId
        }
        $lines.Add(('#### `{0}`' -f $resource.id))
        $lines.Add('')
        $lines.Add(('- External resource ID: {0}' -f $externalResourceId))
        $lines.Add(('- Teardown intent: `{0}`' -f $resource.ownership.teardownIntent))
        $lines.Add('')
        $lines.Add('```json')
        $lines.Add((ConvertTo-AdltCanonicalJson -InputObject $resource.desiredProperties))
        $lines.Add('```')
        $lines.Add('')
    }
    $lines.Add('## Actions')
    $lines.Add('')
    $lines.Add('| ID | Scope | Operation | Mutation | Dependencies | Postconditions |')
    $lines.Add('| --- | --- | --- | --- | --- | --- |')
    foreach ($action in $Plan.actions) {
        $dependencies = @($action.dependsOn | ForEach-Object { '`{0}`' -f $_ }) -join ', '
        $postconditions = @($action.postconditions | ForEach-Object { '`{0}`' -f $_ }) -join ', '
        $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | {4} | {5} |' -f
            $action.id,
            $action.executionScope,
            $action.operation,
            $action.mutation,
            $dependencies,
            $postconditions))
    }
    $lines.Add('')
    $lines.Add('## Approval requirements')
    $lines.Add('')
    $lines.Add('### Blocking findings')
    $lines.Add('')
    foreach ($blockingId in @($Plan.approval.blockingFindingIds)) {
        $lines.Add(('- `{0}`' -f $blockingId))
    }
    $lines.Add('')
    $lines.Add('### Required acknowledgements')
    $lines.Add('')
    foreach ($acknowledgementId in @($Plan.approval.requiredAcknowledgementIds)) {
        $lines.Add(('- `{0}`' -f $acknowledgementId))
    }
    $lines.Add('')
    $lines.Add('## Policy findings')
    $lines.Add('')
    $lines.Add('| ID | Severity | Effect | Configuration | Message |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($finding in $Plan.policyFindings) {
        $lines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` | {4} |' -f
            $finding.id,
            $finding.severity,
            $finding.effect,
            $finding.configurationPath,
            $finding.message))
    }
    $lines.Add('')
    $lines.Add('## Warnings')
    $lines.Add('')
    if ($Plan.warnings.Count -eq 0) {
        $lines.Add('None.')
    }
    else {
        foreach ($warning in $Plan.warnings) {
            $lines.Add(('- {0}' -f $warning))
        }
    }

    return $lines -join [Environment]::NewLine
}

function ConvertTo-AdltPlanHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $encode = [System.Net.WebUtility]::HtmlEncode
    $resourceRows = foreach ($resource in $Plan.resources) {
        '<tr><td><code>{0}</code></td><td>{1}</td><td><code>{2}</code></td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f
            $encode.Invoke([string] $resource.id),
            $encode.Invoke([string] $resource.type),
            $encode.Invoke([string] $resource.apiVersion),
            $encode.Invoke([string] $resource.logicalName),
            $encode.Invoke([string] $resource.ownership.expectedClassification),
            $encode.Invoke([string] $resource.ownership.intent)
    }
    $resourceDetails = foreach ($resource in $Plan.resources) {
        $externalResourceId = if ($null -eq $resource.externalResourceId) {
            'None'
        }
        else {
            $encode.Invoke([string] $resource.externalResourceId)
        }
        $desiredProperties = $encode.Invoke(
            (ConvertTo-AdltCanonicalJson -InputObject $resource.desiredProperties)
        )
        '<details><summary><code>{0}</code></summary><p><strong>External resource ID:</strong> <code>{1}</code></p><p><strong>Teardown:</strong> {2}</p><pre><code>{3}</code></pre></details>' -f
            $encode.Invoke([string] $resource.id),
            $externalResourceId,
            $encode.Invoke([string] $resource.ownership.teardownIntent),
            $desiredProperties
    }
    $actionRows = foreach ($action in $Plan.actions) {
        $dependencies = @($action.dependsOn | ForEach-Object {
            '<code>{0}</code>' -f $encode.Invoke([string] $_)
        }) -join '<br>'
        $postconditions = @($action.postconditions | ForEach-Object {
            '<code>{0}</code>' -f $encode.Invoke([string] $_)
        }) -join '<br>'
        '<tr><td><code>{0}</code></td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f
            $encode.Invoke([string] $action.id),
            $encode.Invoke([string] $action.executionScope),
            $encode.Invoke([string] $action.operation),
            $encode.Invoke([string] $action.mutation),
            $dependencies,
            $postconditions
    }
    $policyRows = foreach ($finding in $Plan.policyFindings) {
        '<tr class="{0}"><td><code>{1}</code></td><td>{2}</td><td>{3}</td><td><code>{4}</code></td><td>{5}</td></tr>' -f
            $encode.Invoke([string] $finding.severity),
            $encode.Invoke([string] $finding.id),
            $encode.Invoke([string] $finding.severity),
            $encode.Invoke([string] $finding.effect),
            $encode.Invoke([string] $finding.configurationPath),
            $encode.Invoke([string] $finding.message)
    }
    $warningItems = if ($Plan.warnings.Count -eq 0) {
        '<li>None.</li>'
    }
    else {
        @($Plan.warnings | ForEach-Object {
            '<li>{0}</li>' -f $encode.Invoke([string] $_)
        }) -join [Environment]::NewLine
    }
    $blockingItems = @($Plan.approval.blockingFindingIds | ForEach-Object {
        '<li><code>{0}</code></li>' -f $encode.Invoke([string] $_)
    }) -join [Environment]::NewLine
    $acknowledgementItems = @($Plan.approval.requiredAcknowledgementIds | ForEach-Object {
        '<li><code>{0}</code></li>' -f $encode.Invoke([string] $_)
    }) -join [Environment]::NewLine

    return @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Azure Data Lab Plan</title>
  <style>
    :root { color-scheme: dark light; font-family: system-ui, sans-serif; }
    body { margin: 0; background: #111827; color: #f9fafb; }
    main { max-width: 1120px; margin: 0 auto; padding: 32px 24px 64px; }
    h1, h2 { letter-spacing: 0; }
    .summary { border-left: 4px solid #38bdf8; padding: 4px 16px; }
    .blocking td { background: #3f1519; }
    .high td { background: #3b2f12; }
    code { overflow-wrap: anywhere; }
    pre { overflow-x: auto; padding: 12px; background: #0b1220; }
    details { border-bottom: 1px solid #374151; padding: 10px 0; }
    summary { cursor: pointer; }
    table { width: 100%; border-collapse: collapse; margin: 12px 0 28px; }
    th, td { border-bottom: 1px solid #374151; padding: 10px 8px; text-align: left; vertical-align: top; }
    th { color: #7dd3fc; }
    .warning { border-left: 4px solid #ef4444; padding: 10px 16px; background: #3f1519; }
    @media (prefers-color-scheme: light) {
      body { background: #ffffff; color: #111827; }
      th, td { border-bottom-color: #d1d5db; }
      .warning { background: #fee2e2; }
      .blocking td { background: #fee2e2; }
      .high td { background: #fef3c7; }
      pre { background: #f3f4f6; }
    }
  </style>
</head>
<body>
<main>
  <h1>Azure Data Lab Plan: $($encode.Invoke([string] $Plan.configuration.metadata.name))</h1>
  <div class="summary">
    <p><strong>Plan hash:</strong> <code>$($encode.Invoke([string] $Plan.planHash))</code></p>
    <p><strong>Target:</strong> $($encode.Invoke([string] $Plan.target.type))</p>
    <p><strong>Engine:</strong> $($encode.Invoke([string] $Plan.configuration.engine.type))</p>
    <p><strong>Azure location:</strong> $($encode.Invoke([string] $Plan.context.location))</p>
    <p><strong>Deployment status:</strong> $($encode.Invoke([string] $Plan.target.deploymentStatus))</p>
    <p><strong>Blocking findings:</strong> $($Plan.approval.blockingFindingIds.Count)</p>
    <p><strong>Required acknowledgements:</strong> $($Plan.approval.requiredAcknowledgementIds.Count)</p>
  </div>
  <h2>Security and lifecycle decisions</h2>
  <table>
    <thead><tr><th>Decision</th><th>Value</th></tr></thead>
    <tbody>
      <tr><td>Secret store</td><td>$($encode.Invoke([string] $Plan.decisions.secretStore.mode))</td></tr>
      <tr><td>Administrative access</td><td>$($encode.Invoke([string] $Plan.decisions.administrativeAccess.mode))</td></tr>
      <tr><td>VM security type</td><td>$($encode.Invoke([string] $Plan.decisions.computeSecurity.securityType))</td></tr>
      <tr><td>Encryption at host</td><td>$($encode.Invoke([string] $Plan.decisions.diskProtection.encryptionAtHost))</td></tr>
      <tr><td>Contains sensitive data</td><td>$($encode.Invoke([string] $Plan.decisions.dataSensitivity.containsSensitiveData))</td></tr>
      <tr><td>Cost estimate requested</td><td>$($encode.Invoke([string] $Plan.decisions.cost.estimateRequested))</td></tr>
      <tr><td>Backup share</td><td>$($encode.Invoke([string] $Plan.decisions.backupShare.enabled))</td></tr>
    </tbody>
  </table>
  <h2>Resources</h2>
  <table>
    <thead><tr><th>ID</th><th>Type</th><th>API version</th><th>Logical name</th><th>Expected ownership</th><th>Intent</th></tr></thead>
    <tbody>$($resourceRows -join [Environment]::NewLine)</tbody>
  </table>
  <h2>Resource desired state</h2>
  $($resourceDetails -join [Environment]::NewLine)
  <h2>Actions</h2>
  <table>
    <thead><tr><th>ID</th><th>Scope</th><th>Operation</th><th>Mutation</th><th>Dependencies</th><th>Postconditions</th></tr></thead>
    <tbody>$($actionRows -join [Environment]::NewLine)</tbody>
  </table>
  <h2>Approval requirements</h2>
  <h3>Blocking findings</h3>
  <ul>$blockingItems</ul>
  <h3>Required acknowledgements</h3>
  <ul>$acknowledgementItems</ul>
  <h2>Policy findings</h2>
  <table>
    <thead><tr><th>ID</th><th>Severity</th><th>Effect</th><th>Configuration</th><th>Message</th></tr></thead>
    <tbody>$($policyRows -join [Environment]::NewLine)</tbody>
  </table>
  <div class="warning">
    <h2>Warnings</h2>
    <ul>$warningItems</ul>
  </div>
</main>
</body>
</html>
"@
}

function Export-AzureDataLabPlan {
    <#
    .SYNOPSIS
    Exports a verified Azure Data Lab plan as JSON, Markdown, or standalone HTML.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $Plan,

        [ValidateSet('Json', 'Markdown', 'Html')]
        [string] $Format = 'Json',

        [string] $Path,

        [switch] $Force
    )

    process {
        $planDictionary = ConvertTo-AdltDictionary -InputObject $Plan
        Assert-AdltPlanHash -Plan $planDictionary

        $content = switch ($Format) {
            'Json' {
                ConvertTo-AdltCanonicalJson -InputObject $planDictionary
            }
            'Markdown' {
                ConvertTo-AdltPlanMarkdown -Plan $planDictionary
            }
            'Html' {
                ConvertTo-AdltPlanHtml -Plan $planDictionary
            }
        }

        if (-not $PSBoundParameters.ContainsKey('Path')) {
            return $content
        }

        if ($PSCmdlet.ShouldProcess($Path, "Export Azure Data Lab plan as $Format")) {
            return Write-AdltAtomicText -Path $Path -Content $content -Force:$Force
        }
    }
}
