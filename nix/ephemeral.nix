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
      m = builtins.match ".*[/:]v?([0-9]+\\.[0-9]+\\.[0-9]+).*" url;
    in
    if m == null then null else builtins.head m;

  # Canonical hercules-ci path, or a repo-name segment (forks named
  # flake-parts). No bare substring — "my-flake-parts-lib" must not match.
  isFlakePartsUrl =
    url:
    builtins.match ".*hercules-ci/flake-parts.*" url != null
    || builtins.match ".*[/:]flake-parts([/#?].*)?" url != null;

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
          # mkDefault (mirroring nix/inject-analysis.nix): a wired consumer
          # already defines this attribute via its committed module, and the
          # shim's definition must yield to it instead of conflicting when
          # someone points the override at a wired repo.
          config.flake.den-lsp-analysis = lib.mkDefault (
            # Order matters: a target with no den input also lacks the den
            # option, so test the input first or that case would be
            # mislabeled as unreachable-config (the eval-only callers — the
            # LSP server — rely on these named reasons).
            if !(inputs ? den) then
              throw messages.noDen
            else if !(options ? den) then
              throw messages.unreachable
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
              }
          );
        };

      wrapModule = module: {
        imports = [
          module
          analysisModule
        ];
      };
    in
    # Forward exactly the real flake-parts OUTPUTS and override only lib: a
    # consumer (or a transitive input whose flake-parts follows the root's)
    # may reference attributes beyond lib/flakeModules/templates, and
    # dropping them would surface a raw attribute-missing trace. Base on
    # `real.outputs` — not the raw flake value — so identity keys (outPath,
    # sourceInfo, narHash, ...) are not re-emitted as outputs; Nix's
    # call-flake wrapper supplies the shim's own identity keys.
    (real.outputs or real)
    // {
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
