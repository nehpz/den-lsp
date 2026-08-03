{ config, ... }:
{
  den = {
    aspects = {
      web = {
        custom = {
          setting = true;
        };
      };

      igloo.includes = [
        config.den.aspects.web
      ];
    };
  };
}
