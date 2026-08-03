{
  version = 1;
  name = "field-quirk-buckets";
  kind = "finding";
  defect = "Duplicated configuration block emitted inside quirk/pipe bucket classes (deployHealthChecks/firewall)";
  task = "Refactor the duplicated deployHealthChecks configuration emitted by both aspects into a shared aspect.";
  # Promoted from known-miss (2026-08-03): the class-agnostic duplication rule
  # detects this defect; the original known-miss designation predated a
  # verified assertion (the lenient matcher absorbed all findings) and was
  # falsified the moment the assertion was tightened.
  expectedFindings = [
    {
      rule = "duplication";
      severity = "gating";
    }
  ];
  goldenable = false;
  exclusionReason = "Detection promoted from known-miss; golden (deduplicated shared-aspect repair) not yet authored, so the scenario stays outside the clear-cut set until it lands.";
  clearCut = false;
  knownMiss = false;
  complete = true;
}
