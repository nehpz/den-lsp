# Idiom rules (U4) — duplication, battery replication, granularity, per-host repetition.
{ lib }:
[
  (import ./duplication.nix { inherit lib; })
  (import ./battery-replication.nix { inherit lib; })
  (import ./granularity.nix { inherit lib; })
  (import ./repetition.nix { inherit lib; })
]
