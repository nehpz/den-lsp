{
  lib ? null,
}:
let
  filterAttrs =
    if builtins ? filterAttrs then
      builtins.filterAttrs
    else if lib != null && lib ? filterAttrs then
      lib.filterAttrs
    else
      pred: set:
      builtins.listToAttrs (
        builtins.concatMap (
          name:
          if pred name set.${name} then
            [
              {
                inherit name;
                value = set.${name};
              }
            ]
          else
            [ ]
        ) (builtins.attrNames set)
      );

  dirEntries = builtins.readDir ./.;
  subdirNames = builtins.attrNames (
    filterAttrs (
      name: type: type == "directory" && builtins.pathExists (./. + "/${name}/scenario.nix")
    ) dirEntries
  );

  # VALIDATION BOUNDARY (deliberate; see fixtures/scenarios/README.md
  # "Validation Boundary" and docs/solutions/conventions/):
  #
  # The loader guards ONLY failure modes that would otherwise pass SILENTLY —
  # a check that matches vacuously and reports green while verifying nothing.
  # Today those are exactly the two guards below (empty expectedFindings /
  # empty expectedError on a non-knownMiss scenario).
  #
  # Everything else about manifest shape fails LOUDLY elsewhere and is NOT
  # re-checked here — do not add schema validation to this function:
  #   - kind taxonomy, per-kind spec shape, and goldenable/exclusionReason
  #     pairing: pinned for the whole committed corpus by
  #     tests/scenarios/comparator.nix (flake-check tier).
  #   - missing/mistyped fields consumed downstream: Nix eval fails with a
  #     usable trace at the consuming site.
  # A full validateScenario pass existed and was removed (PR #30) because it
  # only duplicated those loud failures. If a NEW field gains a silent-pass
  # failure mode, add a guard HERE; if it fails loudly, leave it alone.
  loadScenarioFile =
    path:
    let
      raw = import path;
    in
    if raw.complete or false then
      let
        loaded = raw // {
          knownMiss = raw.knownMiss or false;
          heavy = raw.heavy or false;
          complete = raw.complete or false;
          exclusionReason = raw.exclusionReason or null;
        };
        name = loaded.name or "<unknown>";
      in
      if
        (loaded.kind or "") == "finding" && !loaded.knownMiss && (loaded.expectedFindings or [ ]) == [ ]
      then
        throw "Scenario '${name}' of kind 'finding' with knownMiss=false must declare at least one expected finding - an empty list would make its detection check pass vacuously"
      else if
        (loaded.kind or "") == "eval-error" && !loaded.knownMiss && (loaded.expectedError or "") == ""
      then
        throw "Scenario '${name}' of kind 'eval-error' with knownMiss=false must declare a non-empty expectedError - an empty string would match any output vacuously"
      else
        loaded
    else
      null;

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
  inherit scenarios loadScenarioFile;
}
