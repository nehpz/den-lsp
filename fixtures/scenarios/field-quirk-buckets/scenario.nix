{
  version = 1;
  name = "field-quirk-buckets";
  kind = "finding";
  defect = "Duplicated configuration block emitted inside unanalyzed quirk/pipe bucket classes (deployHealthChecks/firewall)";
  task = "Investigate unanalyzed quirk/pipe bucket class emissions for duplicated configuration.";
  expectedFindings = [ ];
  goldenable = false;
  exclusionReason = "Unanalyzed quirk/pipe bucket class emissions pass through engine unanalyzed; candidate for future rule expansion.";
  clearCut = false;
  knownMiss = true;
  complete = true;
}
