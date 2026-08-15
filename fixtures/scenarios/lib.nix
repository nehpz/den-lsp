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

  loadScenarioFile =
    path:
    let
      raw = import path;
    in
    if raw.complete or false then
      raw
      // {
        knownMiss = raw.knownMiss or false;
        heavy = raw.heavy or false;
        complete = raw.complete or false;
        exclusionReason = raw.exclusionReason or null;
      }
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
