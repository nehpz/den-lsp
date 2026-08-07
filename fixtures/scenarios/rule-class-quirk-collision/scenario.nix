{
  version = 1;
  name = "rule-class-quirk-collision";
  kind = "eval-error";
  defect = "Key 'custom' is registered in both den.classes and den.quirks.";
  task = "Rename the colliding quirk to 'custom-quirk' so den.quirks does not collide with den.classes. Change only the quirk's key, nothing else.";
  expectedError = "den.classes and den.quirks must not share keys";
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
