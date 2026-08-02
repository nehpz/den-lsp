# Structural rules (U3) — gating checks that mirror Den's registry-driven
# key classification.
{ lib }:
[
  (import ./unregistered-class-key.nix { inherit lib; })
  (import ./class-quirk-collision.nix { inherit lib; })
]
