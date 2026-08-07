# den-lsp

Semantic feedback for [Den](https://github.com/denful/den) consumer flakes:
one analysis engine over the evaluated aspect graph, surfaced as an LSP
server (diagnostics, completions, hover) and a headless `nix flake check`
gate. Built so a passing build closure stops being the only "done" signal
coding agents optimize for.

## How it works

Den keeps the capture layer (`den.lib.analysis.capture` — emissions,
registries, entities, declaration positions); den-lsp consumes that IR,
following the den-diagram companion pattern:

- **Engine** (`nix/engine/`) — pure Nix rules over the IR. Every finding is
  fix-shaped: it names the aspects/keys involved and states the concrete
  remedy, citing the Den doc section that establishes the rule.
- **Gate** (`nix/check.nix`) — a flake-parts module for consumer flakes.
  Gating findings fail `checks.<system>.den-lsp`; advisory findings print
  but never block. No per-finding suppression exists anywhere: a wrong
  gating finding is a rule bug — fix or demote the rule.
- **Server** (`server/`) — Rust/tower-lsp host. Re-evaluates
  `path:.#checks.<system>.den-lsp.passthru.analysis` on save (debounced),
  serves last-known-good completions/hover while buffers are broken, and
  rebases engine paths onto the workspace.

## Quickstart (Zero-Touch)

Run `den-lsp-check` directly on any Den consumer repository without adding a flake input or importing a module:

```bash
# Try before adopting (remote):
nix run github:nehpz/den-lsp#den-lsp-check -- --json /path/to/your/den/repo

# Local checkout form:
nix run .#den-lsp-check -- --json <workspace>
```

No `den-lsp` flake input or `flake-parts` module import is required for zero-touch evaluation.

## Consumer Wiring (CI Gate Upgrade)

To integrate `den-lsp` permanently into your flake as an opt-in CI gate (`nix flake check`), add the flake input and import the module:

```nix
{
  inputs.den-lsp.url = "github:nehpz/den-lsp";
  # inside your flake-parts mkFlake:
  imports = [
    inputs.den.flakeModules.default
    inputs.den-lsp.flakeModules.default
  ];
}
```

Then:

- `nix flake check` — the CI gate (fails on gating findings)
- `nix run .#den-lsp-check` — human-readable check report on stdout
- `nix run .#den-lsp-check -- --json` — JSON report or error envelope
- `nix eval --json path:.#checks.<system>.den-lsp.passthru.analysis` — the raw analysis document (`version = 1`, schema in `nix/engine/document.nix`)

## Agent Contract

`den-lsp-check` provides a stable CLI interface and exit taxonomy for automated coding agents and tool integrations. JSON output conforms to findings document v1 (`nix/engine/document.nix`).

### CLI Flags

| Flag | Description | Default |
|---|---|---|
| `--json` | Emit structured JSON findings document v1 or error envelope verbatim on stdout | disabled (human text) |
| `--draft` | Non-blocking evaluation mode; gating findings report but exit `0` | disabled |
| `--gate` | Blocking gate mode; gating findings trigger exit `1` | enabled |
| `--timeout <seconds>` | Evaluation deadline in seconds | `120` |

### Exit Classes

| Exit Code | Class | Description |
|---|---|---|
| `0` | Pass | Clean evaluation, advisory-only findings, or gating findings under `--draft` |
| `1` | Gating Block | Gating findings detected under `--gate` (default mode) |
| `2` | Evaluation / Target Failure | Evaluation failure (`kind: eval-error`) or unsupported target (`kind: unsupported`), disambiguated by `error.kind` |
| `3` | Timeout | Evaluation timed out before completion (`kind: timeout`) |
| `64` | Usage Error | Invalid CLI flag or options (nothing printed to stdout) |

### Error Envelope

When evaluation fails before a findings document can be produced (exit code 2 or 3 in `--json` mode), `den-lsp-check` outputs a structured error envelope on stdout:

```json
{
  "version": 1,
  "error": {
    "kind": "unsupported",
    "message": "workspace is missing flake.nix"
  }
}
```

Valid `kind` values: `"unsupported"` (not a valid Den flake workspace), `"eval-error"` (Nix evaluation error), `"timeout"` (evaluation exceeded timeout). Findings documents (exit 0/1) follow the schema in `nix/engine/document.nix` (`{ version: 1, findings: [...], summary: {...}, inventory: {...} }`).
## Rules

| Rule | Severity | Detects |
|---|---|---|
| `unregistered-class-key` | gating | aspect keys silently falling through to class emission |
| `class-quirk-collision` | gating | keys registered as both class and quirk |
| `duplication` | gating | identical multi-attribute blocks across aspects (atomic single assignments never fire) |
| `battery-replication` | gating | hand-rolled content a registered battery provides |
| `granularity` | advisory | entity config shattered into single-option aspects |
| `repetition` | advisory | the same include attached to every host individually |

## Development

- `nix flake check` — engine unit tests (synthetic IR, hermetic)
- `bash fixtures/run-checks.bash` — E2E matrix against real consumer
  fixtures (base / gating-dup / advisory-only / broken)
- `nix develop -c cargo test` in `server/` — server unit tests
