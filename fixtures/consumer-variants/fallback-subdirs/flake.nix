{
  description = "Consumer flake with modules in subdirectories for fallback discovery test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    den.url = "github:denful/den";
  };

  outputs =
    inputs:
    (inputs.nixpkgs.lib.evalModules {
      modules = [
        inputs.den.flakeModules.default
        ./modules/sub/host.nix
      ];
      specialArgs = { inherit inputs; };
    }).config.flake;
}
