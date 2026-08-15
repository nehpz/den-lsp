# Synthetic analysis IR — mirrors den.lib.analysis.capture output (version 1).
# The baseline is a small, CLEAN config: no rule should fire on it as-is.
# Rule tests build scenario variants with `//` overrides.
#
# IR contract (den: nix/lib/diag/analysis.nix):
#   version, entries, ctxTrace, emissions, scopes, registries, entities
#   emission = { scope; class; identity; declared; opaque; content; }
{
  version = 1;

  entries = [
    {
      name = "igloo";
      class = "nixos";
      parent = null;
    }
  ];

  ctxTrace = [ ];

  emissions = [
    {
      scope = "host=igloo,system=x86_64-linux";
      class = "nixos";
      identity = "igloo";
      declared = true;
      opaque = false;
      content = {
        time.timeZone = "UTC";
      };
    }
    {
      scope = "host=igloo,system=x86_64-linux";
      class = "nixos";
      identity = "default";
      declared = false;
      opaque = false;
      # Framework emission: rules must never force this content (declared
      # gate). Throwing here makes gate violations loud in unit tests.
      content = throw "den-lsp tests: forced content of an undeclared emission";
    }
  ];

  scopes = {
    parent = { };
    entityKind = { };
    contextKeys = { };
  };

  registries = {
    structuralKeys = [
      "name"
      "description"
      "meta"
      "includes"
      "excludes"
      "provides"
      "_"
      "classes"
      "policies"
    ];
    classes = {
      nixos.description = "NixOS system configuration";
      darwin.description = "nix-darwin system configuration";
      homeManager.description = "home-manager configuration";
    };
    quirks = { };
    batteries = {
      define-user = {
        description = "Define the user account for NixOS/Darwin or standalone home-manager.";
        provides = [ ];
        keys = [
          "name"
          "description"
          "includes"
        ];
        callable = false;
      };
      import-tree = {
        description = "Recursively imports non-dendritic .nix files by class.";
        provides = [
          "host"
          "home"
          "user"
        ];
        keys = [
          "description"
          "provides"
        ];
        callable = true;
      };
    };
    aspects = {
      igloo = {
        description = null;
        provides = [ ];
        keys = [
          "nixos"
        ];
        callable = false;
      };
      tux = {
        description = null;
        provides = [ ];
        keys = [
          "includes"
        ];
        callable = false;
      };
    };
  };

  entities = {
    hosts = [
      {
        system = "x86_64-linux";
        name = "igloo";
        class = "nixos";
        users = [ "tux" ];
      }
    ];
    homes = { };
  };
}
