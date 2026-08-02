# Consumer-facing module for plain evalModules Den consumers (no
# flake-parts, no perSystem — e.g. flakes shaped like den's minimal
# template: evalModules + import-tree with den's flake output options).
#
# Wires flake.checks.<system>.den-lsp and flake.apps.<system>.den-lsp-check
# for every system that declares hosts under den.hosts (using
# inputs.nixpkgs.legacyPackages), plus the system-independent
# flake.den-lsp-analysis document (pure eval — the LSP server's preferred
# target on machines whose system declares no hosts).
{ den-lsp }:
{
  config,
  lib,
  inputs,
  ...
}:
let
  core = import ./check-core.nix { inherit den-lsp; };
  systems = builtins.attrNames (config.den.hosts or { });
  gateFor =
    system:
    core.gateFor {
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      inherit lib;
      inherit (config) den;
    };
in
{
  imports = [ ./inject-analysis.nix ];

  # Declare the output den-natively so den STRICT MODE (den.lib.strict on
  # den.schema.flake) accepts it.
  config = {
    den.schema.flake.options.den-lsp-analysis = lib.mkOption {
      type = lib.types.raw;
      description = "den-lsp analysis document (system-independent, pure eval).";
    };

    flake = {
      den-lsp-analysis = core.analysisFor { inherit (config) den; };

      checks = lib.genAttrs systems (system: {
        den-lsp = (gateFor system).check;
      });

      apps = lib.genAttrs systems (system: {
        den-lsp-check = (gateFor system).app;
      });
    };
  };
}
