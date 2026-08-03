{
  version = 1;
  name = "rule-battery-replication";
  kind = "finding";
  defect = "Aspect 'user-config' defines user accounts under 'users.users', replicating what a built-in battery provides.";
  task = "Remove explicit 'users.users' configuration and include 'den.batteries.define-user'.";
  expectedFindings = [
    {
      rule = "battery-replication";
      severity = "gating";
    }
  ];
  goldenable = true;
  exclusionReason = null;
  clearCut = true;
  knownMiss = false;
  complete = true;
}
