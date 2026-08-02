# Repetition rule (advisory, AE7).
# Detects when a declared aspect is parented by a different host entity aspect
# for every host in ir.entities.hosts (>= 2 hosts).
{ lib }:
let
  util = import ./util.nix { inherit lib; };
in
{
  id = "repetition";
  severity = "advisory";
  docRef = "docs/src/content/docs/guides/configure-aspects.mdx";

  check =
    ir:
    let
      hosts = ir.entities.hosts or [ ];
      hostCount = builtins.length hosts;
    in
    if hostCount < 2 then
      [ ]
    else
      let
        hostNames = map (h: h.name) hosts;
        declaredAspects = builtins.attrNames (ir.registries.aspects or { });
        entries = ir.entries or [ ];

        # Extract parent host name from an entry's parent string
        parentHostName = p: if p == null then null else util.baseNameOf (lib.removePrefix "host:" p);

        # Check if aspect 'aspName' is parented by every host entity aspect
        isRepeatedOnAllHosts =
          aspName:
          if builtins.elem aspName hostNames then
            false # Skip host entity aspects themselves
          else
            let
              aspEntries = builtins.filter (
                entry: entry.name == aspName || util.baseNameOf entry.name == aspName
              ) entries;
              parents = map (e: parentHostName e.parent) aspEntries;
            in
            lib.all (hName: builtins.elem hName parents) hostNames;

        repeatedAspects = builtins.filter isRepeatedOnAllHosts declaredAspects;

        mkFinding =
          aspName:
          let
            hostsStr = lib.concatStringsSep ", " hostNames;
          in
          {
            aspectPath = "den.aspects.${aspName}";
            message = "Aspect '${aspName}' is attached individually to every host entity (${hostsStr}).";
            fix = "Express '${aspName}' once via den.default.includes, schema include, or a policy instead of per-host attachment.";
          };
      in
      map mkFinding repeatedAspects;
}
