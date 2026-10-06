"use strict";

(function exposeWizardCore(root, factory) {
  const api = Object.freeze(factory());
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  if (root) {
    root.AzureDataLabWizardCore = api;
  }
})(
  typeof globalThis === "object" ? globalThis : undefined,
  function createWizardCore() {
    const lockedProfileId = "sqlvm-first-canary/v1";
    const uuidPattern =
      /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
    const locationPattern = /^[a-z0-9]{2,40}$/;
    const labNamePattern = /^[A-Za-z0-9][A-Za-z0-9-]{1,62}$/;
    const secretNamePattern = /^[A-Za-z0-9-]{1,127}$/;
    const secretVersionPattern = /^[0-9a-fA-F]{32}$/;
    const profileHashPattern = /^sha256:[a-f0-9]{64}$/;
    const resourceGroupPattern = /^[A-Za-z0-9._()\-]{1,90}$/;
    const keyVaultIdPattern =
      /^\/subscriptions\/([0-9a-fA-F-]{36})\/resourceGroups\/[^/]+\/providers\/Microsoft\.KeyVault\/vaults\/[^/]+$/i;
    const workspaceIdPattern =
      /^\/subscriptions\/([0-9a-fA-F-]{36})\/resourceGroups\/[^/]+\/providers\/Microsoft\.OperationalInsights\/workspaces\/[^/]+$/i;

    const quote = (value) => JSON.stringify(String(value));
    const hasOwn = (value, property) =>
      Object.prototype.hasOwnProperty.call(value, property);

    function validateState(state, deploymentProfile) {
      const errors = {};
      const add = (field, message) => {
        errors[field] = message;
      };

      if (!state || typeof state !== "object") {
        return {
          profileContract: "Wizard state must be a local object."
        };
      }
      if (!deploymentProfile || typeof deploymentProfile !== "object") {
        return {
          profileContract: "The authoritative deployment profile is unavailable."
        };
      }
      if (
        deploymentProfile.id !== lockedProfileId ||
        !profileHashPattern.test(String(deploymentProfile.profileHash || "")) ||
        !deploymentProfile.exactConfiguration ||
        !deploymentProfile.exactConfiguration["sqlVm.compute.vmSize"]
      ) {
        add(
          "profileContract",
          "The wizard supports only the locked sqlvm-first-canary/v1 profile."
        );
      }
      if (
        state.purpose !== "canary" ||
        state.containsSensitiveData !== false
      ) {
        add(
          "profileContract",
          "This profile requires a canary with non-sensitive data and preauthorized owned-resource teardown."
        );
      }
      if (!labNamePattern.test(String(state.labName || ""))) {
        add("labName", "Use 2-63 letters, numbers, or hyphens.");
      }
      if (!uuidPattern.test(String(state.tenantId || ""))) {
        add("tenantId", "Enter a canonical Azure tenant UUID.");
      }
      if (!uuidPattern.test(String(state.subscriptionId || ""))) {
        add("subscriptionId", "Enter a canonical Azure subscription UUID.");
      }
      if (!locationPattern.test(String(state.location || ""))) {
        add("location", "Use the lowercase Azure location name.");
      }
      if (
        !resourceGroupPattern.test(String(state.resourceGroupName || "")) ||
        String(state.resourceGroupName || "").endsWith(".")
      ) {
        add(
          "resourceGroupName",
          "Enter a valid Azure resource group name that does not end in a period."
        );
      }

      const vaultMatch = String(state.keyVaultResourceId || "").match(
        keyVaultIdPattern
      );
      if (!vaultMatch) {
        add(
          "keyVaultResourceId",
          "Enter the full resource ID of an existing Microsoft.KeyVault/vaults resource."
        );
      } else if (
        state.subscriptionId &&
        vaultMatch[1].toLowerCase() !==
          String(state.subscriptionId).toLowerCase()
      ) {
        add(
          "keyVaultResourceId",
          "The Key Vault must be in the configured subscription."
        );
      }

      const workspaceMatch = String(
        state.diagnosticDestinationResourceId || ""
      ).match(workspaceIdPattern);
      if (!workspaceMatch) {
        add(
          "diagnosticDestinationResourceId",
          "Enter a full Log Analytics workspace resource ID."
        );
      } else if (
        state.subscriptionId &&
        workspaceMatch[1].toLowerCase() !==
          String(state.subscriptionId).toLowerCase()
      ) {
        add(
          "diagnosticDestinationResourceId",
          "The workspace must be in the configured subscription."
        );
      }

      if (!secretNamePattern.test(String(state.secretName || ""))) {
        add("secretName", "Use 1-127 letters, numbers, or hyphens.");
      }
      if (!secretVersionPattern.test(String(state.secretVersion || ""))) {
        add("secretVersion", "Enter exactly 32 hexadecimal characters.");
      }
      if (
        !Number.isInteger(state.maximumRunCost) ||
        state.maximumRunCost < 1 ||
        state.maximumRunCost > 10000000
      ) {
        add("maximumRunCost", "Enter a whole amount from 1 to 10,000,000.");
      }
      if (
        !Number.isInteger(state.maximumRuntimeMinutes) ||
        state.maximumRuntimeMinutes < 30 ||
        state.maximumRuntimeMinutes > 720
      ) {
        add(
          "maximumRuntimeMinutes",
          "Runtime must be a whole number from 30 to 720 minutes."
        );
      }
      if (
        !Number.isInteger(state.timeToLiveMinutes) ||
        state.timeToLiveMinutes < 60 ||
        state.timeToLiveMinutes > 1440
      ) {
        add(
          "timeToLiveMinutes",
          "Time to live must be a whole number from 60 to 1,440 minutes."
        );
      } else if (state.timeToLiveMinutes < state.maximumRuntimeMinutes) {
        add(
          "timeToLiveMinutes",
          "Time to live must cover the complete maximum runtime."
        );
      }
      if (!["CHF", "EUR", "USD"].includes(String(state.currency || ""))) {
        add("currency", "Choose CHF, EUR, or USD.");
      }

      return errors;
    }

    function buildYaml(state, deploymentProfile) {
      const descriptionLine = state.description
        ? `  description: ${quote(state.description)}\n`
        : "";
      const amountMinorUnits = state.maximumRunCost * 100;
      const vmSize =
        deploymentProfile.exactConfiguration["sqlVm.compute.vmSize"];

      return (
        'schemaVersion: "1.0"\n' +
        "kind: AzureDataLab\n" +
        "template: sqlvm-first-canary\n" +
        "deploymentProfile:\n" +
        `  id: ${quote(deploymentProfile.id)}\n` +
        `  hash: ${quote(deploymentProfile.profileHash)}\n` +
        "metadata:\n" +
        `  name: ${quote(state.labName)}\n` +
        descriptionLine +
        "  purpose: canary\n" +
        "target:\n" +
        "  type: sqlVm\n" +
        "azure:\n" +
        "  cloud: AzureCloud\n" +
        `  tenantId: ${quote(state.tenantId)}\n` +
        `  subscriptionId: ${quote(state.subscriptionId)}\n` +
        `  location: ${quote(state.location)}\n` +
        "  authentication:\n" +
        "    mode: interactive-user\n" +
        "    contextScope: process\n" +
        "  resourceGroup:\n" +
        "    mode: create\n" +
        `    name: ${quote(state.resourceGroupName)}\n` +
        "engine:\n" +
        "  type: powershell\n" +
        "security:\n" +
        "  vmManagedIdentity: system-assigned\n" +
        "  secretStore:\n" +
        "    mode: reuse-key-vault\n" +
        `    resourceId: ${quote(state.keyVaultResourceId)}\n` +
        "    diagnosticDestinationResourceId: " +
        `${quote(state.diagnosticDestinationResourceId)}\n` +
        "  administrativeAccess:\n" +
        "    mode: deploy-bastion\n" +
        "    sku: basic\n" +
        "  vmAdministratorCredential:\n" +
        "    source: key-vault-secret\n" +
        `    secretName: ${quote(state.secretName)}\n` +
        `    secretVersion: ${quote(state.secretVersion)}\n` +
        "    allowShellOutput: false\n" +
        "  containsSensitiveData: false\n" +
        "cost:\n" +
        "  estimateRequested: true\n" +
        "  maximumRunCost:\n" +
        `    amountMinorUnits: ${amountMinorUnits}\n` +
        `    currency: ${state.currency}\n` +
        "  budget:\n" +
        `    currency: ${state.currency}\n` +
        "lifecycle:\n" +
        `  maximumRuntimeMinutes: ${state.maximumRuntimeMinutes}\n` +
        `  timeToLiveMinutes: ${state.timeToLiveMinutes}\n` +
        "  expiryBehavior: cleanup-only\n" +
        "  teardown:\n" +
        "    mode: preauthorized-canary\n" +
        "    strategy: exact-resource-ids\n" +
        "    retainResourceGroup: true\n" +
        "    freshInventoryRequired: true\n" +
        "    retainBackupShare: false\n" +
        "capabilities:\n" +
        "  backupShare:\n" +
        "    enabled: false\n" +
        "    driveLetter: S\n" +
        "    quotaGiB: 100\n" +
        "    authentication: managed-identity-smb-oauth\n" +
        "    networkAccess: private-endpoint\n" +
        "solutionPacks:\n" +
        "  sqlVmBackupRestore:\n" +
        "    enabled: false\n" +
        "    restoreMode: local-staging\n" +
        "    replaceExistingDatabase: false\n" +
        "sqlVm:\n" +
        "  platform: windows\n" +
        '  sqlServerVersion: "2022"\n' +
        "  compute:\n" +
        `    vmSize: ${vmSize}\n` +
        "    securityType: trustedLaunch\n" +
        "    encryptionAtHost: true\n" +
        "  network:\n" +
        "    vmPublicIp: false\n" +
        "  software:\n" +
        "    catalogIds: []\n" +
        "  sampleData:\n" +
        "    catalogIds: []\n"
      );
    }

    function generate(state, deploymentProfile) {
      const errors = validateState(state, deploymentProfile);
      const matchesLockedProfile = Object.keys(errors).length === 0;
      return Object.freeze({
        matchesLockedProfile,
        requiresPowerShellValidation: true,
        requiresAzurePreflight: true,
        errors: Object.freeze({ ...errors }),
        yaml: matchesLockedProfile
          ? buildYaml(state, deploymentProfile)
          : null
      });
    }

    return {
      lockedProfileId,
      generate,
      validateState,
      hasError(errors, property) {
        return hasOwn(errors, property);
      }
    };
  }
);
