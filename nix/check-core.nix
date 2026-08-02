# Shared gate construction (KD5, R9, R10): from a pkgs set and the
# consumer's den config, build the check derivation and the report app.
# Wrapped by nix/check.nix (flake-parts consumers) and
# nix/check-noflake.nix (plain evalModules consumers).
#
# R13 (eval-failure behavior): the document build is deliberately NOT
# wrapped in tryEval. When the consumer configuration fails to evaluate,
# `nix flake check` surfaces Nix's own root-cause error — which carries the
# failing file position — as the single failure. tryEval would swallow the
# message (Nix exposes no error text in-eval) and cannot catch hard
# evaluation errors anyway. The LSP server derives its R13 diagnostic by
# parsing the same root error from the eval subprocess.
{ den-lsp }:
{
  pkgs,
  lib,
  den,
}:
let
  engine = den-lsp.lib;
  classes = builtins.attrNames (den.classes or { });
  ir = den.lib.analysis.capture { inherit classes; };
  doc = engine.analyze { inherit ir; };
  text = engine.renderText doc;
  hasGating = doc.summary.gating > 0;
  report = pkgs.writeText "den-lsp-report.txt" text;
  checkScript = pkgs.writeShellApplication {
    name = "den-lsp-check";
    text = ''
      cat ${report}
      ${lib.optionalString hasGating ''
        echo
        echo "den-lsp: gating findings — apply the fixes above." >&2
        exit 1
      ''}
    '';
  };
in
{
  check =
    pkgs.runCommandLocal "den-lsp-check"
      {
        passthru.analysis = doc;
        inherit report;
      }
      (
        if hasGating then
          ''
            cat "$report" >&2
            echo >&2
            echo "den-lsp: gating findings — apply the fixes above." >&2
            exit 1
          ''
        else
          ''
            cat "$report"
            cp "$report" "$out"
          ''
      );

  app = {
    type = "app";
    program = lib.getExe checkScript;
  };
}
