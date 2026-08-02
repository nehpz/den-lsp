# Class-quirk collision rule (gating).
# Flags keys that exist in both den.classes and den.quirks.
# Mirrors Den's pipeline assert for registry name collisions.
{ lib }:
{
  id = "class-quirk-collision";
  severity = "gating";
  docRef = "docs/src/content/docs/reference/quirks.mdx";
  check =
    ir:
    let
      classes = ir.registries.classes or { };
      quirks = ir.registries.quirks or { };
      collidingKeys = lib.filter (k: classes ? ${k}) (builtins.attrNames quirks);
    in
    map (k: {
      aspectPath = "den.quirks.${k}";
      message = "Quirk '${k}' collides with registered class '${k}' in den.classes.";
      fix = "Rename quirk '${k}' or class '${k}' to avoid collision between den.quirks and den.classes.";
    }) collidingKeys;
}
