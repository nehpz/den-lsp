{ lib ? null }:
let
  # Builtins-only validation helper for scenario manifests
  validateScenario =
    manifest:
    if !(builtins.isAttrs manifest) then
      throw "Scenario manifest must be an attrset (got ${builtins.typeOf manifest})"
    else
      let
        sName = if manifest ? name && builtins.isString manifest.name && manifest.name != "" then manifest.name else "<unknown>";
        valOf = attr: if manifest ? ${attr} then builtins.toJSON manifest.${attr} else "missing";
      in
      if !(manifest ? version) || manifest.version != 1 then
        throw "Scenario '${sName}' version must be 1 (got ${valOf "version"})"
      else if !(manifest ? name) || !(builtins.isString manifest.name) || manifest.name == "" then
        throw "Scenario manifest name must be a non-empty string (got ${valOf "name"})"
      else if !(manifest ? kind) || (manifest.kind != "finding" && manifest.kind != "eval-error") then
        throw "Scenario '${sName}' kind must be 'finding' or 'eval-error' (got ${valOf "kind"})"
      else if !(manifest ? defect) || !(builtins.isString manifest.defect) then
        throw "Scenario '${sName}' defect must be a string (got ${valOf "defect"})"
      else if !(manifest ? task) || !(builtins.isString manifest.task) then
        throw "Scenario '${sName}' task must be a string (got ${valOf "task"})"
      else if manifest.kind == "finding" && (!(manifest ? expectedFindings) || !(builtins.isList manifest.expectedFindings)) then
        throw "Scenario '${sName}' of kind 'finding' must specify an expectedFindings list (got ${valOf "expectedFindings"})"
      else if manifest.kind == "finding" && !(manifest.knownMiss or false) && manifest.expectedFindings == [ ] then
        throw "Scenario '${sName}' of kind 'finding' with knownMiss=false must declare at least one expected finding - an empty list would make its detection check pass vacuously"
      else if manifest.kind == "eval-error" && (!(manifest ? expectedError) || !(builtins.isString manifest.expectedError) || manifest.expectedError == "") then
        throw "Scenario '${sName}' of kind 'eval-error' must specify a non-empty expectedError string (got ${valOf "expectedError"})"
      else if !(manifest ? goldenable) || !(builtins.isBool manifest.goldenable) then
        throw "Scenario '${sName}' goldenable must be a boolean (got ${valOf "goldenable"})"
      else if manifest.goldenable == false && (!(manifest ? exclusionReason) || !(builtins.isString manifest.exclusionReason) || manifest.exclusionReason == "") then
        throw "Scenario '${sName}' with goldenable=false requires a non-empty exclusionReason string (got ${valOf "exclusionReason"})"
      else if !(manifest ? clearCut) || !(builtins.isBool manifest.clearCut) then
        throw "Scenario '${sName}' clearCut must be a boolean (got ${valOf "clearCut"})"
      else if manifest ? heavy && !(builtins.isBool manifest.heavy) then
        throw "Scenario '${sName}' heavy must be a boolean (got ${valOf "heavy"})"
      else
      manifest // {
        knownMiss = manifest.knownMiss or false;
        heavy = manifest.heavy or false;
        complete = manifest.complete or false;
        exclusionReason = manifest.exclusionReason or null;
      };

  filterAttrs =
    if builtins ? filterAttrs then
      builtins.filterAttrs
    else if lib != null && lib ? filterAttrs then
      lib.filterAttrs
    else
      pred: set:
      builtins.listToAttrs (
        builtins.concatMap (
          name: if pred name set.${name} then [ { inherit name; value = set.${name}; } ] else [ ]
        ) (builtins.attrNames set)
      );

  dirEntries = builtins.readDir ./.;
  subdirNames = builtins.attrNames (
    filterAttrs (
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
