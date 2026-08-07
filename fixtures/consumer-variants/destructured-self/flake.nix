{
  description = "Consumer flake fixture destructuring self in outputs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    den.url = "github:denful/den";
  };

  outputs =
    { self, nixpkgs, flake-parts, den }:
    flake-parts.lib.mkFlake { inputs = { inherit self nixpkgs flake-parts den; }; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        den.flakeModules.default
        ./modules/den.nix
      ];
    };
}
