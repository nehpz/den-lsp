{
  version = 1;
  name = "field-wrapper-masking";
  kind = "finding";
  defect = "Identical configuration emitted across multiple aspects wrapped in option provenance layers";
  task = "Refactor duplicated configuration wrapped in module-provenance layers into a shared aspect named 'shared-openssh'.";
  expectedFindings = [
    {
      rule = "duplication";
      severity = "gating";
    }
  ];
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
