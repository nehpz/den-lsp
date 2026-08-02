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

## Consumer wiring

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

- `nix flake check` — the gate (fails on gating findings)
- `nix run .#den-lsp-check` — the same report, fix-shaped text
- `nix eval --json path:.#checks.<system>.den-lsp.passthru.analysis` — the
  raw analysis document (stable interface, `version = 1`)

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
