---
theme: default
title: Azure Data Lab Toolkit
titleTemplate: '%s'
info: |
  Architecture and roadmap pitch for Azure Data Lab Toolkit.
drawings:
  persist: false
transition: slide-left
mdc: true
wakeLock: false
class: adlt-cover
---

<div class="status-chip status-danger">Unreleased alpha and roadmap</div>

# Azure Data Lab Toolkit

## Repeatable, security-minded, cost-aware data labs

Define a lab once. Review the decisions. Deploy consistently. Prove it works. Remove it cleanly.

<div class="cover-meta">
  <span>Planning, deployment, and teardown implemented; unreleased and unverified</span>
  <span>First target: SQL Server on Azure VM</span>
</div>

<div class="nav-hint">Agenda stays available at the top right · G jumps to a slide · Left/Right moves between slides</div>

---
layout: default
---

# Agenda

<div class="agenda-list">
  <div><span>01</span><strong>Why</strong><small>The repeatability problem and the product promise</small></div>
  <div><span>02</span><strong>Architecture</strong><small>Contracts, extension types, Plan, WhatIf, and lifecycle</small></div>
  <div><span>03</span><strong>Delivery</strong><small>VM first, then Azure SQL, PostgreSQL, engines, Git, and Fabric</small></div>
  <div><span>04</span><strong>Guardrails</strong><small>Assessment, security, cost, ownership, catalogs, and testing</small></div>
  <div><span>05</span><strong>Proof</strong><small>Accountability, community, and the first complete lifecycle</small></div>
</div>

<div class="nav-hint">Agenda stays available on every slide · G jumps to a slide</div>

---
layout: default
---

# Building the lab should not be harder than learning from it

<div class="two-col problem-layout">
  <div class="problem-list">
    <div><strong>Fragmented provisioning</strong><span>Portal steps, scripts, infrastructure code, and guest setup drift apart.</span></div>
    <div><strong>Hidden decisions</strong><span>Identity, networking, licensing, and cost appear after resources already exist.</span></div>
    <div><strong>Manual content</strong><span>Data, tools, permissions, and examples are difficult to reproduce.</span></div>
    <div><strong>Unreliable cleanup</strong><span>A stopped VM is not an empty bill, and failed runs leave uncertainty behind.</span></div>
  </div>
  <div class="statement">
    <span class="statement-copy">Labs become difficult to</span>
    <div class="statement-terms">
      <b>repeat</b><b>compare</b><b>teach</b><b>trust</b>
    </div>
  </div>
</div>

---
layout: default
---

# One definition. One reviewed lifecycle.

<div class="lifecycle">
  <span>Describe</span><i>→</i>
  <span>Validate</span><i>→</i>
  <span>Plan</span><i>→</i>
  <span>Compare</span><i>→</i>
  <span>Approve</span><i>→</i>
  <span>Deploy</span><i>→</i>
  <span>Probe</span><i>→</i>
  <span>Report</span>
</div>

<div class="candidate-note">Assessment adds evidence before or after planning when it is useful. It is not a blocker for every lab.</div>

<div class="two-col compact-top">
  <div>
    <h3>Durable input</h3>
    <p>Versioned YAML captures intent. Templates, flags, and the guided browser wizard resolve into the same model.</p>
  </div>
  <div>
    <h3>Durable evidence</h3>
    <p>Versioned console, JSON, Markdown, and HTML outputs record decisions, costs, probes, failures, and cleanup.</p>
  </div>
</div>

<div class="decision-line">Then shut down, resume, or tear down only after ownership and impact are reviewed.</div>

---
layout: default
---

# Start narrow to prove the foundation

<div class="status-chip status-danger">Current: no deployable cmdlets</div>

## SQL Server on Azure VM is the first implementation

<div class="foundation-grid">
  <span>Networking</span>
  <span>Managed identity</span>
  <span>Key Vault decision</span>
  <span>Bastion decision</span>
  <span>Guest configuration</span>
  <span>Storage and restore</span>
  <span>Software delivery</span>
  <span>Probes and teardown</span>
