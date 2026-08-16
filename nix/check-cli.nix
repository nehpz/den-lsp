# Standalone den-lsp-check CLI on den-lsp's own flake (U2+U3).
#
# Exposed as apps.<system>.den-lsp-check:
#   nix run <den-lsp>#den-lsp-check -- <path>
#
# Renders via check-core.outcomeFor (same renderer/exit mapping as the
# module-generated per-consumer app). Wired targets eval the committed
# document; unwired targets run U1 preflight then the flake-parts shim.
{
  pkgs,
  lib,
  den-lsp-src ? ../.,
}:
let
  helper = pkgs.writeText "den-lsp-check-outcome.nix" ''
    { jsonFile, strictness }:
    let
      nixpkgsLib = import ${pkgs.path}/lib;
      den-lsp = {
        lib = import ${den-lsp-src}/nix/engine { lib = nixpkgsLib; };
      };
      core = import ${den-lsp-src}/nix/check-core.nix { inherit den-lsp; };
      doc = builtins.fromJSON (builtins.readFile jsonFile);
      o = core.outcomeFor doc;
    in {
      inherit (o) text hasGating;
      inherit (core) gatingNotice;
      exitCode = o.exitCode strictness;
    }
  '';
in
pkgs.writeShellApplication {
  name = "den-lsp-check";
  runtimeInputs = [
    pkgs.bash
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.jq
  ];
  text = ''
    DEN_LSP_SRC=${den-lsp-src}
    SHIM=${den-lsp-src}/nix
    EPHEMERAL=${den-lsp-src}/nix/ephemeral.nix
    OUTCOME_HELPER=${helper}
  ''
  + builtins.readFile ./check-cli.bash;
}
