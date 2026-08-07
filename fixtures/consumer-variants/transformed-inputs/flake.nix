{
  description = "Consumer flake that transforms inputs passed to mkFlake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    den.url = "github:denful/den";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake {
      inputs = inputs // {
        customInput = { value = "transformed"; };
      };
    } {
      systems = [ "x86_64-linux" ];
      imports = [
        inputs.den.flakeModules.default
        ./modules/den.nix
      ];
    };
}
