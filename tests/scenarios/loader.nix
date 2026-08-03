{ ... }:
let
  libScenarios = import ../../fixtures/scenarios/lib.nix { };
  scenarios = libScenarios.scenarios;
  validateScenario = libScenarios.validateScenario;

  expectedScenarioNames = [
    "base-advisory-only"
    "base-broken"
    "base-gating-dup"
    "field-fleet-scale"
    "field-quirk-buckets"
    "field-wrapper-masking"
    "rule-battery-replication"
    "rule-class-quirk-collision"
    "rule-repetition"
    "rule-unregistered-class-key"
  ];
  validManifestsLoad = builtins.all (name: builtins.hasAttr name scenarios) expectedScenarioNames;

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

  invalidHeavy = validateScenario {
    version = 1;
    name = "test";
    kind = "finding";
    defect = "defect";
    task = "task";
    expectedFindings = [ ];
    goldenable = true;
    clearCut = true;
    heavy = "not-a-bool";
    knownMiss = false;
    complete = true;
  };
  invalidHeavyRejected = !(builtins.tryEval invalidHeavy).success;

  heavyManifest = validateScenario {
    version = 1;
    name = "test-heavy";
    kind = "finding";
    defect = "defect";
    task = "task";
    expectedFindings = [ ];
    goldenable = false;
    exclusionReason = "performance test";
    clearCut = false;
    heavy = true;
    knownMiss = false;
    complete = true;
  };
  heavyFlagged = heavyManifest.heavy == true;

  knownMissEmptyFindings = validateScenario {
    version = 1;
    name = "test-known-miss";
    kind = "finding";
    defect = "defect";
    task = "task";
    expectedFindings = [ ];
    goldenable = false;
    exclusionReason = "unanalyzed bucket";
    clearCut = false;
    knownMiss = true;
    complete = true;
  };
  knownMissAllowed = knownMissEmptyFindings.knownMiss == true && knownMissEmptyFindings.expectedFindings == [ ];

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
  scenario-loader-invalid-heavy-rejected = invalidHeavyRejected;
  scenario-loader-heavy-flagged = heavyFlagged;
  scenario-loader-known-miss-allowed = knownMissAllowed;
  scenario-loader-incomplete-excluded = incompleteExcluded;
}
