# Battery replication rule (gating, AE2).
# Detects hand-rolled configurations that replicate built-in batteries.
# R7 guard: fires ONLY when the recommended battery exists in ir.registries.batteries.
{ lib }:
let
  util = import ./util.nix { inherit lib; };
in
{
  id = "battery-replication";
  severity = "gating";
  docRef = "docs/src/content/docs/guides/batteries.mdx";

  check =
    ir:
    let
      batteries = ir.registries.batteries or { };

      # Safety discipline: declared, non-opaque emissions only
      declaredEmissions = builtins.filter (e: e.declared && !(e.opaque or false)) (ir.emissions or [ ]);

      checkEmission =
        e:
        let
          asp = util.baseNameOf e.identity;
          c = e.content;

          # Signature (a): users.users account creation
          hasUsersCreation =
            builtins.isAttrs c
            && c ? users
            && builtins.isAttrs c.users
            && c.users ? users
            && builtins.isAttrs c.users.users
            && c.users.users != { };

          # R7 guard for signature (a): recommend define-user or primary-user if registered
          userBattery =
            if batteries ? "define-user" then
              "den.batteries.define-user"
            else if batteries ? "primary-user" then
              "den.batteries.primary-user"
            else
              null;

          userFinding =
            if hasUsersCreation && userBattery != null then
              [
                {
                  aspectPath = "den.aspects.${asp}";
                  message = "Aspect '${asp}' defines user accounts under 'users.users', replicating what a built-in battery provides.";
                  fix = "Remove explicit 'users.users' configuration and include '${userBattery}' in the aspect's 'includes'.";
                }
              ]
            else
              [ ];

          # Signature (b): networking.hostName equal to host name in emission scope
          hostInScope = util.parseHostFromScope e.scope;
          hasMatchingHostname =
            builtins.isAttrs c
            && c ? networking
            && builtins.isAttrs c.networking
            && c.networking ? hostName
            && hostInScope != null
            && c.networking.hostName == hostInScope;

          # R7 guard for signature (b): hostname battery must be registered
          hostnameFinding =
            if hasMatchingHostname && batteries ? "hostname" then
              [
                {
                  aspectPath = "den.aspects.${asp}";
                  message = "Aspect '${asp}' sets 'networking.hostName' to '${hostInScope}', matching host '${hostInScope}' in scope.";
                  fix = "Remove explicit 'networking.hostName' configuration and include 'den.batteries.hostname' in den.default.includes or the host aspect.";
                }
              ]
            else
              [ ];
        in
        userFinding ++ hostnameFinding;
    in
    lib.unique (lib.concatMap checkEmission declaredEmissions);
}
