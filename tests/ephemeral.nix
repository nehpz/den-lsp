# Unit tests for ephemeral injection wrapper (U1, R1, R2, R3).
{ lib, engine, den-lsp ? null }:
let
  ephemeral = import ../nix/ephemeral.nix;

  denLspArg = if den-lsp != null then den-lsp else ../.;
  denLspFlake =
    if builtins.isAttrs denLspArg && denLspArg ? inputs then
      denLspArg
    else
      builtins.getFlake (if builtins.isPath denLspArg then "path:" + toString denLspArg else toString denLspArg);

  inputOverrides = {
    den = denLspFlake.inputs.den;
    nixpkgs = denLspFlake.inputs.nixpkgs;
  };

  consumerPath = ./. + "/../fixtures/consumer";
  uninstrumentedPath = ./. + "/../fixtures/consumer-variants/uninstrumented";
  gatingDupPath = ./. + "/../fixtures/consumer-variants/gating-dup";
  gatingDupUninstrumentedPath = ./. + "/../fixtures/consumer-variants/gating-dup-uninstrumented";
  noflakePath = ./. + "/../fixtures/consumer-variants/noflake";
  nonDenPath = ./. + "/../fixtures/consumer-variants/non-den";
  brokenPath = ./. + "/../fixtures/consumer-variants/broken";
  destructuredSelfPath = ./. + "/../fixtures/consumer-variants/destructured-self";
  fallbackSubdirsPath = ./. + "/../fixtures/consumer-variants/fallback-subdirs";
  fallbackNoModulesPath = ./. + "/../fixtures/consumer-variants/fallback-no-modules";
  pathModulePath = ./. + "/../fixtures/consumer-variants/path-module";
  singleArgMkFlakePath = ./. + "/../fixtures/consumer-variants/single-arg-mkflake";
  specialArgsPath = ./. + "/../fixtures/consumer-variants/special-args";
  moduleArgsPath = ./. + "/../fixtures/consumer-variants/module-args";
  unrecognizedFlakePartsPath = ./. + "/../fixtures/consumer-variants/unrecognized-flake-parts";

  # Helper to normalize findings for comparison
  normalizeDoc = doc: {
    inherit (doc) version summary;
    findings = map (f: f // { position = if f.position != null then f.position // { file = baseNameOf f.position.file; } else null; }) doc.findings;
  };

  # Scenario 1: Un-instrumented copy of base consumer fixture yields a findings document normalized-identical to instrumented fixture's.
  instrumentedBaseDoc = ephemeral { workspace = consumerPath; den-lsp = denLspArg; inherit inputOverrides; };
  uninstrumentedBaseDoc = ephemeral { workspace = uninstrumentedPath; den-lsp = denLspArg; inherit inputOverrides; };
  uninstrumentedBaseIdentical = normalizeDoc uninstrumentedBaseDoc == normalizeDoc instrumentedBaseDoc;

  # Scenario 2: Un-instrumented copy of gating-dup variant yields the same gating finding as its instrumented sibling.
  instrumentedGatingDupDoc = ephemeral { workspace = gatingDupPath; den-lsp = denLspArg; inherit inputOverrides; };
  uninstrumentedGatingDupDoc = ephemeral { workspace = gatingDupUninstrumentedPath; den-lsp = denLspArg; inherit inputOverrides; };
  gatingDupMatchesSibling =
    (uninstrumentedGatingDupDoc.summary.gating == 1)
    && (normalizeDoc uninstrumentedGatingDupDoc == normalizeDoc instrumentedGatingDupDoc);

  # Scenario 3: Already-instrumented fixtures/consumer analyzed through wrapper produces the same document as direct den-lsp-analysis evaluation (R2).
  directBaseFlake = builtins.getFlake ("path:" + toString consumerPath);
  alreadyInstrumentedReuse =
    (instrumentedBaseDoc.version == directBaseFlake.den-lsp-analysis.version)
    && (normalizeDoc instrumentedBaseDoc == normalizeDoc directBaseFlake.den-lsp-analysis);

  # Scenario 4: A noflake-shaped consumer is analyzed successfully through the wrapper.
  noflakeDoc = ephemeral { workspace = noflakePath; den-lsp = denLspArg; inherit inputOverrides; };
  noflakeAnalyzed = (noflakeDoc ? version) && (noflakeDoc.version == 1) && (noflakeDoc.summary.gating == 0);

  # Scenario 5: A flake with no Den configuration produces the unsupported-target error value, not a raw Nix trace (R3).
  nonDenRes = ephemeral { workspace = nonDenPath; den-lsp = denLspArg; inherit inputOverrides; };
  unsupportedNonDen =
    (nonDenRes ? error)
    && (nonDenRes.error.kind == "unsupported")
    && (nonDenRes.version == 1);

  # Scenario 6: A consumer whose Den config fails evaluation propagates an eval failure distinct from unsupported (R3 boundary).
  brokenTryEval = builtins.tryEval (ephemeral { workspace = brokenPath; den-lsp = denLspArg; inherit inputOverrides; });
  brokenEvalFailurePropagated = brokenTryEval.success == false;

  # Scenario 7: A consumer whose outputs destructures self evaluates successfully (#1).
  destructuredSelfDoc = ephemeral { workspace = destructuredSelfPath; den-lsp = denLspArg; inherit inputOverrides; };
  destructuredSelfAnalyzed = (destructuredSelfDoc ? version) && (destructuredSelfDoc.version == 1) && (destructuredSelfDoc.summary.gating == 0);

  # Scenario 8: Fallback module discovery finds modules recursively in subdirectories (#2a).
  fallbackSubdirsDoc = ephemeral { workspace = fallbackSubdirsPath; den-lsp = denLspArg; inherit inputOverrides; };
  fallbackSubdirsAnalyzed = (fallbackSubdirsDoc ? version) && (fallbackSubdirsDoc.version == 1) && (fallbackSubdirsDoc.summary.gating == 0);

  # Scenario 9: Fallback module discovery with no modules yields unsupported error envelope (#2b).
  fallbackNoModulesRes = ephemeral { workspace = fallbackNoModulesPath; den-lsp = denLspArg; inherit inputOverrides; };
  unsupportedFallbackNoModules =
    (fallbackNoModulesRes ? error)
    && (fallbackNoModulesRes.error.kind == "unsupported")
    && (fallbackNoModulesRes.version == 1);

  # Scenario 10: A consumer passing a path module to mkFlake normalizes and evaluates without crashing (#6).
  pathModuleDoc = ephemeral { workspace = pathModulePath; den-lsp = denLspArg; inherit inputOverrides; };
  pathModuleAnalyzed = (pathModuleDoc ? version) && (pathModuleDoc.version == 1) && (pathModuleDoc.summary.gating == 0);

  # Scenario 11: Single-argument mkFlake call shape is handled cleanly (#14).
  singleArgMkFlakeDoc = ephemeral { workspace = singleArgMkFlakePath; den-lsp = denLspArg; inherit inputOverrides; };
  singleArgMkFlakeAnalyzed = (singleArgMkFlakeDoc ? version) && (singleArgMkFlakeDoc.version == 1) && (singleArgMkFlakeDoc.summary.gating == 0);

  # Scenario 12: Consumer passing specialArgs to mkFlake preserves specialArgs without missing-attribute errors.
  specialArgsDoc = ephemeral { workspace = specialArgsPath; den-lsp = denLspArg; inherit inputOverrides; };
  specialArgsAnalyzed = (specialArgsDoc ? version) && (specialArgsDoc.version == 1) && (specialArgsDoc.summary.gating == 0);

  # Scenario 13: Consumer module using flake-parts module args like withSystem evaluates natively.
  moduleArgsDoc = ephemeral { workspace = moduleArgsPath; den-lsp = denLspArg; inherit inputOverrides; };
  moduleArgsAnalyzed = (moduleArgsDoc ? version) && (moduleArgsDoc.version == 1) && (moduleArgsDoc.summary.gating == 0);

  # Scenario 14: Target flake declaring flake-parts input with unrecognized shape returns unsupported error envelope.
  unrecognizedFlakePartsRes = ephemeral { workspace = unrecognizedFlakePartsPath; den-lsp = denLspArg; inherit inputOverrides; };
  unsupportedUnrecognizedFlakeParts =
    (unrecognizedFlakePartsRes ? error)
    && (unrecognizedFlakePartsRes.error.kind == "unsupported")
    && (unrecognizedFlakePartsRes.version == 1);
in
{
  ephemeral-uninstrumented-base-identical = uninstrumentedBaseIdentical;
  ephemeral-gating-dup-matches-instrumented = gatingDupMatchesSibling;
  ephemeral-already-instrumented-reuse = alreadyInstrumentedReuse;
  ephemeral-noflake-consumer = noflakeAnalyzed;
  ephemeral-unsupported-non-den = unsupportedNonDen;
  ephemeral-broken-eval-failure = brokenEvalFailurePropagated;
  ephemeral-destructured-self = destructuredSelfAnalyzed;
  ephemeral-fallback-subdirs = fallbackSubdirsAnalyzed;
  ephemeral-unsupported-fallback-no-modules = unsupportedFallbackNoModules;
  ephemeral-path-module = pathModuleAnalyzed;
  ephemeral-single-arg-mkflake = singleArgMkFlakeAnalyzed;
  ephemeral-special-args = specialArgsAnalyzed;
  ephemeral-module-args = moduleArgsAnalyzed;
  ephemeral-unrecognized-flake-parts = unsupportedUnrecognizedFlakeParts;
}
