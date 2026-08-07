---
title: Plan-time PR topology and real-user feature gating
date: "2026-08-07"
category: conventions
module: development-workflow
problem_type: convention
component: development_workflow
severity: medium
applies_when:
  - "Planning PR topology for multi-unit feature plans"
  - "Deciding whether a planned feature ships or parks"
  - "Working in a repo with per-round-billed review bots"
  - "Auditing a finished branch before opening a PR"
tags:
  - pr-topology
  - user-gating
  - review-cost
  - single-concern-prs
  - feature-parking
---

# Plan-Time PR Topology and Real-User Feature Gating

## Context

den-lsp roadmap Focus 2 ("field readiness/distribution") was planned as one 5-unit implementation plan (`docs/plans/2026-08-07-001-feat-field-readiness-distribution-plan.md`, on the parked `feat/field-readiness` branch — not on `main`, since PR #9 closed unmerged) and shipped as a single PR #9: 2,363 additions / 114 deletions across 11 commits, bundling five concerns — an ephemeral Nix injection layer, a runtime `den-lsp-check` CLI, an LSP-server reliability floor, evidence-runner coupling, and adoption docs.

The review bot (Devin) re-reviews the **entire PR on every push** and bills per round. Three full review rounds fired (8, 6, then 5 findings — 19 total), concentrated in the ephemeral-injection component. Each fix push was itself new unreviewed code, seeding the next round: the rounds converged but never closed.

The repo owner — the sole real user of the product — closed PR #9 unmerged on two grounds:

1. **Topology violation**: it broke the standing rule against multi-thousand-line multi-concern PRs.
2. **No real user for most of it**: his den repos already import den-lsp as a committed module, and a machine-readable channel already existed (`nix eval --json .#checks…analysis` plus the gate's exit code). The zero-touch injection and most of the CLI served a hypothetical "future adopter" persona — by the owner's assessment, roughly 70% of the diff and 90% of the review churn served nobody real.

A per-feature user-value audit sorted the branch; the keepers re-shipped as two single-concern PRs (#10, #11) whose review loops terminated immediately — one fix batch each — and both merged the same day.

## Guidance

### 1. Decide PR topology at plan time

PR boundaries are a planning decision, not an afterthought once a branch exists.

- One PR per implementation unit or dependency layer; single concern per PR.
- Stack PRs when units depend on each other; never bundle a whole multi-unit plan into one branch.
- Record the intended PR split in the plan doc itself, next to the implementation units.

*den-lsp shape*: Focus 2 should have been declared up front as separate PRs — the `server/src/eval.rs` reliability slice (became PR #10) and the evidence-runner presentation slice (became PR #11) — with the adoption layer as its own later decision.

### 2. Price every push with the review cost model

When a per-round-billed review bot is configured, every push purchases a full re-review of the whole PR.

- Review surface scales with PR size; small PRs bound what each round can cost.
- Fix commits are new unreviewed code — on a large PR they feed the next round. Oversized PRs are self-feeding credit burners.
- PR #9 burned three rounds this way (per this session's conclusion on bot billing); PR #10's 577-line diff took one round, with its 3 findings fixed in a single batch push.

### 3. Gate every planned feature by the actual user

Ask, per feature: **"why does the real user personally need this today?"**

- A persona ("coding agents", "future adopters") is not a user.
- If the honest answer names a hypothetical, the feature does not ship — it parks.
- Run this gate at plan time and again before opening the PR; the answer can change as the plan meets reality.

*den-lsp shape*: the real user runs the LSP daily in his editor and reads the evidence-kernel readout to make GO/NO-GO calls — so the reliability floor, CI coverage, and runner metric fidelity all passed the gate. Zero-touch injection for uninstrumented repos passed nothing: his repos are instrumented.

### 4. Parking is cheap; shipping is not

- Reviewed, green code on a branch costs nothing until someone real needs it.
- Shipping it costs review rounds (money), model context (tokens), and the maintainer's reading time — the human must read every line that lands on `main`.

## Why This Matters

1. **Money**: per-round billing multiplies with PR size and round count; 19 findings across 3 rounds on PR #9 vs 5 findings total across the two small PRs, each closed out with a single fix batch, for the same shipped value.
2. **Tokens**: large PRs force the reviewer to re-ingest thousands of unchanged lines every push.
3. **Attention**: speculative abstractions for non-existent users burn the scarcest resource — the maintainer's reading time.
4. **Convergence**: bounded review surface makes review loops terminate; unbounded surface makes them self-feeding.

## When to Apply

- At plan ship-decision time, when a plan has more than one implementation unit.
- Before opening any PR: audit the branch for single-concern shape and real-user value.
- In any repo with automated review bots (Devin, CodeRabbit, Cursor Bugbot) — the cost model applies regardless of PR author.

## Examples

**Anti-example — PR #9** (`feat: zero-touch analysis, agent CLI contract, and LSP reliability floor`): CLOSED unmerged. 2,363 additions / 114 deletions, 11 commits, five concerns. Three review rounds, 19 findings. Closing comment: "Closing: oversized multi-concern PR. Useful slices will return as small single-concern PRs."

**Correct — PR #10** (`feat(server): deadline, cancellation, and stale-publish guard for LSP evals`): MERGED. 577 additions / 76 deletions, single concern (`server/src/eval.rs` + one CI `cargo test` step). First review round's 3 findings fixed in one batch push; the follow-up round surfaced only 1 valid-but-out-of-scope finding, deferred as issue #12 (`medium priority`) with no further push — terminating the loop per the standing triage discipline.

**Correct — PR #11** (`feat(evidence): full finding context in adapter presentation + intake convention`): MERGED. 65 additions / 9 deletions, single concern. One review round; 1 finding, fixed differently than suggested with rationale in the reply.

**The audit that sorted the branch:**

| Feature | What the real user personally gets | Verdict |
| --- | --- | --- |
| LSP reliability floor (`server/src/eval.rs`) | No wedged editor when `nix eval` hangs; stale diagnostics never publish | **Keep** → PR #10 |
| CI `cargo test` step | Server suite actually runs before merge (previously never ran in CI) | **Keep** → PR #10 |
| Evidence-runner context parity (`tools/evidence-runner/findings-format.jq`) | Kernel readout he decides from carries full finding context | **Keep** → PR #11 |
| Field-failure intake docs | Real breakages become fixtures under existing goldenability rules | **Keep** → PR #11 |
| Ephemeral zero-touch Nix injection | Nothing — his repos already import den-lsp | **Park** (branch) |
| `den-lsp-check` runtime CLI | Nothing — `nix eval --json` channel already exists | **Park** (branch) |
| Adoption/quickstart docs | Nothing — marketing for adopters who don't exist yet | **Park** (branch) |

## Related

- PR #9 (closed origin postmortem), PR #10 / PR #11 (the convention applied), issue #12 (deferred-finding triage artifact) — https://github.com/nehpz/den-lsp
- `docs/plans/2026-08-07-001-feat-field-readiness-distribution-plan.md` (historical: lives on the parked `feat/field-readiness` branch) — the plan that lacked a PR-topology decision
- Standing PR review discipline: wait for the first bot round, triage must/should/could/won't, one batch push per round, deferred items become labeled issues