</div>

<div class="danger-line">
  The unfinished <a href="https://github.com/kaysauter/azure-sqlvm-toolkit" target="_blank" rel="noreferrer">Azure SQLVM Toolkit</a>
  provides practical lessons for the broader design. No deployable implementation is inherited.
</div>

---
layout: default
---

# Core contracts coordinate distinct extensions

<img class="architecture-image" :src="'./data-lab-architecture.svg'" alt="Azure Data Lab Toolkit architecture with separate target providers, capability modules, catalogs, solution packs, probes, and deployment engines" />

<div class="architecture-key">
  <span><b>Core</b> resolves policy, approvals, orchestration, state, and evidence.</span>
  <span><b>Extensions</b> contribute typed intent; engines consume the approved plan.</span>
</div>

---
layout: default
---

# Plan and WhatIf answer different questions

<div class="compare-grid">
  <section>
    <span class="compare-command">-Plan</span>
    <h3>What will this definition mean?</h3>
    <ul>
      <li>Offline and deterministic</li>
      <li>No Azure sign-in or mutation</li>
      <li>Resolves defaults and derived values</li>
      <li>Records provenance and a stable plan hash</li>
      <li>Surfaces missing facts as unverified</li>
    </ul>
  </section>
  <section>
    <span class="compare-command">-WhatIf</span>
    <h3>What would happen in this Azure environment?</h3>
    <ul>
      <li>Azure-authenticated live reconciliation</li>
      <li>No mutation or approval</li>
      <li>Compares immutable plan, run state, and resources</li>
      <li>Reports create, reuse, update, replace, or conflict</li>
      <li>Surfaces drift and unknown ownership</li>
    </ul>
  </section>
</div>

<div class="candidate-note">Engine-native previews may add evidence; they do not redefine the toolkit's WhatIf contract.</div>

---
layout: default
---

# One model, four ways in

<div class="input-map">
  <div><span class="input-id">1</span><strong>Templates</strong><small>Curated, reviewable starting points</small></div>
  <div><span class="input-id">2</span><strong>Browser wizard</strong><small>Optional guided configuration, offline</small></div>
  <div><span class="input-id">3</span><strong>YAML</strong><small>Canonical, versioned input</small></div>
  <div><span class="input-id">4</span><strong>PowerShell flags</strong><small>Explicit per-run overrides</small></div>
</div>

<div class="input-arrow">Every route resolves to one schema, one provenance record, and one normalized plan.</div>

<div class="warning-panel">
  Secret generation or display, sensitive data, public access, unverified artifacts, license acceptance, replacement, and deletion remain explicit.
</div>

---
layout: default
---

# A deliberate delivery sequence

<ol class="target-sequence">
  <li><strong>SQL Server on Azure VM</strong><span>Plan → canary → useful lab → release</span></li>
  <li><strong>Azure SQL Database and SQL MI</strong><span>Managed SQL paths</span></li>
  <li><strong>PostgreSQL</strong><span>Azure managed → VM → container</span></li>
  <li><strong>Bicep and Terraform</strong><span>Independent engine gates</span></li>
  <li><strong>Git and CI/CD adapters</strong><span>GitHub, Azure DevOps, GitLab, Gitea, Forgejo</span></li>
  <li><strong>Microsoft Fabric</strong><span>Guidance → items → CI/CD + solution-pack lanes</span></li>
  <li><strong>Later platforms</strong><span>Databricks, more data targets, SQL Linux, Kubernetes</span></li>
</ol>

<div class="backlog-line">
  Delivery order is not technical coupling. Terraform does not depend on Bicep, and Fabric workspace creation does not depend on Git.
</div>

---
layout: default
---

# Assessment adds evidence. Migration remains separate.

<div class="three-col">
  <div class="plain-panel">
    <h3>Discover</h3>
    <p>Versions, features, dependencies, workload shape, data size, and operational needs.</p>
  </div>
  <div class="plain-panel">
    <h3>Compare</h3>
    <p>Compatibility, security, target fit, sizing, cost, licensing, and migration readiness.</p>
  </div>
  <div class="plain-panel">
    <h3>Explain</h3>
    <p>Evidence, confidence, blockers, trade-offs, prerequisites, and unresolved questions.</p>
  </div>
