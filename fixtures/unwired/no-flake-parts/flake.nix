{
  description = "R4 fixture: Den consumer with no flake-parts input";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    den.url = "github:denful/den";
  };

  outputs = inputs: {
    # Intentionally not a flake-parts consumer.
    packages.x86_64-linux.hello = inputs.nixpkgs.legacyPackages.x86_64-linux.hello;
  };
}
