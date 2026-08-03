_: {
  den.aspects.tux = {
    nixos =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.hello ];
      };
  };
}