</div>

<div class="two-col compact-top">
  <div>
    <h3>First assessment paths</h3>
    <div class="link-group link-group-single" aria-label="First assessment references">
      <a href="https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/overview" target="_blank" rel="noreferrer">SQL Server enabled by Azure Arc</a>
      <a href="https://learn.microsoft.com/en-us/ssms/migrate/migrate-sql-server-azure-sql" target="_blank" rel="noreferrer">Migration component in SSMS</a>
    </div>
  </div>
  <div>
    <h3>Security boundary</h3>
    <p>Identity, collection privilege, billing, prerequisites, and data handling must be visible before assessment begins.</p>
  </div>
</div>

---
layout: default
---

# Guardrails survive deployment and teardown

<div class="four-col">
  <div class="plain-panel">
    <h3>Security</h3>
    <p>Every target records a secret-store decision. Every Azure VM records a Bastion-first administrative-access decision.</p>
  </div>
  <div class="plain-panel">
    <h3>Cost</h3>
    <p>A separate estimate operation with assumptions, uncertainty, budget limits, and HTML output.</p>
  </div>
  <div class="plain-panel">
    <h3>Ownership</h3>
    <p>Owned, adopted, reused, and external resources have different deletion eligibility.</p>
  </div>
  <div class="plain-panel">
    <h3>Teardown</h3>
    <p>Preview, confirmation, reverse dependency order, retained-resource evidence, and cleanup proof.</p>
  </div>
</div>

<div class="danger-line">Unknown ownership blocks deletion. A matching name, resource group, or tag is not enough.</div>

---
layout: default
---

# Governed catalogs, including your own artifacts

<div class="catalog-contract">
  <span>Owner</span><span>Source</span><span>License</span><span>Version</span>
  <span>Integrity</span><span>Compatibility</span><span>Sensitivity</span><span>Removal</span>
</div>

<div class="two-col compact-top">
  <div>
    <h3>Community and sample sources</h3>
    <div class="link-group" aria-label="Community tools and sample data sources">
      <a href="https://github.com/microsoft/sql-server-samples" target="_blank" rel="noreferrer">Microsoft SQL samples</a>
      <a href="https://sqlsunday.com/downloads/" target="_blank" rel="noreferrer">SQL Sunday</a>
      <a href="https://www.sqlbi.com/tools/contoso-data-generator/" target="_blank" rel="noreferrer">SQLBI Contoso</a>
      <a href="https://github.com/devrimgunduz/pagila" target="_blank" rel="noreferrer">Pagila</a>
      <a href="https://github.com/lerocha/chinook-database" target="_blank" rel="noreferrer">Chinook</a>
      <a href="https://dbatools.io/" target="_blank" rel="noreferrer">dbatools</a>
      <a href="https://www.brentozar.com/first-aid/" target="_blank" rel="noreferrer">First Responder Kit</a>
    </div>
  </div>
  <div>
    <h3>Custom and private sources</h3>
    <p>Users can select local files or URLs, private sources, checksums, authentication references, and sensitivity metadata. Community content is optional, never mandatory.</p>
  </div>
</div>

<div class="candidate-note">A catalog entry is metadata and policy. Planning never downloads or executes its content.</div>

---
layout: default
---

# Fabric needs guidance and honest capability limits

<div class="candidate-note">Fabric delivery follows PostgreSQL, Bicep, Terraform, and the general Git/CI adapter segment.</div>

<div class="fabric-tree">
  <div><strong>Transactional relational?</strong><span>Evaluate a SQL database in Fabric</span></div>
  <div><strong>Governed relational analytics?</strong><span>Evaluate Warehouse</span></div>
  <div><strong>Spark or open formats?</strong><span>Evaluate Lakehouse</span></div>
</div>

