{
  version = 1;
  name = "base-broken";
  kind = "eval-error";
  defect = "Deliberate evaluation error thrown inside aspect module";
  task = "Fix the evaluation error in the aspect module by replacing the broken aspect's body with an empty attribute set ({ }); do not add class keys such as nixos.";
  expectedError = "deliberate eval error in broken module";
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
