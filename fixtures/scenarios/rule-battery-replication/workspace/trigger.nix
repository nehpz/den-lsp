{ config, ... }:
{
  den = {
    aspects = {
      user-config.nixos = {
        users.users.tux = {
          isNormalUser = true;
        };
      };

      igloo.includes = [
        config.den.aspects.user-config
      ];
    };
  };
}
