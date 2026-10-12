# GitHub Workflows

| Workflow | Runs on | What it does |
| --- | --- | --- |
| [`module-ci.yml`](module-ci.yml) | Every pull request; pushes to `main` that change `src/`, `tests/`, `examples/`, `build.ps1`, the analyzer settings, `.editorconfig`, `.gitattributes` or any workflow file; `v*` tags; manual runs | Runs `./build.ps1 -Task All` (parser and PSScriptAnalyzer checks, Pester with the coverage gate, build and package) with PowerShell 7.6 or later on Linux, Windows and macOS. On a pull request, only when it changes one of the paths listed for pushes. A `v*` tag also verifies, attests and publishes the release. |
| [`docs-checks.yml`](docs-checks.yml) | Every pull request; manual runs | Builds the Astro site and the Slidev deck in `docs-site/` and checks internal routes and anchors. On a pull request, only when it changes `docs-site/`, `docs-checks.yml` or `deploy-docs.yml`. |
| [`deploy-docs.yml`](deploy-docs.yml) | Pushes to `main` that change `docs-site/`, `CHANGELOG.md` or the workflow; manual runs | Builds and link-checks the site, then deploys it to GitHub Pages. |

## Required checks

The `main` ruleset requires two checks from GitHub Actions: **Module checks**,
the gate job of `module-ci.yml`, and **Docs checks**, the gate job of
`docs-checks.yml`.

A workflow that a path filter skips leaves its required checks pending, which
blocks the merge. Both workflows therefore run on every pull request, and their
first job, `changes`, diffs the pull request against its merge base to decide
whether the real checks are needed. The gate job runs even when an earlier job
fails or the run is cancelled. It passes only when the checks succeeded, or were
skipped because nothing they cover changed; anything else fails it.

A pull request runs the workflow files it contains, its own gate included, so a
change under `.github/workflows/` deserves the same review as the code it
guards. `tests/Unit/Workflows.Tests.ps1` pins the properties these files must
keep, and module checks run whenever any workflow file changes.

## Releases

Releases are published by `module-ci.yml`; do not create them by hand.

1. Merge to `main` a commit whose manifest,
   `src/AzureDataLabToolkit/AzureDataLabToolkit.psd1`, carries the release
   version, and which contains `release-notes/<version>.md` and a
   `## [<version>]` section in `CHANGELOG.md`. `<version>` is `ModuleVersion`,
   followed by `-<Prerelease>` for a prerelease.
2. Push the tag `v<version>`, for example `v0.1.0-alpha1`, on that commit. Push
   release tags one at a time: GitHub creates no push event when more than three
   tags are pushed at once.
3. The three platform checks run on the tagged commit, and the Linux leg keeps
   the tested package for 7 days.
4. **Protected release provenance** runs with a read-only token. It requires
   that:
   - the tag has the form `v<major>.<minor>.<patch>[-<prerelease>]`, its commit
     is reachable from `main` and is the commit the platform checks tested, and
     it equals `v` plus the manifest version;
   - there is exactly one tested package, named
     `AzureDataLabToolkit-<version>.zip` and laid out as
     `AzureDataLabToolkit/<ModuleVersion>`, and its build provenance records
     that commit and version;
   - `release-notes/<version>.md` is a non-empty file, and `CHANGELOG.md` has
     exactly one `## [<version>]` section.

   It then writes the package's SHA-256 file and an SPDX 2.3 SBOM, and keeps
   the package, both files and the notes as an artifact for 90 days.
5. **Publish release** runs no repository code. It attests the package's build
   provenance and SBOM, confirms that the tag still points at the verified
   commit, and only then creates the GitHub release, with
   `release-notes/<version>.md` as its body and the zip, its `.sha256` file and
   `sbom.spdx.json` as assets. A prerelease is marked as one and never becomes
   the latest release.

A failed run leaves no partial public release, and a tag that already has a
release, even a draft, fails at the publish step instead of replacing it. After
a transient failure, re-run the failed jobs; if an interrupted run left a draft
release, delete it first.
