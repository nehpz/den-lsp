---
title: Silent-pass vs loud-fail validation boundary
date: "2026-08-15"
category: conventions
module: test-infrastructure
problem_type: convention
component: fixtures_scenarios
severity: medium
applies_when:
  - "Adding or reviewing validation for internal static manifests/configs"
  - "A reviewer (human or bot) asks to restore schema validation the repo removed"
  - "Adding a new field to scenario.nix manifests"
tags:
  - validation
  - review-cost
  - scenario-manifests
  - vacuous-pass
---

# Silent-Pass vs Loud-Fail Validation Boundary

## Context

PR #30 deleted the scenario loader's `validateScenario` pass (55 lines of
imperative schema checks over static, internal, few-in-number manifests).
Review bots re-requested schema validation in three consecutive rounds, each
time as a fresh finding. The decline rationale lived only in resolved PR
threads, so every new review round rediscovered the "missing" validation.

## Convention

Validation for internal static data is placed by **failure mode**, not by
data shape:

- **Silent-pass failure modes** — a bad value makes a check report green
  while verifying nothing (e.g. an empty `expectedFindings` list matching
  vacuously) — are guarded at **load time**, where the bad value enters.
- **Loud failure modes** — a bad value already fails visibly (Nix eval trace
  at the consuming site, or a corpus invariant in
  `tests/scenarios/comparator.nix` under `nix flake check`) — are **not**
  re-checked at load. Duplicating a loud failure buys nothing and grows the
  exact validator the deletion removed.

Current mapping for scenario manifests: see the "Validation Boundary"
section of `fixtures/scenarios/README.md` and the comment block above
`loadScenarioFile` in `fixtures/scenarios/lib.nix`.

## Why not both?

A load-time schema validator over static internal manifests is dead weight:
the corpus is committed, so the comparator tier already fails CI on any
invalid manifest, and authors get a Nix eval trace at worst. The only checks
that pay rent at load are the ones no other tier can catch — the silent ones.

## Review-cycle corollary

When a deliberate non-change keeps getting re-flagged across review rounds,
the decline rationale must move from PR comments into the code and docs the
reviewer actually reads (a comment at the decision site + the owning
README). PR threads are not durable; the next round — and the next bot —
starts from the diff, not from resolved conversations.
