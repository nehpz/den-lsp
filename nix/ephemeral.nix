# Ephemeral injection wrapper for den-lsp.
#
# Analyzes any stock Den consumer flake (den >= 0.18.0) at invocation time
# without requiring a committed den-lsp flake input or repo configuration.
#
# Evaluation flow:
#   1. Already-instrumented target: if the target exposes a `den-lsp-analysis`
#      output, use it directly (zero double injection, identical results).
#   2. Den flake without den-lsp: reconstruct evaluation with
#      `nix/inject-analysis.nix` injected into the target's module graph
#      (covers flake-parts and plain evalModules consumers).
#   3. Non-Den target: return an explicit versioned error envelope
#      `{ version, error = { kind = "unsupported", message } }`, distinct
#      from a Den evaluation failure.
#
# Target workspace paths handle dirty working trees via `path:` refs.

args:
let
  workspace = if builtins.isAttrs args && (args ? workspace || args ? den-lsp) then args.workspace else args;
  den-lsp-default = if builtins.pathExists (./. + "/flake.nix") then ./. else ../.;
  den-lsp-arg = if builtins.isAttrs args && args ? den-lsp then args.den-lsp else den-lsp-default;
  inputOverrides = if builtins.isAttrs args && args ? inputOverrides then args.inputOverrides else { };

  denLspFlake =
    if builtins.isAttrs den-lsp-arg && den-lsp-arg ? lib then
      den-lsp-arg
    else
      builtins.getFlake (
        if builtins.isPath den-lsp-arg then "path:" + toString den-lsp-arg else toString den-lsp-arg
      );

  lib = denLspFlake.inputs.nixpkgs.lib;

  core = import ./check-core.nix { den-lsp = denLspFlake; };
  injectModule = import ./inject-analysis.nix;
  noflakeModule = import ./check-noflake.nix { den-lsp = denLspFlake; };

  unsupportedError = msg: {
    version = 1;
    error = {
      kind = "unsupported";
      message = msg;
    };
  };

  # Construct path ref for dirty working tree support
  targetRef =
    if builtins.isAttrs workspace then
      workspace
    else if builtins.isPath workspace then
      "path:" + toString workspace
    else if builtins.isString workspace then
      if lib.hasPrefix "path:" workspace || lib.hasPrefix "github:" workspace || lib.hasPrefix "git:" workspace then
        workspace
      else
        "path:" + workspace
    else
      workspace;

  targetFlake =
    if builtins.isAttrs workspace && workspace ? outputs then
      workspace
    else
      builtins.getFlake targetRef;

  isAlreadyInstrumented =
    (targetFlake ? den-lsp-analysis)
    || (targetFlake ? outputs && targetFlake.outputs ? den-lsp-analysis);

  committedResult =
    if targetFlake ? den-lsp-analysis then
      targetFlake.den-lsp-analysis
    else
      targetFlake.outputs.den-lsp-analysis;

  hasDenInput = (targetFlake ? inputs && targetFlake.inputs ? den) || (inputOverrides ? den);

  targetDir = if builtins.isPath workspace then workspace else targetFlake.outPath;

  getModulesFromDir =
    dir:
    let
      hasTrigger = builtins.pathExists (dir + "/trigger.nix");
      triggerMod = if hasTrigger then [ (dir + "/trigger.nix") ] else [ ];
      modulesDir = dir + "/modules";
      hasModules = builtins.pathExists modulesDir;
      findNixFiles =
        currentDir:
        let
          entries = builtins.readDir currentDir;
        in
        lib.concatLists (
          lib.mapAttrsToList (
            name: type:
            let
              subPath = currentDir + "/${name}";
            in
            if type == "directory" then
              findNixFiles subPath
            else if type == "regular" && lib.hasSuffix ".nix" name then
              [ subPath ]
            else
              [ ]
          ) entries
        );
      unsortedFiles = if hasModules then findNixFiles modulesDir else [ ];
      moduleFiles = builtins.sort (a: b: toString a < toString b) unsortedFiles;
    in
    moduleFiles ++ triggerMod;

  rawFlake =
    if builtins.pathExists (targetDir + "/flake.nix") then import (targetDir + "/flake.nix") else null;

  wrapFlakePartsModule =
    module:
    {
      imports = [
        module
        injectModule
        ({ config, lib, ... }: {
          config.flake.den-lsp-analysis = lib.mkDefault (core.analysisFor { inherit (config) den; });
        })
      ];
    };

  wrapEvalModulesArgs =
    args:
    args
    // {
      modules = (args.modules or [ ]) ++ [ noflakeModule ];
    };

  baseInputs =
    { self = { outPath = targetDir; } // (if builtins.isAttrs targetFlake then targetFlake else { }); }
    // (if targetFlake ? inputs then targetFlake.inputs else { })
    // inputOverrides;

  hasFlakePartsInput = baseInputs ? flake-parts;

  augmentedInputs =
    baseInputs
    // lib.optionalAttrs hasFlakePartsInput {
      flake-parts = baseInputs.flake-parts // {
        lib = baseInputs.flake-parts.lib // {
          mkFlake =
            argsOrModule:
            let
              isArgs =
                builtins.isAttrs argsOrModule
                && (
                  argsOrModule ? inputs
                  || argsOrModule ? self
                  || argsOrModule ? specialArgs
                  || argsOrModule ? moduleLocation
                );
              origMkFlake = baseInputs.flake-parts.lib.mkFlake;
              cleanArgs = args: (if builtins.isAttrs args then args else { }) // {
                inputs = augmentedInputs // (if builtins.isAttrs args && args ? self then { inherit (args) self; } else { });
              };
            in
            if isArgs then
              module: origMkFlake (cleanArgs argsOrModule) (wrapFlakePartsModule module)
            else
              origMkFlake { inputs = augmentedInputs; } (wrapFlakePartsModule argsOrModule);
          evalFlakeModule =
            argsOrModule:
            let
              isArgs =
                builtins.isAttrs argsOrModule
                && (
                  argsOrModule ? inputs
                  || argsOrModule ? self
                  || argsOrModule ? specialArgs
                  || argsOrModule ? moduleLocation
                );
              origEval = baseInputs.flake-parts.lib.evalFlakeModule;
              cleanArgs = args: (if builtins.isAttrs args then args else { }) // {
                inputs = augmentedInputs // (if builtins.isAttrs args && args ? self then { inherit (args) self; } else { });
              };
            in
            if isArgs then
              module: origEval (cleanArgs argsOrModule) (wrapFlakePartsModule module)
            else
              origEval { inputs = augmentedInputs; } (wrapFlakePartsModule argsOrModule);
        };
      };
    }
    // lib.optionalAttrs (baseInputs ? nixpkgs) {
      nixpkgs = baseInputs.nixpkgs // {
        lib = baseInputs.nixpkgs.lib // {
          evalModules =
            args: baseInputs.nixpkgs.lib.evalModules (wrapEvalModulesArgs args);
        };
      };
    };

  reconstructedAnalysis =
    if rawFlake != null && rawFlake ? outputs then
      let
        outs = rawFlake.outputs augmentedInputs;
      in
      if outs ? den-lsp-analysis then
        outs.den-lsp-analysis
      else if outs ? flake && outs.flake ? den-lsp-analysis then
        outs.flake.den-lsp-analysis
      else
        null
    else
      null;

  fallbackAnalysis =
    if hasDenInput && (!hasFlakePartsInput) then
      let
        discoveredModules = getModulesFromDir targetDir;
      in
      if discoveredModules == [ ] then
        unsupportedError "Target flake fallback module discovery found no modules in modules/ or trigger.nix."
      else
        let
          eval =
            baseInputs.nixpkgs.lib.evalModules {
              modules = [
                baseInputs.den.flakeModules.default
                noflakeModule
              ] ++ discoveredModules;
              specialArgs = { inputs = baseInputs; };
            };
        in
        core.analysisFor { inherit (eval.config) den; }
    else
      null;

  finalAnalysis =
    if reconstructedAnalysis != null then
      reconstructedAnalysis
    else if hasFlakePartsInput then
      unsupportedError "Target flake declares a flake-parts input but exposes an unrecognized outputs shape."
    else if fallbackAnalysis != null then
      fallbackAnalysis
    else
      unsupportedError "Target flake does not expose a supported Den configuration.";
in
if isAlreadyInstrumented then
  committedResult
else if !hasDenInput then
  unsupportedError "Target flake does not use Den (missing 'den' input or configuration)."
else
  finalAnalysis
