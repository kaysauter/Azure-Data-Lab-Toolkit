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
class: adlt-cover
---

<div class="status-chip status-danger">Early architecture scaffold</div>

# Azure Data Lab Toolkit

## Repeatable, security-minded, cost-aware data labs

Define a lab once. Review its implications. Deploy consistently. Prove it works. Remove it cleanly.

<div class="cover-meta">
  <span>No deployable cmdlets yet</span>
  <span>First target: SQL Server on Azure VM</span>
</div>

<div class="nav-hint">Use Left/Right to navigate | Press G to jump to a slide</div>

---
layout: default
---

# Agenda

<div class="agenda-list">
  <div><span>01</span><strong>The problem</strong><small>Why data labs are harder to repeat than they should be</small></div>
  <div><span>02</span><strong>Product vision</strong><small>One definition and one complete lifecycle</small></div>
  <div><span>03</span><strong>Architecture and experience</strong><small>Core, providers, engines, YAML, flags, templates, and TUI</small></div>
  <div><span>04</span><strong>Targets and ecosystem</strong><small>SQL, Fabric, PostgreSQL, data, and tools</small></div>
  <div><span>05</span><strong>Trust, community, and next steps</strong><small>Security, cost, testing, attribution, and the first proof point</small></div>
</div>

<div class="nav-hint">This agenda is always available from the Agenda link | Press G for Slidev's slide jump</div>

---
layout: default
---

# Building the lab should not be harder than learning from it

<div class="two-col">
  <div class="problem-list">
    <div><strong>Fragmented provisioning</strong><span>Portal steps, scripts, infrastructure code, and guest setup drift apart.</span></div>
    <div><strong>Hidden decisions</strong><span>Identity, networking, licensing, and cost often appear after resources exist.</span></div>
    <div><strong>Manual content</strong><span>Data, tools, permissions, and examples are difficult to reproduce.</span></div>
    <div><strong>Unreliable cleanup</strong><span>A stopped VM is not an empty bill, and a failed run can leave resources behind.</span></div>
  </div>
  <div class="statement">
    Labs become difficult to <b>repeat</b>, <b>compare</b>, <b>teach</b>, and <b>trust</b>.
  </div>
</div>

---
layout: default
---

# One definition. One plan. Many data targets.

<div class="lifecycle">
  <span>Describe</span><i>→</i>
  <span>Validate</span><i>→</i>
  <span>Assess</span><i>→</i>
  <span>Plan</span><i>→</i>
  <span>Approve</span><i>→</i>
  <span>Deploy</span><i>→</i>
  <span>Probe</span><i>→</i>
  <span>Report</span>
</div>

<div class="two-col compact-top">
  <div>
    <h3>Durable input</h3>
    <p>Versioned YAML captures the lab. Templates, flags, and a future terminal UI resolve into that same model.</p>
  </div>
  <div>
    <h3>Durable evidence</h3>
    <p>Console, JSON, Markdown, and HTML outputs record decisions, costs, probes, failures, and cleanup.</p>
  </div>
</div>

<div class="decision-line">Then: shut down, resume, or tear down after a reviewed summary.</div>

---
layout: default
---

# Start narrow to build the right foundation

<div class="status-chip status-danger">Current: architecture scaffold, not production-ready</div>

## SQL Server on Azure VM is the first implementation

<div class="foundation-grid">
  <span>Networking</span>
  <span>Managed identity</span>
  <span>Key Vault</span>
  <span>Azure Bastion</span>
  <span>Guest configuration</span>
  <span>Storage and restore</span>
  <span>Software delivery</span>
  <span>Probes and teardown</span>
</div>

