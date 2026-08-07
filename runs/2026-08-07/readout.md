# Evidence Kernel - Go/No-Go Readout

## Verdict: GO

**AUTHORIZES ENTRY INTO FIELD READINESS**

*(Note: This readout authorizes entry into field readiness work; it is not evidence of field performance.)*

## Headline Metrics

- Scenarios Evaluated (Clear-Cut): 8
- Catch Rate (detected): 8/8 (100%)
- Finding Precision: 8/8 (100%)
- Repair Success Rate: 8/8 (100%)
- Wall-Clock Distribution: min 23s, median 43s, max 155s
- Turn Distribution: min 13, median 22.5, max 30

## Clear-Cut Scenarios

| Scenario | Kind | Detected | Precise | Repaired | Wall Clock (s) | Turns | Verdict Reason |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base-advisory-only | finding | true | true | true | 23s | 15 | match_and_clean |
| base-broken | eval-error | true | true | true | 39s | 30 | match_and_clean |
| base-gating-dup | finding | true | true | true | 155s | 24 | match_and_clean |
| field-wrapper-masking | finding | true | true | true | 61s | 24 | match_and_clean |
| rule-battery-replication | finding | true | true | true | 48s | 21 | match_and_clean |
| rule-class-quirk-collision | eval-error | true | true | true | 34s | 24 | match_and_clean |
| rule-repetition | finding | true | true | true | 39s | 13 | match_and_clean |
| rule-unregistered-class-key | finding | true | true | true | 47s | 19 | match_and_clean |

## Coverage Appendix (Known Misses)

Known-miss scenarios document engine limitations outside headline metrics denominators (KTD8).

No known-miss scenarios present.

## Control Arm

Control-arm scenarios evaluate performance with findings withheld (R10), excluded from headline metrics.

No control-arm scenarios present.
