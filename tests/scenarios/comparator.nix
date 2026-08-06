{ ... }:
let
  libScenarios = import ../../fixtures/scenarios/lib.nix { };
  scenarios = libScenarios.scenarios;

  scenariosList = builtins.attrValues scenarios;

  validKinds = builtins.all (s: s.kind == "finding" || s.kind == "eval-error") scenariosList;

  findingScenariosHaveFindings = builtins.all (
    s: s.kind != "finding" || builtins.isList s.expectedFindings
  ) scenariosList;

  evalErrorScenariosHaveError = builtins.all (
    s: s.kind != "eval-error" || (builtins.isString s.expectedError && s.expectedError != "")
  ) scenariosList;

  goldenableValid = builtins.all (
    s: s.goldenable == true || (builtins.isString s.exclusionReason && s.exclusionReason != "")
  ) scenariosList;
in
{
  scenario-comparator-valid-kinds = validKinds;
  scenario-comparator-finding-specs = findingScenariosHaveFindings;
  scenario-comparator-eval-error-specs = evalErrorScenariosHaveError;
  scenario-comparator-goldenable-valid = goldenableValid;
}
