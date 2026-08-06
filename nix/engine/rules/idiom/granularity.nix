# Granularity rule (advisory, AE6).
# Detects over-fragmentation: >=3 declared aspects whose max leaves across any single
# scope group has leafCount == 1 and which declare no provides.
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

      # Helper: max leaves for an aspect across any single scope group.
      # The capture layer can replicate one logical emission many times within a
      # scope (one row per instantiation), so identical (scope, class, content)
      # rows are deduplicated first. Then leaves of DISTINCT emissions are
      # summed within each scope group, and the max across scope groups is the
      # aspect's size: a multi-scope duplicate still counts 1, while an aspect
      # emitting several distinct one-leaf chunks in one scope counts them all.
      leavesForAspect =
        aspName:
        let
          aspEmissions = builtins.filter (e: util.baseNameOf e.identity == aspName) emissions;
          uniqueEmissions = lib.unique (
            map (e: {
              scope = e.scope or "";
              class = e.class or "";
              inherit (e) content;
            }) aspEmissions
          );
          groupedByScope = lib.groupBy (e: e.scope) uniqueEmissions;
          scopeLeafCounts = lib.mapAttrsToList (
            _scope: scopeEmissions: lib.foldl' (acc: e: acc + util.leafCount e.content) 0 scopeEmissions
          ) groupedByScope;
        in
        if scopeLeafCounts == [ ] then 0 else lib.foldl' lib.max 0 scopeLeafCounts;
      # Find declared aspects that are single-leaf and declare no provides
      isSingleLeafNoProvides =
        aspName: aspectDef:
        let
          maxLeaves = leavesForAspect aspName;
          provides = builtins.filter (p: p != "__functor") (aspectDef.provides or [ ]);
        in
        maxLeaves == 1 && provides == [ ];

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
