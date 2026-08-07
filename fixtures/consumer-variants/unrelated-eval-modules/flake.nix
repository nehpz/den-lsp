{
  description = "Target flake with an unrelated evalModules call alongside a Den evalModules call";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    den.url = "github:denful/den";
  };

  outputs =
    inputs:
    let
      unrelated = inputs.nixpkgs.lib.evalModules {
        modules = [
          ({ lib, ... }: {
            options.unrelatedOpt = lib.mkOption {
              type = lib.types.str;
              default = "ok";
            };
          })
        ];
      };
      denEval = inputs.nixpkgs.lib.evalModules {
        modules = [
          inputs.den.flakeModules.default
          ./modules/den.nix
        ];
        specialArgs = { inherit inputs; };
      };
    in
    denEval.config.flake // { inherit unrelated; };
}
