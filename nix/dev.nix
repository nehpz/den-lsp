# den-lsp's own development wiring: engine unit tests as eval-time checks,
# the Rust server package, and the dev shell.
{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      engine = inputs.self.lib;
      engineTests = import ../tests { inherit lib engine; };
      checkCond =
        name: cond:
        pkgs.runCommandLocal name { } (
          if cond then
            "touch $out"
          else
            ''
              echo "engine test failed: ${name}" >&2
              exit 1
            ''
        );
    in
    {
      checks = lib.mapAttrs' (
        name: cond: lib.nameValuePair "engine-${name}" (checkCond name cond)
      ) engineTests;

      packages.den-lsp-server = pkgs.rustPlatform.buildRustPackage {
        pname = "den-lsp-server";
        version = "0.1.0";
        src = ../server;
        cargoLock.lockFile = ../server/Cargo.lock;
        meta.mainProgram = "den-lsp-server";
      };

      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.cargo
          pkgs.rustc
          pkgs.rust-analyzer
          pkgs.rustfmt
          pkgs.clippy
          pkgs.nixfmt-rfc-style
        ];
      };
    };
}
