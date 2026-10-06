function New-AdltResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Id,

        [Parameter(Mandatory)]
        [string] $Type,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d{4}-\d{2}-\d{2}(-preview)?$')]
        [string] $ApiVersion,

        [Parameter(Mandatory)]
        [string] $LogicalName,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $DesiredProperties,

        [Parameter(Mandatory)]
        [ValidateSet('create', 'reuse', 'observe')]
        [string] $OwnershipIntent,

        [Parameter(Mandatory)]
        [ValidateSet('owned', 'adopted', 'reused', 'external')]
        [string] $ExpectedClassification,

        [ValidateSet('delete-after-proof-and-approval', 'retain', 'retain-until-separately-approved')]
        [string] $TeardownIntent,

        [AllowNull()]
        [string] $ExternalResourceId = $null
    )

    $normalizedExternalResourceId = if (
        [string]::IsNullOrWhiteSpace($ExternalResourceId)
    ) {
        $null
    }
    else {
        [string] $ExternalResourceId
    }
    if ($DesiredProperties.Count -eq 0) {
        throw "Resource '$Id' must declare desired properties."
    }
    if (
        $OwnershipIntent -eq 'reuse' -and
        $null -eq $normalizedExternalResourceId
    ) {
        throw "Reused resource '$Id' must declare an external resource ID."
    }
    if (
        $OwnershipIntent -eq 'create' -and
        $null -ne $normalizedExternalResourceId
    ) {
        throw "Created resource '$Id' cannot declare an external resource ID."
    }

    if (-not $PSBoundParameters.ContainsKey('TeardownIntent')) {
        $TeardownIntent = if ($ExpectedClassification -in @('reused', 'external')) {
            'retain'
        }
        else {
            'delete-after-proof-and-approval'
        }
    }

    return [ordered]@{
        id          = $Id
        type        = $Type
        apiVersion  = $ApiVersion
        logicalName = $LogicalName
        externalResourceId = $normalizedExternalResourceId
        desiredProperties = Copy-AdltValue -InputObject $DesiredProperties
        ownership   = [ordered]@{
            intent                 = $OwnershipIntent
            expectedClassification = $ExpectedClassification
            observedClassification = 'unverified'
            collisionPolicy        = 'fail'
            replacePolicy          = 'forbidden'
            teardownIntent         = $TeardownIntent
        }
        desiredState = 'present'
        liveState    = 'unverified'
    }
}

function New-AdltAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Id,

        [Parameter(Mandatory)]
        [ValidateSet('ensure', 'reference', 'stage', 'render')]
        [string] $Operation,

        [Parameter(Mandatory)]
        [string] $ResourceId,

        [ValidateSet('offline', 'azure', 'guest')]
        [string] $ExecutionScope,

        [Parameter(Mandatory)]
        [ValidatePattern('^sha256:[a-f0-9]{64}$')]
        [string] $PlanIntentHash,

        [string[]] $DependsOn = @(),

        [bool] $Mutation = $true,

        [ValidateSet('intend-owned', 'intend-reused', 'none')]
        [string] $OwnershipEffect = 'intend-owned',

        [string[]] $Postconditions = @('desired-state-observed')
    )

    if (-not $PSBoundParameters.ContainsKey('ExecutionScope')) {
        $ExecutionScope = if ($Operation -eq 'render') {
            'offline'
        }
        elseif ($ResourceId -like 'azure.*') {
            'azure'
        }
        else {
            'guest'
        }
    }
    $preconditions = switch ($ExecutionScope) {
        'offline' {
            @(
                'approved-plan-hash-matches'
                'local-input-contract-valid'
            )
        }
        'azure' {
            @(
                'approved-plan-hash-matches'
                'live-state-observed'
                'ownership-established'
                'collision-check-passed'
            )
        }
        'guest' {
            @(
                'approved-plan-hash-matches'
                'live-state-observed'
                'target-ready'
                'guest-execution-authorized'
                'collision-check-passed'
            )
        }
    }
    $reconciliationStateSource = switch ($ExecutionScope) {
        'offline' { 'local-artifact-state' }
        'azure' { 'azure-control-plane' }
        'guest' { 'guest-probe' }
    }

    return [ordered]@{
        id             = $Id
        operation      = $Operation
        resourceId     = $ResourceId
        executionScope = $ExecutionScope
        dependsOn      = @($DependsOn)
        mutation       = $Mutation
        retryClass     = 'reconcile-before-retry'
        idempotencyKey = ('adlt:v1:{0}:{1}' -f $PlanIntentHash, $Id)
        ownershipEffect = $OwnershipEffect
        preconditions  = @($preconditions)
        postconditions = @($Postconditions)
        reconciliation = [ordered]@{
            beforeAttempt = 'required'
            afterAttempt  = 'required'
            unknownState  = 'stop'
            stateSource   = $reconciliationStateSource
        }
    }
}

