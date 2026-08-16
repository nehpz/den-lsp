---
title: LSP Position.character treated as a UTF-8 byte index panics on non-ASCII
date: "2026-08-15"
category: runtime-errors
module: lsp-server
problem_type: runtime_error
component: tooling
symptoms:
  - "textDocument/completion panics when the line before the cursor contains non-ASCII"
  - "textDocument/hover panics when the line before the cursor contains non-ASCII"
  - "panic message: byte index N is not a char boundary; it is inside a multi-byte char"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [lsp, utf-16, position-encoding, char-boundary, hover, completion, panic]
---


# LSP Position.character treated as a UTF-8 byte index panics on non-ASCII

Lives on [PR #30](https://github.com/nehpz/den-lsp/pull/30) (`refactor: dedupe fixture trees, prune dead code, trim server deps`). The PR is **open and unmerged to `main`** as of this writing. The UTF-16 conversion landed on that branch as two commits (SHAs are branch-local and may be rewritten on merge): `fix(server): convert UTF-16 Position.character to a byte index before slicing` (completion / `determine_context`), then `fix(server): convert hover cursor column from UTF-16 before slicing` (hover + shared helper). Claims below are grounded in the current sources `server/src/context.rs` and `server/src/main.rs`.

## Problem

The language server treated LSP `Position.character` as a UTF-8 byte offset into a Rust `&str`. The LSP spec counts that field in UTF-16 code units, so any non-ASCII character before the cursor made `&line[..col]` (and the equivalent prefix slice in `determine_context`) land inside a multi-byte UTF-8 sequence and panic.

## Symptoms

A completion or hover request whose cursor sits after non-ASCII on the same line panics the server with Rust's char-boundary check — for example `byte index 11 is not a char boundary; it is inside 'é' (bytes 10..12) of \`      "café\``. The panic is not a product of [PR #30](https://github.com/nehpz/den-lsp/pull/30)'s context-pipeline refactor: both the pre-refactor code on `main` and the refactored code on the PR branch used the same pattern of feeding `pos.character` straight into a `&str` index.

On `main` (and identically after PR #30's context-pipeline refactor commit, before either UTF-16 fix), `determine_context` clamped the LSP column against the line's **byte** length and sliced:

```rust
// origin/main and the PR #30 refactor, server/src/context.rs — both had this pattern
let current_line = lines[line_idx];
let end_col = col_idx.min(current_line.len());
// main allocated a prefix; the PR #30 refactor sliced in place — both panic the same way
&current_line[..end_col]
```

The hover handler did the same thing with no conversion at all (`server/src/main.rs` on `main` and on the PR #30 branch pre-fix):

```rust
let line = lines[pos.line as usize];
let col = pos.character as usize;
if col >= line.len() {
    return Ok(None);
}
// … walk ASCII identifier bytes from `col` …
let word = &line[start..end];
```

Completion reached the same slice through `determine_context(&buffer, pos.line as usize, pos.character as usize)`. ASCII-only buffers hid the bug because one UTF-16 code unit equals one UTF-8 byte; the first `é` (1 UTF-16 unit, 2 UTF-8 bytes) or `🦀` (2 UTF-16 units, 4 UTF-8 bytes) before the cursor made the indices diverge and the slice illegal.

## What Didn't Work

The first fix was instance-scoped. Review flagged the completion path, and the first PR #30 fix commit (`fix(server): convert UTF-16 Position.character to a byte index before slicing`) inlined a `char_indices` + `len_utf16` walk only inside `determine_context`. Completion started converting; hover was left as `let col = pos.character as usize`. The next review round flagged the identical hover pattern. The class of "every consumer of `Position.character` that indexes a `&str`" was never enumerated, so the same input-interpretation bug shipped through another review cycle on the same PR.

## Solution

The follow-up PR #30 commit (`fix(server): convert hover cursor column from UTF-16 before slicing`) extracted the conversion into a shared helper and converted **both** consumers. The implementation in current `server/src/context.rs:9-20`:

```rust
/// Convert an LSP `Position.character` (UTF-16 code units) into a byte index
/// on `line`, clamped to the line length, always landing on a char boundary.
pub fn utf16_col_to_byte_idx(line: &str, col: usize) -> usize {
    let mut utf16_acc = 0;
    for (byte_idx, ch) in line.char_indices() {
        if utf16_acc >= col {
            return byte_idx;
        }
        utf16_acc += ch.len_utf16();
    }
    line.len()
}
```

`determine_context` now documents that `col_idx` is UTF-16, not a byte offset (`server/src/context.rs:22-25`), and converts before slicing the cursor prefix (`server/src/context.rs:32-33`, used at `server/src/context.rs:42-43`):

```rust
let current_line = lines[line_idx];
let end_col = utf16_col_to_byte_idx(current_line, col_idx);
// …
let line = if i == line_idx {
    &current_line[..end_col]
} else {
    lines[i]
};
```

Completion still passes `pos.character` into `determine_context`, which is now the conversion site (`server/src/main.rs:191-192`):

```rust
// Position.character is UTF-16; determine_context converts to a byte index.
let context = determine_context(&buffer, pos.line as usize, pos.character as usize);
```

Hover converts with the same helper before the identifier walk and the `&line[start..end]` slice (`server/src/main.rs:221-223` and `server/src/main.rs:248`):

```rust
let line = lines[pos.line as usize];
// Position.character is UTF-16; convert to a byte index before slicing.
let col = crate::context::utf16_col_to_byte_idx(line, pos.character as usize);
```

A crate-wide grep of `pos.character`, `Position.character`, and `character as usize` in `*.rs` shows those are the only two `Position.character` consumers: `server/src/main.rs:192` (completion → `determine_context`) and `server/src/main.rs:223` (hover → `utf16_col_to_byte_idx`). Every other hit is the helper definition, its doc comments, or tests.

## Why This Works

The LSP `Position` type counts `character` in UTF-16 code units (the protocol default; this server does not negotiate `utf-8` position encoding). A Rust `&str` is UTF-8 bytes, and indexing it is only legal at a char boundary. The helper walks `line.char_indices()`, so every candidate `byte_idx` is already a boundary; it accumulates `ch.len_utf16()` so BMP characters (`é`) count as 1 and supplementary-plane characters (`🦀`) count as 2, matching the spec. When the accumulated UTF-16 offset reaches the requested column it returns that boundary; if the column is past the end of the line the loop falls through to `line.len()`, which is also a boundary. The prefix slice in `determine_context` and the word slice in hover therefore cannot panic on encoding, and past-the-end columns clamp instead of overflowing.

`test_context_utf16_column_after_non_ascii` (`server/src/context.rs:131-148`) puts the cursor after `café` using a real UTF-16 column (`"      \"café".encode_utf16().count()`) and asserts `InIncludesList`. `test_context_ascii_mid_line_column_unchanged` (`server/src/context.rs:150-159`) keeps the ASCII mid-line case (`col == 4` → `AtAspectKey`) so the conversion is a no-op where encodings agree. `test_utf16_col_to_byte_idx_boundaries` (`server/src/context.rs:161-175`) is the boundary-walk: every column from `0` through `line.encode_utf16().count() + 2` on `"a🦀é-word"` must yield an index that `&line[..idx]` accepts, with explicit points after `a` (1), after the 2-unit crab (3 → byte 5), after `é` (4 → byte 7), and a past-the-end clamp (99 → `line.len()`).

## Prevention

1. Any new `Position` consumer must route the column through `context::utf16_col_to_byte_idx`. Never use `pos.character` (or a `col_idx` that came from it) to index a `&str`. Completion already delegates; hover calls the helper at `server/src/main.rs:223`. A third handler that slices a line at the cursor copies the old panic unless it does the same.

2. When a reviewer flags one instance of an input-interpretation bug, grep every consumer of that input and fix the class in one commit. The first fix converted only completion; a second commit had to come back for hover. The grep that would have collapsed those two rounds is the one in Solution: `pos.character` / `Position.character` / `character as usize` across `*.rs`.

3. Keep the boundary-walk regression pattern in `server/src/context.rs` tests. `test_utf16_col_to_byte_idx_boundaries` proves every returned index is a char boundary, including supplementary-plane and past-the-end columns; `test_context_utf16_column_after_non_ascii` proves the completion heuristic still classifies after a multi-byte character; `test_context_ascii_mid_line_column_unchanged` proves ASCII columns did not shift. A future helper change that returns a mid-character index fails those tests before it reaches hover or completion.

## Related Issues

- Surfaced during review of [PR #30](https://github.com/nehpz/den-lsp/pull/30) (CodeRabbit flagged completion, Devin flagged hover one round later); no standalone GitHub issue exists.
- `docs/solutions/conventions/plan-time-pr-topology-and-real-user-gating.md` — process context: per-round-billed review bots make instance-scoped fixes expensive; the class-audit rule in Prevention item 2 is the code-side counterpart.
- Overlap with existing solution docs assessed Low across all five dimensions; no docs made stale by this learning.
