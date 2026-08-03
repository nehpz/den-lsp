{
  version = 1;
  name = "rule-repetition";
  kind = "finding";
  defect = "Aspect 'monitoring' is attached individually to every host entity instead of global inclusion.";
  task = "Move repeated aspect 'monitoring' from individual host includes to den.default.includes.";
  expectedFindings = [
    {
      rule = "repetition";
      severity = "advisory";
    }
  ];
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
