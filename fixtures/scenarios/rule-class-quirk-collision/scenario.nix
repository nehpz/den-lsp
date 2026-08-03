{
  version = 1;
  name = "rule-class-quirk-collision";
  kind = "eval-error";
  defect = "Key 'custom' is registered in both den.classes and den.quirks.";
  task = "Rename the colliding quirk so den.quirks does not collide with den.classes.";
  expectedError = "den.classes and den.quirks must not share keys";
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
