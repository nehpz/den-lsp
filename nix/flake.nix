# KTD1(a) shim flake: used as `--override-input flake-parts path:./nix`.
# Source root is nix/, so engine/ and den-analysis.nix are in-tree and
# do not need a parent-path den-lsp input.
{
  description = "flake-parts shim that injects den-lsp analysis (KTD1a)";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
  };

  # Forward the shim's full result (every real flake-parts output with only
  # lib overridden) — re-narrowing here would defeat ephemeral.nix's
  # pass-through for consumers that reference other flake-parts attributes.
  outputs = inputs: import ./ephemeral.nix { inherit inputs; };
}
