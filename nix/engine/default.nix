# den-lsp analysis engine — pure functions over the Den analysis IR
# (den.lib.analysis.capture output). No dependency beyond nixpkgs.lib.
#
# analyze { ir, rules ? rules.default } -> document (see document.nix)
# renderText document -> fix-shaped text report, gating findings first
{ lib }:
let
  document = import ./document.nix { inherit lib; };
  render = import ./render.nix { inherit lib; };
  rules = import ./rules { inherit lib; };
  # Function-arg `rules` shadows the let-binding, so the default cannot
  # be `rules.default` (infinite recursion). Bind it once here.
  defaultRules = rules.default;
in
{
  inherit (document) version mkDocument;
  inherit (render) renderText normalizeFile normalizePosition;
  inherit rules;

  analyze =
    {
      ir,
      rules ? defaultRules,
    }:
    document.mkDocument { inherit ir rules; };
}
