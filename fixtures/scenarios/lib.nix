{ lib ? null }:
let
  # Builtins-only validation helper for scenario manifests
  validateScenario =
    manifest:
    if !(builtins.isAttrs manifest) then
      throw "Scenario manifest must be an attrset"
    else if !(manifest ? version) || manifest.version != 1 then
      throw "Scenario manifest version must be 1"
    else if !(manifest ? name) || !(builtins.isString manifest.name) || manifest.name == "" then
      throw "Scenario manifest name must be a non-empty string"
    else if !(manifest ? kind) || (manifest.kind != "finding" && manifest.kind != "eval-error") then
      throw "Scenario manifest kind must be 'finding' or 'eval-error'"
    else if !(manifest ? defect) || !(builtins.isString manifest.defect) then
      throw "Scenario manifest defect must be a string"
    else if !(manifest ? task) || !(builtins.isString manifest.task) then
      throw "Scenario manifest task must be a string"
    else if manifest.kind == "finding" && (!(manifest ? expectedFindings) || !(builtins.isList manifest.expectedFindings)) then
      throw "Scenario manifest of kind 'finding' must specify an expectedFindings list"
    else if manifest.kind == "eval-error" && (!(manifest ? expectedError) || !(builtins.isString manifest.expectedError) || manifest.expectedError == "") then
      throw "Scenario manifest of kind 'eval-error' must specify a non-empty expectedError string"
    else if !(manifest ? goldenable) || !(builtins.isBool manifest.goldenable) then
      throw "Scenario manifest goldenable must be a boolean"
    else if manifest.goldenable == false && (!(manifest ? exclusionReason) || !(builtins.isString manifest.exclusionReason) || manifest.exclusionReason == "") then
      throw "Scenario manifest with goldenable=false requires a non-empty exclusionReason string"
    else if !(manifest ? clearCut) || !(builtins.isBool manifest.clearCut) then
      throw "Scenario manifest clearCut must be a boolean"
    else
      manifest // {
        knownMiss = manifest.knownMiss or false;
        complete = manifest.complete or false;
        exclusionReason = manifest.exclusionReason or null;
      };

  dirEntries = builtins.readDir ./.;
  subdirNames = builtins.attrNames (
    builtins.filterAttrs (
      name: type: type == "directory" && builtins.pathExists (./. + "/${name}/scenario.nix")
    ) dirEntries
  );

  loadScenarioFile =
    path:
    let
      raw = import path;
    in
    if raw.complete or false then validateScenario raw else null;

  scenariosList = builtins.filter (s: s != null) (
    map (dir: loadScenarioFile (./. + "/${dir}/scenario.nix")) subdirNames
  );

  scenarios = builtins.listToAttrs (
    map (s: {
      name = s.name;
      value = s;
    }) scenariosList
  );
in
{
  inherit scenarios validateScenario loadScenarioFile;
}
