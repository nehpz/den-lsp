{ inputs, ... }: {
  den.hosts.x86_64-linux.igloo.users.tux = { };
  den.aspects.web.nixos.services.openssh.enable = (inputs.customInput.value == "transformed");
}
