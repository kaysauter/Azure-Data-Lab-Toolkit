function Assert-AdltYamlNodeSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [YamlDotNet.RepresentationModel.YamlNode] $Node,

        [ValidateRange(0, 100)]
        [int] $Depth = 0,

        [Parameter(Mandatory)]
        [ref] $NodeCount
    )

    $NodeCount.Value++
    if ($NodeCount.Value -gt 10000) {
        throw 'The YAML document contains more than 10,000 nodes.'
    }

    if ($Depth -gt 40) {
        throw 'The YAML document exceeds the maximum nesting depth of 40.'
    }

    if (-not $Node.Anchor.IsEmpty) {
        throw 'YAML anchors and aliases are not allowed in toolkit configuration.'
    }

    if (-not $Node.Tag.IsEmpty) {
        throw 'Explicit YAML tags are not allowed in toolkit configuration.'
    }

    if ($Node -is [YamlDotNet.RepresentationModel.YamlMappingNode]) {
        foreach ($pair in $Node.Children.GetEnumerator()) {
            if ($pair.Key -isnot [YamlDotNet.RepresentationModel.YamlScalarNode]) {
                throw 'YAML mapping keys must be scalar strings.'
            }

            Assert-AdltYamlNodeSafe -Node $pair.Key -Depth ($Depth + 1) -NodeCount $NodeCount
            Assert-AdltYamlNodeSafe -Node $pair.Value -Depth ($Depth + 1) -NodeCount $NodeCount
        }
    }
    elseif ($Node -is [YamlDotNet.RepresentationModel.YamlSequenceNode]) {
        foreach ($child in $Node.Children) {
            Assert-AdltYamlNodeSafe -Node $child -Depth ($Depth + 1) -NodeCount $NodeCount
        }
    }
}

function ConvertFrom-AdltYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Yaml
    )

    if ($Yaml.IndexOf([char] 0) -ge 0) {
        throw 'YAML configuration cannot contain NUL characters.'
    }

    $stream = [YamlDotNet.RepresentationModel.YamlStream]::new()
    $reader = [System.IO.StringReader]::new($Yaml)
    try {
        $stream.Load($reader)
    }
    catch {
        throw "YAML parsing failed: $($_.Exception.GetBaseException().Message)"
    }
    finally {
        $reader.Dispose()
    }

    if ($stream.Documents.Count -ne 1) {
        throw 'Toolkit configuration must contain exactly one YAML document.'
    }

    $nodeCount = 0
    Assert-AdltYamlNodeSafe -Node $stream.Documents[0].RootNode -NodeCount ([ref] $nodeCount)

    try {
        $result = ConvertFrom-Yaml -Yaml $Yaml -Ordered -ErrorAction Stop
    }
    catch {
        throw "YAML conversion failed: $($_.Exception.GetBaseException().Message)"
    }

    if ($result -isnot [System.Collections.IDictionary]) {
        throw 'The YAML document root must be an object.'
    }

    return ConvertTo-AdltDictionary -InputObject $result
}

function Read-AdltYamlFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $item = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop

    if ($item.PSIsContainer) {
        throw "YAML path '$Path' points to a directory."
    }

    if ($item.Length -gt $script:AzureDataLabToolkitMaximumYamlBytes) {
        throw "YAML configuration exceeds the maximum size of $script:AzureDataLabToolkitMaximumYamlBytes bytes."
    }

    if ($item.Extension -notin @('.yaml', '.yml')) {
        throw "Configuration path '$Path' must use a .yaml or .yml extension."
    }

    $yaml = [System.IO.File]::ReadAllText($resolvedPath)
    return ConvertFrom-AdltYaml -Yaml $yaml
}
