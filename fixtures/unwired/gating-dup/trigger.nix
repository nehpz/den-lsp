{ config, ... }:
{
  den = {
    aspects = {
      web.nixos = {
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "no";
        };
      };

      db.nixos = {
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "no";
        };
      };

      igloo.includes = [
        config.den.aspects.web
        config.den.aspects.db
      ];
    };
  };
}