function New-AdltStableAzureNameSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    $slug = ConvertTo-AdltSlug -Value $Configuration.metadata.name -MaximumLength 20
    $subscriptionIdentity = (
        [string] $Configuration.azure.subscriptionId
    ).Trim().ToLowerInvariant()
    $resourceGroupIdentity = (
        [string] $Configuration.azure.resourceGroup.name
    ).Trim().ToLowerInvariant()
    $nameSeed = '{0}|{1}|{2}|{3}|{4}' -f
        $subscriptionIdentity,
        $Configuration.azure.location,
        $resourceGroupIdentity,
        $Configuration.metadata.name,
        $Configuration.target.type
    $suffix = (Get-AdltSha256 -Value $nameSeed).Substring(0, 12)
    $compactSlug = $slug -replace '-', ''

    $keyVaultPrefix = 'adlt'
    $maximumKeyVaultSlugLength = (
        24 - $keyVaultPrefix.Length - $suffix.Length - 2
    )
    $keyVaultSlug = if ($slug.Length -gt $maximumKeyVaultSlugLength) {
        $slug.Substring(0, $maximumKeyVaultSlugLength).TrimEnd('-')
    }
    else {
        $slug
    }
    $keyVaultName = '{0}-{1}-{2}' -f $keyVaultPrefix, $keyVaultSlug, $suffix

    $storagePrefix = 'adlt'
    $maximumStorageSlugLength = 24 - $storagePrefix.Length - $suffix.Length
    $storageSlug = if ($compactSlug.Length -gt $maximumStorageSlugLength) {
        $compactSlug.Substring(0, $maximumStorageSlugLength)
    }
    else {
        $compactSlug
    }
    $storageName = '{0}{1}{2}' -f $storagePrefix, $storageSlug, $suffix
    $virtualMachineName = ConvertTo-AdltSlug `
        -Value ('vm-{0}' -f $slug) `
        -MaximumLength 15

    return [ordered]@{
        virtualNetwork       = ('vnet-{0}' -f $slug)
        workloadSubnet       = 'snet-workload'
        bastionSubnet        = 'AzureBastionSubnet'
        networkSecurityGroup = ('nsg-{0}' -f $slug)
        networkInterface     = ('nic-{0}' -f $slug)
        keyVault             = $keyVaultName
        keyVaultPrivateEndpoint = ('pep-{0}-vault' -f $slug)
        keyVaultPrivateDnsZone = 'privatelink.vaultcore.azure.net'
        keyVaultDnsZoneLink  = ('link-{0}-vault' -f $slug)
        keyVaultDnsZoneGroup = 'default'
        keyVaultRole         = Get-AdltDeterministicGuid -Value (
            '{0}|role|key-vault-secrets' -f $nameSeed
        )
        bastion              = ('bas-{0}' -f $slug)
        bastionPublicIp      = ('pip-{0}-bastion' -f $slug)
        virtualMachine       = $virtualMachineName
        sqlVirtualMachine    = $virtualMachineName
        storageAccount       = $storageName
        fileShare            = 'backups'
        privateEndpoint      = ('pep-{0}-files' -f $slug)
        backupPrivateDnsZone = 'privatelink.file.core.windows.net'
        backupDnsZoneLink    = ('link-{0}-files' -f $slug)
        backupDnsZoneGroup   = 'default'
        fileShareRole        = Get-AdltDeterministicGuid -Value (
            '{0}|role|files-smb' -f $nameSeed
        )
    }
}

