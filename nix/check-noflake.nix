# Consumer-facing module for plain evalModules Den consumers (no
# flake-parts, no perSystem — e.g. flakes shaped like den's minimal
# template: evalModules + import-tree with den's flake output options).
#
# Wires flake.checks.<system>.den-lsp and flake.apps.<system>.den-lsp-check
# for every system that declares hosts under den.hosts, using
# inputs.nixpkgs.legacyPackages for the package set.
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
    core {
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      inherit lib;
      den = config.den;
    };
in
{
  imports = [ ./inject-analysis.nix ];

  config.flake.checks = lib.genAttrs systems (system: {
    den-lsp = (gateFor system).check;
  });

  config.flake.apps = lib.genAttrs systems (system: {
    den-lsp-check = (gateFor system).app;
  });
}
