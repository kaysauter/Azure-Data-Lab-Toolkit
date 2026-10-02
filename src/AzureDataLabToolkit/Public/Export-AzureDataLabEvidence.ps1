function Export-AzureDataLabEvidence {
    <#
    .SYNOPSIS
    Exports verified evidence as canonical JSON, Markdown, or standalone HTML.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $Evidence,

        [ValidateSet('Json', 'Markdown', 'Html')]
        [string] $Format = 'Json',

        [string] $Path,

        [switch] $Force
    )

    process {
        $evidenceDictionary = ConvertTo-AdltDictionary -InputObject $Evidence
        Assert-AdltEvidence -Evidence $evidenceDictionary

        $content = switch ($Format) {
            'Json' {
                ConvertTo-AdltCanonicalJson -InputObject $evidenceDictionary
            }
            'Markdown' {
                ConvertTo-AdltEvidenceMarkdown -Evidence $evidenceDictionary
            }
            'Html' {
                ConvertTo-AdltEvidenceHtml -Evidence $evidenceDictionary
            }
        }

        if (-not $PSBoundParameters.ContainsKey('Path')) {
            return $content
        }

        if ($PSCmdlet.ShouldProcess(
            $Path,
            "Export Azure Data Lab evidence as $Format"
        )) {
            return Write-AdltAtomicText `
                -Path $Path `
                -Content $content `
                -Force:$Force `
                -Private
        }
    }
}
