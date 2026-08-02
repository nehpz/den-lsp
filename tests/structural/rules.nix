# Tests for U3 structural rules: unregistered-class-key and class-quirk-collision
{
  lib,
  engine,
  syntheticIr,
}:
let
  # Baseline syntheticIr has igloo (nixos class key) and tux (includes structural key)
  cleanDoc = engine.analyze {
    ir = syntheticIr;
  };

  # Scenario for AE3: unregistered key 'custom' in aspect 'web'
  ae3Ir = syntheticIr // {
    registries = syntheticIr.registries // {
      aspects = syntheticIr.registries.aspects // {
        web = {
          description = null;
          provides = [ ];
          keys = [ "custom" ];
          callable = false;
        };
      };
    };
  };

  ae3Doc = engine.analyze {
    ir = ae3Ir;
  };

  ae3Findings = lib.filter (f: f.rule == "unregistered-class-key") ae3Doc.findings;
  ae3Finding = builtins.head ae3Findings;

  # Scenario for registered class key: should NOT fire
  registeredClassIr = syntheticIr // {
    registries = syntheticIr.registries // {
      aspects = syntheticIr.registries.aspects // {
        web = {
          description = null;
          provides = [ ];
          keys = [ "nixos" ];
          callable = false;
        };
      };
    };
  };

  registeredClassDoc = engine.analyze {
    ir = registeredClassIr;
  };

  # Scenario for registered quirk key: should NOT fire
  registeredQuirkIr = syntheticIr // {
    registries = syntheticIr.registries // {
      quirks = {
        firewall = {
          description = "Firewall quirk";
        };
      };
      aspects = syntheticIr.registries.aspects // {
        web = {
          description = null;
          provides = [ ];
          keys = [ "firewall" ];
          callable = false;
        };
      };
    };
  };

  registeredQuirkDoc = engine.analyze {
    ir = registeredQuirkIr;
  };

  # Scenario for class-quirk collision
  collisionIr = syntheticIr // {
    registries = syntheticIr.registries // {
      quirks = {
        nixos = {
          description = "Colliding quirk name";
        };
      };
    };
  };

  collisionDoc = engine.analyze {
    ir = collisionIr;
  };

  collisionFindings = lib.filter (f: f.rule == "class-quirk-collision") collisionDoc.findings;
  collisionFinding = builtins.head collisionFindings;
in
{
  clean-synthetic-ir-no-structural-findings =
    lib.filter (
      f: f.rule == "unregistered-class-key" || f.rule == "class-quirk-collision"
    ) cleanDoc.findings == [ ];

  # Covers AE3.
  covers-ae3-unregistered-key-fires =
    builtins.length ae3Findings == 1
    && ae3Finding.severity == "gating"
    && ae3Finding.aspectPath == "den.aspects.web"
    && lib.hasInfix "web" ae3Finding.message
    && lib.hasInfix "custom" ae3Finding.message
    && lib.hasInfix "den.classes" ae3Finding.message
    && lib.hasInfix "den.quirks" ae3Finding.message
    && lib.hasInfix "den.classes" ae3Finding.fix
    && lib.hasInfix "web" ae3Finding.fix;

  registered-class-key-does-not-fire =
    lib.filter (f: f.rule == "unregistered-class-key") registeredClassDoc.findings == [ ];

  registered-quirk-key-does-not-fire =
    lib.filter (f: f.rule == "unregistered-class-key") registeredQuirkDoc.findings == [ ];

  class-quirk-collision-fires =
    builtins.length collisionFindings == 1
    && collisionFinding.severity == "gating"
    && collisionFinding.aspectPath == "den.quirks.nixos"
    && lib.hasInfix "nixos" collisionFinding.message
    && lib.hasInfix "den.classes" collisionFinding.message
    && lib.hasInfix "den.quirks" collisionFinding.fix;
}