function Get-AdltResourceNameFromId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^/subscriptions/[0-9a-fA-F-]+/')]
        [string] $ResourceId
    )

    return $ResourceId.TrimEnd('/').Substring(
        $ResourceId.TrimEnd('/').LastIndexOf('/') + 1
    )
}

function New-AdltPolicyFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^policy\.[a-z0-9.-]+$')]
        [string] $Id,

        [Parameter(Mandatory)]
        [ValidateSet('information', 'warning', 'high', 'blocking')]
        [string] $Severity,

        [Parameter(Mandatory)]
        [ValidateSet('observe', 'acknowledge', 'resolve-before-deploy')]
        [string] $Effect,

        [Parameter(Mandatory)]
        [string] $ConfigurationPath,

        [Parameter(Mandatory)]
        [string] $Message
    )

    return [ordered]@{
        id                      = $Id
        severity                = $Severity
        effect                  = $Effect
        configurationPath       = $ConfigurationPath
        message                 = $Message
        acknowledgementRequired = $Effect -eq 'acknowledge'
        blocksDeployment        = $Effect -eq 'resolve-before-deploy'
    }
}

function Get-AdltCanonicalPlanIntentPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $payload = Copy-AdltValue -InputObject $Plan

    # These fields are derived from this payload or belong to a particular run.
    foreach ($field in @(
            'planHash',
            'intentHash',
            'generatedAt',
            'timestamp',
            'runId',
            'runIntentId'
        )) {
        if ($payload.Contains($field)) {
            $payload.Remove($field)
        }
    }

    foreach ($action in @($payload.actions)) {
        if ($action.Contains('idempotencyKey')) {
            $action.Remove('idempotencyKey')
        }
    }

    return $payload
}

function Set-AdltPlanIntentBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Plan
    )

    $intentPayload = Get-AdltCanonicalPlanIntentPayload -Plan $Plan
    $intentHash = Get-AdltSha256Identifier -Value (
        ConvertTo-AdltCanonicalJson -InputObject $intentPayload
    )

    $Plan.intentHash = $intentHash
    foreach ($action in @($Plan.actions)) {
        $action.idempotencyKey = 'adlt:v1:{0}:{1}' -f
            $intentHash,
            $action.id
    }
    $Plan.planHash = Get-AdltPlanHash -Plan $Plan

    return $Plan
}

# Complete the target contributor's graph before deriving integrity fields.
function New-AdltTargetPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Provenance
    )

    $targetType = [string] $Configuration.target.type
    if (-not $script:AdltTargetPlanContributors.Contains($targetType)) {
        throw "No target plan contributor is registered for '$targetType'."
    }

    $descriptor = $script:AdltTargetPlanContributors[$targetType]
    if (
        $descriptor.supportedSchemaVersions -notcontains
        $Configuration.schemaVersion
    ) {
        throw "Target contributor '$targetType' does not support schema '$($Configuration.schemaVersion)'."
    }

    Assert-AdltContributorGraph -Configuration $Configuration

    $command = Get-Command `
        -Name $descriptor.planFunctionName `
        -CommandType Function `
        -ErrorAction Stop
    $plan = & $command `
        -Configuration $Configuration `
        -Provenance $Provenance
    [void] (Set-AdltPlanIntentBinding -Plan $plan)
    Assert-AdltPlanContract -Plan $plan

    return $plan
}
