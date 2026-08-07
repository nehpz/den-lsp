{
  version = 1;
  name = "base-gating-dup";
  kind = "finding";
  defect = "Duplicated configuration block emitted across multiple aspects";
  task = "Refactor duplicated configuration block across aspects into a shared aspect named 'shared-openssh'.";
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
