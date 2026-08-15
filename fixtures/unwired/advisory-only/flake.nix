{
  description = "Unwired advisory-only variant fixture for den-lsp zero-touch tests";

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

      imports = [
        inputs.den.flakeModules.default
        ./modules/den.nix
        ./modules/igloo.nix
        ./trigger.nix
      ];
    };
}
