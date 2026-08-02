# Consumer-facing flake-parts module (KD5, R9, R10).
#
# Importing this module in a flake-parts Den consumer wires:
#   checks.<system>.den-lsp   — the gate: fails iff any gating finding exists;
#                               advisory findings print but never affect
#                               status (AE4). Raw document at .passthru.analysis.
#   apps.<system>.den-lsp-check — fix-shaped text report, same exit semantics.
#   flake.den-lsp-analysis    — the raw analysis document, system-independent
#                               (pure eval, no pkgs). Preferred LSP server
#                               target: an editing machine's system may
#                               declare no hosts, so the per-system checks
#                               path may not exist there:
#                                 nix eval --json path:.#den-lsp-analysis
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

  config.flake.den-lsp-analysis = core.analysisFor { inherit (config) den; };

  config.perSystem =
    { pkgs, ... }:
    let
      gate = core.gateFor {
        inherit pkgs lib;
        inherit (config) den;
      };
    in
    {
      checks.den-lsp = gate.check;
      apps.den-lsp-check = gate.app;
    };
}
