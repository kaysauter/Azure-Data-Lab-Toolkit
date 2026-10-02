"use strict";

(function initializeWizard() {
  const data = window.AzureDataLabWizardData;
  const core = window.AzureDataLabWizardCore;
  const form = document.getElementById("wizard-form");
  const steps = [
    "lab",
    "azure",
    "security",
    "compute",
    "lifecycle",
    "content",
    "review"
  ];
  let activeStepIndex = 0;
  let catalogType = "all";

  const getField = (name) => form.elements.namedItem(name);
  const getValue = (name) => String(getField(name).value || "").trim();

  function collectState() {
    return Object.freeze({
      labName: getValue("labName"),
      description: getValue("description"),
      purpose: "canary",
      tenantId: getValue("tenantId"),
      subscriptionId: getValue("subscriptionId"),
      location: getValue("location"),
      resourceGroupName: getValue("resourceGroupName"),
      keyVaultResourceId: getValue("keyVaultResourceId"),
      diagnosticDestinationResourceId: getValue(
        "diagnosticDestinationResourceId"
      ),
      secretName: getValue("secretName"),
      secretVersion: getValue("secretVersion"),
      currency: getValue("currency"),
      maximumRunCost: Number(getValue("maximumRunCost")),
      maximumRuntimeMinutes: Number(getValue("maximumRuntimeMinutes")),
      timeToLiveMinutes: Number(getValue("timeToLiveMinutes")),
      containsSensitiveData: false
    });
  }

  function getReadiness(state, errors) {
    const hasNoError = (...fields) =>
      fields.every((field) => !Object.prototype.hasOwnProperty.call(errors, field));
    const profileMatches = hasNoError("profileContract");
    return [
      {
        label: "Lab identity",
        detail: "Locked canary, non-sensitive data, exact-resource cleanup",
        ready: profileMatches && hasNoError("labName")
      },
      {
        label: "Azure scope",
        detail: "Tenant, subscription, region, resource group",
        ready: hasNoError(
          "tenantId",
          "subscriptionId",
          "location",
          "resourceGroupName"
        )
      },
      {
        label: "Security baseline",
        detail: "Key Vault reference, immutable secret, Bastion",
        ready: hasNoError(
          "keyVaultResourceId",
          "diagnosticDestinationResourceId",
          "secretName",
          "secretVersion"
        )
      },
      {
        label: "Compute",
        detail: "Trusted Launch SQL Server 2022 profile",
        ready: profileMatches
      },
      {
        label: "Cost & lifecycle",
        detail: "Estimate admission limit and declared lifecycle",
        ready: hasNoError(
          "maximumRunCost",
          "maximumRuntimeMinutes",
          "timeToLiveMinutes"
        )
      },
      {
        label: "Optional content",
        detail: "Catalog visible; deployment selections omitted",
        ready: true,
        planning: true
      }
    ];
  }

  function setErrorState(errors) {
    form.querySelectorAll("[data-error-for]").forEach((element) => {
      const fieldName = element.dataset.errorFor;
      element.textContent = errors[fieldName] || "";
      const field = getField(fieldName);
      if (field && field instanceof HTMLElement) {
        field.setAttribute(
          "aria-invalid",
          errors[fieldName] ? "true" : "false"
        );
      }
    });
  }

  function renderReadiness(state, errors) {
    const items = getReadiness(state, errors);
    const list = document.getElementById("readiness-list");
    list.replaceChildren();

    items.forEach((item) => {
      const row = document.createElement("div");
      row.className = `readiness-item${item.ready ? " ready" : ""}`;
      const indicator = document.createElement("span");
      indicator.className = "readiness-indicator";
      indicator.setAttribute("aria-hidden", "true");
      const copy = document.createElement("span");
      const label = document.createElement("strong");
      label.textContent = item.label;
      const detail = document.createElement("small");
      detail.textContent = item.detail;
      copy.append(label, detail);
      row.append(indicator, copy);
      list.append(row);
    });

    const readinessByStep = {
      lab: items[0].ready,
      azure: items[1].ready,
      security: items[2].ready,
      compute: items[3].ready,
      lifecycle: items[4].ready,
      content: true,
      review: Object.keys(errors).length === 0
    };
    document.querySelectorAll("[data-step-link]").forEach((button) => {
      const stateIndicator = button.querySelector(".step-state");
      stateIndicator.className = "step-state";
      if (button.dataset.stepLink === "content") {
        stateIndicator.classList.add("planning");
      } else if (readinessByStep[button.dataset.stepLink]) {
        stateIndicator.classList.add("ready");
      }
    });
  }

  function renderReview(state, errors) {
    const errorBox = document.getElementById("review-errors");
    const messages = Object.values(errors);
    errorBox.replaceChildren();
    if (messages.length > 0) {
      const title = document.createElement("strong");
      title.textContent = "Resolve these settings before export:";
      const list = document.createElement("ul");
      messages.forEach((message) => {
        const item = document.createElement("li");
        item.textContent = message;
        list.append(item);
      });
      errorBox.append(title, list);
    }

    const rows = [
      ["Lab", `${state.labName || "Not set"} (${state.purpose})`],
      ["Azure scope", `${state.location || "Not set"} / ${state.resourceGroupName || "Not set"}`],
      ["Target", "Windows SQL Server 2022 on Standard_D4s_v5"],
      ["Security", "Trusted Launch, host encryption, Bastion Basic, no VM public IP"],
      ["Secret handling", "Existing Key Vault and immutable secret version; no secret value in YAML"],
      [
        "Lifecycle",
        `${state.maximumRuntimeMinutes || 0} minute pricing assumption; ` +
          `${state.timeToLiveMinutes || 0} minute local authorization TTL`
      ],
      [
        "Estimate admission limit",
        `${state.maximumRunCost || 0} ${state.currency}; not an Azure billing cap`
      ],
      ["Optional content", "Not included in this deployable alpha profile"]
    ];
    const summary = document.getElementById("review-summary");
    summary.replaceChildren();
    rows.forEach(([labelText, valueText]) => {
      const row = document.createElement("div");
      const label = document.createElement("span");
      const value = document.createElement("strong");
      label.textContent = labelText;
      value.textContent = valueText;
      row.append(label, value);
      summary.append(row);
    });

    const fileName = `${state.labName || "azure-data-lab"}.yaml`;
    document.getElementById("validation-command").textContent =
      `Test-AzureDataLabDeploymentConfiguration -Path ./${fileName}`;
  }

  function renderCatalog() {
    const query = document
      .getElementById("catalog-filter")
      .value.trim()
      .toLowerCase();
    const items = data.catalog.filter((item) => {
      const typeMatches = catalogType === "all" || item.type === catalogType;
      const searchable = [
        item.id,
        item.name,
        item.publisher,
        item.version,
        ...item.tags
      ]
        .join(" ")
        .toLowerCase();
      return typeMatches && (!query || searchable.includes(query));
    });

    const list = document.getElementById("catalog-list");
    list.replaceChildren();
    if (items.length === 0) {
      const empty = document.createElement("p");
      empty.className = "catalog-empty";
      empty.textContent = "No catalog entries match this filter.";
      list.append(empty);
      return;
    }

    items.forEach((item) => {
      const row = document.createElement("article");
      row.className = "catalog-item";
      const copy = document.createElement("div");
      const heading = document.createElement("h3");
      heading.textContent = item.name.includes(item.version)
        ? item.name
        : `${item.name} ${item.version}`;
      const publisher = document.createElement("p");
      publisher.textContent = `${item.publisher} - ${item.id}`;
      const tags = document.createElement("div");
      tags.className = "catalog-tags";
      item.tags.forEach((tag) => {
        const tagElement = document.createElement("span");
        tagElement.textContent = tag;
        tags.append(tagElement);
      });
      copy.append(heading, publisher, tags);
      const status = document.createElement("span");
      status.className = "planning-label";
      status.textContent = "Planning only";
      row.append(copy, status);
      list.append(row);
    });
  }

  function render() {
    const state = collectState();
    const generated = core.generate(state, data.profile);
    const errors = generated.errors;
    const matchesLockedProfile = generated.matchesLockedProfile;
    const yaml = generated.yaml || "";

    setErrorState(errors);
    renderReadiness(state, errors);
    renderReview(state, errors);

    const yamlPreview = document.getElementById("yaml-preview");
    yamlPreview.value = yaml;
    document.getElementById("yaml-lines").textContent =
      yaml ? `${yaml.trimEnd().split("\n").length} lines` : "0 lines";

    const stateElement = document.getElementById("yaml-state");
    stateElement.className =
      `yaml-state${matchesLockedProfile ? " ready" : ""}`;
    stateElement.textContent = matchesLockedProfile
      ? "Matches the locked browser profile. Authoritative PowerShell validation and live Azure preflight are still required."
      : `${Object.keys(errors).length} locked-profile setting(s) need attention.`;

    ["header-status", "rail-status"].forEach((id) => {
      const status = document.getElementById(id);
      status.className =
        `status-badge${matchesLockedProfile ? " ready" : ""}`;
      status.textContent = matchesLockedProfile
        ? "Profile matched; validate in PowerShell"
        : "Locked profile incomplete";
    });

    document.getElementById("download-yaml").disabled =
      !matchesLockedProfile;
    document.getElementById("copy-yaml").disabled = !matchesLockedProfile;
    document.getElementById("footer-status").textContent =
      matchesLockedProfile
        ? "Locked profile matched. Export, then validate in PowerShell."
        : `${Object.keys(errors).length} profile validation issue(s) remain.`;

    return { state, errors, matchesLockedProfile, yaml };
  }

  function showStep(index) {
    activeStepIndex = Math.max(0, Math.min(steps.length - 1, index));
    const activeStep = steps[activeStepIndex];
    document.querySelectorAll(".wizard-step").forEach((section) => {
      section.hidden = section.dataset.step !== activeStep;
    });
    document.querySelectorAll("[data-step-link]").forEach((button) => {
      if (button.dataset.stepLink === activeStep) {
        button.setAttribute("aria-current", "step");
      } else {
        button.removeAttribute("aria-current");
      }
    });
    document.getElementById("previous-step").disabled = activeStepIndex === 0;
    const next = document.getElementById("next-step");
    next.textContent =
      activeStepIndex === steps.length - 1 ? "Download YAML" : "Continue";
    document.querySelector(".form-canvas").scrollTo({ top: 0, behavior: "smooth" });
    render();
  }

  function downloadYaml() {
    const snapshot = render();
    if (!snapshot.matchesLockedProfile) {
      showStep(steps.indexOf("review"));
      return;
    }
    const blob = new Blob([snapshot.yaml], {
      type: "application/yaml;charset=utf-8"
    });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `${snapshot.state.labName}.yaml`;
    anchor.style.display = "none";
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
  }

  async function copyText(text, button) {
    let copied = false;
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        copied = true;
      } catch {
        copied = false;
      }
    }
    if (!copied) {
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.append(textarea);
      textarea.select();
      copied = document.execCommand("copy");
      textarea.remove();
    }
    const prior = button.textContent;
    button.textContent = copied ? "Copied" : "Select manually";
    window.setTimeout(() => {
      button.textContent = prior;
    }, 1400);
  }

  form.addEventListener("input", render);
  form.addEventListener("change", render);

  document.querySelectorAll("[data-step-link]").forEach((button) => {
    button.addEventListener("click", () => {
      showStep(steps.indexOf(button.dataset.stepLink));
    });
  });

  document.getElementById("previous-step").addEventListener("click", () => {
    showStep(activeStepIndex - 1);
  });
  document.getElementById("next-step").addEventListener("click", () => {
    if (activeStepIndex === steps.length - 1) {
      downloadYaml();
    } else {
      showStep(activeStepIndex + 1);
    }
  });
  document.getElementById("download-yaml").addEventListener("click", downloadYaml);
  document.getElementById("copy-yaml").addEventListener("click", (event) => {
    copyText(render().yaml, event.currentTarget);
  });
  document.getElementById("copy-command").addEventListener("click", (event) => {
    copyText(
      document.getElementById("validation-command").textContent,
      event.currentTarget
    );
  });
  document.getElementById("reset-wizard").addEventListener("click", () => {
    form.reset();
    showStep(0);
  });
  document.getElementById("catalog-filter").addEventListener("input", renderCatalog);
  document.querySelectorAll("[data-catalog-type]").forEach((button) => {
    button.addEventListener("click", () => {
      catalogType = button.dataset.catalogType;
      document.querySelectorAll("[data-catalog-type]").forEach((candidate) => {
        candidate.setAttribute(
          "aria-pressed",
          String(candidate === button)
        );
      });
      renderCatalog();
    });
  });
  document.querySelectorAll("[data-theme-choice]").forEach((button) => {
    button.addEventListener("click", () => {
      const theme = button.dataset.themeChoice;
      document.documentElement.dataset.theme = theme;
      document.querySelectorAll("[data-theme-choice]").forEach((candidate) => {
        candidate.setAttribute(
          "aria-pressed",
          String(candidate.dataset.themeChoice === theme)
        );
      });
      try {
        window.localStorage.setItem("adlt-wizard-theme", theme);
      } catch {
        // The wizard remains functional when local storage is unavailable.
      }
    });
  });

  try {
    const storedTheme = window.localStorage.getItem("adlt-wizard-theme");
    if (storedTheme === "light" || storedTheme === "dark") {
      document.documentElement.dataset.theme = storedTheme;
      document.querySelectorAll("[data-theme-choice]").forEach((button) => {
        button.setAttribute(
          "aria-pressed",
          String(button.dataset.themeChoice === storedTheme)
        );
      });
    }
  } catch {
    // Dark mode remains the deterministic default.
  }

  renderCatalog();
  showStep(0);
})();
