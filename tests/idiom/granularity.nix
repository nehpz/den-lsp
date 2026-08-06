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

  # Regression (field-observed): a single-option aspect included in several
  # scopes emits its one-leaf content once per scope. Leaf counting is
  # max-per-emission, not sum-across-emissions, so multi-scope inclusion
  # must not let a single-option aspect escape the rule.
  multiScopeIr = granularityIr // {
    emissions =
      granularityIr.emissions
      ++ (map (e: e // { scope = "user=tux,host=igloo,system=x86_64-linux"; }) granularityIr.emissions);
  };
  # Regression: an aspect emitting multiple distinct 1-leaf emissions in the same scope
  # (e.g. across two classes or modules) sums to >1 leaves in that scope group, so it
  # must NOT count toward the single-option advisory.
  sameScopeMultiEmissionIr = granularityIr // {
    emissions = granularityIr.emissions ++ [
      {
        scope = "host=igloo,system=x86_64-linux";
        class = "home-manager";
        identity = "opt1";
        declared = true;
        opaque = false;
        content = {
          programs.git.enable = true;
        };
      }
    ];
  };

  docMultiScope = engine.analyze {
    ir = multiScopeIr;
    inherit rules;
  };

  docGranular = engine.analyze {
    ir = granularityIr;
    inherit rules;
  };

  docSameScopeMultiEmission = engine.analyze {
    ir = sameScopeMultiEmissionIr;
    inherit rules;
  };

  # Regression (field-observed): the capture layer can replicate one logical
  # emission many times within a scope (identical scope/class/content rows).
  # Duplicates must collapse before leaf summing, or every real workspace's
  # single-option aspects would escape the rule.
  capReplicatedIr = granularityIr // {
    emissions = granularityIr.emissions ++ granularityIr.emissions ++ granularityIr.emissions;
  };

  docCapReplicated = engine.analyze {
    ir = capReplicatedIr;
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

  # Regression: multi-scope single-leaf aspects still fire granularity.
  capture-replicated-duplicates-collapse =
    docCapReplicated.summary.advisory == 1
    || throw "Expected capture-replicated duplicate emissions to collapse and still fire granularity: ${builtins.toJSON docCapReplicated.findings}";

  multi-scope-single-leaf-still-fires =
    docMultiScope.summary.advisory == 1 && (builtins.head docMultiScope.findings).rule == "granularity";

  # Regression: multiple emissions in the same scope sum leaf counts within that scope group.
  same-scope-multi-emission-leaves-summed = docSameScopeMultiEmission.summary.advisory == 0;
}
