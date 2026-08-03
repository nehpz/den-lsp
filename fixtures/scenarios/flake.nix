{
  description = "Hermetic scenario detection tier checks for den-lsp";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0.1";
    den.url = "github:denful/den/v0.18.0";
    den-lsp.url = "github:nehpz/den-lsp";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      den,
      den-lsp,
      flake-parts,
    }:
    let
      lib = nixpkgs.lib;
      scenariosLib = import ./lib.nix { inherit lib; };
      scenarios = scenariosLib.scenarios;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      getModules =
        dir:
        let
          hasTrigger = builtins.pathExists (dir + "/trigger.nix");
          triggerMod = if hasTrigger then [ (dir + "/trigger.nix") ] else [ ];
          modulesDir = dir + "/modules";
          hasModules = builtins.pathExists modulesDir;
          moduleFiles =
            if hasModules then
              let
                entries = builtins.readDir modulesDir;
                nixFiles = builtins.filter (
                  name: entries.${name} == "regular" && builtins.match ".*\\.nix" name != null
                ) (builtins.attrNames entries);
              in
              map (name: modulesDir + "/${name}") nixFiles
            else
              [ ];
        in
        # Workspace flakes import modules/*.nix before trigger.nix; keep the
        # hermetic tier on the same order so merge-tie behavior cannot drift.
        moduleFiles ++ triggerMod;

      evalWorkspace =
        dir:
        let
          eval = flake-parts.lib.evalFlakeModule {
            inputs = {
              inherit den den-lsp flake-parts;
              nixpkgs = inputs.nixpkgs;
            };
          } {
            # `systems` has no flake-parts default. Nothing here forces a
            # perSystem-derived value today (only flake.den-lsp-analysis is
            # read), but set it explicitly so a future flake-parts or check
            # change cannot break every scenario at once with a confusing
            # "option `systems` is used but not defined" error.
            systems = [
              "x86_64-linux"
              "aarch64-linux"
              "aarch64-darwin"
            ];
            imports = [
              den.flakeModules.default
              den-lsp.flakeModules.default
            ] ++ getModules dir;
          };
        in
        eval.config.flake.den-lsp-analysis;

      checkCond =
        pkgs: name: cond: msg:
        pkgs.runCommandLocal name { } (
          if cond then
            "touch $out"
          else
            ''
              echo "scenario check failed: ${name}" >&2
              echo ${pkgs.lib.escapeShellArg msg} >&2
              exit 1
            ''
        );

      evalScenarioCond =
        s:
        let
          scenarioDir = ./. + "/${s.name}";
          workspaceDir = scenarioDir + "/workspace";
          goldenDir = scenarioDir + "/golden";
        in
        if s.kind == "eval-error" then
          let
            # builtins.tryEval cannot expose the error message in pure Nix, so the
            # hermetic tier asserts only that evaluation fails; the expectedError
            # substring is asserted by the evidence runner's eval leg
            # (tools/evidence-runner/run.bash eval-error path).
            evalRes = builtins.tryEval (builtins.deepSeq (evalWorkspace workspaceDir) true);
            # A goldenable eval-error scenario still ships a golden (the repaired
            # tree); it must evaluate cleanly with zero findings even though the
            # defective workspace is asserted to fail.
            goldenRes =
              if s.goldenable then
                builtins.tryEval (builtins.deepSeq (evalWorkspace goldenDir) true)
              else
                { success = true; };
            goldenClean = !s.goldenable || (evalWorkspace goldenDir).findings == [ ];
            cond = evalRes.success == false && goldenRes.success && (goldenRes.success -> goldenClean);
            msg = "Expected evaluation error for scenario '${s.name}' with a clean golden; workspace evaluated or golden failed/was not clean.";
          in
          {
            inherit (s) name;
            inherit cond msg;
          }
        else
          let
            # Contain throws to this scenario's check instead of aborting the
            # whole flake eval. tryEval catches throw/assert only; other eval
            # errors (e.g. missing attributes) still abort - that is a Nix
            # limitation, not a policy choice.
            docRes = builtins.tryEval (
              let
                doc = evalWorkspace workspaceDir;
              in
              builtins.deepSeq doc doc
            );
            actualFindings =
              if docRes.success then
                map (f: {
                  rule = f.rule;
                  severity = f.severity;
                }) docRes.value.findings
              else
                [ ];

            sortFindings = builtins.sort (a: b: (builtins.toJSON a) < (builtins.toJSON b));

            # Known-miss scenarios assert the miss exactly: zero findings today.
            # If the engine later detects the defect, this check goes red and the
            # stale known-miss must be promoted, never silently absorbed.
            matchWorkspace =
              docRes.success
              && (
                if s.knownMiss then
                  actualFindings == [ ]
                else
                  sortFindings actualFindings == sortFindings s.expectedFindings
              );

            # The golden is the known-correct repair: it must re-analyze with zero
            # findings of any severity (advisory included), or advisory false
            # positives on clean configurations would pass CI undetected.
            goldenPass =
              if s.goldenable then
                let
                  goldenRes = builtins.tryEval (
                    let
                      fs = (evalWorkspace goldenDir).findings;
                    in
                    builtins.deepSeq fs fs
                  );
                in
                goldenRes.success && goldenRes.value == [ ]
              else
                true;

            cond = matchWorkspace && goldenPass;
            msg =
              if !docRes.success then
                "Workspace evaluation for scenario '${s.name}' threw instead of producing an analysis document."
              else
                "Finding mismatch or golden finding failure for scenario '${s.name}'. Expected: ${builtins.toJSON s.expectedFindings}, Actual: ${builtins.toJSON actualFindings}";
          in
          {
            inherit (s) name;
            inherit cond msg;
          };

      buildScenarioCheck = pkgs: evalRes: checkCond pkgs "scenario-${evalRes.name}" evalRes.cond evalRes.msg;

      nonHeavyScenarios = lib.filterAttrs (_: s: !s.heavy) scenarios;
      heavyScenarios = lib.filterAttrs (_: s: s.heavy) scenarios;

      evaluatedNonHeavy = lib.mapAttrs (_: evalScenarioCond) nonHeavyScenarios;
      evaluatedHeavy = lib.mapAttrs (_: evalScenarioCond) heavyScenarios;
    in
    {
      # Standard nix flake checks — excludes heavy scenarios.
      checks = lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        lib.mapAttrs' (
          name: res: lib.nameValuePair "scenario-${name}" (buildScenarioCheck pkgs res)
        ) evaluatedNonHeavy
      );

      # Heavy scenarios (e.g. fleet-scale) exposed under a separate attribute set
      # so nix flake check skips them by default.
      heavyChecks = lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        lib.mapAttrs' (
          name: res: lib.nameValuePair "scenario-${name}" (buildScenarioCheck pkgs res)
        ) evaluatedHeavy
      );
    };
}
