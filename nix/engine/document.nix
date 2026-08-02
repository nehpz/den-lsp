# The versioned analysis document — the single contract shared by the
# flake check, the CLI report, and the LSP server (KTD5).
#
# document = {
#   version = 1;
#   findings = [
#     {
#       rule;        # rule id, e.g. "duplication"
#       severity;    # "gating" | "advisory"
#       aspectPath;  # den.aspects path or aspect identity the finding is about
#       position;    # null | { file; line; column; } (file normalized repo-relative)
#       message;     # what is wrong, naming the specific aspects/keys involved
#       fix;         # the concrete remedy (fix-shaped, R7)
#       docRef;      # den doc section establishing the rule (R12)
#     }
#   ];
#   inventory = { classes; quirks; batteries; aspects; structuralKeys; entities; };
#   summary = { gating; advisory; };
# }
{ lib }:
let
  render = import ./render.nix { inherit lib; };

  version = 1;

  # A rule (KTD6): { id; severity; docRef; check = ir: [ rawFinding ]; }
  # rawFinding: { aspectPath; message; fix; position ? null; }
  runRule =
    ir: rule:
    map (f: {
      rule = rule.id;
      inherit (rule) severity docRef;
      inherit (f) aspectPath message fix;
      position = render.normalizePosition (f.position or null);
    }) (rule.check ir);

  severityRank = s: if s == "gating" then 0 else 1;

  mkDocument =
    { ir, rules }:
    let
      findings = lib.sortOn (f: [
        (severityRank f.severity)
        f.rule
        f.aspectPath
      ]) (lib.concatMap (runRule ir) rules);
    in
    {
      inherit version findings;
      summary = {
        gating = builtins.length (builtins.filter (f: f.severity == "gating") findings);
        advisory = builtins.length (builtins.filter (f: f.severity == "advisory") findings);
      };
      inventory = {
        inherit (ir.registries)
          classes
          quirks
          batteries
          aspects
          structuralKeys
          ;
        entities = ir.entities;
      };
    };
in
{
  inherit version mkDocument;
}
