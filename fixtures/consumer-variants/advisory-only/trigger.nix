{ config, ... }:
{
  den = {
    aspects = {
      asp1.nixos.programs.git.enable = true;
      asp2.nixos.programs.vim.enable = true;
      asp3.nixos.programs.zsh.enable = true;

      igloo.includes = [
        config.den.aspects.asp1
        config.den.aspects.asp2
        config.den.aspects.asp3
      ];
    };
  };
}
