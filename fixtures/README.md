# Consumer Flake Fixture Family (`fixtures/`)

This directory contains consumer flake fixtures for end-to-end integration testing of `den-lsp`.

## Directory Layout

- `consumer/`: Base minimal Den consumer flake using `flake-parts` (`den.flakeModules.default` + `den-lsp.flakeModules.default`). Defines host `igloo` (`x86_64-linux`) and user `tux` with a clean aspect. Produces zero gating findings.
- `scenarios/base-*/workspace/`: Variant consumer flakes used by the E2E matrix (same trees the hermetic scenario tier evaluates):
  - `base-gating-dup/workspace/`: AE1 trigger: two aspects (`web` and `db`) emitting identical multi-attribute `nixos` configuration blocks (`services.openssh`), triggering a gating duplication finding.
  - `base-advisory-only/workspace/`: AE6 trigger: multiple single-option aspects with no declared provides, demonstrating that advisory findings print without failing the gate (exit 0).
  - `base-broken/workspace/`: R13 trigger: module with a deliberate evaluation error (`throw`), asserting root error reporting with file location details (`trigger.nix`).
- `unwired/`: Zero-touch fixtures with no `den-lsp` input (flake-parts shim injection). Clean base; `gating-dup`, `advisory-only`, and `broken` variants of the same triggers as `scenarios/base-*/workspace`; plus negatives (`no-den`, `no-flake-parts`, `renamed-flake-parts`, `old-den`, `unreachable`, `inline-imports`).
- `run-checks.bash`: E2E runner script that evaluates and asserts behavior across the base fixture, wired scenario workspaces, and unwired zero-touch fixtures.

## Usage

Run the fixture test suite:

```bash
./fixtures/run-checks.bash
```

The script automatically detects the host system via `builtins.currentSystem` and overrides `den` and `den-lsp` inputs with local repository paths (`--override-input den ... --override-input den-lsp ...`).