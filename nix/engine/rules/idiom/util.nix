{ lib }:
rec {
  # Count scalar leaves in serialized content, skipping __opaque and __truncated markers.
  leafCount =
    v:
    if builtins.isAttrs v then
      if v ? __opaque || v ? __truncated then
        0
      else
        lib.foldl' (acc: val: acc + leafCount val) 0 (builtins.attrValues v)
    else if builtins.isList v then
      lib.foldl' (acc: val: acc + leafCount val) 0 v
    else if
      builtins.isBool v
      || builtins.isInt v
      || builtins.isFloat v
      || builtins.isString v
      || builtins.isPath v
      || v == null
    then
      1
    else
      0;

  # Base aspect name of an identity string ("web/openssh" -> "web", "igloo:1" -> "igloo")
  baseNameOf =
    identity:
    let
      m = builtins.match "([^:/[{]+).*" identity;
    in
    if m == null then identity else builtins.head m;

  # Parse host name from an emission scope string like "host=igloo,system=x86_64-linux"
  parseHostFromScope =
    scope:
    let
      m = builtins.match ".*host=([^,]+).*" scope;
    in
    if m != null then builtins.head m else null;
}
