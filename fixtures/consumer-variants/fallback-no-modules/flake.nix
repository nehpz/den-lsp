{
  description = "Consumer flake with den input but no modules for fallback discovery test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    den.url = "github:denful/den";
  };

  outputs = inputs: { };
}
