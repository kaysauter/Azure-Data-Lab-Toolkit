function ConvertTo-AdltEvidenceMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('# Azure Data Lab Evidence: {0}' -f $Evidence.stage))
    $lines.Add('')
    $lines.Add(('- Evidence hash: `{0}`' -f $Evidence.evidenceHash))
    $lines.Add(('- Run ID: `{0}`' -f $Evidence.runId))
    $lines.Add(('- Plan hash: `{0}`' -f $Evidence.planHash))
    $lines.Add(('- Status: `{0}`' -f $Evidence.status))
    $lines.Add(('- Started: `{0}`' -f $Evidence.startedAt))
    $lines.Add(('- Completed: `{0}`' -f $Evidence.completedAt))
    $lines.Add('')

    if (@($Evidence.probes).Count -gt 0) {
        $lines.Add('## Probes')
        $lines.Add('')
        $lines.Add('| Probe | Status | Message |')
        $lines.Add('| --- | --- | --- |')
        foreach ($probe in @($Evidence.probes)) {
            $messageText = ([string] $probe.message) -replace '\r?\n', ' '
            $message = [System.Net.WebUtility]::HtmlEncode($messageText)
            $message = $message -replace '([\\`*_\[\]()#!|])', '\$1'
            $lines.Add(('| `{0}` | `{1}` | {2} |' -f
                    $probe.probeId,
                    $probe.status,
                    $message))
        }
        $lines.Add('')
    }

    $lines.Add('## Payload')
    $lines.Add('')
    $lines.Add(
        '    {0}' -f (
            ConvertTo-AdltCanonicalJson -InputObject $Evidence.payload
        )
    )

    return $lines -join [Environment]::NewLine
}

function ConvertTo-AdltEvidenceHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Evidence
    )

    $encode = {
        param([AllowNull()][object] $Value)
        [System.Net.WebUtility]::HtmlEncode([string] $Value)
    }
    $probeRows = @(
        foreach ($probe in @($Evidence.probes)) {
            '<tr><td><code>{0}</code></td><td>{1}</td><td>{2}</td></tr>' -f
                $encode.Invoke($probe.probeId),
                $encode.Invoke($probe.status),
                $encode.Invoke($probe.message)
        }
    )
    $payload = $encode.Invoke(
        (ConvertTo-AdltCanonicalJson -InputObject $Evidence.payload)
    )

    return @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Azure Data Lab Evidence</title>
  <style>
    body { margin: 0; background: #101419; color: #edf3f8; font-family: system-ui, sans-serif; }
    main { max-width: 1040px; margin: 0 auto; padding: 32px 24px 64px; }
    h1, h2 { letter-spacing: 0; }
    code, pre { font-family: ui-monospace, monospace; }
    pre { overflow: auto; padding: 14px; background: #080b0e; border: 1px solid #34414c; }
    table { width: 100%; border-collapse: collapse; margin: 16px 0 28px; }
    th, td { padding: 10px; text-align: left; border-bottom: 1px solid #34414c; vertical-align: top; }
    .status { display: inline-block; padding: 4px 8px; border: 1px solid #6e8293; }
  </style>
</head>
<body>
<main>
  <h1>Azure Data Lab Evidence: $($encode.Invoke($Evidence.stage))</h1>
  <p class="status">$($encode.Invoke($Evidence.status))</p>
  <p><strong>Evidence hash:</strong> <code>$($encode.Invoke($Evidence.evidenceHash))</code></p>
  <p><strong>Run ID:</strong> <code>$($encode.Invoke($Evidence.runId))</code></p>
  <p><strong>Plan hash:</strong> <code>$($encode.Invoke($Evidence.planHash))</code></p>
  <p><strong>Started:</strong> $($encode.Invoke($Evidence.startedAt))</p>
  <p><strong>Completed:</strong> $($encode.Invoke($Evidence.completedAt))</p>
  <h2>Probes</h2>
  <table>
    <thead><tr><th>Probe</th><th>Status</th><th>Message</th></tr></thead>
    <tbody>$($probeRows -join [Environment]::NewLine)</tbody>
  </table>
  <h2>Payload</h2>
  <pre>$payload</pre>
</main>
</body>
</html>
"@
}
