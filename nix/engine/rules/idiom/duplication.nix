# Duplication rule (gating, AE1).
# Detects identical multi-attribute configuration blocks emitted by 2+ distinct
# declared aspects within the same class.
#
# Emissions are grouped by class + content hash instead of pairwise
# comparison: pairwise recursion is O(n^2) forcing and overflows the eval
# call depth on fleet-sized IRs (hundreds of emissions on a real infra
# flake); hashing forces each content exactly once.
{ lib }:
let
  util = import ./util.nix { inherit lib; };
in
{
  id = "duplication";
  severity = "gating";
  docRef = "docs/src/content/docs/guides/configure-aspects.mdx";

  check =
    ir:
    let
      # Safety discipline: analyze ONLY declared, non-opaque emissions.
      # The multi-leaf threshold (R3) also keeps atomic single assignments
      # out of the gate.
      candidates = builtins.filter (
        e: e.declared && !(e.opaque or false) && util.leafCount e.content >= 2
      ) (ir.emissions or [ ]);

      summarizeContent =
        c: if builtins.isAttrs c then lib.concatStringsSep ", " (builtins.attrNames c) else "block";

      keyed = map (e: {
        key = "${e.class}:${builtins.hashString "sha256" (builtins.toJSON e.content)}";
        aspect = util.baseNameOf e.identity;
        inherit (e) class content;
      }) candidates;

      groups = builtins.groupBy (x: x.key) keyed;

      findingFor =
        group:
        let
          aspects = lib.sort (a: b: a < b) (lib.unique (map (x: x.aspect) group));
          quoted = map (a: "'${a}'") aspects;
          first = builtins.head group;
        in
        lib.optional (builtins.length aspects >= 2) {
          aspectPath = "den.aspects.${builtins.head aspects}";
          message = "Aspects ${lib.concatStringsSep " and " quoted} emit identical multi-attribute '${first.class}' configuration block (${summarizeContent first.content}).";
          fix = "Extract the duplicated configuration into a shared aspect 'shared-${lib.concatStringsSep "-" aspects}' (or shared include) and include it in ${lib.concatStringsSep " and " quoted}.";
        };
    in
    lib.concatMap findingFor (builtins.attrValues groups);
}
