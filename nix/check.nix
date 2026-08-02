# Consumer-facing flake-parts module (KD5, R9, R10).
#
# Importing this module in a flake-parts Den consumer wires, per system:
#   checks.den-lsp       — the gate: fails iff any gating finding exists;
#                          advisory findings print but never affect status (AE4).
#                          The raw analysis document is exposed at
#                          .passthru.analysis — the stable eval target for the
#                          LSP server and tooling (KTD5):
#                            nix eval --json path:.#checks.<system>.den-lsp.passthru.analysis
#   apps.den-lsp-check   — fix-shaped text report with the same exit semantics:
#                            nix run .#den-lsp-check
#
# Works against stock den (>= v0.18.0): the analysis layer is injected via
# inject-analysis.nix, no den changes required. Plain evalModules consumers
# use flakeModules.noflake (nix/check-noflake.nix) instead.
{ den-lsp }:
{ config, lib, ... }:
let
  core = import ./check-core.nix { inherit den-lsp; };
in
{
  imports = [ ./inject-analysis.nix ];

  config.perSystem =
    { pkgs, ... }:
    let
      gate = core {
        inherit pkgs lib;
        den = config.den;
      };
    in
    {
      checks.den-lsp = gate.check;
      apps.den-lsp-check = gate.app;
    };
}
