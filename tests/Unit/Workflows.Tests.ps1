BeforeDiscovery {
    $workflowFiles = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $PSScriptRoot '../../.github/workflows') `
            -File |
            Where-Object Extension -In '.yml', '.yaml' |
            Sort-Object Name |
            ForEach-Object { @{ File = $_.Name } }
    )
    # The gate and change-detection scripts run under bash on the ubuntu
    # runner. On Windows, bash can resolve to WSL, so those tests skip there.
    $bashUnavailable = $IsWindows -or
        $null -eq (Get-Command bash -CommandType Application -ErrorAction SilentlyContinue) -or
        $null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
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

    function Get-TestStepRun {
        param(
            [Parameter(Mandatory)]
            [string] $File,

            [Parameter(Mandatory)]
            [string] $Job,

            [Parameter(Mandatory)]
            [scriptblock] $Where
        )

        $steps = @(
            $script:Workflows[$File]['jobs'][$Job]['steps'] |
                Where-Object { $null -ne $_ } |
                Where-Object $Where
        )
        if ($steps.Count -ne 1) {
            throw "Expected exactly one matching step in $File/$Job."
        }
        return [string] $steps[0]['run']
    }

    # Runs a step's script the way the runner does: bash --noprofile --norc
    # -eo pipefail <file>, with the step's env: values in the environment.
    function Invoke-TestBashScript {
        param(
            [Parameter(Mandatory)]
            [string] $Script,

            [Parameter(Mandatory)]
            [hashtable] $Environment,

            [string] $WorkingDirectory = $TestDrive
        )

        $path = Join-Path $TestDrive ('step-{0}.sh' -f [guid]::NewGuid())
        [System.IO.File]::WriteAllText($path, $Script)
        $saved = @{}
        foreach ($name in $Environment.Keys) {
            $saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
            [System.Environment]::SetEnvironmentVariable(
                $name,
                [string] $Environment[$name]
            )
        }
        Push-Location -LiteralPath $WorkingDirectory
        try {
            # Standard input is closed, so a script that reads it fails
            # instead of waiting forever.
            $output = $null | & bash --noprofile --norc -eo pipefail $path 2>&1
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = (@($output) -join "`n")
            }
        }
        finally {
            Pop-Location
            foreach ($name in $saved.Keys) {
                [System.Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
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

    It 'passes the <Name> gate only on success or a deliberate skip' -ForEach @(
        @{ File = 'module-ci.yml'; Gate = 'module-checks'; Name = 'Module checks'; Checks = 'offline-contracts' }
        @{ File = 'docs-checks.yml'; Gate = 'docs-checks'; Name = 'Docs checks'; Checks = 'build' }
    ) -Skip:$bashUnavailable {
        # The gate's inputs must come from the jobs it judges.
        $gateEnvironment = @(
            $script:Workflows[$File]['jobs'][$Gate]['steps'] |
                Where-Object { $null -ne $_ }
        )[0]['env']
        @($gateEnvironment.Keys | Sort-Object) |
            Should -BeExactly @('CHANGES_RESULT', 'CHECKS_RESULT', 'RELEVANT')
        $gateEnvironment['CHANGES_RESULT'] |
            Should -BeExactly '${{ needs.changes.result }}'
        $gateEnvironment['RELEVANT'] |
            Should -BeExactly '${{ needs.changes.outputs.relevant }}'
        $gateEnvironment['CHECKS_RESULT'] |
            Should -BeExactly ('${{ needs.' + $Checks + '.result }}')

        # The decision itself, not only the job graph: the gate's own script
        # runs for every combination of upstream results, and only two may
        # pass. An empty relevance value stands in for a failed change
        # detection; this harness removes it from the environment (setting a
        # variable to empty deletes it), and the script rejects both forms.
        $script = Get-TestStepRun -File $File -Job $Gate -Where { $true }
        $passing = @(
            foreach ($changes in 'success', 'failure', 'cancelled', 'skipped') {
                foreach ($relevant in 'true', 'false', 'maybe', '') {
                    foreach ($checks in 'success', 'failure', 'cancelled', 'skipped') {
                        $result = Invoke-TestBashScript -Script $script -Environment @{
                            CHANGES_RESULT = $changes
                            RELEVANT       = $relevant
                            CHECKS_RESULT  = $checks
                        }
                        if ($result.ExitCode -eq 0) {
                            '{0}/{1}/{2}' -f $changes, $relevant, $checks
                        }
                    }
                }
            }
        )
        $passing | Should -BeExactly @('success/true/success', 'success/false/skipped')
    }

    It 'decides whether the checks in <File> must run' -ForEach @(
        @{
            File     = 'module-ci.yml'
            Relevant = 'src/a.ps1'
            Renamed  = 'src/b.ps1'
            Unusual  = 'src/ä b.ps1'
        }
        @{
            File     = 'docs-checks.yml'
            Relevant = 'docs-site/a.mdx'
            Renamed  = 'docs-site/b.mdx'
            Unusual  = 'docs-site/ä b.mdx'
        }
    ) -Skip:$bashUnavailable {
        $script = Get-TestStepRun -File $File -Job 'changes' -Where {
            [string] $_['id'] -ceq 'detect'
        }
        function Get-Relevance {
            param(
                [hashtable] $Environment,
                [string] $WorkingDirectory = $TestDrive
            )

            $outputPath = Join-Path $TestDrive ('output-{0}' -f [guid]::NewGuid())
            [System.IO.File]::WriteAllText($outputPath, '')
            $Environment.GITHUB_OUTPUT = $outputPath
            $Environment.RUNNER_TEMP = $TestDrive
            $Environment.LC_ALL = 'C'
            $result = Invoke-TestBashScript `
                -Script $script `
                -Environment $Environment `
                -WorkingDirectory $WorkingDirectory
            $result.ExitCode | Should -Be 0 -Because $result.Output
            return [System.IO.File]::ReadAllText($outputPath)
        }

        # A push to main, a v* tag and a manual run must never be judged
        # irrelevant: a tag run that skipped its checks would also skip the
        # release jobs and still report green.
        foreach ($eventName in 'push', 'workflow_dispatch') {
            Get-Relevance -Environment @{ EVENT_NAME = $eventName } |
                Should -BeExactly "relevant=true`n"
        }

        # A pull request is judged by a real three-dot diff, so the git
        # invocation, the NUL-separated loop and the assignment all run.
        $repository = Join-Path $TestDrive "repository-$File"
        [void] (New-Item -ItemType Directory -Path $repository)
        function Invoke-TestGit {
            & git -C $repository -c user.name=test -c user.email=test@example.invalid @args
            if ($LASTEXITCODE -ne 0) { throw "git $args failed." }
        }
        Invoke-TestGit init --quiet
        foreach ($path in $Relevant, 'README.md') {
            $full = Join-Path $repository $path
            [void] (New-Item -ItemType Directory -Force -Path (Split-Path $full))
            [System.IO.File]::WriteAllText($full, "base`n")
        }
        Invoke-TestGit add --all
        Invoke-TestGit commit --quiet -m base
        $base = (& git -C $repository rev-parse HEAD).Trim()
        $cases = @(
            @{ Change = { [System.IO.File]::AppendAllText((Join-Path $repository $Relevant), "edit`n") }; Expected = 'true' }
            @{ Change = { Invoke-TestGit mv $Relevant $Renamed }; Expected = 'true' }
            @{ Change = { Invoke-TestGit mv $Relevant 'moved-out.txt' }; Expected = 'true' }
            @{ Change = {
                    $full = Join-Path $repository $Unusual
                    [System.IO.File]::WriteAllText($full, "new`n")
                }; Expected = 'true' }
            @{ Change = { [System.IO.File]::AppendAllText((Join-Path $repository 'README.md'), "edit`n") }; Expected = 'false' }
        )
        foreach ($case in $cases) {
            Invoke-TestGit checkout --quiet --detach $base
            & $case.Change
            Invoke-TestGit add --all
            Invoke-TestGit commit --quiet -m change
            $head = (& git -C $repository rev-parse HEAD).Trim()
            Get-Relevance -WorkingDirectory $repository -Environment @{
                EVENT_NAME = 'pull_request'
                BASE_SHA   = $base
                HEAD_SHA   = $head
            } | Should -BeExactly "relevant=$($case.Expected)`n"
        }
    }

    It 'runs the docs checks whenever the site or a docs workflow changes' {
        $script = Get-TestStepRun -File 'docs-checks.yml' -Job 'changes' -Where {
            [string] $_['id'] -ceq 'detect'
        }
        $match = [regex]::Match($script, "pattern='([^']+)'")
        $match.Success | Should -BeTrue
        $pattern = $match.Groups[1].Value
        foreach ($path in @(
                'docs-site/src/content/docs/index.mdx'
                'docs-site/package.json'
                '.github/workflows/docs-checks.yml'
                '.github/workflows/deploy-docs.yml'
            )) {
            $path | Should -MatchExactly $pattern
        }
        foreach ($path in @(
                'docs-site'
                'README.md'
                'src/AzureDataLabToolkit/AzureDataLabToolkit.psm1'
                '.github/workflows/module-ci.yml'
            )) {
            $path | Should -Not -MatchExactly $pattern
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
            '.editorconfig'
            'PSScriptAnalyzerSettings.psd1'
            'build.ps1'
            'examples/sqlvm-minimal.yaml'
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
                '.editorconfig'
                'PSScriptAnalyzerSettings.psd1'
                'build.ps1'
                'examples/**'
                'src/**'
                'tests/**'
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

Describe 'Release safeguards' {
    It 'keeps every check in the provenance step' {
        $script = Get-TestStepRun -File 'module-ci.yml' -Job 'release-provenance' -Where {
            [string] $_['id'] -ceq 'verify'
        }
        foreach ($literal in @(
                "'^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+)?$'"
                'git merge-base --is-ancestor HEAD origin/main'
                'The release tag does not identify the tested commit.'
                "must equal '`$expectedTag'"
                'must be a regular, '
                'CHANGELOG.md must contain exactly one'
                'Exactly one tested release package is required.'
                'The release package module layout is invalid.'
                '-RequireGit'
            )) {
            $script.Contains($literal) |
                Should -BeTrue -Because "the provenance step must keep: $literal"
        }
    }

    It 'publishes only after attesting and re-checking the tag, and never replaces a release' {
        $steps = @(
            $script:ModuleWorkflow['jobs']['publish-release']['steps'] |
                Where-Object { $null -ne $_ }
        )
        $names = @($steps | ForEach-Object { [string] $_['name'] })
        $names | Should -BeExactly @(
            'Download verified release evidence'
            'Attest release build provenance'
            'Attest release SBOM'
            'Confirm the tag still identifies the verified commit'
            'Publish the release'
        )
        [string] $steps[3]['run'] |
            Should -BeLike '*commits/refs/tags/$TAG*VERIFIED_COMMIT*'
        $publish = [string] $steps[4]['run']
        $publish.Contains('select(.tag_name == $tag)') | Should -BeTrue
        $publish.Contains('refusing to replace it') | Should -BeTrue
        $publish.Contains('--verify-tag') | Should -BeTrue
        $publish.Contains('--prerelease --latest=false') | Should -BeTrue
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
