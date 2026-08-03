{ config, ... }:
{
  den = {
    aspects = {
      common = {
        nixos = {
          programs.git.enable = true;
          programs.vim.enable = true;
          programs.zsh.enable = true;
        };
      };

      igloo.includes = [
        config.den.aspects.common
      ];
    };
  };
}
