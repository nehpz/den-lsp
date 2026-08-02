{
  lib,
  engine,
  syntheticIr,
}:
let
  rules = engine.rules.idiom;

  # Base emission with users.users
  userEm = {
    scope = "host=igloo,system=x86_64-linux";
    class = "nixos";
    identity = "my-user";
    declared = true;
    opaque = false;
    content = {
      users.users.tux = {
        isNormalUser = true;
      };
    };
  };

  # Covers AE2.
  # Registered define-user battery -> finding recommends den.batteries.define-user
  userRegisteredIr = syntheticIr // {
    emissions = [ userEm ];
    registries = syntheticIr.registries // {
      batteries = syntheticIr.registries.batteries // {
        define-user = {
          description = "Define user";
          provides = [ ];
        };
      };
    };
  };

  # Covers AE2.
  # Battery absent from registries -> silent per R7 guard
  userAbsentIr = syntheticIr // {
    emissions = [ userEm ];
    registries = syntheticIr.registries // {
      batteries = { }; # No define-user or primary-user registered
    };
  };

  docUserReg = engine.analyze {
    ir = userRegisteredIr;
    inherit rules;
  };
  docUserAbs = engine.analyze {
    ir = userAbsentIr;
    inherit rules;
  };

  userFinding = builtins.head docUserReg.findings;
in
{
  # Covers AE2.
  covers-ae2-battery-replication =
    docUserReg.summary.gating == 1
    && userFinding.rule == "battery-replication"
    && userFinding.severity == "gating"
    && lib.hasInfix "my-user" userFinding.message
    && lib.hasInfix "den.batteries.define-user" userFinding.fix;

  # Covers AE2.
  covers-ae2-battery-replication-absent-guard =
    docUserAbs.summary.gating == 0 && builtins.length docUserAbs.findings == 0;
}
