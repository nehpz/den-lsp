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
in
{
  inherit (document) version mkDocument;
  inherit (render) renderText normalizeFile normalizePosition;
  inherit rules;

  analyze =
    {
      ir,
      rules ? (import ./rules { inherit lib; }).default,
    }:
    document.mkDocument { inherit ir rules; };
}
