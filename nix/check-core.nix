# Shared gate construction (KD5, R9, R10, KTD6): from a pkgs set and the
# consumer's den config, build the check derivation and the report app.
# Wrapped by nix/check.nix (flake-parts consumers) and
# nix/check-noflake.nix (plain evalModules consumers).
# The standalone CLI (nix/check-cli.nix) consumes outcomeFor / gatingNotice
# so module-app and field CLI share one renderer and exit mapping.
#
# R13 (eval-failure behavior): the document build is deliberately NOT
# wrapped in tryEval. When the consumer configuration fails to evaluate,
# `nix flake check` surfaces Nix's own root-cause error — which carries the
# failing file position — as the single failure. tryEval would swallow the
# message (Nix exposes no error text in-eval) and cannot catch hard
# evaluation errors anyway. The LSP server derives its R13 diagnostic by
# parsing the same root error from the eval subprocess.
{ den-lsp }:
rec {
  # Pure analysis document — no pkgs needed. Exposed system-independently
  # as the flake output `den-lsp-analysis` (the LSP server's preferred eval
  # target, since an editing machine's system may declare no hosts).
  analysisFor =
    { den }:
    den-lsp.lib.analyze {
      ir = den.lib.analysis.capture { classes = builtins.attrNames (den.classes or { }); };
    };

  gatingNotice = "den-lsp: gating findings — apply the fixes above.";

  # One renderer + exit-semantics source (KTD6). `strictness` is "gate"
  # (default) or "draft"; it only changes the exit code, never findings.
  outcomeFor = doc: rec {
    text = den-lsp.lib.renderText doc;
    hasGating = doc.summary.gating > 0;
    exitCode =
      strictness:
      if strictness == "draft" then
        0
      else if hasGating then
        1
      else
        0;
  };

  # One script template for the module app and the check derivation.
  # `report` is the store path of the rendered text. `toStderr` redirects
  # the report (and the blank line before the notice). `onSuccess` is
  # appended when there are no gating findings (the check copies to $out).
  textModeGateScript =
    {
      report,
      hasGating,
      toStderr ? false,
      onSuccess ? "",
    }:
    let
      redir = if toStderr then " >&2" else "";
    in
    ''
      cat ${report}${redir}
    ''
    + (
      if hasGating then
        ''
          echo${redir}
          echo "${gatingNotice}" >&2
          exit 1
        ''
      else
        onSuccess
    );

  gateFor =
    {
      pkgs,
      lib,
      den,
    }:
    let
      doc = analysisFor { inherit den; };
      outcome = outcomeFor doc;
      report = pkgs.writeText "den-lsp-report.txt" outcome.text;
      checkScript = pkgs.writeShellApplication {
        name = "den-lsp-check";
        text = textModeGateScript {
          inherit report;
          inherit (outcome) hasGating;
        };
      };
    in
    {
      check =
        pkgs.runCommandLocal "den-lsp-check"
          {
            passthru.analysis = doc;
            inherit report;
          }
          (textModeGateScript {
            inherit report;
            inherit (outcome) hasGating;
            toStderr = outcome.hasGating;
            onSuccess = ''
              cp ${report} "$out"
            '';
          });

      app = {
        type = "app";
        program = lib.getExe checkScript;
      };
    };
}
