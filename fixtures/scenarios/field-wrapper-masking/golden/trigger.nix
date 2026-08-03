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

      sniff-web = {
        includes = [ config.den.aspects.shared-openssh ];
      };

      sniff-db = {
        includes = [ config.den.aspects.shared-openssh ];
      };

      igloo.includes = [
        config.den.aspects.sniff-web
        config.den.aspects.sniff-db
      ];
    };
  };
}
