_: {
  den.aspects.igloo = {
    nixos =
      { pkgs, ... }:
      {
        fileSystems."/".device = "/dev/null";
        boot.loader.grub.enable = false;
      };
  };
}
