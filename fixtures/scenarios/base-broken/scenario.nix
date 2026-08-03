{
  version = 1;
  name = "base-broken";
  kind = "eval-error";
  defect = "Deliberate evaluation error thrown inside aspect module";
  task = "Fix the evaluation error in the aspect module.";
  expectedError = "deliberate eval error in broken module";
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
