# Security Policy

## What this software does

Azure Data Lab Toolkit authenticates to Azure, creates real resources, and deletes them. It is
intended to be run by its owner against their own subscription.

Read this before you run anything:

- **This is alpha software.** v0.1.0-alpha1 is the first prerelease, published on GitHub
  Releases only; there is no package on the PowerShell Gallery. Anything else you obtain is a
  development snapshot from a branch.
- **It has never been run against a live Azure subscription.** Not once. Every Azure-facing
  code path is implemented and unit-tested, and none of it is field-proven.
- `Start-AzureDataLabDeployment` creates billable Azure resources.
  `Start-AzureDataLabTeardown` deletes resources.
- There is no production security baseline and the project is not production ready.

If you choose to run it, use a throwaway subscription or a dedicated resource group with a
spend cap.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately through GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**, or go straight to
<https://github.com/kaysauter/Azure-Data-Lab-Toolkit/security/advisories/new>. If you cannot
use GitHub, email **kay@kayondata.com** instead. Either way, include:

- what you found and where (file and line, or a command sequence)
- what an attacker could achieve
- how to reproduce it
- the commit SHA you looked at

You will get an acknowledgement. This is a single-maintainer project, so no fix timeline is
promised — you will be told honestly whether and when it will be addressed, rather than given
a target that gets missed.

## Supported versions

| Version | Supported |
| --- | --- |
| Latest alpha prerelease (0.1.0-alpha1) | Fixes land on the default branch and ship in the next alpha tag |
| Older tags and untagged snapshots | No |

No version is supported for production use, and there are no backports: a fix reaches users
through the next alpha tag.

## Scope

In scope, and genuinely interesting:

- Any path by which a secret value reaches the normalized plan, run state, evidence, logs,
  reports, or the module's own process memory. The design intends that the VM administrator
  password **cannot** enter the process: it is an ARM `secureString` fed by a Key Vault
  reference with a pinned `secretVersion`. A counterexample is a real finding.
- Any way to call an Azure command that is not on the allowlist in
  `src/AzureDataLabToolkit/Private/70-AzureCommand.ps1`, or to escape the parameter-shape
  checks it applies to nine of those commands.
- Any way to deploy or delete without a matching typed approval phrase, approver principal, and
  mutation lease — including replaying or forging an execution authorization, or breaking the
  hash chain from `planHash` through to `readinessHash`.
- Any way to make teardown delete a resource that is not in the approved inventory.
- Supply-chain gaps: the module script lock and its closed-world check, the runtime dependency
  lock, the build-tool lock, or the SBOM.
- Local privilege or information disclosure via the run store, whose files are meant to be
  owner-only on all platforms.
- Anything in the browser configuration wizard that reaches the network, accepts a secret, or
  escapes its `file://` sandbox.

Out of scope:

- Features that are documented as absent. Guest software installation and database restore are
  not implemented; saying so is not a vulnerability.
- Cost. An expensive but correctly approved deployment is a licensing or sizing choice, not a
  security issue. `Start-AzureDataLabDeployment` tells you what it will create.
- `-GeneratePassword` and `-ShowGeneratedPassword` not doing anything. They record plan intent
  only — there is no password generator in this module and nothing writes a value to the host.
  `-ShowGeneratedPassword` sets `allowShellOutput`, which raises a high-severity
  acknowledge-required finding and nothing consumes. If you find a path that *does* emit a
  credential, that is firmly in scope.
- `packageDigest` not being verified. Wherever it appears — the runtime dependency lock, the
  runtime identity, an execution authorization and the runtime-dependency checksums in the
  release SBOM — it is copied from the lock and records which upstream package archive the lock
  was reviewed against. The dependency installer's `Install-PSResource` call downloads and
  unpacks that archive but keeps no copy, and nothing in this module or its release workflow
  hashes it. The installed-content guarantee is `contentDigest`: the installed files are hashed
  and compared with it when a locked dependency is verified, immediately before it is imported.
  A way to make the module load dependency content that does not match its `contentDigest` is
  firmly in scope.
- Findings that require an attacker who can already write to the repository, your PowerShell
  installation, or your Azure subscription. Those attackers defeat everything here by simpler
  means.
- Vulnerabilities in Azure itself, or in the pinned third-party modules. Report those upstream.

## What is already enabled

Private vulnerability reporting, secret scanning and push protection are on for this
repository. Dependabot security updates are not yet enabled.

## Credit

Reporters are credited by name in the release notes unless they ask not to be. There is no
bug bounty.
