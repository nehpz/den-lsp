{
  description = "noflake variant fixture for den-lsp tests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    den.url = "github:denful/den";
  };

  outputs =
    inputs:
    (inputs.nixpkgs.lib.evalModules {
      modules = [
        inputs.den.flakeModules.default
        ./modules/den.nix
        ./modules/igloo.nix
      ];
      specialArgs = { inherit inputs; };
    }).config.flake;
}
