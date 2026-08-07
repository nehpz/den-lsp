# Renders a findings document's findings as the adapter-facing text block.
# Single source of truth for the runner presentation (run.bash) and its tests.
.findings // [] | map(
  "Finding:\n  Rule: \(.rule)\n  Severity: \(.severity)" +
  (if .aspectPath then "\n  Aspect: \(.aspectPath)" else "" end) +
  (if .position and .position.file then "\n  File: \(.position.file)" else "" end) +
  (if .position and .position.line then "\n  Line: \(.position.line)" else "" end) +
  (if .position and .position.column then "\n  Column: \(.position.column)" else "" end) +
  (if .message then "\n  Message: \(.message)" else "" end) +
  (if .fix then "\n  Fix: \(.fix)" else "" end) +
  (if .docRef then "\n  DocRef: \(.docRef)" else "" end)
) | join("\n\n")
