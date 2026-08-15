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
Authoring contract for `scenario.nix` (the loader applies defaults for `knownMiss`, `heavy`, `complete`, and `exclusionReason`; malformed manifests fail at eval):

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
   A free variable is a choice with no semantic consequence for the evaluated outcome — naming, formatting, incidental shape. Choices the configuration semantics constrain (e.g. *where* a shared aspect attaches: to the duplicating aspects' `includes`, not the host's) are deliberately left unpinned — getting them wrong changes behavior for consumers of those aspects, and the comparator failing such a repair is the harness measuring real capability, not a missing pin.
2. **Goldens contain only what the task requests.** No incidental edits (descriptions, formatting, refactors) beyond the pinned repair — any unprompted delta becomes a false-negative `golden_mismatch` for a correct agent.

## Field-Failure Intake Convention

Every real-world breakage (engine crash, wrong finding, hang, timeout) encountered in production or consumer usage becomes a minimized scenario or fixture in the evaluation corpus by convention:

1. **Reproduction & Minimization:** Create the smallest reproducer workspace or input that triggers the defect.
2. **Engine Crashes & Hangs:** Engine crashes, evaluation errors, and hangs become hermetic fixtures evaluated in the hermetic tier (or unit tests) rather than agent-arm scenarios, verifying pure detection or evaluation correctness cleanly.
3. **Wrong Findings & Repair Scenarios:** Real-world defect repairs that require agent action become benchmark scenarios in `fixtures/scenarios/<name>/`.
4. **Goldenability Rules:** Goldenable repairs follow the existing authoring rules — every agent-chosen free variable (names of created or renamed entities, repair shape, edit scope) must be pinned in `task`. Inherently ambiguous cases where free variables cannot be pinned without trivializing the task are recorded with `goldenable = false` + `exclusionReason` rather than bending the judgment.

> Comparability note: the adapter findings presentation gained `fix`, `docRef`, and column on 2026-08-07. Repair-rate and repair-time numbers from sweeps before that boundary are not comparable with later ones; the readout's provenance section records each sweep's den-lsp revision, which delimits the boundary.

## Consumption Tiers
- **Hermetic Tier** (`nix flake check "path:fixtures/scenarios" --override-input den-lsp "$PWD"`): Evaluates scenario manifests, verifies workspace evaluation/error status against expected specs, and validates golden structure.
- **Heavy Tier** (manual; excluded from the default gate for cost): `nix build "path:fixtures/scenarios#heavyChecks.<system>.scenario-field-fleet-scale" --override-input den-lsp "$PWD"`. Run before releases or when touching capture/normalization paths - `nix flake check` only warns about the non-standard `heavyChecks` output and never builds it.
- **Evidence Runner** (`tools/evidence-runner/run.bash`): Materializes `workspace/`, pre-evaluates findings/errors, runs adapter agent, runs diff comparison via `compare.bash` against `golden/`, and emits structured JSON metrics.
