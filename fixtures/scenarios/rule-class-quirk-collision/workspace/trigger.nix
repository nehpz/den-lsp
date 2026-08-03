{ config, ... }:
{
  den = {
    classes.custom = { };
    quirks.custom = {
      description = "Colliding quirk name";
    };

    aspects = {
      web.nixos = {
        services.nginx.enable = true;
      };

      igloo.includes = [
        config.den.aspects.web
      ];
    };
  };
}
