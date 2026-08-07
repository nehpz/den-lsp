{
  description = "Consumer flake using flake-parts module args like withSystem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    den.url = "github:denful/den";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      { withSystem, config, lib, ... }:
      {
        imports = [
          inputs.den.flakeModules.default
          ./modules/den.nix
        ];
      }
    );
}
