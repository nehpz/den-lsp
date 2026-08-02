# Text rendering for the analysis document, and position normalization.
#
# KTD7: the engine normalizes positions to repo-relative paths (stripping
# the /nix/store/<hash>-source/ prefix pure evaluation reports), so check
# and CLI output is clean and clickable. The LSP server rebases these
# repo-relative paths onto the absolute workspace root.
{ lib }:
let
  # "/nix/store/<hash>-source/modules/den.nix" -> "modules/den.nix".
  # Paths outside the store pass through unchanged.
  normalizeFile =
    file:
    let
      m = builtins.match "/nix/store/[^/]+/(.*)" file;
    in
    if m == null then file else builtins.head m;

  normalizePosition = pos: if pos == null then null else pos // { file = normalizeFile pos.file; };

  renderFinding =
    f:
    let
      marker = if f.severity == "gating" then "✗" else "•";
      at = lib.optionalString (
        f.position != null
      ) "\n  at: ${f.position.file}:${toString f.position.line}";
    in
    ''
      ${marker} [${f.severity}] ${f.rule} — ${f.aspectPath}
        ${f.message}
        fix: ${f.fix}${at}
        ref: ${f.docRef}
    '';

  renderText =
    doc:
    let
      s = doc.summary;
      header =
        if doc.findings == [ ] then
          "den-lsp: no findings."
        else
          "den-lsp: ${toString s.gating} gating, ${toString s.advisory} advisory finding(s).";
    in
    lib.concatStringsSep "\n" ([ header ] ++ map renderFinding doc.findings);
in
{
  inherit normalizeFile normalizePosition renderText;
}
