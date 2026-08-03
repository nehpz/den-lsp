{
  version = 1;
  name = "field-fleet-scale";
  kind = "finding";
  defect = "Large-scale aspect fleet producing hundreds of emissions triggers evaluation depth limits if duplication check is pairwise recursive";
  task = "Refactor fleet configuration while preserving O(n) analysis performance under large emission scale.";
  expectedFindings = [
    {
      rule = "duplication";
      severity = "gating";
    }
  ];
  goldenable = false;
  exclusionReason = "Performance regression scenario, no repair";
  clearCut = false;
  heavy = true;
  knownMiss = false;
  complete = true;
}
