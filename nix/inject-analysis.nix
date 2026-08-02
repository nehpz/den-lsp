# Injects the vendored analysis layer into the consumer's den.lib.
# den.lib is a freeform (lazyAttrsOf) option in den's nixModule, so this
# merges cleanly with any den version. mkDefault yields automatically once
# den ships a native den.lib.analysis upstream.
{ config, lib, ... }:
{
  config.den.lib.analysis = lib.mkDefault (
    import ./den-analysis.nix {
      den = config.den;
      inherit lib;
    }
  );
}
