{ config, ... }:
{
  den = {
    aspects = {
      web.deployHealthChecks = {
        http = {
          port = 8080;
          path = "/healthz";
        };
      };

      db.deployHealthChecks = {
        http = {
          port = 8080;
          path = "/healthz";
        };
      };

      igloo.includes = [
        config.den.aspects.web
        config.den.aspects.db
      ];
    };
  };
}
