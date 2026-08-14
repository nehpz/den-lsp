{
  description = "Unwired inline-imports fixture: Den aspects declared in flake.nix outputs, not modules/*.nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    den.url = "github:denful/den";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [ inputs.den.flakeModules.default ];

      den.hosts.x86_64-linux.igloo.users.tux = { };

      den.aspects.igloo = {
        nixos =
          { pkgs, ... }:
          {
            environment.systemPackages = [ pkgs.hello ];
          };
      };
    };
}
