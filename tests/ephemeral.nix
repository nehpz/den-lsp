# Unit tests for ephemeral injection wrapper (U1, R1, R2, R3).
{ lib, engine, den-lsp ? null }:
let
  ephemeral = import ../nix/ephemeral.nix;

  denLspArg = if den-lsp != null then den-lsp else ../.;

  consumerPath = ./. + "/../fixtures/consumer";
  uninstrumentedPath = ./. + "/../fixtures/consumer-variants/uninstrumented";
  gatingDupPath = ./. + "/../fixtures/consumer-variants/gating-dup";
  gatingDupUninstrumentedPath = ./. + "/../fixtures/consumer-variants/gating-dup-uninstrumented";
  noflakePath = ./. + "/../fixtures/consumer-variants/noflake";
  nonDenPath = ./. + "/../fixtures/consumer-variants/non-den";
  brokenPath = ./. + "/../fixtures/consumer-variants/broken";

  # Helper to normalize findings for comparison
  normalizeDoc = doc: {
    inherit (doc) version summary;
    findings = map (f: f // { position = if f.position != null then f.position // { file = baseNameOf f.position.file; } else null; }) doc.findings;
  };

  # Scenario 1: Un-instrumented copy of base consumer fixture yields a findings document normalized-identical to instrumented fixture's.
  instrumentedBaseDoc = ephemeral { workspace = consumerPath; den-lsp = denLspArg; };
  uninstrumentedBaseDoc = ephemeral { workspace = uninstrumentedPath; den-lsp = denLspArg; };
  uninstrumentedBaseIdentical = normalizeDoc uninstrumentedBaseDoc == normalizeDoc instrumentedBaseDoc;

  # Scenario 2: Un-instrumented copy of gating-dup variant yields the same gating finding as its instrumented sibling.
  instrumentedGatingDupDoc = ephemeral { workspace = gatingDupPath; den-lsp = denLspArg; };
  uninstrumentedGatingDupDoc = ephemeral { workspace = gatingDupUninstrumentedPath; den-lsp = denLspArg; };
  gatingDupMatchesSibling =
    (uninstrumentedGatingDupDoc.summary.gating == 1)
    && (normalizeDoc uninstrumentedGatingDupDoc == normalizeDoc instrumentedGatingDupDoc);

  # Scenario 3: Already-instrumented fixtures/consumer analyzed through wrapper produces the same document as direct den-lsp-analysis evaluation (R2).
  directBaseFlake = builtins.getFlake ("path:" + toString consumerPath);
  alreadyInstrumentedReuse =
    (instrumentedBaseDoc.version == directBaseFlake.den-lsp-analysis.version)
    && (normalizeDoc instrumentedBaseDoc == normalizeDoc directBaseFlake.den-lsp-analysis);

  # Scenario 4: A noflake-shaped consumer is analyzed successfully through the wrapper.
  noflakeDoc = ephemeral { workspace = noflakePath; den-lsp = denLspArg; };
  noflakeAnalyzed = (noflakeDoc ? version) && (noflakeDoc.version == 1) && (noflakeDoc.summary.gating == 0);

  # Scenario 5: A flake with no Den configuration produces the unsupported-target error value, not a raw Nix trace (R3).
  nonDenRes = ephemeral { workspace = nonDenPath; den-lsp = denLspArg; };
  unsupportedNonDen =
    (nonDenRes ? error)
    && (nonDenRes.error.kind == "unsupported")
    && (nonDenRes.version == 1);

  # Scenario 6: A consumer whose Den config fails evaluation propagates an eval failure distinct from unsupported (R3 boundary).
  brokenTryEval = builtins.tryEval (ephemeral { workspace = brokenPath; den-lsp = denLspArg; });
  brokenEvalFailurePropagated = brokenTryEval.success == false;
in
{
  ephemeral-uninstrumented-base-identical = uninstrumentedBaseIdentical;
  ephemeral-gating-dup-matches-instrumented = gatingDupMatchesSibling;
  ephemeral-already-instrumented-reuse = alreadyInstrumentedReuse;
  ephemeral-noflake-consumer = noflakeAnalyzed;
  ephemeral-unsupported-non-den = unsupportedNonDen;
  ephemeral-broken-eval-failure = brokenEvalFailurePropagated;
}
