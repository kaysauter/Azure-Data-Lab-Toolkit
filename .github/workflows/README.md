# GitHub Workflows

GitHub is the first planned CI/CD provider.

The initial workflow set is expected to include:

- Pester and PowerShell parser checks;
- PSScriptAnalyzer;
- documentation and link validation;
- CodeQL;
- Checkov for Bicep and Terraform;
- dependency and vulnerability scanning;
- opt-in Azure deployment tests with teardown verification.

No workflow is added until there is executable code or configuration for it to validate.
