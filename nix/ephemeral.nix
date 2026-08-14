# Ephemeral analysis injection for unwired Den consumers (KTD1a).
#
# Two call patterns:
#   { inputs }  — shim flake outputs. nix/flake.nix imports this and is
#                 used as `--override-input flake-parts path:./nix`.
#                 lib.mkFlake / lib.evalFlakeModule append the analysis
#                 module so the consumer exposes `den-lsp-analysis`.
#   { target }  — preflight. Inspects the consumer's flake.nix inputs and
#                 throws a named R4 error for unanalyzable targets, or
#                 returns true if the override-input path may proceed.
#
# den v0.18.0 sourceInfo.lastModified (github:denful/den/v0.18.0).
{
  inputs ? null,
  target ? null,
}:
let
  denFloor = "0.18.0";
  # flake.lock of this repo, nodes.den.locked.lastModified for v0.18.0.
  denFloorLastModified = 1781621963;

  messages = {
    noFlakeParts = "den-lsp: no flake-parts input (this wrapper analyzes flake-parts Den consumers)";
    renamedFlakeParts = "den-lsp: flake-parts is present under a nonstandard input name (the input must be named 'flake-parts')";
    noDen = "den-lsp: no den input (this target is not a Den flake)";
    versionFloor = "den-lsp: den is below the v0.18.0 version floor";
    unreachable = "den-lsp: den configuration is unreachable (den module not imported)";
  };

  versionFromUrl =
    url:
    let
      m = builtins.match ".*[/:]v([0-9]+\\.[0-9]+\\.[0-9]+).*" url;
    in
    if m == null then null else builtins.head m;

  isFlakePartsUrl =
    url:
    builtins.match ".*hercules-ci/flake-parts.*" url != null
    || builtins.match ".*flake-parts.*" url != null;

  preflight =
    targetPath:
    let
      flakeFile = targetPath + "/flake.nix";
      raw =
        if builtins.pathExists flakeFile then import flakeFile else throw "den-lsp: no flake.nix at target";
      inps = raw.inputs or { };
      names = builtins.attrNames inps;
      urlOf = n: inps.${n}.url or "";
      renamedNames = builtins.filter (n: n != "flake-parts" && isFlakePartsUrl (urlOf n)) names;
      denVer = versionFromUrl (urlOf "den");
    in
    if !(inps ? flake-parts) && renamedNames != [ ] then
      throw messages.renamedFlakeParts
    else if !(inps ? flake-parts) then
      throw messages.noFlakeParts
    else if !(inps ? den) then
      throw messages.noDen
    else if denVer != null && builtins.compareVersions denVer denFloor < 0 then
      throw messages.versionFloor
    else
      true;

  denTooOld =
    den:
    let
      lm = den.sourceInfo.lastModified or 0;
    in
    lm > 0 && lm < denFloorLastModified;

  shim =
    flakeInputs:
    let
      real = flakeInputs.flake-parts;
      nixpkgsLib =
        if flakeInputs ? nixpkgs-lib then
          flakeInputs.nixpkgs-lib.lib
        else
          flakeInputs.flake-parts.inputs.nixpkgs-lib.lib;
      engine = import ./engine { lib = nixpkgsLib; };

      analysisModule =
        {
          config,
          lib,
          options,
          inputs,
          ...
        }:
        {
          # Do not assign config.den.* — that requires the den option to exist
          # and would produce a raw "option `den' does not exist" trace on
          # unreachable targets. Capture is invoked directly against config.den.
          config.flake.den-lsp-analysis =
            if !(options ? den) then
              throw messages.unreachable
            else if !(inputs ? den) then
              throw messages.noDen
            else if denTooOld inputs.den then
              throw messages.versionFloor
            else
              engine.analyze {
                ir =
                  (import ./den-analysis.nix {
                    inherit (config) den;
                    inherit lib;
                  }).capture
                    {
                      classes = builtins.attrNames (config.den.classes or { });
                    };
              };
        };

      wrapModule = module: {
        imports = [
          module
          analysisModule
        ];
      };
    in
    {
      inherit (real) flakeModules templates;
      lib = real.lib // {
        mkFlake = args: module: real.lib.mkFlake args (wrapModule module);
        evalFlakeModule = args: module: real.lib.evalFlakeModule args (wrapModule module);
      };
    };
in
if target != null then
  preflight target
else if inputs != null then
  shim inputs
else
  throw "den-lsp: ephemeral.nix requires inputs (shim) or target (preflight)"
