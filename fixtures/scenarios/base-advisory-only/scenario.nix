{
  version = 1;
  name = "base-advisory-only";
  kind = "finding";
  defect = "Over-fragmented single-option aspects with no declared provides";
  task = "Consolidate fragmented single-option aspects into a unified aspect named 'common'.";
  expectedFindings = [
    {
      rule = "granularity";
      severity = "advisory";
    }
  ];
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
