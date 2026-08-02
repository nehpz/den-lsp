{
  description = "advisory-only variant fixture for den-lsp tests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    den.url = "github:denful/den";
    den-lsp.url = "github:denful/den-lsp";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      imports = [
        inputs.den.flakeModules.default
        inputs.den-lsp.flakeModules.default
        ../../consumer/modules/den.nix
        ../../consumer/modules/igloo.nix
        ./trigger.nix
      ];
    };
}
