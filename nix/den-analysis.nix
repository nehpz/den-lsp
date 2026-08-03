# Vendored analysis capture — everything the den-lsp engine needs from one
# evaluation of a Den consumer config.
#
# This file is den-lsp's own copy of the analysis layer, injected into the
# consumer's `den.lib.analysis` via nix/inject-analysis.nix (den.lib is a
# freeform option, so the injection needs NO den changes and works against
# stock den — verified back to v0.18.0, whose captureFleet already exposes
# scopedClassImports). When den ships a native den.lib.analysis upstream,
# the mkDefault injection yields to it automatically; keep this file in
# sync with den nix/lib/diag/analysis.nix until then.
#
# Public API (den.lib.analysis):
#   capture { classes, root ? null, ctx ? {} }
#     root == null -> fleet mode: walks the ENTIRE flake scope tree
#       (flake -> fleet -> environment -> host -> user) per class.
#     root != null -> entity mode: mirrors captureWithPathsWith's calling
#       convention for a single resolved entity root.
#     Returns the analysis IR (see below).
#   serialize
#     Safe content serializer: JSON-able tree with __opaque / __truncated
#     markers; never forces functions, derivations, or throwing values.
#   positionsFromDefinitions
#     [ { file, value } ] -> name -> { file, line, column } | null.
#     Feed it option definitions (e.g. options.den.aspects.definitionsWithLocations
#     from the consumer's module eval) to recover declaration positions.
#
# Analysis IR shape (version 1):
#   {
#     version = 1;
#     entries;      # trace entries (tracingHandler shape)
#     ctxTrace;     # entity-kind context trace
#     emissions;    # [ { scope; class; identity; opaque; content; } ]
#     scopes;       # fleet mode: { parent; entityKind; contextKeys; } else { }
#     registries;   # { structuralKeys; classes; quirks; batteries; aspects; }
#     entities;     # { hosts = [ { system; name; class; users; } ]; homes; }
#   }
{
  den,
  lib,
  ...
}:
let
  fxLib = den.lib.aspects.fx;

  maxDepth = 32;

  # Serialize a value into a JSON-able tree. Guards, in order: values that
  # throw on forcing (__opaque = "error"), functions (arg names kept),
  # derivations (name kept), functors (keys kept), depth (bounded so
  # recursive structures cannot diverge). Paths become strings so toJSON
  # never copies them to the store.
  serializeDepth =
    depth: raw:
    let
      ev = builtins.tryEval raw;
      v = ev.value;
    in
    if !ev.success then
      { __opaque = "error"; }
    else if
      v == null || builtins.isBool v || builtins.isInt v || builtins.isFloat v || builtins.isString v
    then
      v
    else if builtins.isPath v then
      toString v
    else if builtins.isFunction v then
      {
        __opaque = "function";
        args = builtins.attrNames (builtins.functionArgs v);
      }
    else if lib.isDerivation v then
      {
        __opaque = "derivation";
        name = v.name or "<drv>";
      }
    else if builtins.isAttrs v then
      if depth == 0 then
        { __truncated = true; }
      else if v ? __functor then
        {
          __opaque = "functor";
          keys = builtins.attrNames v;
        }
      else
        builtins.mapAttrs (_: serializeDepth (depth - 1)) v
    else if builtins.isList v then
      if depth == 0 then { __truncated = true; } else map (serializeDepth (depth - 1)) v
    else
      { __opaque = builtins.typeOf v; };

  serialize = serializeDepth maxDepth;

  # Class-collector modules arrive in three shapes (class-collector.nix /
  # emit-classes.nix): raw emit-class params (__rawEntry — the module lives
  # under .module; the param's ctx must NOT be walked, it references the
  # whole den config graph), and anonymous/named wraps
  # { _file/key = loc; imports = [ module ]; }. loc is "${class}@${identity}".
  moduleOf =
    mod:
    if !builtins.isAttrs mod then
      mod
    else if mod ? __loc && mod ? module then
      normalizeModule mod.module
    else if (mod ? key || mod ? _file) && mod ? imports then
      normalizeModule (builtins.head mod.imports)
    else
      normalizeModule mod;

  # Aspect content picks up module-provenance wrapper layers on its way
  # through the option system (e.g. { _file = "…via option den.aspects.x.nixos";
  # imports = [ <actual> ]; }). The _file strings differ per aspect, so two
  # identical blocks would never compare equal — strip pure wrapper levels
  # (attrsets holding only imports/_file/key metadata) before serialization.
  # Metadata keys nested inside real config are left untouched.
  isWrapper =
    m:
    builtins.isAttrs m
    && m ? imports
    && builtins.isList m.imports
    && builtins.all (
      k:
      builtins.elem k [
        "imports"
        "_file"
        "key"
      ]
    ) (builtins.attrNames m);

  normalizeModule =
    m:
    if !isWrapper m then
      m
    else if builtins.length m.imports == 1 then
      normalizeModule (builtins.head m.imports)
    else
      { imports = map normalizeModule m.imports; };

  identityOf =
    class: mod:
    let
      loc = if !builtins.isAttrs mod then null else mod.__loc or mod.key or mod._file or null;
    in
    if loc == null then "<anon>" else lib.removePrefix "${class}@" loc;

  # Base aspect name of an emission identity: the first segment before any
  # provider path ("/"), multi-module index ("["), disambiguator (":"), or
  # context suffix ("{"). "igloo" -> "igloo"; "par-probe/{host=igloo}" -> "par-probe".
  baseNameOf =
    identity:
    let
      m = builtins.match "([^:/[{]+).*" identity;
    in
    if m == null then identity else builtins.head m;

  # scopedClassImports (scope -> class -> [module]) -> flat emission records.
  #
  # content is LAZY: forcing it walks the emitted module, which is only
  # total for consumer-authored plain data. Consumers MUST gate forcing on
  # `declared` (the emission's base name is a den.aspects declaration) —
  # framework emissions can reference option-merged values whose forcing
  # raises uncatchable evaluation errors (e.g. a battery option default
  # reading an absent flake input).
  emissionsFrom =
    scopedClassImports:
    lib.flatten (
      lib.mapAttrsToList (
        scope: byClass:
        lib.mapAttrsToList (
          class: mods:
          map (
            mod:
            let
              content = moduleOf mod;
              identity = identityOf class mod;
            in
            {
              inherit scope class identity;
              declared = (den.aspects or { }) ? ${baseNameOf identity};
              opaque = builtins.isFunction content;
              content = serialize content;
            }
          ) mods
        ) byClass
      ) scopedClassImports
    );

  aspectInfo =
    v:
    if builtins.isFunction v then
      {
        description = null;
        provides = [ ];
        keys = [ ];
        callable = true;
      }
    else
      {
        description = v.description or null;
        provides = builtins.attrNames (v.provides or v._ or { });
        keys = builtins.attrNames v;
        callable = v ? __functor;
      };

  tryQuirks = builtins.tryEval den.quirks;
  rawQuirks =
    if tryQuirks.success then
      tryQuirks.value
    else
      lib.genAttrs (builtins.attrNames (den.classes or { })) (k: {
        description = "Colliding quirk";
      });

  registriesSnapshot = {
    structuralKeys = builtins.attrNames fxLib.keyClassification.structuralKeysSet;
    classes = builtins.mapAttrs (_: c: {
      description = if builtins.isAttrs c && (builtins.tryEval c.description).success then c.description else null;
    }) (den.classes or { });
    quirks = builtins.mapAttrs (_: q: {
      description = if builtins.isAttrs q && (builtins.tryEval q.description).success then q.description else null;
    }) rawQuirks;
    batteries = builtins.mapAttrs (_: aspectInfo) (den.batteries or { });
    aspects = builtins.mapAttrs (_: aspectInfo) (den.aspects or { });
  };

  entitiesSnapshot = {
    hosts = lib.flatten (
      lib.mapAttrsToList (
        system: hosts:
        lib.mapAttrsToList (name: host: {
          inherit system name;
          class = host.class or null;
          users = builtins.attrNames (host.users or { });
        }) hosts
      ) (den.hosts or { })
    );
    homes = builtins.mapAttrs (_: v: builtins.attrNames v) (den.homes or { });
  };

  captureFleetMode =
    classes:
    let
      tryFleet = builtins.tryEval (lib.genAttrs classes (class: den.lib.capture.captureFleet { inherit class; }));
    in
    if tryFleet.success then
      let
        perClass = tryFleet.value;
        first = perClass.${lib.head classes};
      in
      {
        version = 1;
        entries = lib.concatMap (c: perClass.${c}.entries) classes;
        inherit (first) ctxTrace;
        emissions = lib.concatMap (c: emissionsFrom perClass.${c}.scopedClassImports) classes;
        scopes = {
          parent = first.scopeParent;
          entityKind = first.scopeEntityKind;
          contextKeys = builtins.mapAttrs (_: ctx: builtins.attrNames ctx) first.scopeContexts;
        };
        registries = registriesSnapshot;
        entities = entitiesSnapshot;
      }
    else
      {
        version = 1;
        entries = [ ];
        ctxTrace = [ ];
        emissions = [ ];
        scopes = { };
        registries = registriesSnapshot;
        entities = entitiesSnapshot;
      };

  captureEntityMode =
    {
      classes,
      root,
      ctx,
    }:
    let
      raw = den.lib.capture.captureWithPathsWith { inherit classes root ctx; };
      scopedClassImports =
        raw.scopedClassImports
          or (throw "den-lsp: entity-mode capture needs a den whose captureWithPathsWith exposes scopedClassImports (den > v0.18.0); use fleet mode (root = null), which works on stock den");
    in
    {
      version = 1;
      inherit (raw) entries ctxTrace;
      emissions = lib.concatMap (c: emissionsFrom scopedClassImports.${c}) classes;
      scopes = { };
      registries = registriesSnapshot;
      entities = entitiesSnapshot;
    };

  capture =
    {
      classes,
      root ? null,
      ctx ? { },
    }:
    if root == null then captureFleetMode classes else captureEntityMode { inherit classes root ctx; };

  # Recover declaration positions from option definitions. Each def is
  # { file, value }; unsafeGetAttrPos resolves the position of a statically
  # declared attr name in that definition, null for dynamically-constructed
  # attrs. First non-null definition wins per name.
  positionsFromDefinitions =
    defs:
    lib.foldl' (
      acc: def:
      let
        v = def.value or { };
        names = if builtins.isAttrs v then builtins.attrNames v else [ ];
        fresh = lib.genAttrs names (name: builtins.unsafeGetAttrPos name v);
      in
      # Keep existing non-null positions; fill gaps from this definition.
      fresh // builtins.mapAttrs (name: pos: if pos == null then fresh.${name} or null else pos) acc
    ) { } defs;
in
{
  inherit
    capture
    serialize
    positionsFromDefinitions
    ;
}
