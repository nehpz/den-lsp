{ config, ... }:
{
  den = {
    aspects = {
      shared-openssh.nixos = {
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "no";
        };
      };

      web = {
        includes = [ config.den.aspects.shared-openssh ];
      };

      db = {
        includes = [ config.den.aspects.shared-openssh ];
      };

      igloo.includes = [
        config.den.aspects.web
        config.den.aspects.db
      ];
    };
  };
}
