"use strict";

window.AzureDataLabWizardData = Object.freeze({
  profile: Object.freeze({
    id: "sqlvm-first-canary/v1",
    profileHash:
      "sha256:9ad21b4a4938a7e11b3fc74dc8501a336f7db50c5cda968eef266ff360901107",
    exactConfiguration: Object.freeze({
      "sqlVm.compute.vmSize": "Standard_D4s_v5"
    })
  }),
  catalog: Object.freeze([
    Object.freeze({
      id: "software.dbatools",
      type: "software",
      name: "dbatools",
      version: "2.8.2",
      publisher: "dbatools community",
      tags: Object.freeze(["powershell", "restore", "sql-server", "sqlvm"]),
      status: "planning-only"
    }),
    Object.freeze({
      id: "software.git-for-windows",
      type: "software",
      name: "Git for Windows",
      version: "2.53.0.windows.3",
      publisher: "Git for Windows project",
      tags: Object.freeze(["developer-tools", "git", "sqlvm"]),
      status: "planning-only"
    }),
    Object.freeze({
      id: "sample-data.adventureworks-2022",
      type: "sample-data",
      name: "AdventureWorks 2022",
      version: "2022",
      publisher: "Microsoft",
      tags: Object.freeze([
        "microsoft",
        "oltp",
        "sample",
        "sql-server",
        "sqlvm"
      ]),
      status: "planning-only"
    })
  ])
});
