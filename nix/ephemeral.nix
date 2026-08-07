# Ephemeral injection wrapper for den-lsp (R1, R2, R3).
#
# Analyzes any stock Den consumer flake (den >= 0.18.0) at invocation time
# without requiring a committed den-lsp flake input or repo configuration.
#
# Evaluation flow (plan KTD2):
#   1. Already-instrumented target: if target exposes `den-lsp-analysis` output,
#      use it directly (R2: zero double injection, identical results).
#   2. Den flake without den-lsp: reconstruct evaluation with `nix/inject-analysis.nix`
#      injected into the target's module graph (covers flake-parts and evalModules).
#   3. Non-Den target: return an explicit versioned error envelope `{ version, error = { kind = "unsupported", message } }`
#      distinct from a Den evaluation failure (R3).
#
# Target workspace paths handle dirty working trees via `path:` refs.

args:
let
  workspace = if builtins.isAttrs args && (args ? workspace || args ? den-lsp) then args.workspace else args;
  den-lsp-default = if builtins.pathExists (./. + "/flake.nix") then ./. else ../.;
  den-lsp-arg = if builtins.isAttrs args && args ? den-lsp then args.den-lsp else den-lsp-default;

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

  hasDenInput = (targetFlake ? inputs) && (targetFlake.inputs ? den);

  targetDir = if builtins.isPath workspace then workspace else targetFlake.outPath;

  getModulesFromDir =
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
    moduleFiles ++ triggerMod;

  rawFlake =
    if builtins.pathExists (targetDir + "/flake.nix") then import (targetDir + "/flake.nix") else null;

  wrapFlakePartsModule =
    module:
    let
      modObj = if builtins.isFunction module then module else (_: module);
    in
    arg:
    let
      res = modObj arg;
    in
    res
    // {
      imports = (res.imports or [ ]) ++ [
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

  augmentedInputs =
    if targetFlake ? inputs then
      targetFlake.inputs
      // lib.optionalAttrs (targetFlake.inputs ? flake-parts) {
        flake-parts = targetFlake.inputs.flake-parts // {
          lib = targetFlake.inputs.flake-parts.lib // {
            mkFlake =
              args: module:
              targetFlake.inputs.flake-parts.lib.mkFlake args (wrapFlakePartsModule module);
            evalFlakeModule =
              args: module:
              targetFlake.inputs.flake-parts.lib.evalFlakeModule args (wrapFlakePartsModule module);
          };
        };
      }
      // lib.optionalAttrs (targetFlake.inputs ? nixpkgs) {
        nixpkgs = targetFlake.inputs.nixpkgs // {
          lib = targetFlake.inputs.nixpkgs.lib // {
            evalModules =
              args: targetFlake.inputs.nixpkgs.lib.evalModules (wrapEvalModulesArgs args);
          };
        };
      }
    else
      { };

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
    if hasDenInput && (targetFlake.inputs ? flake-parts) then
      let
        eval =
          targetFlake.inputs.flake-parts.lib.evalFlakeModule
            { inputs = targetFlake.inputs; }
            {
              systems = [
                "x86_64-linux"
                "aarch64-linux"
                "aarch64-darwin"
              ];
              imports = [
                targetFlake.inputs.den.flakeModules.default
                injectModule
              ] ++ getModulesFromDir targetDir;
            };
      in
      core.analysisFor { inherit (eval.config) den; }
    else
      null;

  finalAnalysis =
    if reconstructedAnalysis != null then
      reconstructedAnalysis
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
