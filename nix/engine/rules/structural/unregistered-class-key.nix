# Unregistered class key rule (gating).
# Flags aspect keys that match no structural key, registered class (den.classes),
# registered quirk (den.quirks), or nested aspect provides key.
# Mirrors Den's fall-through key classification in nix/lib/aspects/fx/key-classification.nix.
{ lib }:
{
  id = "unregistered-class-key";
  severity = "gating";
  docRef = "docs/src/content/docs/reference/quirks.mdx";
  check =
    ir:
    let
      aspects = ir.registries.aspects or { };
      classes = ir.registries.classes or { };
      quirks = ir.registries.quirks or { };
      rawStructural = ir.registries.structuralKeys or [ ];
      isStructuralKey =
        k:
        if builtins.isList rawStructural then
          builtins.elem k rawStructural
        else if builtins.isAttrs rawStructural then
          rawStructural ? ${k}
        else
          false;
    in
    lib.concatMap (
      aspectName:
      let
        aspectInfo = aspects.${aspectName};
        keys = aspectInfo.keys or [ ];
        provides = aspectInfo.provides or [ ];
        isNestedKey = k: builtins.elem k provides;
      in
      lib.concatMap (
        key:
        if isStructuralKey key || classes ? ${key} || quirks ? ${key} || isNestedKey key then
          [ ]
        else
          [
            {
              aspectPath = "den.aspects.${aspectName}";
              message = "Aspect '${aspectName}' contains key '${key}' which is not a structural key, registered class (den.classes), registered quirk (den.quirks), or nested aspect key.";
              fix = "Register '${key}' in den.classes or den.quirks, or nest it under provides in aspect '${aspectName}'.";
            }
          ]
      ) keys
    ) (builtins.attrNames aspects);
}
