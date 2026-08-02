{
  lib,
  engine,
  syntheticIr,
}:
let
  rules = engine.rules.idiom;

  # Covers AE7.
  # Aspect 'monitoring' attached individually to host 'igloo' and host 'tux'
  repetitionIr = syntheticIr // {
    entities = {
      hosts = [
        {
          name = "igloo";
          system = "x86_64-linux";
          class = "nixos";
        }
        {
          name = "tux";
          system = "x86_64-linux";
          class = "nixos";
        }
      ];
      homes = { };
    };
    registries = syntheticIr.registries // {
      aspects = {
        monitoring = {
          provides = [ ];
        };
        igloo = {
          provides = [ ];
        };
        tux = {
          provides = [ ];
        };
      };
    };
    entries = [
      {
        name = "igloo";
        parent = null;
      }
      {
        name = "tux";
        parent = null;
      }
      {
        name = "monitoring";
        parent = "igloo";
      }
      {
        name = "monitoring";
        parent = "tux";
      }
    ];
  };

  docRepetition = engine.analyze {
    ir = repetitionIr;
    inherit rules;
  };
  repFinding = builtins.head docRepetition.findings;
in
{
  # Covers AE7.
  covers-ae7-per-host-repetition =
    docRepetition.summary.advisory == 1
    && docRepetition.summary.gating == 0
    && repFinding.rule == "repetition"
    && repFinding.severity == "advisory"
    && lib.hasInfix "monitoring" repFinding.message
    && lib.hasInfix "igloo" repFinding.message
    && lib.hasInfix "tux" repFinding.message
    && lib.hasInfix "den.default.includes" repFinding.fix;
}
