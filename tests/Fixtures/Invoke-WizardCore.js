"use strict";

const fs = require("node:fs");

if (process.argv.length !== 5) {
  throw new Error(
    "Usage: node Invoke-WizardCore.js <core-path> <profile-json> <state-json>"
  );
}

const [, , corePath, profilePath, statePath] = process.argv;
const core = require(corePath);
const deploymentProfile = JSON.parse(fs.readFileSync(profilePath, "utf8"));
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
const result = core.generate(state, deploymentProfile);

process.stdout.write(JSON.stringify(result));
