# Field-Failure Intake

Operational pathway for turning production breakages into durable evaluation corpus entries. Governed by **Field-Failure Intake** in [`CONCEPTS.md`](../CONCEPTS.md); this doc is the how-to, not a restatement of those definitions.

## Pathway

### 1. Capture verbatim

Record the failing invocation exactly as observed:

- **Command** — full argv, env overrides, and input overrides (e.g. `--override-input`).
- **Target repo ref** — commit SHA, branch, or flake lock input that produced the failure.
- **Output** — stdout, stderr, exit code, and hang/timeout boundary (how long before abort).

Do not paraphrase or trim stack traces before filing.

### 2. Minimize

Reduce to the smallest workspace, module set, or invocation that still reproduces the failure. Strip unrelated hosts, aspects, and inputs. Keep the minimized artifact in-repo (`fixtures/` or `fixtures/scenarios/<name>/`) so the **Evidence Kernel** hermetic tier can run it in CI.

### 3. Classify and route

Map the minimized failure to one **CONCEPTS.md** failure class and its destination tier:

| Failure class | Destination tier | Corpus location |
|---|---|---|
| **engine crash** | **Evidence Kernel** hermetic tier | `fixtures/` consumer fixture or `fixtures/scenarios/<name>/` checked by `nix flake check "path:fixtures/scenarios"` |
| **hang** | hermetic tier | same |
| **timeout** | hermetic tier | same |
| **wrong finding** | goldenable **Scenario** (hermetic tier checks `expectedFindings` / `expectedError`; agent arm optional) | `fixtures/scenarios/<name>/` |
| **repair defect** | goldenable **Scenario** (agent arm + **Golden** comparison) | `fixtures/scenarios/<name>/` |

**Wrong finding** and **repair defect** scenarios must satisfy **Goldenability**: pin every agent-chosen free variable in the scenario `task` prompt and keep **Golden** workspaces limited to prompted edits. See [`docs/solutions/test-failures/golden-mismatch-unpinned-free-variables.md`](solutions/test-failures/golden-mismatch-unpinned-free-variables.md) for the pinning contract and `goldenable = false` + `exclusionReason` escape hatch.

Engine-class failures (crash, hang, timeout) do not enter the agent arm; they verify detection, evaluation, or liveness under the hermetic tier only.

Authoring surface: [`fixtures/scenarios/README.md`](../fixtures/scenarios/README.md) (**Scenario** manifest schema, **Finding** severities gating vs advisory).

### 4. Land with the fix

Ship the minimized fixture and its hermetic check in the **same PR** as any engine or **Finding** fix. A fix without a corpus entry regresses silently; a corpus entry without a fix fails CI by design.

## References

- [`CONCEPTS.md`](../CONCEPTS.md) — **Field-Failure Intake**, **Scenario**, **Golden**, **Goldenability**, **Evidence Kernel**, **Finding**
- [`fixtures/scenarios/README.md`](../fixtures/scenarios/README.md) — scenario contract and consumption tiers
- [`docs/solutions/test-failures/golden-mismatch-unpinned-free-variables.md`](solutions/test-failures/golden-mismatch-unpinned-free-variables.md) — free-variable pinning for goldenable scenarios
