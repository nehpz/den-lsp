# Engine unit tests over synthetic analysis IR — hermetic, no den input
# needed. Each attr is a boolean; nix/dev.nix turns them into checks named
# checks.<system>.engine-<name>. Rule suites add their tests here:
#   tests/structural/*.nix and tests/idiom/*.nix export { <name> = bool; }
#   and are merged below.
{ lib, engine, den-lsp ? null }:
let
  # Minimal synthetic IR mirroring den.lib.analysis.capture's shape.
  # Keep in sync with den nix/lib/diag/analysis.nix (IR version 1).
  syntheticIr = import ./fixtures/synthetic-ir.nix;

  emptyDoc = engine.analyze {
    ir = syntheticIr;
    rules = [ ];
  };

  stubRule = {
    id = "stub";
    severity = "gating";
    docRef = "docs/src/content/docs/reference/aspects.mdx";
    check = ir: [
      {
        aspectPath = "den.aspects.web";
        message = "stub finding";
        fix = "stub fix";
        position = {
          file = "/nix/store/abc123-source/modules/web.nix";
          line = 3;
          column = 1;
        };
      }
    ];
  };

  stubDoc = engine.analyze {
    ir = syntheticIr;
    rules = [ stubRule ];
  };

  stubFinding = builtins.head stubDoc.findings;

  jsonRoundTrip =
    doc: builtins.fromJSON (builtins.toJSON doc) == builtins.fromJSON (builtins.toJSON doc);

  core = {
    empty-doc-valid = emptyDoc.version == 1 && emptyDoc.findings == [ ] && emptyDoc.summary.gating == 0;
    inventory-populated =
      emptyDoc.inventory.classes ? nixos && emptyDoc.inventory.batteries ? define-user;
    stub-finding-tagged =
      stubFinding.rule == "stub"
      && stubFinding.severity == "gating"
      && stubFinding.docRef != ""
      && stubFinding.message == "stub finding";
    store-path-normalized = stubFinding.position.file == "modules/web.nix";
    render-header-counts = lib.hasInfix "1 gating, 0 advisory" (engine.renderText stubDoc);
    render-empty = lib.hasInfix "no findings" (engine.renderText emptyDoc);
    json-round-trips = jsonRoundTrip stubDoc;
  };

  suiteDir =
    dir:
    let
      files = builtins.readDir dir;
      nixFiles = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) files;
    in
    lib.foldl' lib.mergeAttrs { } (
      lib.mapAttrsToList (n: _: import (dir + "/${n}") { inherit lib engine syntheticIr; }) nixFiles
    );

  structural = if builtins.pathExists ./structural then suiteDir ./structural else { };
  idiom = if builtins.pathExists ./idiom then suiteDir ./idiom else { };
  scenarios = if builtins.pathExists ./scenarios then suiteDir ./scenarios else { };
  ephemeral = if builtins.pathExists ./ephemeral.nix then import ./ephemeral.nix { inherit lib engine den-lsp; } else { };
in
core // structural // idiom // scenarios // ephemeral
