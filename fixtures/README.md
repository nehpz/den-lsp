# Consumer Flake Fixture Family (`fixtures/`)

This directory contains consumer flake fixtures for end-to-end integration testing of `den-lsp`.

## Directory Layout

- `consumer/`: Base minimal Den consumer flake using `flake-parts` (`den.flakeModules.default` + `den-lsp.flakeModules.default`). Defines host `igloo` (`x86_64-linux`) and user `tux` with a clean aspect. Produces zero gating findings.
- `consumer-variants/`: Variant consumer flakes importing base modules plus a specific trigger module:
  - `gating-dup/`: AE1 trigger: two aspects (`web` and `db`) emitting identical multi-attribute `nixos` configuration blocks (`services.openssh`), triggering a gating duplication finding.
  - `advisory-only/`: AE6 trigger: multiple single-option aspects with no declared provides, demonstrating that advisory findings print without failing the gate (exit 0).
  - `broken/`: R13 trigger: module with a deliberate evaluation error (`throw`), asserting root error reporting with file location details (`trigger.nix`).
- `run-checks.bash`: E2E runner script that evaluates and asserts behavior across the base fixture and all variant flakes.

## Usage

Run the fixture test suite:

```bash
./fixtures/run-checks.bash
```

The script automatically detects the host system via `builtins.currentSystem` and overrides `den` and `den-lsp` inputs with local repository paths (`--override-input den ... --override-input den-lsp ...`).
