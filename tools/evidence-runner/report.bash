#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IN_FILE="./evidence-metrics.jsonl"
OUT_FILE=""

usage() {
  cat <<EOF
Usage: report.bash [options]

Options:
  --in <file>    Metrics JSON-lines input file (default: ./evidence-metrics.jsonl)
  --out <file>   Optional output markdown file
  --help, -h     Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)
      IN_FILE="$2"
      shift 2
      ;;
    --out)
      OUT_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ ! -f "$IN_FILE" ]; then
  echo "Error: Input metrics file '${IN_FILE}' not found." >&2
  exit 1
fi

if [ ! -s "$IN_FILE" ]; then
  echo "Error: Input metrics file '${IN_FILE}' is empty." >&2
  exit 1
fi
SWEEP_META_CHECK="$(jq -R -n '
  [inputs | select(length > 0) | try fromjson catch empty] as $rows |
  ($rows | map(select(.sweepMeta == true))) as $metas |
  ($rows | map(select(.sweepMeta != true))) as $data |
  if ($metas | length) > 0 then
    ($metas[0].selected // 0) as $expected |
    ($data | length) as $actual |
    if $expected != $actual then
      {incomplete: true, expected: $expected, actual: $actual}
    else
      {incomplete: false}
    end
  else
    {incomplete: false}
  end
' "$IN_FILE")"

if [ "$(jq -r '.incomplete' <<< "$SWEEP_META_CHECK")" = "true" ]; then
  EXPECTED="$(jq -r '.expected' <<< "$SWEEP_META_CHECK")"
  ACTUAL="$(jq -r '.actual' <<< "$SWEEP_META_CHECK")"
  echo "Error: INCOMPLETE SWEEP: expected ${EXPECTED} scenario result(s) from sweepMeta, but found ${ACTUAL}." >&2
  exit 1
fi


CLEAR_CUT_COUNT="$(jq -R -n '
  [inputs | select(length > 0) | try fromjson catch empty] |
  [ .[] | select(.sweepMeta != true and .clearCut == true and .goldenable == true and .controlArm == false and .knownMiss == false) ] | length
' "$IN_FILE")"

if [ "$CLEAR_CUT_COUNT" -lt 5 ]; then
  echo "Error: Clear-cut scenario count (${CLEAR_CUT_COUNT}) is below R17 floor of 5. Refusing to render readout." >&2
  exit 1
fi

READOUT="$(jq -r -R -n '
  def fmt_num:
    if type == "number" then
      if . == (. | floor) then (. | floor | tostring) else tostring end
    else
      tostring
    end;

  def calc_median:
    if length == 0 then "N/A"
    else
      sort as $s | ($s | length) as $len |
      if ($len % 2 == 1) then
        $s[(($len - 1) / 2) | floor] | fmt_num
      else
        (($s[($len / 2 - 1) | floor] + $s[($len / 2) | floor]) / 2) | fmt_num
      end
    end;

  def pct(cnt; total):
    if total == 0 then "0.0%"
    else
      (((cnt / total) * 10000 | round) / 100 | tostring) + "%"
    end;

  [inputs | select(length > 0) | try {valid: true, val: fromjson} catch {valid: false}] as $parsed |
  ($parsed | map(select(.valid == true and .val.sweepMeta != true) | .val)) as $all |
  ($parsed | map(select(.valid == false)) | length) as $skipped_lines |

  ($parsed | map(select(.valid == true and .val.sweepMeta == true) | .val)) as $metas |
  ($metas[0] // {}) as $meta |
  ($all | map(.model // empty) | unique) as $models |
  ($all | map(.thinking // empty) | unique) as $thinkings |
  ($all | map(.cost | select(type == "number"))) as $cost_vals |
  ($all | map(.tokens | select(type == "number"))) as $token_vals |

  def is_clear_cut: .clearCut == true and .goldenable == true and .controlArm == false and .knownMiss == false;

  ($all | map(select(is_clear_cut))) as $cc |
  ($all | map(select(.knownMiss == true and .controlArm == false))) as $km |
  ($all | map(select(.controlArm == true))) as $ca |

  ($cc | length) as $cc_len |
  ($cc | map(select(.detected == true)) | length) as $det_cnt |
  ($cc | map(select(.precise == true)) | length) as $prec_cnt |
  ($cc | map(select(.repaired == true)) | length) as $rep_cnt |

  ($cc | map(select(.detected == false or .precise == false))) as $triage_rows |
  (if ($triage_rows | length) > 0 then "NO-GO" else "GO" end) as $verdict |
  ($cc | map(.wallClockSec) | min) as $w_min |
  ($cc | map(.wallClockSec) | calc_median) as $w_med |
  ($cc | map(.wallClockSec) | max) as $w_max |

  ($cc | map(.turns | select(. != null))) as $turn_vals |
  (if ($turn_vals | length) == 0 then "N/A" else ($turn_vals | min | tostring) end) as $t_min |
  (if ($turn_vals | length) == 0 then "N/A" else ($turn_vals | calc_median) end) as $t_med |
  (if ($turn_vals | length) == 0 then "N/A" else ($turn_vals | max | tostring) end) as $t_max |

  ($cc | map(select(.verdictReason == "timeout" or .verdictReason == "garbage_output" or .verdictReason == "adapter_failed")) | length > 0) as $has_failures |

  [
    "# Evidence Kernel - Go/No-Go Readout\n",
    "## Verdict: \($verdict)\n",
    (if $verdict == "GO" then
      "**AUTHORIZES ENTRY INTO FIELD READINESS**\n\n*(Note: This readout authorizes entry into field readiness work; it is not evidence of field performance.)*\n"
    else
      "## Tool-Bug Triage\n\nThe following clear-cut scenario(s) failed detection or precision requirements (KD5/AE5). Any detection or precision miss is triaged as a tool bug by definition.\n\n| Scenario | Kind | Detected | Precise | Verdict Reason |\n| --- | --- | --- | --- | --- |\n" +
      ($triage_rows | map("| \(.scenario) | \(.kind) | \(.detected) | \(.precise) | \(.verdictReason) |") | join("\n")) + "\n"
    end),
    "## Provenance\n",
    "- Adapter: \($meta.adapter // "unrecorded")",
    "- Model: \(if ($models | length) == 0 then "unrecorded" else ($models | join(", ")) end)",
    "- Thinking: \(if ($thinkings | length) == 0 then "adapter default" else ($thinkings | join(", ")) end)",
    "- Scenario Rev: \($meta.scenarioRev // "unrecorded")",
    "- Total LLM Cost: \(if ($cost_vals | length) == 0 then "unrecorded" else ("$" + (($cost_vals | add * 100 | round) / 100 | tostring) + (if ($cost_vals | add) == 0 then " (provider reported zero cost)" else "" end)) end)",
    "- Total Tokens: \(if ($token_vals | length) == 0 then "unrecorded" else ($token_vals | add | tostring) end)\n",
    "## Headline Metrics\n",
    "- Scenarios Evaluated (Clear-Cut): \($cc_len)",
    "- Catch Rate (detected): \($det_cnt)/\($cc_len) (\(pct($det_cnt; $cc_len)))",
    "- Finding Precision: \($prec_cnt)/\($cc_len) (\(pct($prec_cnt; $cc_len)))",
    "- Repair Success Rate: \($rep_cnt)/\($cc_len) (\(pct($rep_cnt; $cc_len)))",
    "- Wall-Clock Distribution: min \($w_min)s, median \($w_med)s, max \($w_max)s",
    "- Turn Distribution: min \($t_min), median \($t_med), max \($t_max)\n",
    "## Clear-Cut Scenarios\n",
    "| Scenario | Kind | Detected | Precise | Repaired | Wall Clock (s) | Turns | Verdict Reason |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ($cc | map("| \(.scenario) | \(.kind) | \(.detected) | \(.precise) | \(.repaired) | \(.wallClockSec)s | \(.turns // "null") | \(.verdictReason) |") | join("\n")) + "\n",
    (if $has_failures then
      "* Footnote: Adapter failure rows (verdictReason in timeout, garbage_output, adapter_failed) count as repaired=false.\n"
    else empty end),
    (if $skipped_lines > 0 then
      "* Footnote: Skipped \($skipped_lines) malformed JSONL line(s) during input processing.\n"
    else empty end),
    "## Coverage Appendix (Known Misses)\n",
    "Known-miss scenarios document engine limitations outside headline metrics denominators (KTD8).\n",
    (if ($km | length) > 0 then
      "| Scenario | Kind | Detected | Precise | Repaired | Wall Clock (s) | Turns | Verdict Reason |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n" +
      ($km | map("| \(.scenario) | \(.kind) | \(.detected) | \(.precise) | \(.repaired) | \(.wallClockSec)s | \(.turns // "null") | \(.verdictReason) |") | join("\n")) + "\n"
    else
      "No known-miss scenarios present.\n"
    end),
    "## Control Arm\n",
    "Control-arm scenarios evaluate performance with findings withheld (R10), excluded from headline metrics.\n",
    (if ($ca | length) > 0 then
      "| Scenario | Kind | Detected | Precise | Repaired | Wall Clock (s) | Turns | Verdict Reason |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n" +
      ($ca | map("| \(.scenario) | \(.kind) | \(.detected) | \(.precise) | \(.repaired) | \(.wallClockSec)s | \(.turns // "null") | \(.verdictReason) |") | join("\n")) + "\n"
    else
      "No control-arm scenarios present.\n"
    end)
  ] | join("\n")
' "$IN_FILE")"

printf "%s\n" "$READOUT"

if [ -n "$OUT_FILE" ]; then
  mkdir -p "$(dirname "$OUT_FILE")"
  printf "%s\n" "$READOUT" > "$OUT_FILE"
fi

# A NO-GO readout is a failed gate: exit nonzero so CI steps and scripts
# that run this as a check actually block on the verdict.
if printf "%s\n" "$READOUT" | grep -q "^## Verdict: NO-GO"; then
  exit 2
fi
