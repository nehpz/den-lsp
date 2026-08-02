{ ... }:
{
  den.aspects.igloo = {
    nixos =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.hello ];
      };
  };
}
