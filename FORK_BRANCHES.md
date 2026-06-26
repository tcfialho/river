# Fork branch topology

This fork has **two branch lineages on different bases**. They do not share a git
merge-base, so raw line-count diffs between them are huge (~2600 lines) — that is
base divergence, **not lost work**.

## Fork lineage (base `89a0523`)

| Branch | Role | Tip |
| --- | --- | --- |
| `maindeck-animations` | **Legacy** — granular development history | `85d90b7` |
| `maindeck-squashed` | **Canonical** — consolidated, ~8 thematic commits | `78e9da9` |

`maindeck-squashed` contains 100% of `maindeck-animations` plus improvements.
Verified with `git diff maindeck-animations maindeck-squashed`: only `Output.zig`
and `WindowManager.zig` differ, and every difference is an improvement present
only in `maindeck-squashed` (more robust tearing page-flip backoff, FNV-1a
comments, named constants). **Nothing was lost; `maindeck-animations` is safe to
abandon.**

## PR lineage (base = current `main` `d4fef52`)

Eight `pr/*` branches, each `main` + 1 clean commit, intended for opening PRs
upstream:

- `pr/foreign-toplevel-leak-fix`
- `pr/input-optimizations`
- `pr/layer-surface-dedup`
- `pr/lazy-coalesce-8ms`
- `pr/order-hash-fnv`
- `pr/output-commit-dedup`
- `pr/tearing-test-backoff`
- `pr/textinput-log-downgrade`

All eight features are also present in `maindeck-squashed`. In fact
`maindeck-squashed` is **ahead** of the `pr/*` branches: protocol
`WindowManagerV1` v7 (pr branches are v5), FNV-1a render-order hash
(`pr/lazy-coalesce-8ms` still uses Blake3), and `renderAndCommit(output, force)`
for the animation frame loop.

## Note

`maindeck-squashed` sits on the older base `89a0523`, not current `main`.
Rebasing it onto `main` is optional cleanup for alignment only — unrelated to any
content loss.
