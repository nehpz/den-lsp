# Evidence Kernel - Go/No-Go Readout

## Verdict: GO

**AUTHORIZES ENTRY INTO FIELD READINESS**

*(Note: This readout authorizes entry into field readiness work; it is not evidence of field performance.)*

## Provenance

- Adapter: omp
- Model: devin/swe-1-7
- Thinking: adapter default
- Scenario Rev: 32a9fa8
- Total LLM Cost: $0 (provider reported zero cost)
- Total Tokens: 19624291

## Headline Metrics

- Scenarios Evaluated (Clear-Cut): 8
- Catch Rate (detected): 8/8 (100%)
- Finding Precision: 8/8 (100%)
- Repair Success Rate: 8/8 (100%)
- Wall-Clock Distribution: min 40s, median 248.5s, max 447s
- Turn Distribution: min 12, median 36.5, max 85

## Clear-Cut Scenarios

| Scenario | Kind | Detected | Precise | Repaired | Wall Clock (s) | Turns | Verdict Reason |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base-advisory-only | finding | true | true | true | 172s | 35 | match_and_clean |
| base-broken | eval-error | true | true | true | 203s | 38 | match_and_clean |
| base-gating-dup | finding | true | true | true | 308s | 60 | match_and_clean |
| field-wrapper-masking | finding | true | true | true | 447s | 85 | match_and_clean |
| rule-battery-replication | finding | true | true | true | 355s | 72 | match_and_clean |
| rule-class-quirk-collision | eval-error | true | true | true | 40s | 12 | match_and_clean |
| rule-repetition | finding | true | true | true | 294s | 17 | match_and_clean |
| rule-unregistered-class-key | finding | true | true | true | 100s | 28 | match_and_clean |

## Coverage Appendix (Known Misses)

Known-miss scenarios document engine limitations outside headline metrics denominators (KTD8).

No known-miss scenarios present.

## Control Arm

Control-arm scenarios evaluate performance with findings withheld (R10), excluded from headline metrics.

No control-arm scenarios present.
