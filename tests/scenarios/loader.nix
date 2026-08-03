{ ... }:
let
  libScenarios = import ../../fixtures/scenarios/lib.nix { };
  scenarios = libScenarios.scenarios;
  validateScenario = libScenarios.validateScenario;

  validManifestsLoad =
    (builtins.attrNames scenarios) == [ "base-advisory-only" "base-broken" "base-gating-dup" ];

  invalidVersion = validateScenario {
    version = 2;
    name = "test";
    kind = "finding";
    defect = "defect";
    task = "task";
    expectedFindings = [ ];
    goldenable = true;
    clearCut = true;
    knownMiss = false;
    complete = true;
  };
  wrongVersionRejected = !(builtins.tryEval invalidVersion).success;

  missingExclusionReason = validateScenario {
    version = 1;
    name = "test";
    kind = "finding";
    defect = "defect";
    task = "task";
    expectedFindings = [ ];
    goldenable = false;
    clearCut = true;
    knownMiss = false;
    complete = true;
  };
  goldenableFalseWithoutReasonRejected = !(builtins.tryEval missingExclusionReason).success;

  incompleteFile = builtins.toFile "scenario.nix" ''
    {
      version = 1;
      name = "incomplete-test";
      kind = "finding";
      defect = "defect";
      task = "task";
      expectedFindings = [ ];
      goldenable = true;
      clearCut = true;
      knownMiss = false;
      complete = false;
    }
  '';
  incompleteExcluded = (libScenarios.loadScenarioFile incompleteFile) == null;
in
{
  scenario-loader-valid-manifests-load = validManifestsLoad;
  scenario-loader-wrong-version-rejected = wrongVersionRejected;
  scenario-loader-goldenable-false-without-reason-rejected = goldenableFalseWithoutReasonRejected;
  scenario-loader-incomplete-excluded = incompleteExcluded;
}
