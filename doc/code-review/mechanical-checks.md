# Mechanical checks

Run these before the manual passes. They are fast relative to a review, they
catch the whole class of findings that would otherwise waste the author's time,
and a review written against code that does not build is worthless.

All checks are driven by `make` from the repository root. Do not substitute
bare `cargo` invocations - see "Why make, not cargo" below.

## The standard pre-submission gate

```sh
make prepush
```

Runs, in order: `format-check`, `ci-job-clippy`, `ci-job-syntax`,
`licensecheck`. This is what `doc/CodeReview.md` calls the "standard developer
CI" and what a contributor is expected to have run before pushing. If it fails,
report that first - nothing else in the review matters until it passes.

| Target | What it checks |
| --- | --- |
| `make format` (alias `make fmt`) | Applies `cargo fmt`. Run this to *fix*, not to check. |
| `make format-check` | `cargo fmt --check` across the workspace, plus a scan for literal tab characters in `.rs` files. |
| `make clippy` (= `ci-job-clippy`) | Clippy under Tock's *subset* of lints, configured by `clippy.toml`. |
| `make licensecheck` | Every non-exempt file carries a license header. |
| `make ci-job-syntax` | `cargo check` over the workspace with warnings denied. |

## Building the code the change actually touches

The workspace `cargo check` does not build everything, and a passing
`ci-job-syntax` does not mean the affected boards link. Build at least one
board that includes the changed code:

```sh
make -C boards/<board>
```

To find which boards pull in a changed chip or capsule crate:

```sh
grep -rl "<crate-name>" boards/*/Cargo.toml boards/*/*/Cargo.toml
```

Chip and capsule crates are only meaningfully exercised through a board build:
LTO, `panic_handler` selection, linker-symbol resolution, and code size are all
board-level properties. A change to `chips/` that has never been built into a
board has not been compiled the way it will ship.

`make ci-job-compilation` builds *all* boards (slow, but it is what CI does).

## Tests and the heavier jobs

| Target | Use it when |
| --- | --- |
| `make ci-job-libraries` / `ci-job-archs` / `ci-job-kernel` / `ci-job-capsules` / `ci-job-chips` | The change touches that tree; these run the unit tests. |
| `make ci-job-rustdoc` | Doc comments changed, or intra-doc links were added - this is what catches broken links. |
| `make ci-job-msrv` | `Cargo.toml`, toolchain, or language-feature usage changed. |
| `make ci-job-miri` | Changes to unsafe code in the kernel that Miri covers (experimental, limited). |
| `make ci-job-qemu` | Changes that a QEMU-hosted board can exercise. |
| `make ci-all` | Everything CI runs. If this passes locally, upstream CI should pass. |

If a CI check fails upstream, the corresponding `make ci-job-<name>` reproduces
it locally; treating a non-reproducible CI failure as a bug is explicit project
policy.

## License headers on new files

New files need the header at the very top, before the module doc comment:

```rust
// Licensed under the Apache License, Version 2.0 or the MIT License.
// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright Tock Contributors <year>.
```

Use the comment syntax of the file's language (`#` for shell, Makefiles, TOML,
YAML). The year is the year the file was created; do not bump it on edits.
Files that cannot carry comments are exempt via `/.lcignore` - notably `*.md`
and `*.json` - as are a handful of vendored and generated files listed there.
Check that list before reporting a missing header, and check it before adding
an exemption: a new entry in `.lcignore` is itself a review-worthy change.

## Why make, not cargo

- `make clippy` applies `clippy.toml` and Tock's chosen lint subset. Running
  `cargo clippy` directly uses Clippy's defaults and produces a flood of
  failures on existing, accepted code - findings from a bare `cargo clippy` run
  are not reportable.
- `make -C boards/<board>` sets the flags and target the board needs; invoking
  `cargo` from the top-level workspace for a board build hits known problems.

## Notes

- Warnings are denied in `ci-job-syntax` and `ci-job-compilation`. A change that
  builds locally but leaves a warning will fail CI.
- Do not silence a dead-code warning with `#![allow(dead_code)]` to make a check
  pass. It is nearly always a signal that the code is genuinely unreachable, or
  that a board is not wiring it up.
- `licensecheck` walks the working tree, not the index, so it also sees
  untracked scratch files. A complaint about a path the change under review did
  not touch is a local-environment artifact, not a finding - confirm the path is
  actually part of the change before reporting it.
