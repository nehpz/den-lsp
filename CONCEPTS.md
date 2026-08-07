# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Den analysis

### Aspect
A named, reusable unit of Den configuration intent that hosts include; aspects emit class-scoped configuration into the evaluated graph den-lsp analyzes. Repairs frequently create or restructure aspects (e.g. extracting duplicated configuration into a shared aspect).

### Finding
A semantic diagnostic den-lsp emits over the evaluated aspect graph. Severity is either gating (blocks completion) or advisory (informational); a finding carries fix-shaped guidance intended to be actionable by a coding agent.

## Evaluation (evidence kernel)

### Evidence Kernel
The minimal evaluation capability that measures whether den-lsp findings are detected, precise, and agent-repairable. Split into two tiers: a hermetic tier that verifies detection and precision without an LLM (cheap, runs in CI) and an agent arm that drives a real coding agent through a repair and judges the outcome (costly, on demand).

### Scenario
A versioned bundle of base fixture, seeded defect, expected findings (or expected evaluation error), agent task prompt, and golden outcome. The scenario corpus is the durable asset; both evaluation tiers consume the same scenario unchanged.

### Golden
The known-correct repaired workspace a scenario carries. A repair succeeds only when the repaired workspace's normalized evaluated outcome matches the golden and re-analysis is clean. Goldens must contain no changes the task prompt does not request.

### Goldenability
The gate on scenario membership in the clear-cut set: a scenario qualifies only when its correct repair is unambiguous. Every agent-chosen free variable — names of created or renamed entities, repair shape, edit scope — must be pinned in the task prompt; a scenario that cannot pin them is excluded with a recorded reason rather than bending the judgment.

### Clear-cut Set
The goldenable, non-known-miss scenarios over which detection and precision must be complete — a miss there is a tool bug by definition — while repair rate is a learned number, not a preset bar.

### Known-miss
A scenario declaring a defect the engine cannot yet detect. It documents coverage honestly outside the headline denominators, and known-miss status is declared at authoring time — never assigned retroactively to excuse a detection failure.

### Deletion Masquerade
The failure mode where an agent silences a finding by deleting the flagged configuration instead of repairing intent. Golden-outcome comparison exists to catch it: re-analysis comes back clean, but the outcome no longer matches the golden.

### Readout
The rendered report aggregating per-scenario results into the strategy metrics and a go/no-go verdict. It informs the human go/no-go decision and is not part of the CI gate, which runs only the hermetic tier.

### Adapter
The declarative interface between the evidence kernel and one coding agent: how the agent is invoked, how findings are presented, and how status and turn counts are read back. Adding an agent means adding an adapter, never changing the runner.

### Field-Failure Intake
The convention requiring every real-world breakage (engine crash, wrong finding, hang, timeout) to be minimized into a scenario or fixture in the evaluation corpus. Engine crashes and hangs become hermetic fixtures evaluated in the hermetic tier, while repair defects become scenarios following standard goldenability and pinning rules.
