{ config, ... }:
{
  den.aspects.asp1.nixos.programs.git.enable = true;
  den.aspects.asp2.nixos.programs.vim.enable = true;
  den.aspects.asp3.nixos.programs.zsh.enable = true;

  den.aspects.igloo.includes = [
    config.den.aspects.asp1
    config.den.aspects.asp2
    config.den.aspects.asp3
  ];
}
