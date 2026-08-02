{ config, ... }:
{
  den.aspects.web.nixos = {
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };
  };

  den.aspects.db.nixos = {
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };
  };

  den.aspects.igloo.includes = [
    config.den.aspects.web
    config.den.aspects.db
  ];
}
