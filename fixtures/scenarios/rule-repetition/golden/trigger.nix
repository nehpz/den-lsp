{ config, ... }:
{
  den = {
    default.includes = [
      config.den.aspects.monitoring
    ];

    aspects = {
      monitoring.nixos = {
        services.prometheus.enable = true;
      };
    };
  };
}
