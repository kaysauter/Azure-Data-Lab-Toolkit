function Resolve-AdltSqlVmBackupRestoreConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance
    )

    $backupShareEnabled = [bool] $Configuration.capabilities.backupShare.enabled
    $solutionPackEnabled = [bool] $Configuration.solutionPacks.sqlVmBackupRestore.enabled
    if (-not $backupShareEnabled -and -not $solutionPackEnabled) {
        return
    }

    if (-not $backupShareEnabled) {
        Set-AdltDerivedValue `
            -Configuration $Configuration `
            -Provenance $Provenance `
            -Path 'capabilities.backupShare.enabled' `
            -Value $true `
            -Rule 'sqlvm-backup-restore-requires-azure-files'
    }

    if (-not $solutionPackEnabled) {
        Set-AdltDerivedValue `
            -Configuration $Configuration `
            -Provenance $Provenance `
            -Path 'solutionPacks.sqlVmBackupRestore.enabled' `
            -Value $true `
            -Rule 'backup-share-enables-manual-restore-pack'
    }

    $restore = $Configuration.solutionPacks.sqlVmBackupRestore
    if ($restore.restoreMode -ne 'local-staging') {
        throw "Restore mode '$($restore.restoreMode)' is not supported by the first restore solution pack."
    }
    if ($restore.replaceExistingDatabase) {
        throw 'Database replacement is refused by the first restore solution pack.'
    }

    $catalogIds = [System.Collections.Generic.List[string]]::new()
    foreach ($catalogId in @($Configuration.sqlVm.software.catalogIds)) {
        if (-not $catalogIds.Contains([string] $catalogId)) {
            $catalogIds.Add([string] $catalogId)
        }
    }

    if (-not $catalogIds.Contains('software.dbatools')) {
        $catalogIds.Add('software.dbatools')
        Set-AdltDerivedValue `
            -Configuration $Configuration `
            -Provenance $Provenance `
            -Path 'sqlVm.software.catalogIds' `
            -Value $catalogIds.ToArray() `
            -Rule 'backup-share-requires-dbatools'
    }
}

function Get-AdltSqlVmBackupRestorePlanFragment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Names,

        [Parameter(Mandatory)]
        [string] $PlanIntentHash
    )

    if (-not $Configuration.solutionPacks.sqlVmBackupRestore.enabled) {
        return
    }
    if ([string]::IsNullOrWhiteSpace([string] $Names.fileShare)) {
        throw 'The backup-restore solution pack requires a resolved file-share name.'
    }

    $renderAction = New-AdltAction `
        -Id 'action.guest.restore-script.render.backups' `
        -Operation 'render' `
        -ResourceId 'guest.restore-script.backups' `
        -PlanIntentHash $PlanIntentHash `
        -Mutation $false `
        -OwnershipEffect 'none' `
        -Postconditions @(
            'script-rendered-locally'
            'manual-restore-required'
            'preview-is-default'
            'execute-switch-required'
            'database-replacement-disabled'
        )
    $stageAction = New-AdltAction `
        -Id 'action.guest.restore-script.stage.backups' `
        -Operation 'stage' `
        -ResourceId 'guest.restore-script.backups' `
        -PlanIntentHash $PlanIntentHash `
        -DependsOn @(
            'action.guest.restore-script.render.backups'
            'action.guest.mount-script.stage.backups'
            'action.catalog.stage.software.dbatools'
        ) `
        -OwnershipEffect 'none' `
        -Postconditions @(
            'script-present-on-file-share'
            'remote-staging-requires-approved-engine'
            'manual-restore-required'
        )

    return [ordered]@{
        name      = 'sqlVmBackupRestore'
        resources = @()
        actions   = @($renderAction, $stageAction)
        decisions = [ordered]@{
            secretStoreDecision = [ordered]@{
                mode      = 'not-applicable'
                rationale = 'The manual restore script contains no secret and runs under the explicitly signed-in user context.'
            }
        }
        warnings  = @(
            'Backup restore is manual by design; no SYSTEM, extension, Run Command, SQL Agent, or scheduled restore is planned.'
        )
    }
}

Register-AdltSolutionPackPlanContributor `
    -Name 'sqlVmBackupRestore' `
    -FunctionName 'Get-AdltSqlVmBackupRestorePlanFragment' `
    -ConfigurationFunctionName 'Resolve-AdltSqlVmBackupRestoreConfiguration' `
    -ContractVersion '1.0' `
    -SupportedSchemaVersions @('1.0') `
    -TargetTypes @('sqlVm') `
    -ActivationPaths @(
        'capabilities.backupShare.enabled'
        'solutionPacks.sqlVmBackupRestore.enabled'
    ) `
    -Dependencies @(
        'capability:azureFilesBackup'
        'catalog:software.dbatools'
    )
