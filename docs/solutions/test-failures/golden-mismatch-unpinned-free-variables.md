---
title: Golden-mismatch false negatives from unpinned free variables in eval task prompts
date: 2026-08-06
category: test-failures
module: evidence-kernel
problem_type: test_failure
component: testing_framework
symptoms:
  - "Agent repairs judged repaired: false with verdictReason: golden_mismatch despite clean re-analysis"
  - "Repair success rate 4/8 while catch rate and precision are 8/8"
  - "Multiple models fail the same scenarios in the same way"
root_cause: logic_error
resolution_type: test_fix
severity: high
tags: [agent-eval, golden-comparison, task-prompts, measurement-validity, goldenability, eval-harness]
---

# Pin Agent-Chosen Free Variables and Repair Shapes in Benchmark Task Prompts

## Problem

In `den-lsp`'s agent-evaluation harness ("evidence kernel", located in `tools/evidence-runner/`), an agent's repair is judged by comparing the repaired workspace's normalized evaluated output against a per-scenario golden workspace using structural JSON equality (design decision **KTD6** in `docs/plans/2026-08-03-001-feat-evidence-kernel-plan.md:178`). This outcome-equality design decision (**KD3**, `docs/plans/2026-08-03-001-feat-evidence-kernel-plan.md:42`) was chosen over simple "finding silenced" checks to ensure that deleting a flagged configuration does not masquerade as a valid repair (**AE1**, `docs/plans/2026-08-03-001-feat-evidence-kernel-plan.md:110`).

However, during the first automated agent evaluation sweep (`google-antigravity/gemini-3.6-flash`), the harness reported a repair success rate of only 4/8 (50%), recorded in `runs/2026-08-07/evidence-metrics.jsonl`. A second model (`claude-haiku-4-5`) had already failed all three pre-fix smoke attempts on `base-gating-dup` the same way. Upon manual transcript reconstruction and JSON diffing, every single failure was revealed to be a false negative (`verdictReason: "golden_mismatch"`). The agents had produced semantically and materially correct repairs, but because the scenario task prompts left entity names or attribute shapes unconstrained as free variables, the agents chose valid identifiers (e.g., naming an extracted aspect `'common'` or `'openssh'` instead of `'shared-openssh'`) or clean structural variants (e.g., `{ nixos = { }; }` instead of `{ }`) that differed from the golden files. Additionally, one golden workspace contained an unprompted description edit that no task prompt requested.

Because the comparator's equivalence boundary enforced literal key equality for user-defined identifiers, these valid repairs were flagged as mismatches. The R4 "goldenability gate" (**R4**, `docs/plans/2026-08-03-001-feat-evidence-kernel-plan.md:59`), which dictates that ambiguous scenarios must be excluded or disambiguated, failed to catch these unpinned free variables during initial scenario authoring.

## Symptoms

During evaluation runs recorded in `runs/2026-08-07/evidence-metrics.jsonl`, 4 out of 8 clear-cut scenarios failed with `verdictReason: "golden_mismatch"`:

- `base-advisory-only`: `repaired: false`, `verdictReason: "golden_mismatch"` (`runs/2026-08-07/evidence-metrics.jsonl:2`)
- `base-gating-dup`: `repaired: false`, `verdictReason: "golden_mismatch"` (`runs/2026-08-07/evidence-metrics.jsonl:4`)
- `field-wrapper-masking`: `repaired: false`, `verdictReason: "golden_mismatch"` (`runs/2026-08-07/evidence-metrics.jsonl:5`)
- `rule-class-quirk-collision`: `repaired: false`, `verdictReason: "golden_mismatch"` (`runs/2026-08-07/evidence-metrics.jsonl:7`)

In all four cases:
1. `detected` was `true` and `precise` was `true`.
2. The agent successfully eliminated the target diagnostic finding — the runner assigns `verdictReason: "golden_mismatch"` only when the golden match fails while re-analysis is clean (`tools/evidence-runner/run.bash:443-444`).
3. The comparator failed in `tools/evidence-runner/compare.bash:127` because `MATCH` evaluated to `false` when comparing normalized JSON outputs (`$r == $g`).

Prior to the prompt-pinning fix, `claude-haiku-4-5` failed all three smoke-run attempts on `base-gating-dup` with the same `golden_mismatch` verdict (session triage; smoke metrics were not retained in the repo).

