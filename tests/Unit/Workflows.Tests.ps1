BeforeDiscovery {
    $workflowFiles = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $PSScriptRoot '../../.github/workflows') `
            -File |
            Where-Object Extension -In '.yml', '.yaml' |
            Sort-Object Name |
            ForEach-Object { @{ File = $_.Name } }
    )
}

BeforeAll {
    $script:RepositoryRoot = (
        Resolve-Path (Join-Path $PSScriptRoot '../..')
    ).ProviderPath
    $script:ModulePath = Join-Path `
        $script:RepositoryRoot `
        'src/AzureDataLabToolkit/AzureDataLabToolkit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # The module's pinned powershell-yaml, called directly rather than through
    # the configuration reader, which also refuses the anchors and tags that
    # GitHub accepts in workflows. Optional keys are read with the indexer:
    # build.ps1 runs these tests under Set-StrictMode -Version Latest, where
    # dot access to a missing key throws.
    $script:Workflows = [ordered]@{}
    foreach ($file in @(
            Get-ChildItem `
                -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows') `
                -File |
                Where-Object Extension -In '.yml', '.yaml'
        )) {
        $script:Workflows[$file.Name] = InModuleScope AzureDataLabToolkit `
            -Parameters @{ Path = $file.FullName } {
                param($Path)

                ConvertFrom-Yaml `
                    -Yaml ([System.IO.File]::ReadAllText($Path)) `
                    -Ordered
            }
    }
    $script:ModuleWorkflow = $script:Workflows['module-ci.yml']

    function Test-GrantsWrite {
        param(
            [AllowNull()]
            [object] $Permissions
        )

        if ($null -eq $Permissions) {
            return $false
        }
        if ($Permissions -is [string]) {
            return $Permissions -cne 'read-all'
        }
        return @(
            $Permissions.Values |
                Where-Object { [string] $_ -cnotin @('read', 'none') }
        ).Count -gt 0
    }
}

Describe 'Required-check workflows' {
    It 'runs <File> on every pull request' -ForEach @(
        @{ File = 'module-ci.yml' }
        @{ File = 'docs-checks.yml' }
    ) {
        # A path filter would leave the required check pending, which blocks
        # the pull request forever. The changes job decides what runs instead.
        $trigger = $script:Workflows[$File]['on']
        $trigger.Contains('pull_request') | Should -BeTrue
        $trigger['pull_request'] | Should -BeNullOrEmpty
    }

    It 'never skips the <Name> gate in <File>' -ForEach @(
        @{
            File   = 'module-ci.yml'
            Gate   = 'module-checks'
            Name   = 'Module checks'
            Checks = 'offline-contracts'
        }
        @{
            File   = 'docs-checks.yml'
            Gate   = 'docs-checks'
            Name   = 'Docs checks'
            Checks = 'build'
        }
    ) {
        # The main ruleset requires these job names. A skipped required check
        # counts as passing, so the gate must always run, must be the only job
        # reporting under that name, and must judge both the change detection
        # and the checks it guards. continue-on-error anywhere on that path
        # would turn a failure into a pass.
        $jobs = $script:Workflows[$File]['jobs']
        @(
            $jobs.Values | Where-Object { [string] $_['name'] -ceq $Name }
        ).Count | Should -Be 1
        $jobs[$Gate]['name'] | Should -BeExactly $Name
        $jobs[$Gate]['if'] | Should -BeExactly 'always()'
        @($jobs[$Gate]['needs']) | Should -BeExactly @('changes', $Checks)
        $jobs[$Checks]['needs'] | Should -BeExactly 'changes'
        $jobs[$Checks]['if'] |
            Should -BeExactly "needs.changes.outputs.relevant == 'true'"
        foreach ($jobId in @('changes', $Checks, $Gate)) {
            $jobs[$jobId].Contains('continue-on-error') | Should -BeFalse
            foreach ($step in @($jobs[$jobId]['steps'])) {
                $step.Contains('continue-on-error') | Should -BeFalse
            }
        }
    }

    It 'runs the module checks whenever a file they test changes' {
        # The module suite reads every workflow file, so a pull request that
        # changes only a docs workflow must still run it.
        $detect = @(
            $script:ModuleWorkflow['jobs']['changes']['steps'] |
                Where-Object { [string] $_['id'] -ceq 'detect' }
        )
        $detect.Count | Should -Be 1
        $match = [regex]::Match(
            [string] $detect[0]['run'],
            "pattern='([^']+)'"
        )
        $match.Success | Should -BeTrue
        $pattern = $match.Groups[1].Value

        $covered = @(
            foreach ($name in $script:Workflows.Keys) {
                ".github/workflows/$name"
            }
            '.gitattributes'
            'build.ps1'
            'src/AzureDataLabToolkit/AzureDataLabToolkit.psm1'
            'tests/Unit/Workflows.Tests.ps1'
        )
        foreach ($path in $covered) {
            $path | Should -MatchExactly $pattern
        }
        foreach ($path in @(
                'README.md'
                '.github/workflows/README.md'
                'docs-site/src/content/docs/index.mdx'
            )) {
            $path | Should -Not -MatchExactly $pattern
        }

        $pushPaths = @($script:ModuleWorkflow['on']['push']['paths'])
        foreach ($path in @(
                '.github/workflows/*.yml'
                '.github/workflows/*.yaml'
                '.gitattributes'
            )) {
            $pushPaths | Should -Contain $path
        }
    }
}

Describe 'Release workflow' {
    It 'publishes only from a pushed tag, after every platform check' {
        $trigger = $script:ModuleWorkflow['on']
        $trigger.Contains('release') | Should -BeFalse
        @($trigger['push']['tags']) | Should -BeExactly @('v*')

        $jobs = $script:ModuleWorkflow['jobs']
        $tagPush = "github.event_name == 'push' && github.ref_type == 'tag'"
        $jobs['release-provenance']['if'] | Should -BeExactly $tagPush
        $jobs['release-provenance']['needs'] |
            Should -BeExactly 'offline-contracts'
        $jobs['publish-release']['if'] | Should -BeExactly $tagPush
        $jobs['publish-release']['needs'] |
            Should -BeExactly 'release-provenance'
    }

    It 'never cancels a tag run that has started' {
        $concurrency = $script:ModuleWorkflow['concurrency']
        $concurrency['cancel-in-progress'] |
            Should -BeExactly '${{ github.ref_type != ''tag'' }}'
    }

    It 'keeps write and OIDC permissions out of jobs that run repository code' {
        # release-provenance dot-sources build.ps1, so it may only read.
        # publish-release holds the release-writing and token-minting
        # permissions, so it may only download the verified evidence, attest
        # it and call gh: it never has the repository on disk.
        $workflow = $script:ModuleWorkflow
        @($workflow['permissions'].Keys) | Should -BeExactly @('contents')
        $workflow['permissions']['contents'] | Should -BeExactly 'read'

        $privileged = @(
            foreach ($job in $workflow['jobs'].GetEnumerator()) {
                if (Test-GrantsWrite -Permissions $job.Value['permissions']) {
                    $job.Key
                }
            }
        )
        $privileged | Should -BeExactly @('publish-release')

        $provenance = $workflow['jobs']['release-provenance']['permissions']
        @($provenance.Keys) | Should -BeExactly @('contents')
        $provenance['contents'] | Should -BeExactly 'read'

        foreach ($step in @($workflow['jobs']['publish-release']['steps'])) {
            if ($step.Contains('uses')) {
                [string] $step['uses'] | Should -MatchExactly (
                    '^actions/(download-artifact|attest)@[0-9a-f]{40}$'
                )
            }
            else {
                # git or pwsh in command position, a clone, or module code.
                # gh api paths such as repos/<repo>/git/ref/... stay allowed.
                [string] $step['run'] | Should -Not -Match (
                    '(?m)(^|[;&|(]|\$\()\s*(git|pwsh|powershell)\b|' +
                    '\bclone\b|Import-Module|build\.ps1'
                )
            }
        }
    }
}

Describe 'Workflow supply chain' {
    It 'pins every action in <File> to a full commit SHA' -ForEach $workflowFiles {
        # A job that calls a reusable workflow has a job-level uses and no
        # steps; one in this repository is referenced by a local path.
        foreach ($job in $script:Workflows[$File]['jobs'].Values) {
            if ($job.Contains('uses')) {
                [string] $job['uses'] | Should -MatchExactly (
                    '^(\./\.github/workflows/[\w.-]+\.ya?ml|' +
                    '[\w.-]+/[\w./-]+@[0-9a-f]{40})$'
                )
            }
            foreach ($step in @($job['steps'] | Where-Object { $null -ne $_ })) {
                if ($step.Contains('uses')) {
                    [string] $step['uses'] |
                        Should -MatchExactly '^[\w.-]+/[\w./-]+@[0-9a-f]{40}$'
                }
            }
        }
    }

    It 'keeps the token out of every checkout in <File>' -ForEach $workflowFiles {
        # No workflow pushes, and a persisted token would be readable by every
        # later step, including the npm and module code these jobs run.
        foreach ($job in $script:Workflows[$File]['jobs'].Values) {
            foreach ($step in @($job['steps'] | Where-Object { $null -ne $_ })) {
                if ([string] $step['uses'] -like 'actions/checkout@*') {
                    $step['with']['persist-credentials'] |
                        Should -BeExactly $false
                }
            }
        }
    }
}
