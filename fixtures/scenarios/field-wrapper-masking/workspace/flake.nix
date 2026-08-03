{
  description = "field-wrapper-masking workspace fixture for den-lsp tests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    den.url = "github:denful/den";
    den-lsp.url = "github:nehpz/den-lsp";
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
        inputs.den-lsp.flakeModules.default
        ./modules/den.nix
        ./modules/igloo.nix
        ./trigger.nix
      ];
    };
}