## What Didn't Work

1. **Relying solely on clean re-analysis (`cleanReanalysis`):** Checking only whether findings are cleared is insufficient because an agent can delete the defective module entirely, which clears the finding but destroys configuration state (**KD3** / **AE1**).
2. **Teaching the comparator alpha-equivalence of free identifiers:** Attempting to update `tools/evidence-runner/compare.bash` (lines 93-124) with AST-level alpha-renaming or heuristic set-isomorphism was evaluated and rejected due to high implementation complexity, non-deterministic matching risk, and potential masking of real structural defects.

## Solution

The issue was resolved in commit `42b1447` ("fix(scenarios): pin agent-chosen names and repair shapes in task prompts") on branch `feat/evidence-omp-adapter` (unmerged to `main` at the time of writing).

Instead of modifying the comparator, every agent-chosen free variable in the scenario task prompts was explicitly pinned to match the golden workspace, and unprompted edits in golden files were reverted.

### Task Prompt Changes in `fixtures/scenarios/`

1. **`fixtures/scenarios/base-advisory-only/scenario.nix:6`**
   ```nix
   # Before:
   task = "Consolidate fragmented single-option aspects into a unified aspect.";
   
   # After (fixtures/scenarios/base-advisory-only/scenario.nix:6):
   task = "Consolidate fragmented single-option aspects into a unified aspect named 'common'.";
   ```

2. **`fixtures/scenarios/base-gating-dup/scenario.nix:6`**
   ```nix
   # Before:
   task = "Refactor duplicated configuration block across aspects into a shared aspect.";
   
   # After (fixtures/scenarios/base-gating-dup/scenario.nix:6):
   task = "Refactor duplicated configuration block across aspects into a shared aspect named 'shared-openssh'.";
   ```

3. **`fixtures/scenarios/field-wrapper-masking/scenario.nix:6`**
   ```nix
   # Before:
   task = "Refactor duplicated configuration wrapped in module-provenance layers into a shared aspect.";
   
   # After (fixtures/scenarios/field-wrapper-masking/scenario.nix:6):
   task = "Refactor duplicated configuration wrapped in module-provenance layers into a shared aspect named 'shared-openssh'.";
   ```

4. **`fixtures/scenarios/base-broken/scenario.nix:6`**
   ```nix
   # Before:
   task = "Fix the evaluation error in the aspect module.";
   
   # After (fixtures/scenarios/base-broken/scenario.nix:6):
   task = "Fix the evaluation error in the aspect module by replacing the broken aspect's body with an empty attribute set ({ }); do not add class keys such as nixos.";
   ```

5. **`fixtures/scenarios/rule-class-quirk-collision/scenario.nix:6`**
   ```nix
   # Before:
   task = "Rename the colliding quirk so den.quirks does not collide with den.classes.";
   
   # After (fixtures/scenarios/rule-class-quirk-collision/scenario.nix:6):
   task = "Rename the colliding quirk to 'custom-quirk' so den.quirks does not collide with den.classes. Change only the quirk's key, nothing else.";
   ```

### Golden Workspace Cleanup

In `fixtures/scenarios/rule-class-quirk-collision/golden/trigger.nix:6`, an unprompted description edit present in the golden file was reverted to match the initial trigger module:

```nix
# Before (in golden/trigger.nix prior to 42b1447):
description = "Non-colliding quirk name";

# After (fixtures/scenarios/rule-class-quirk-collision/golden/trigger.nix:6):
description = "Colliding quirk name";
```

### Quantitative Verification

Following commit `42b1447`:

- **Gemini 3.6 Flash (`google-antigravity/gemini-3.6-flash`):** Repair success rate rose from **4/8 (50%)** in `runs/2026-08-07/evidence-metrics.jsonl` to **8/8 (100%)** in `runs/2026-08-07/evidence-metrics-2.jsonl` and `runs/2026-08-07/readout.md:14`.
- **Claude Haiku 4.5 (`haiku`):** Went from failing every pre-fix attempt on `base-gating-dup` to passing it. The post-fix sweep (`runs/2026-08-07/evidence-metrics-haiku.jsonl`) records **6/8** because it ran before the `base-broken` prompt pin landed; after that pin, a single-scenario re-run of `base-broken` passed (session-verified; not retained as a committed metrics file), leaving `field-wrapper-masking` as the only failure (effective **7/8**). Per session triage of the retained transcript (`runs/2026-08-07/evidence-metrics-haiku-artifacts/`, untracked), that remaining failure is a genuine model capability defect — the agent attached the shared aspect to the host's includes rather than the duplicating aspects — not a harness artifact.

