{
  lib,
  engine,
  syntheticIr,
}:
let
  rules = engine.rules.idiom;

  # Covers AE6.
  # 3 single-option aspects with no provides -> advisory finding
  granularityIr = syntheticIr // {
    emissions = [
      {
        scope = "host=igloo,system=x86_64-linux";
        class = "nixos";
        identity = "opt1";
        declared = true;
        opaque = false;
        content = {
          services.openssh.enable = true;
        };
      }
      {
        scope = "host=igloo,system=x86_64-linux";
        class = "nixos";
        identity = "opt2";
        declared = true;
        opaque = false;
        content = {
          services.nginx.enable = true;
        };
      }
      {
        scope = "host=igloo,system=x86_64-linux";
        class = "nixos";
        identity = "opt3";
        declared = true;
        opaque = false;
        content = {
          services.fail2ban.enable = true;
        };
      }
    ];
    registries = syntheticIr.registries // {
      aspects = {
        opt1 = {
          provides = [ ];
        };
        opt2 = {
          provides = [ ];
        };
        opt3 = {
          provides = [ ];
        };
      };
    };
  };

  docGranular = engine.analyze {
    ir = granularityIr;
    inherit rules;
  };
  granFinding = builtins.head docGranular.findings;
in
{
  # Covers AE6.
  covers-ae6-granularity-drift =
    docGranular.summary.advisory == 1
    && docGranular.summary.gating == 0
    && granFinding.rule == "granularity"
    && granFinding.severity == "advisory"
    && lib.hasInfix "opt1" granFinding.message
    && lib.hasInfix "opt2" granFinding.message
    && lib.hasInfix "opt3" granFinding.message;

  # Covers AE6.
  covers-advisory-severity = granFinding.severity == "advisory";
}
