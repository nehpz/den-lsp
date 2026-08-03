{ config, lib, ... }:
let
  makeSubAspect =
    idx: sub:
    let
      name = "fleet-${toString idx}-${toString sub}";
    in
    {
      inherit name;
      value = {
        nixos =
          if idx == 0 && (sub == 0 || sub == 1) then
            {
              services.openssh = {
                enable = true;
                settings.PermitRootLogin = "no";
              };
            }
          else
            {
              services = {
                "svc-${toString idx}-${toString sub}" = {
                  enable = true;
                  port = 8000 + idx * 8 + sub;
                };
              };
              environment.etc."conf-${toString idx}-${toString sub}.conf".text =
                "fleet config ${toString idx}-${toString sub}";
              systemd.services."service-${toString idx}-${toString sub}".description =
                "Fleet service ${toString idx}-${toString sub}";
              users.users."user-${toString idx}-${toString sub}".isSystemUser = true;
            };
      };
    };

  makeAspectGroup = idx: builtins.genList (sub: makeSubAspect idx sub) 8;
  allAspectsList = lib.flatten (builtins.genList makeAspectGroup 50);
  generatedAspects = builtins.listToAttrs allAspectsList;
  aspectNames = map (a: a.name) allAspectsList;
  aspectRefs = map (name: config.den.aspects.${name}) aspectNames;
in
{
  den = {
    aspects = generatedAspects // {
      igloo.includes = aspectRefs;
    };
  };
}