## Why This Works

The harness comparator in `tools/evidence-runner/compare.bash` operates via strict structural comparison over `jq`-normalized output:

```bash
# tools/evidence-runner/compare.bash:123-127
REPAIRED_NORM="$(jq "$NORM_JQ" <<< "${REPAIRED_RAW}")"
GOLDEN_NORM="$(jq "$NORM_JQ" <<< "${GOLDEN_RAW}")"

MATCH="$(jq -n --argjson r "${REPAIRED_NORM}" --argjson g "${GOLDEN_NORM}" '$r == $g')"
```

The normalization filter `NORM_JQ` (`tools/evidence-runner/compare.bash:93-121`) strips source positions (`.position`, `.__loc`), store paths (`/nix/store/...`), and unwraps single-element module provenance wrappers (`is_wrapper`). However, attribute keys representing user-created or renamed entities (such as aspect names or quirk keys) remain intact and are compared for exact equality.

By explicitly specifying exact names (`'common'`, `'shared-openssh'`, `'custom-quirk'`) and structural constraints (`replace body with empty attribute set { }; do not add class keys`) directly in the task prompt, all free variables are bound before the agent executes. This aligns the agent's expected output with the golden workspace without compromising the deletion-masquerade protections guaranteed by outcome-equality evaluation (**KD3**).

## Prevention

When authoring or maintaining agent-evaluation scenarios judged by outcome equality:

1. **Enumerate and Pin Free Variables:** Identify every agent-chosen free variable in the repair space—including entity names, attribute keys, directory paths, and structural shapes. Explicitly specify these values in the scenario's `task` prompt string.
2. **Apply the Goldenability Gate (R4):** If a scenario's task cannot pin free variables without trivializing the prompt, or if the repair remains inherently ambiguous, exclude the scenario from the clear-cut set (`goldenable = false; exclusionReason = "...";`) per **R4** (`docs/plans/2026-08-03-001-feat-evidence-kernel-plan.md:59`).
3. **Audit Golden Workspaces:** Goldens must contain *only* changes directly requested by the task prompt. Ensure no incidental refactoring or field edits exist in the golden workspace files.
4. **Triage Mismatches Before Blaming Models:** Treat uniform repair-rate failures characterized by `verdictReason: "golden_mismatch"` with clean re-analysis as benchmark artifacts until proven otherwise. Inspect raw agent transcripts and diff normalized outputs before concluding an agent lacks repair capability.

## Related Issues

- **Commit:** `42b1447` ("fix(scenarios): pin agent-chosen names and repair shapes in task prompts") on branch `feat/evidence-omp-adapter`
- **Design Plan:** `docs/plans/2026-08-03-001-feat-evidence-kernel-plan.md` (Design decisions **KD3**, **KTD6**, **R4**, **R7**, **AE1**, **AE2**)
- **Harness Comparator:** `tools/evidence-runner/compare.bash:72-161`
- **Evaluation Runs & Metrics:**
  - `runs/2026-08-07/evidence-metrics.jsonl` (Initial 4/8 sweep)
  - `runs/2026-08-07/evidence-metrics-2.jsonl` (Post-fix 8/8 sweep)
  - `runs/2026-08-07/evidence-metrics-haiku.jsonl` (Haiku sweep, 6/8 — ran before the base-broken pin; base-broken passed a pinned re-run)
  - `runs/2026-08-07/readout.md` (Go/No-Go Readout)
- **Scenario Contract:** `fixtures/scenarios/README.md` (manifest fields `task`, `goldenable`, `exclusionReason` — the authoring surface this learning constrains)
- **Strategy Metrics:** `STRATEGY.md` (successful-repair-rate metric this false negative distorted)
- **PR:** [#1 — evidence kernel](https://github.com/nehpz/den-lsp/pull/1) (merged; introduced the scenario corpus and comparator this learning corrects)
