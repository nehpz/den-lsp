# Scenario Contract

## Directory Layout
Each benchmark scenario lives in a subdirectory under `fixtures/scenarios/<name>/`:
- `scenario.nix`: Nix expression returning the scenario manifest attrset.
- `workspace/`: Input Nix workspace directory containing defective code/configuration.
- `golden/`: Ground-truth repaired workspace directory (required when `goldenable = true`).
- `expected` specs: Declared inside `scenario.nix` via `expectedFindings` or `expectedError`.

## Kind Taxonomy
- `finding`: Defect is a structural or idiomatic rule violation. Workspace evaluates cleanly; expected findings declared via `expectedFindings`.
- `eval-error`: Defect causes Nix evaluation to fail. Expected error substring declared via `expectedError`.

## Manifest Field Schema
Validation rules enforced by `validateScenario` (`fixtures/scenarios/lib.nix`):

- `version` (Integer, Required): Must equal `1`.
- `name` (String, Required): Non-empty string; matches directory name.
- `kind` (String, Required): Must be `"finding"` or `"eval-error"`.
- `defect` (String, Required): String describing defect category/type.
- `task` (String, Required): String prompt describing repair task.
- `expectedFindings` (List of Attrs, Required if `kind == "finding"`): List of expected finding specifications (`[{ rule; severity; ... }]`).
- `expectedError` (String, Required if `kind == "eval-error"`): Non-empty substring matched against evaluation error output.
- `goldenable` (Boolean, Required): `true` if canonical `golden/` directory exists; `false` otherwise.
- `exclusionReason` (String, Required if `goldenable == false`): Non-empty string explaining exclusion from golden set.
- `clearCut` (Boolean, Required): `true` if defect boundaries and repair criteria are unambiguous.
- `knownMiss` (Boolean, Optional, default `false`): Authoring-time-only designation for known engine/adapter gaps. Never a post-hoc reclassification.
- `heavy` (Boolean, Optional, default `false`): Resource-heavy scenario. Excluded from default evaluation sweeps.
- `complete` (Boolean, Optional, default `false`): If `false` or missing, loader ignores scenario.

## Flag Semantics
- `clearCut`: Marks unambiguous scenarios included in standard benchmark suites.
- `knownMiss`: Authoring-time classification only. Must never be set or changed post-hoc based on test runs.
- `heavy`: Marks scale or long-running tests. Excluded from default checks (`--set clear-cut`).
- `goldenable`: Dictates diff comparison against `golden/`. Requires `exclusionReason` when `false`.

## Authoring Rules for Goldenable Scenarios

The evidence runner judges a repair by structural equality of the normalized evaluated outcome against `golden/` — agent-chosen identifiers (aspect names, quirk keys) are part of that comparison. Two rules keep the judgment measuring repair correctness rather than naming taste (see `docs/solutions/test-failures/golden-mismatch-unpinned-free-variables.md`):

1. **Pin every agent-chosen free variable in `task`.** If the correct repair creates or renames a named entity, the prompt must state the exact name (e.g. "into a shared aspect named 'shared-openssh'"); if the repair shape is open (empty body vs. empty class bucket), the prompt must pin it and bound the edit scope ("change only X, nothing else"). A scenario whose free variables cannot be pinned without trivializing the task is not goldenable — set `goldenable = false` with an `exclusionReason` instead of bending the judgment.
2. **Goldens contain only what the task requests.** No incidental edits (descriptions, formatting, refactors) beyond the pinned repair — any unprompted delta becomes a false-negative `golden_mismatch` for a correct agent.

## Consumption Tiers
- **Hermetic Tier** (`nix flake check "path:fixtures/scenarios" --override-input den-lsp "$PWD"`): Evaluates scenario manifests, verifies workspace evaluation/error status against expected specs, and validates golden structure.
- **Heavy Tier** (manual; excluded from the default gate for cost): `nix build "path:fixtures/scenarios#heavyChecks.<system>.scenario-field-fleet-scale" --override-input den-lsp "$PWD"`. Run before releases or when touching capture/normalization paths - `nix flake check` only warns about the non-standard `heavyChecks` output and never builds it.
- **Evidence Runner** (`tools/evidence-runner/run.bash`): Materializes `workspace/`, pre-evaluates findings/errors, runs adapter agent, runs diff comparison via `compare.bash` against `golden/`, and emits structured JSON metrics.
