{
  version = 1;
  name = "rule-unregistered-class-key";
  kind = "finding";
  defect = "Aspect 'web' contains unregistered key 'custom'.";
  task = "Register key 'custom' in den.classes or den.quirks.";
  expectedFindings = [
    {
      rule = "unregistered-class-key";
      severity = "gating";
    }
  ];
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
