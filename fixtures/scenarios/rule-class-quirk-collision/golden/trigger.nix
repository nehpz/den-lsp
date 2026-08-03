{ config, ... }:
{
  den = {
    classes.custom = { };
    quirks.custom-quirk = {
      description = "Non-colliding quirk name";
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
