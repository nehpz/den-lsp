# Granularity rule (advisory, AE6).
# Detects over-fragmentation: >=3 declared aspects whose total content across all
# emissions has leafCount == 1 and which declare no provides.
{ lib }:
let
  util = import ./util.nix { inherit lib; };
in
{
  id = "granularity";
  severity = "advisory";
  docRef = "docs/src/content/docs/guides/configure-aspects.mdx";

  check =
    ir:
    let
      declaredAspects = ir.registries.aspects or { };
      emissions = builtins.filter (e: e.declared && !(e.opaque or false)) (ir.emissions or [ ]);

      # Helper: max leaves for an aspect across any single emission
      leavesForAspect =
        aspName:
        let
          aspEmissions = builtins.filter (e: util.baseNameOf e.identity == aspName) emissions;
          leafCounts = map (e: util.leafCount e.content) aspEmissions;
        in
        if leafCounts == [ ] then 0 else lib.foldl' lib.max 0 leafCounts;
      # Find declared aspects that are single-leaf and declare no provides
      isSingleLeafNoProvides =
        aspName: aspectDef:
        let
          totalLeaves = leavesForAspect aspName;
          provides = builtins.filter (p: p != "__functor") (aspectDef.provides or [ ]);
        in
        totalLeaves == 1 && provides == [ ];

      matchingAspects = lib.filterAttrs isSingleLeafNoProvides declaredAspects;
      aspectNames = builtins.attrNames matchingAspects;
      count = builtins.length aspectNames;
    in
    if count >= 3 then
      let
        aspectsStr = lib.concatMapStringsSep ", " (a: "'${a}'") aspectNames;
      in
      [
        {
          aspectPath = "den.aspects";
          message = "Found ${toString count} single-option aspects with no declared provides: ${aspectsStr}.";
          fix = "Consolidate single-option aspects ${aspectsStr} into fewer domain-focused aspects or include them directly.";
        }
      ]
    else
      [ ];
}
