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
        triggerMod ++ moduleFiles;

      evalWorkspace =
        dir:
        let
          eval = flake-parts.lib.evalFlakeModule {
            inputs = {
              inherit den den-lsp flake-parts;
              nixpkgs = inputs.nixpkgs;
            };
          } {
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
              echo "${msg}" >&2
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
            evalRes = builtins.tryEval (builtins.deepSeq (evalWorkspace workspaceDir) true);
            cond = evalRes.success == false;
            msg = "Expected evaluation error for scenario '${s.name}', but evaluation succeeded.";
          in
          {
            inherit (s) name;
            inherit cond msg;
          }
        else
          let
            doc = evalWorkspace workspaceDir;
            actualFindings = map (f: {
              rule = f.rule;
              severity = f.severity;
            }) doc.findings;

            # Known-miss scenarios assert the miss exactly: zero findings today.
            # If the engine later detects the defect, this check goes red and the
            # stale known-miss must be promoted, never silently absorbed.
            matchWorkspace =
              if s.knownMiss then actualFindings == [ ] else actualFindings == s.expectedFindings;

            goldenPass =
              if s.goldenable then
                let
                  goldenDoc = evalWorkspace goldenDir;
                in
                goldenDoc.summary.gating == 0
              else
                true;

            cond = matchWorkspace && goldenPass;
            msg = "Finding mismatch or golden gating finding failure for scenario '${s.name}'. Expected: ${builtins.toJSON s.expectedFindings}, Actual: ${builtins.toJSON actualFindings}";
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
