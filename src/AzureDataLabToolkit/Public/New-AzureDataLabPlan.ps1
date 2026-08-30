function New-AzureDataLabPlan {
    <#
    .SYNOPSIS
    Creates a deterministic Azure Data Lab plan without contacting Azure.

    .DESCRIPTION
    Resolves configuration in the order schema defaults, template, YAML, and
    explicit command flags. The resulting immutable plan records provenance,
    ownership, security decisions, lifecycle intent, and a SHA-256 plan hash.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [System.Collections.IDictionary] $InputObject,

        [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
        [string] $Template,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{1,62}$')]
        [string] $Name,

        [ValidateSet('lab', 'canary')]
        [string] $Purpose,

        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $TenantId,

        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string] $SubscriptionId,

        [ValidatePattern('^[a-z0-9]+$')]
        [string] $Location,

        [ValidateSet('interactive-user', 'managed-identity', 'oidc')]
        [string] $AuthenticationMode,

        [ValidateLength(1, 90)]
        [string] $ResourceGroupName,

        [ValidateSet('powershell', 'bicep', 'terraform')]
        [string] $Engine,

        [ValidateSet('deploy-key-vault', 'reuse-key-vault', 'approved-external-store', 'not-applicable')]
        [string] $SecretStoreMode,

        [ValidatePattern('^/subscriptions/[0-9a-fA-F-]+/')]
        [string] $SecretStoreResourceId,

        [ValidatePattern('^/subscriptions/[0-9a-fA-F-]+/')]
        [string] $KeyVaultDiagnosticDestinationResourceId,

        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string] $VmAdministratorSecretVersion,

        [ValidateSet('deploy-bastion', 'reuse-bastion', 'opt-out')]
        [string] $AdministrativeAccessMode,

        [ValidatePattern('^/subscriptions/[0-9a-fA-F-]+/')]
        [string] $BastionResourceId,

        [ValidateLength(10, 500)]
        [string] $AdministrativeAccessRationale,

        [ValidateSet('developer', 'basic', 'standard', 'premium')]
        [string] $BastionSku,

        [ValidateSet('standard', 'trustedLaunch', 'confidentialVm')]
        [string] $VmSecurityType,

        [ValidatePattern('^/subscriptions/[0-9a-fA-F-]+/')]
        [string] $DiskEncryptionSetResourceId,

        [ValidateSet('2022', '2025')]
        [string] $SqlServerVersion,

        [string[]] $SoftwareId,

        [string[]] $SampleDataId,

        [switch] $GeneratePassword,

        [switch] $ShowGeneratedPassword,

        [switch] $ContainsSensitiveData,

        [switch] $CostEstimate,

        [ValidateRange(1, 1000000000)]
        [long] $MonthlyBudget,

        [ValidateRange(1, 1000000000000)]
        [long] $MaximumRunCostMinorUnits,

        [ValidatePattern('^[A-Z]{3}$')]
        [string] $BudgetCurrency,

        [ValidateRange(30, 720)]
        [int] $MaximumRuntimeMinutes,

        [ValidateRange(60, 1440)]
        [int] $TimeToLiveMinutes,

        [switch] $PreauthorizeTeardown,

        [switch] $DeleteBackupShareOnTeardown,

        [switch] $EnableBackupShare,

        [ValidateRange(1, 102400)]
        [int] $BackupShareQuotaGiB,

        [ValidatePattern('^[D-Z]$')]
        [string] $BackupDriveLetter
    )

    process {
        $overrides = [ordered]@{}
        $parameterPathMap = [ordered]@{
            Name                     = 'metadata.name'
            Purpose                  = 'metadata.purpose'
            TenantId                 = 'azure.tenantId'
            SubscriptionId           = 'azure.subscriptionId'
            Location                 = 'azure.location'
            AuthenticationMode       = 'azure.authentication.mode'
            ResourceGroupName        = 'azure.resourceGroup.name'
            Engine                   = 'engine.type'
            SecretStoreMode          = 'security.secretStore.mode'
            SecretStoreResourceId    = 'security.secretStore.resourceId'
            KeyVaultDiagnosticDestinationResourceId =
                'security.secretStore.diagnosticDestinationResourceId'
            VmAdministratorSecretVersion =
                'security.vmAdministratorCredential.secretVersion'
            AdministrativeAccessMode = 'security.administrativeAccess.mode'
            BastionResourceId        = 'security.administrativeAccess.resourceId'
            AdministrativeAccessRationale = 'security.administrativeAccess.rationale'
            BastionSku               = 'security.administrativeAccess.sku'
            VmSecurityType           = 'sqlVm.compute.securityType'
            DiskEncryptionSetResourceId = 'sqlVm.compute.diskEncryptionSetId'
            SqlServerVersion         = 'sqlVm.sqlServerVersion'
            SoftwareId               = 'sqlVm.software.catalogIds'
            SampleDataId             = 'sqlVm.sampleData.catalogIds'
            MonthlyBudget            = 'cost.budget.monthlyLimit'
            MaximumRunCostMinorUnits = 'cost.maximumRunCost.amountMinorUnits'
            BudgetCurrency           = 'cost.budget.currency'
            MaximumRuntimeMinutes    = 'lifecycle.maximumRuntimeMinutes'
            TimeToLiveMinutes        = 'lifecycle.timeToLiveMinutes'
            BackupShareQuotaGiB      = 'capabilities.backupShare.quotaGiB'
            BackupDriveLetter        = 'capabilities.backupShare.driveLetter'
        }

        foreach ($parameterName in $parameterPathMap.Keys) {
            if ($PSBoundParameters.ContainsKey($parameterName)) {
                $overrides[$parameterPathMap[$parameterName]] = $PSBoundParameters[$parameterName]
            }
        }

        if ($GeneratePassword.IsPresent) {
            $overrides['security.vmAdministratorCredential.source'] = 'generate-during-deployment'
        }
        if ($ShowGeneratedPassword.IsPresent) {
            $overrides['security.vmAdministratorCredential.allowShellOutput'] = $true
        }
        if ($ContainsSensitiveData.IsPresent) {
            $overrides['security.containsSensitiveData'] = $true
        }
        if ($CostEstimate.IsPresent) {
            $overrides['cost.estimateRequested'] = $true
        }
        if ($PreauthorizeTeardown.IsPresent) {
            $overrides['lifecycle.teardown.mode'] = 'preauthorized-canary'
        }
        if ($DeleteBackupShareOnTeardown.IsPresent) {
            $overrides['lifecycle.teardown.retainBackupShare'] = $false
        }
        if ($EnableBackupShare.IsPresent) {
            $overrides['capabilities.backupShare.enabled'] = $true
        }

        $resolveParameters = @{
            Overrides = $overrides
        }
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $resolveParameters.Path = $Path
        }
        else {
            $resolveParameters.InputObject = $InputObject
        }
        if ($PSBoundParameters.ContainsKey('Template')) {
            $resolveParameters.Template = $Template
        }

        $resolution = Resolve-AdltConfiguration @resolveParameters
        return New-AdltTargetPlan `
            -Configuration $resolution.Configuration `
            -Provenance $resolution.Provenance
    }
}
