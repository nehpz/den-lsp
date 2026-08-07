{ inputs, ... }:
{
  imports = [
    inputs.den.flakeModules.default
  ];

  den.hosts.x86_64-linux.igloo.users.tux = { };
}
