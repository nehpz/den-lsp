{ config, ... }:
{
  den = {
    classes.nixos = { };
    aspects = {
      sniff-web.nixos = {
        _file = "<unknown-file>, via option den.aspects.sniff-web.nixos";
        imports = [
          {
            services.openssh = {
              enable = true;
              settings.PermitRootLogin = "no";
            };
          }
        ];
      };

      sniff-db.nixos = {
        _file = "<unknown-file>, via option den.aspects.sniff-db.nixos";
        imports = [
          {
            services.openssh = {
              enable = true;
              settings.PermitRootLogin = "no";
            };
          }
        ];
      };

      igloo.includes = [
        config.den.aspects.sniff-web
        config.den.aspects.sniff-db
      ];
    };
  };
}
