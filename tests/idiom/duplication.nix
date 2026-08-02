{
  lib,
  engine,
  syntheticIr,
}:
let
  rules = engine.rules.idiom;

  # Covers AE1.
  # Multi-attribute block duplicated across two declared aspects (web and db).
  multiAttrIr = syntheticIr // {
    emissions = [
      {
        scope = "host=igloo,system=x86_64-linux";
        class = "nixos";
        identity = "web";
        declared = true;
        opaque = false;
        content = {
          services.openssh = {
            enable = true;
            port = 22;
          };
        };
      }
      {
        scope = "host=igloo,system=x86_64-linux";
        class = "nixos";
        identity = "db";
        declared = true;
        opaque = false;
        content = {
          services.openssh = {
            enable = true;
            port = 22;
          };
        };
      }
    ];
  };

  # Covers AE1.
  # Single atomic assignment duplicated across web and db — must NOT fire.
  singleAtomicIr = syntheticIr // {
    emissions = [
      {
        scope = "host=igloo,system=x86_64-linux";
        class = "nixos";
        identity = "web";
        declared = true;
        opaque = false;
        content = {
          services.openssh.enable = true;
        };
      }
      {
        scope = "host=igloo,system=x86_64-linux";
        class = "nixos";
        identity = "db";
        declared = true;
        opaque = false;
        content = {
          services.openssh.enable = true;
        };
      }
    ];
  };

  docMulti = engine.analyze {
    ir = multiAttrIr;
    inherit rules;
  };
  docSingle = engine.analyze {
    ir = singleAtomicIr;
    inherit rules;
  };

  dupFinding = builtins.head docMulti.findings;
in
{
  # Covers AE1.
  covers-ae1-multi-attr-duplication =
    docMulti.summary.gating == 1
    && dupFinding.rule == "duplication"
    && dupFinding.severity == "gating"
    && lib.hasInfix "web" dupFinding.message
    && lib.hasInfix "db" dupFinding.message
    && lib.hasInfix "shared-db-web" dupFinding.fix;

  # Covers AE1.
  covers-ae1-single-atomic-duplication-ignored =
    docSingle.summary.gating == 0 && builtins.length docSingle.findings == 0;
}
