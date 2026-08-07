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

  baseInputs =
    { self = { outPath = targetDir; } // (if builtins.isAttrs targetFlake then targetFlake else { }); }
    // (if targetFlake ? inputs then targetFlake.inputs else { })
    // inputOverrides;

  hasFlakePartsInput = baseInputs ? flake-parts;

  isDenFlavored =
    args:
    let
      modules = if builtins.isAttrs args && args ? modules then args.modules else [ ];
      denModules =
        if baseInputs ? den then
          (lib.attrValues (baseInputs.den.flakeModules or { }))
          ++ (lib.attrValues (baseInputs.den.nixosModules or { }))
        else
          [ ];
      hasDenModule = lib.any (dm:
        lib.elem dm modules
        || lib.any (m: builtins.isAttrs m && m ? imports && lib.elem dm m.imports) modules
      ) denModules;
    in
    hasDenModule;

  wrapEvalModulesArgs =
    args:
    if isDenFlavored args then
      args // { modules = (args.modules or [ ]) ++ [ noflakeModule ]; }
    else
      args;

  wrappedMkFlake =
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
      mergedInputs = mergeInputsFor (if isArgs then argsOrModule else { });
      cleanArgs = args: (if builtins.isAttrs args then args else { }) // {
        inputs = mergedInputs // (if builtins.isAttrs args && args ? self then { inherit (args) self; } else { });
      };
    in
    if isArgs then
      module: origMkFlake (cleanArgs argsOrModule) (wrapFlakePartsModule module)
    else
      origMkFlake { inputs = mergedInputs; } (wrapFlakePartsModule argsOrModule);

  wrappedEvalFlakeModule =
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
      mergedInputs = mergeInputsFor (if isArgs then argsOrModule else { });
      cleanArgs = args: (if builtins.isAttrs args then args else { }) // {
        inputs = mergedInputs // (if builtins.isAttrs args && args ? self then { inherit (args) self; } else { });
      };
    in
    if isArgs then
      module: origEval (cleanArgs argsOrModule) (wrapFlakePartsModule module)
    else
      origEval { inputs = mergedInputs; } (wrapFlakePartsModule argsOrModule);

  mergeInputsFor =
    argsOrModule:
    let
      callerInputs =
        if builtins.isAttrs argsOrModule && argsOrModule ? inputs then
          argsOrModule.inputs
        else if targetFlake ? inputs then
          targetFlake.inputs
        else
          { };
      mergedBase = callerInputs // inputOverrides;
      mergedWithFlakeParts =
        mergedBase
        // lib.optionalAttrs (mergedBase ? flake-parts || baseInputs ? flake-parts) {
          flake-parts =
            let
              fp = if mergedBase ? flake-parts then mergedBase.flake-parts else baseInputs.flake-parts;
            in
            fp // {
              lib = fp.lib // {
                mkFlake = wrappedMkFlake;
                evalFlakeModule = wrappedEvalFlakeModule;
              };
            };
        };
      mergedFinal =
        mergedWithFlakeParts
        // lib.optionalAttrs (mergedBase ? nixpkgs || baseInputs ? nixpkgs) {
          nixpkgs =
            let
              np = if mergedBase ? nixpkgs then mergedBase.nixpkgs else baseInputs.nixpkgs;
            in
            np // {
              lib = np.lib // {
                evalModules = args: np.lib.evalModules (wrapEvalModulesArgs args);
              };
            };
        };
    in
    mergedFinal;

  augmentedInputs = mergeInputsFor { inputs = baseInputs; };

  rawFlakeInputs =
    if targetFlake ? inputs then builtins.attrNames targetFlake.inputs else [ ];

  outputsInputs =
    lib.filterAttrs
      (n: _: n == "self" || lib.elem n rawFlakeInputs)
      augmentedInputs;

  reconstructedAnalysis =
    if rawFlake != null && rawFlake ? outputs then
      let
        outs = rawFlake.outputs outputsInputs;
      in
      if outs ? den-lsp-analysis then
        outs.den-lsp-analysis
      else if outs ? flake && outs.flake ? den-lsp-analysis then
        outs.flake.den-lsp-analysis
      else
        null
    else
      null;

  finalAnalysis =
    if reconstructedAnalysis != null then
      reconstructedAnalysis
    else if hasFlakePartsInput then
      unsupportedError "Target flake declares a flake-parts input but exposes an unrecognized outputs shape."
    else
      unsupportedError "Target flake does not expose a supported Den configuration.";

  shouldReuseCommitted =
    isAlreadyInstrumented && (inputOverrides == { });
in
if shouldReuseCommitted then
  committedResult
else if !hasDenInput && !isAlreadyInstrumented then
  unsupportedError "Target flake does not use Den (missing 'den' input or configuration)."
else
  finalAnalysis
