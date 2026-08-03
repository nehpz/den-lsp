---
name: den-lsp
last_updated: 2026-08-02
---

# den-lsp Strategy

## Target problem

Coding agents editing Den consumer flakes can produce configurations that evaluate and build successfully while still containing semantic mistakes. Incorrect aspect structure can remain silent because a passing build closure does not prove that the evaluated configuration matches its intended meaning.

## Our approach

Analyze evaluated intent, not source syntax: treat Den’s evaluated aspect graph as the source of truth for semantic correctness. Use that shared understanding to catch mistakes that ordinary linters and build checks cannot reliably see.

## Who it's for

**Primary:** Coding agents editing Den consumer flakes — They’re hiring den-lsp to catch intent-level mistakes and provide enough context to repair them correctly before declaring the work complete.

**Secondary:** Den flake maintainers — They’re hiring den-lsp to validate agent-authored and human-authored configurations during editing and review.

## Key metrics

- **Pre-completion defect catch rate** — Share of seeded semantic Den defects caught before an agent declares the task complete; measured by the agent evaluation harness.
- **Finding precision** — Share of emitted findings that correspond to real semantic issues rather than rule defects or noise; measured by the agent evaluation harness.
- **Successful repair rate** — Share of findings that coding agents resolve correctly using den-lsp’s guidance; measured by the agent evaluation harness.
- **Time to valid repair** — Elapsed time from a finding appearing until the semantic issue is correctly repaired; measured by the agent evaluation harness.

## Tracks

### Semantic analysis quality

Expand and refine evaluated-graph rules while maintaining high precision and concrete, fix-shaped guidance.

_Why it serves the approach:_ The evaluated graph only becomes a useful source of truth when its rules identify real intent-level mistakes reliably.

### Agent feedback loop

Deliver fast, consistent semantic findings while agents edit and when they validate completion.

_Why it serves the approach:_ Immediate, actionable feedback lets agents repair mistakes while the relevant context is still available.

### Evaluation and evidence

Build and maintain a repeatable seeded-defect harness covering detection, precision, repair success, and repair time.

_Why it serves the approach:_ The harness makes semantic correctness and agent repairability measurable rather than assumed.

### Den analysis contract

Keep Den’s captured IR and den-lsp’s consumption contract expressive, stable, and sufficient for intent-level analysis.

_Why it serves the approach:_ Evaluated-intent analysis depends on a trustworthy representation of aspects, entities, registries, and declaration context.

## Marketing

**One-liner:** Catch the mistakes a passing build cannot.

**Key message:** den-lsp gives coding agents and maintainers semantic feedback over the evaluated Den aspect graph, turning silent intent-level mistakes into concrete repairs.
