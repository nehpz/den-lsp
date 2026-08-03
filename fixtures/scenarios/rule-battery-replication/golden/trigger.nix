{ config, ... }:
{
  den = {
    aspects = {
      user-config = {
        includes = [
          config.den.batteries.define-user
        ];
      };

      igloo.includes = [
        config.den.aspects.user-config
      ];
    };
  };
}
