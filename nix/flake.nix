# KTD1(a) shim flake: used as `--override-input flake-parts path:./nix`.
# Source root is nix/, so engine/ and den-analysis.nix are in-tree and
# do not need a parent-path den-lsp input.
{
  description = "flake-parts shim that injects den-lsp analysis (KTD1a)";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
  };

  outputs =
    inputs:
    let
      inherit (import ./ephemeral.nix { inherit inputs; }) lib flakeModules templates;
    in
    {
      inherit lib flakeModules templates;
    };
}
