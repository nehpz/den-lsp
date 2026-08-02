# Rule registry (KTD6). A rule is a plain attrset:
#   {
#     id;        # stable rule id
#     severity;  # "gating" | "advisory" — rule-level, never per finding (R4/R5)
#     docRef;    # den doc section establishing the rule (R12)
#     check;     # ir -> [ { aspectPath; message; fix; position ? null; } ]
#   }
#
# Precision discipline (KD2/R11): gating rules must be provable from the
# evaluated graph with near-zero false positives. A disputed gating finding
# is a rule bug — revise or demote the rule here; there is no per-finding
# suppression anywhere in the toolchain.
#
# Safety discipline: rules may force emission content ONLY for emissions
# with `declared = true` (consumer-authored aspects). Framework emissions
# can reference option-merged values whose forcing raises uncatchable
# evaluation errors.
{ lib }:
let
  structural = import ./structural { inherit lib; };
  idiom = import ./idiom { inherit lib; };
in
{
  inherit structural idiom;
  default = structural ++ idiom;
}
