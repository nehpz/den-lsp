{ ... }:
let
  libScenarios = import ../../fixtures/scenarios/lib.nix { };
  scenarios = libScenarios.scenarios;

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

  heavyFlagged = scenarios.field-fleet-scale.heavy == true;

  knownMissAllowed = builtins.all (s: builtins.isBool s.knownMiss) (builtins.attrValues scenarios);

  incompleteExcluded = (libScenarios.loadScenarioFile ../fixtures/incomplete-scenario.nix) == null;

  # A non-known-miss finding scenario with no expected findings would make its
  # hermetic detection check pass vacuously; the loader must reject it.
  emptyExpectedNonMissRejected =
    !(builtins.tryEval (libScenarios.loadScenarioFile ../fixtures/vacuous-finding-scenario.nix))
    .success;
in
{
  scenario-loader-valid-manifests-load = validManifestsLoad;
  scenario-loader-heavy-flagged = heavyFlagged;
  scenario-loader-known-miss-allowed = knownMissAllowed;
  scenario-loader-incomplete-excluded = incompleteExcluded;
  scenario-loader-empty-expected-non-miss-rejected = emptyExpectedNonMissRejected;
}
