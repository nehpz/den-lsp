{
  description = "Consumer flake passing specialArgs to mkFlake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    den.url = "github:denful/den";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; specialArgs = { customVal = "ok"; }; } (
      { customVal, ... }:
      {
        imports = [
          inputs.den.flakeModules.default
          ./modules/den.nix
        ];
      }
    );
}
