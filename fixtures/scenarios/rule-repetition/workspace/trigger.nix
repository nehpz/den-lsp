{ config, ... }:
{
  den = {
    aspects = {
      monitoring.nixos = {
        services.prometheus.enable = true;
      };

      igloo.includes = [
        config.den.aspects.monitoring
      ];

      tux.includes = [
        config.den.aspects.monitoring
      ];
    };
  };
}
