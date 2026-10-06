function Get-AdltSensitiveValueFinding {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [string] $Path = '$'
    )

    if (
        $InputObject -is [securestring] -or
        $InputObject -is [pscredential]
    ) {
        [ordered]@{
            path = $Path
            kind = 'secret-object'
        }
        return
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            Get-AdltSensitiveValueFinding `
                -InputObject $InputObject[$key] `
                -Path ('{0}.{1}' -f $Path, [string] $key)
        }
        return
    }
    if (
        $InputObject -is [System.Collections.IList] -and
        $InputObject -isnot [string]
    ) {
        for ($index = 0; $index -lt $InputObject.Count; $index++) {
            Get-AdltSensitiveValueFinding `
                -InputObject $InputObject[$index] `
                -Path ('{0}[{1}]' -f $Path, $index)
        }
        return
    }
    if ($InputObject -isnot [string]) {
        return
    }

    $patterns = [ordered]@{
        'private-key'       = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
        'jwt'               = '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{12,}\.eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}(?![A-Za-z0-9_-])'
        'sas-query'         = '(?i)(?:[?&]|^)(?:sig|se|sp|sv|srt|ss)=[^&\s]+'
        'connection-secret' = '(?i)(?:^|[;\s])(?:password|pwd|accountkey|clientsecret|sharedaccesssignature)\s*=\s*[^;\s]+'
        'uri-userinfo'      = '(?i)https?://[^/\s:@]+:[^/\s@]+@'
        'github-token'      = '(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{20,}(?![A-Za-z0-9_])'
    }
    foreach ($kind in $patterns.Keys) {
        if ([regex]::IsMatch([string] $InputObject, $patterns[$kind])) {
            [ordered]@{
                path = $Path
                kind = $kind
            }
            return
        }
    }
}