The working predecessor remains [Azure SQLVM Toolkit](https://github.com/kaysauter/azure-sqlvm-toolkit). Its behavior is not automatically available in this new repository.

---
layout: default
---

# Core plans. Providers specialize. Engines execute.

<img class="architecture-image" :src="'./data-lab-architecture.svg'" alt="Azure Data Lab Toolkit architecture" />

<div class="lifecycle lifecycle-small">
  <span>Defaults</span><i>→</i><span>Validate</span><i>→</i><span>Assess</span><i>→</i>
  <span>Plan</span><i>→</i><span>Deploy</span><i>→</i><span>Probe</span><i>→</i>
  <span>Teardown preview</span><i>→</i><span>Teardown</span>
</div>

---
layout: default
---

# One model, four ways in

<div class="input-map">
  <div><span class="input-id">1</span><strong>Templates</strong><small>Curated starting points</small></div>
  <div><span class="input-id">2</span><strong>Terminal UI</strong><small>Optional guided configuration</small></div>
  <div><span class="input-id">3</span><strong>YAML</strong><small>Canonical, versioned input</small></div>
  <div><span class="input-id">4</span><strong>PowerShell flags</strong><small>Explicit per-run overrides</small></div>
</div>

<div class="input-arrow">All routes resolve into the same validated configuration and plan.</div>

<div class="warning-panel">
  Risky operations remain deliberate: secret generation, secret display, sensitive data, public access, license acceptance, and deletion.
</div>

---
layout: default
---

# A deliberate target sequence

<ol class="target-sequence">
  <li><strong>SQL Server on Azure VM</strong><span>Reference provider</span></li>
  <li><strong>Azure SQL Database</strong><span>First managed SQL target</span></li>
  <li><strong>Azure SQL Managed Instance</strong><span>Network-heavy managed instance</span></li>
  <li><strong>Microsoft Fabric</strong><span>Guided workspaces and items</span></li>
  <li><strong>Azure Database for PostgreSQL</strong><span>Managed PostgreSQL</span></li>
  <li><strong>Linux VMs and containers</strong><span>SQL Server and PostgreSQL</span></li>
  <li><strong>Kubernetes</strong><span>After container contracts mature</span></li>
</ol>

<div class="backlog-line">Ecosystem backlog: Azure Databricks, additional Git providers, and future data platforms.</div>

---
layout: default
---

# Assess first. Migrate later.

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
    <p>Evidence, confidence, blockers, trade-offs, and unresolved questions.</p>
  </div>
</div>

[SQL Server enabled by Azure Arc](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/overview) is the preferred first assessment integration where its prerequisites are acceptable.

<div class="warning-panel">
  BACPAC may become a later import mechanism. It is not an assessment strategy.
</div>

---
layout: default
---

# Safety and cost are part of the plan

<div class="three-col">
  <div class="plain-panel">
    <h3>Security</h3>
    <ul>
      <li>Managed identity</li>
      <li>Key Vault references</li>
      <li>Private networking and Bastion</li>
      <li>Sensitive-data acknowledgement</li>
      <li>Separate secret-output opt-ins</li>
    </ul>
  </div>
  <div class="plain-panel">
    <h3>Cost</h3>
    <ul>
      <li>Explicit estimate operation</li>
      <li>YAML input and HTML output</li>
      <li>Budgets and warnings</li>
      <li>Timestamped assumptions</li>
      <li>Known omissions</li>
    </ul>
  </div>
  <div class="plain-panel">
    <h3>Lifecycle</h3>
    <ul>
      <li>TTL and shutdown</li>
      <li>Resumable operations</li>
      <li>Deletion summary</li>
      <li>Explicit confirmation</li>
      <li>Cleanup proof</li>
    </ul>
  </div>
</div>

<div class="danger-line">A lab label does not make SQL Server licensing, sensitive data, or public access safe by itself.</div>

---
layout: default
---

# A governed catalog, not a download list

<div class="catalog-contract">
  <span>Owner</span><span>Source</span><span>License</span><span>Version</span>
  <span>Checksum</span><span>Compatibility</span><span>Sensitivity</span><span>Removal</span>
</div>

<div class="two-col compact-top">
  <div>
    <h3>Planned data candidates</h3>
    <p>
      [Microsoft SQL samples](https://github.com/microsoft/sql-server-samples),
      [SQL Sunday](https://sqlsunday.com/downloads/),
      [SQLBI Contoso](https://www.sqlbi.com/tools/contoso-data-generator/),
      Stack Overflow distributions, [Pagila](https://github.com/devrimgunduz/pagila), and
      [Chinook](https://github.com/lerocha/chinook-database).
    </p>
  </div>
  <div>
    <h3>Planned tool candidates</h3>
    <p>
      [dbatools](https://dbatools.io/), [First Responder Kit](https://www.brentozar.com/first-aid/),
      [Tabular Editor](https://tabulareditor.com/), [FUAM](https://github.com/microsoft/fabric-toolbox/tree/main/monitoring/fabric-unified-admin-monitoring),
      [Rayfin](https://github.com/microsoft/rayfin), and TMDL tooling.
    </p>
  </div>
</div>

<div class="candidate-note">Candidates are credited interests, not bundled or implemented dependencies.</div>

---
layout: default
---

# Fabric needs guidance, not just automation

<div class="fabric-tree">
  <div><strong>Transactional relational workload?</strong><span>Start by evaluating a SQL database in Fabric</span></div>
  <div><strong>Governed relational analytics?</strong><span>Start by evaluating Warehouse</span></div>
  <div><strong>Spark, open formats, or mixed data?</strong><span>Start by evaluating Lakehouse</span></div>
</div>

<div class="two-col compact-top">
  <div>
    <h3>Workspace and item lifecycle</h3>
    <p>Validate capacity, roles, workspaces, dependencies, environment parameters, probes, and recovery.</p>
  </div>
  <div>
    <h3>Shortcuts and CI/CD</h3>
    <p>Explain reference versus copy, identity, source permissions, metadata versus data, Git support, and deployment-pipeline limits.</p>
  </div>
</div>

Planned demonstrations include [FUAM](https://github.com/microsoft/fabric-toolbox/tree/main/monitoring/fabric-unified-admin-monitoring), [Rayfin](https://github.com/microsoft/rayfin), and [TMDL](https://learn.microsoft.com/en-us/analysis-services/tmdl/tmdl-overview).

---
layout: default
---

# Automation must prove deployment and cleanup

<div class="pipeline">
  <span>Schema</span><i>→</i>
  <span>Pester</span><i>→</i>
  <span>Security</span><i>→</i>
  <span>Plan</span><i>→</i>
  <span>Protected deploy</span><i>→</i>
  <span>Probe</span><i>→</i>
  <span>Teardown proof</span>
</div>

<div class="two-col compact-top">
  <div>
    <h3>Every pull request</h3>
    <p>Dependency review, Dependabot, CodeQL, secret scanning, PowerShell analysis, Checkov when infrastructure code exists, vulnerability scanning, tests, docs, and links.</p>
  </div>
  <div>
    <h3>Protected live lanes</h3>
    <p>GitHub OIDC, approved subscriptions and regions, strict TTL, constrained cost, retained reports, and cleanup queries. Larger matrices run nightly.</p>
  </div>
</div>

<div class="candidate-note">GitHub comes first. Azure DevOps, GitLab, Gitea, and Forgejo remain provider candidates.</div>

---
layout: default
---

# Accelerated by AI. Accountable to people.

<div class="two-col">
  <div>
    <h3>Acceleration</h3>
    <p>
      [OpenAI Codex](https://openai.com/codex/) and [Claude](https://claude.com/product/overview)
      are helping with research, architecture exploration, implementation, documentation, and review.
    </p>
    <p>That acceleration makes a long-held idea practical to pursue now.</p>
  </div>
  <div>
    <h3>Accountability</h3>
    <p>Source control, reproducible tests, security checks, upstream documentation, licenses, and human judgment remain authoritative.</p>
    <p>AI assistance does not transfer responsibility away from the maintainer.</p>
  </div>
</div>

<div class="community-call">
  Maintainers are invited to showcase tools and databases through reproducible, properly credited lab scenarios.
</div>

[LinkedIn](https://www.linkedin.com/in/kaysauter/) · [Kay On Data contact form](https://www.kayondata.com/contact/)

---
layout: default
class: final-slide
---

# The next proof point: one complete lab lifecycle

<div class="proof-line">
  YAML <i>→</i> validated plan <i>→</i> deployed SQL VM lab <i>→</i> probes and HTML report <i>→</i> confirmed teardown with cleanup proof
</div>

<div class="milestones">
  <span>1. Decision-complete architecture</span>
  <span>2. PowerShell module and public API</span>
  <span>3. YAML, flags, contracts, plan, and state</span>
  <span>4. Security, cost, catalog, CI, and testing foundations</span>
  <span>5. SQL Server on Azure VM reference provider</span>
</div>

<div class="final-links">
  <a href="https://github.com/kaysauter/Azure-Data-Lab-Toolkit">Repository</a>
  <a href="https://github.com/users/kaysauter/projects/6/views/1">Public roadmap</a>
  <a href="https://www.kayondata.com/contact/">Suggest a project</a>
</div>
