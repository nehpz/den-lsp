{
  description = "den-lsp — semantic feedback for Den consumer flakes: analysis engine, flake check gate, and LSP server.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0.1";
    nix-eval-jobs.url = "https://flakehub.com/f/DeterminateSystems/nix-eval-jobs/3.21.9";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
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

      imports = [ ./nix/dev.nix ];

      flake = {
        # Pure analysis engine — usable from any eval that holds a den config.
        lib = import ./nix/engine { lib = inputs.nixpkgs.lib; };

        # Consumer-facing modules. Both self-inject the vendored analysis
        # layer (works against stock den >= v0.18.0, no den changes needed):
        #   default — flake-parts consumers (perSystem)
        #   noflake — plain evalModules consumers (den flake output options)
        flakeModules = {
          default = import ./nix/check.nix { den-lsp = inputs.self; };
          den-lsp = inputs.self.flakeModules.default;
          noflake = import ./nix/check-noflake.nix { den-lsp = inputs.self; };
        };
      };
    };
}