<div class="two-col compact-top">
  <div>
    <h3>Workspace and item lifecycle</h3>
    <p>Guide capacity, roles, workspaces, dependencies, environment parameters, probes, and recovery.</p>
  </div>
  <div>
    <h3>Shortcuts and CI/CD</h3>
    <p>Explain reference versus copy, identity and source access, cache behavior, supported Git integration, and deployment-pipeline limits.</p>
  </div>
</div>

<div class="warning-panel">
  Full Fabric infrastructure-as-code parity is exploratory. Unsupported operations fail explicitly; they do not fall back to hidden automation.
</div>

---
layout: default
---

# Automation must prove deployment and cleanup

<div class="pipeline">
  <span>Schema</span><i>→</i>
  <span>Pester</span><i>→</i>
  <span>PowerShell analysis</span><i>→</i>
  <span>Security</span><i>→</i>
  <span>Build</span><i>→</i>
  <span>Protected live test</span><i>→</i>
  <span>Cleanup proof</span>
</div>

<div class="two-col compact-top">
  <div>
    <h3>Toolkit repository CI</h3>
    <p>Dependency review, Dependabot, secret scanning, PSScriptAnalyzer, Pester, docs and links, plus Checkov when Bicep or Terraform exists. CodeQL complements this but does not analyze PowerShell.</p>
  </div>
  <div>
    <h3>User-facing pipeline intent</h3>
    <p>Plan, approve, deploy, probe, report, and teardown through OIDC, protected environments, remotely locked state, and retained evidence.</p>
  </div>
</div>

<div class="candidate-note">GitHub is the reference adapter. Azure DevOps, GitLab, Gitea, and Forgejo are planned before Fabric; Fabric still supports only its own current integration matrix.</div>

---
layout: default
---

# Accelerated by AI. Accountable to people.

<div class="two-col">
  <div>
    <h3>Acceleration</h3>
    <div class="link-group link-group-single" aria-label="AI collaborators">
      <a href="https://openai.com/codex/" target="_blank" rel="noreferrer">OpenAI Codex</a>
      <a href="https://claude.com/product/overview" target="_blank" rel="noreferrer">Claude</a>
    </div>
    <p>They help with research, architecture exploration, implementation, documentation, and review.</p>
    <p>That acceleration makes a long-held idea practical to pursue at this scale.</p>
  </div>
  <div>
    <h3>Accountability</h3>
    <p>Source control, reproducible tests, security checks, upstream documentation, licenses, independent review, and human judgment remain authoritative.</p>
    <p>AI assistance does not transfer responsibility away from the maintainer.</p>
  </div>
</div>

<div class="community-call">
  Maintainers can showcase tools and databases through reproducible, properly credited lab scenarios. Commercial projects should make contact first.
</div>

<div class="link-group contact-links" aria-label="Contact Kay Sauter">
  <a href="https://www.linkedin.com/in/kaysauter/" target="_blank" rel="noreferrer">LinkedIn</a>
  <a href="https://www.kayondata.com/contact/" target="_blank" rel="noreferrer">Kay On Data contact form</a>
</div>

---
layout: default
class: final-slide
---

# The first proof: one complete lab lifecycle

<div class="proof-line">
  YAML <i>→</i> validated Plan <i>→</i> live WhatIf <i>→</i> approved PowerShell deployment <i>→</i> probes and HTML evidence <i>→</i> ownership-aware teardown <i>→</i> cleanup proof
</div>

<div class="milestones">
  <span>1. Decision-complete contracts</span>
  <span>2. Installable offline Core</span>
  <span>3. GitHub engineering CI</span>
  <span>4. SQL VM plan and secure canary</span>
  <span>5. Useful lab and release evidence</span>
</div>

<div class="final-links">
  <a href="/Azure-Data-Lab-Toolkit/architecture/">Architecture</a>
  <a href="https://github.com/kaysauter/Azure-Data-Lab-Toolkit" target="_blank" rel="noreferrer">Repository</a>
  <a href="https://github.com/users/kaysauter/projects/6/views/1" target="_blank" rel="noreferrer">Public roadmap</a>
</div>
