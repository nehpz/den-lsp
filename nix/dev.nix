# den-lsp's own development wiring: engine unit tests as eval-time checks,
# the Rust server package, and the dev shell.
{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, ... }:
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
      apps.evidence-runner = {
        type = "app";
        program = "${
          pkgs.writeShellApplication {
            name = "evidence-runner";
            runtimeInputs = [
              pkgs.bash
              pkgs.jq
              pkgs.git
              pkgs.coreutils
              pkgs.nix
            ];
            text = ''
              # writeShellApplication prepends runtimeInputs to the caller PATH (it does
              # not replace it); run.bash additionally appends common host bin dirs so
              # agent CLIs stay reachable under stripped environments.
              exec ${../tools/evidence-runner}/run.bash "$@"
            '';
          }
        }/bin/evidence-runner";
      };

      # Standalone field CLI (U2+U3): nix run .#den-lsp-check -- <path>
      apps.den-lsp-check = {
        type = "app";
        program = "${
          import ./check-cli.nix {
            inherit pkgs lib;
            den-lsp-src = ../.;
          }
        }/bin/den-lsp-check";
      };

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
          pkgs.nixfmt
          pkgs.fh
          pkgs.nix-eval-jobs
        ];
      };
    };
}
