# den-lsp

Semantic feedback for [Den](https://github.com/denful/den) consumer flakes:
one analysis engine over the evaluated aspect graph, surfaced as an LSP
server (diagnostics, completions, hover), an agent-consumable CLI, and a
headless `nix flake check` gate. Built so a passing build closure stops
being the only "done" signal coding agents optimize for.

Zero-touch: the LSP server and the CLI analyze any stock Den consumer flake
(den >= v0.18.0) with **no den-lsp flake input and no committed module** —
the analysis layer is injected ephemerally at invocation time.

## Editor setup

Install the server and point your editor's LSP client at it:

```sh
nix profile install github:nehpz/den-lsp#den-lsp-server
```

Configure your editor to run `den-lsp-server` for Nix files in a Den
workspace. On save the server re-evaluates the workspace (debounced, 60s
deadline) and publishes findings as diagnostics — gating findings as
errors, advisory findings as warnings. Wired repos (see [CI gate](#ci-gate))
resolve through their committed analysis output; unwired repos fall back to
ephemeral injection automatically.

## Agent / CLI usage

Analyze any Den consumer repo, no wiring required:

```sh
nix run github:nehpz/den-lsp#den-lsp-check -- <path>          # fix-shaped text report
nix run github:nehpz/den-lsp#den-lsp-check -- --json <path>   # findings document v1 on stdout
```

Flags:

- `--json` — write the version-1 findings document to stdout, verbatim;
  the text report and all progress go to stderr. On failure or timeout
  stdout stays empty — branch on the exit code before parsing.
- `--draft` — report all findings, exit 0 even with gating findings
  (mid-edit checkpoint).
- `--gate` — fail on gating findings (pre-completion checkpoint; default).
- `--deadline SECONDS` — evaluation time bound (default 60).

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Analysis completed, nothing blocking (clean, advisory-only, or `--draft`) |
| 1 | Gating findings under `--gate` |
| 2 | Analysis failure (eval error, not a Den flake, den < v0.18.0). Exit-2 stderr carries stable `den-lsp:`-prefixed reason lines that scripts may match. |
| 3 | Evaluation timed out |
| 64 | Usage error |

Strictness and output are invocation flags only — there is no repo config
and no per-finding suppression: a wrong gating finding is a rule bug — fix
or demote the rule.

## How it works

Den keeps the capture layer (emissions, registries, entities, declaration
positions); den-lsp consumes that IR, following the den-diagram companion
pattern:

- **Engine** (`nix/engine/`) — pure Nix rules over the IR. Every finding is
  fix-shaped: it names the aspects/keys involved and states the concrete
  remedy, citing the Den doc section that establishes the rule.
- **Ephemeral injection** (`nix/ephemeral.nix`) — a flake-parts shim used as
  `--override-input flake-parts`, wrapping `mkFlake` so the consumer's own
  flake exposes `den-lsp-analysis` without any committed wiring.
- **Server** (`server/`) — Rust/tower-lsp host: debounced re-evaluation,
  superseded-eval cancellation, last-known-good completions/hover while
  buffers are broken.
- **Gate** (`nix/check.nix`) — the committed CI option below.

## CI gate

To gate a repo's CI on gating findings, commit the flake-parts module:

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

- `nix flake check` — fails on gating findings; advisory findings print but
  never block
- `nix run .#den-lsp-check` — the same report, same exit semantics
- `nix eval --json path:.#den-lsp-analysis` — the raw analysis document
  (stable interface, `version = 1`)

Plain `evalModules` consumers use `flakeModules.noflake` instead.

## Rules

| Rule | Severity | Detects |
|---|---|---|
| `unregistered-class-key` | gating | aspect keys silently falling through to class emission |
| `class-quirk-collision` | gating | keys registered as both class and quirk |
| `duplication` | gating | identical multi-attribute blocks across aspects (atomic single assignments never fire) |
| `battery-replication` | gating | hand-rolled content a registered battery provides |
| `granularity` | advisory | entity config shattered into single-option aspects |
| `repetition` | advisory | the same include attached to every host individually |

## Field failures

Every real-world breakage — crash, wrong finding, hang, timeout — becomes a
fixture in the eval corpus: see
[`docs/field-failure-intake.md`](docs/field-failure-intake.md).

## Development

- `nix flake check` — engine unit tests (synthetic IR, hermetic)
- `bash fixtures/run-checks.bash` — E2E matrix against real consumer
  fixtures (wired and unwired: base / gating-dup / advisory-only / broken,
  CLI contract rows, R4 error rows)
- `nix develop -c cargo test` in `server/` — server unit tests