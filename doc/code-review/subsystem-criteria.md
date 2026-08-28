# Review criteria by subsystem

Tock applies different standards to different parts of the tree. The same
patch is upkeep in a board crate and significant in `kernel/`. Establish which
directory a change lands in before judging it.

Sources: `AGENTS.md`, `doc/CodeReview.md`, `doc/CodeGoals.md`, `doc/Style.md`,
`doc/ExternalDependencies.md`, and the TRDs under `doc/reference/`.

## Rules that apply everywhere

**The execution model.**

- `core` only, never `std`. No dynamic allocation in the kernel; the `Grant`
  mechanism is the only allocation-like facility, and it is capsule-only.
- No unwinding panics, and panicking is strongly discouraged generally - return
  `Result`/`ErrorCode` instead. Treat a new panicking path in code that runs
  after boot as a finding, not a style note.
- Nightly toolchain, but **no new unstable features**.
- No external dependencies. `doc/ExternalDependencies.md` governs the narrow,
  pre-approved exceptions (`tock-registers`, `flux-rs`); a new entry in any
  `Cargo.toml` `[dependencies]` pointing outside the repo is a significant
  change requiring its own discussion, not something to wave through.
- Conditional compilation (`#[cfg]`, features) is heavily discouraged and must
  be motivated and documented where used.
- This is an OS for constrained devices: code size and RAM are correctness
  concerns, not micro-optimizations.

**`unsafe`.**

- New code in `capsules/`, `chips/`, and `libraries/` may not use `unsafe`
  **at all**. This is a hard rule; report any violation regardless of how
  well-justified the block looks.
- Every `unsafe` must be accompanied by a comment explaining why it is needed
  and why it cannot trigger undefined behavior. The forms are the ones clippy
  defines - `# Safety` as a doc section on an `unsafe fn`
  (`clippy::missing_safety_doc`), and a `// SAFETY:` comment on the block
  (`clippy::undocumented_unsafe_blocks`). Write those two forms; anything else
  is an error to be corrected. See "The safety-comment rule" below for what
  clippy does and does not catch here.
- A `SAFETY:` comment that restates *what* the code does, rather than *why the
  precondition holds*, is not a safety comment. This is worth a finding.
- `unsafe` used where nothing is actually memory- or type-unsafe is itself a
  defect: it should be a safe function, or the invariant should be enforced by
  a capability.
- Conversely: new functionality that is publicly exported and carries
  invariants the type system cannot enforce - especially access to core kernel
  data structures - should be guarded by a capability.

**The safety-comment rule.** Clippy's lints define the convention, so write
what they expect and nothing else:

- `# Safety` as a doc section on an `unsafe fn`, and `// SAFETY:` on the unsafe
  block.
- A safe function must **not** carry a `# Safety` doc section
  (`clippy::unnecessary_safety_doc`). If a function documents preconditions
  under `# Safety` but is not `unsafe`, either the section is wrong or the
  signature is.

**Write new code as if these lints were denied everywhere.** They are not
denied everywhere *yet* - `missing_safety_doc` is currently `allow` in the root
`Cargo.toml`, and `undocumented_unsafe_blocks` sits in the `restriction` group,
which is allowed wholesale - but that is a transitional state, not permission.
[tock/tock#5003](https://github.com/tock/tock/pull/5003) denies
`clippy::missing_safety_doc` for the kernel crate, and the intent is to extend
that across the tree. Undocumented `unsafe` in new code is a defect when it is
written, not when CI eventually starts failing on it.

One consequence for a reviewer: because the lints are not on yet, **nothing in
CI currently checks that unsafe code is documented at all**. That check exists
only in review, which is why it is on this list. A second: clippy is looser
about the *form* than the convention is. `missing_safety_doc` accepts a
`Safety` heading at any level, so `### Safety` satisfies it; and
`undocumented_unsafe_blocks` matches the `SAFETY:` prefix case-insensitively,
so `// safety:` passes. Write `# Safety` and `// SAFETY:` regardless - passing
the lint is the floor, not the standard.

Correcting pre-existing deviations is worthwhile, but belongs in its own pull
request rather than in whatever change is under review.

**Callbacks.** Code must not issue a callback from within a downcall. A
callback may only fire in response to an interrupt or a deferred call. See
`bug-patterns.md` for how to detect a violation.

**Documentation and naming** (`doc/Style.md`).

- `//!` at the top of a file: the first line is a tagline under 80 characters,
  the second line is bare `//!`, then the body. Public modules get one.
- `///` on public functions and data structures. `//` for internal notes and
  for rationale that future readers will need.
- Subtle or extensively-discussed design rationale belongs in the source file,
  not only in the PR thread - the PR thread is not where the next reader looks.
- Descriptive names, no abbreviations: `ArrayIndex` not `ArrayIdx`,
  `ButtonInterrupt` not `BtnInterrupt`.
- `#[inline]` needs an adjacent comment saying why.
- `lib.rs` / `mod.rs` should only wire up modules and exports; OS logic belongs
  in a descriptively named file.
- `static_init!()`, `static_buf!()`, and friends may only be called from board
  crates - and within those, only from `main()` or a `*_component_helper!()`
  macro, never from a component's `finalize()`. (`arch/x86` holds the in-tree
  exception; see `bug-patterns.md` §14 for the bar a non-board use has to
  meet.)

## `kernel/` (excluding HILs)

The highest-scrutiny tree in the repository; everything depends on it.

- Substantial changes should be preceded by a discussion issue, and often need
  a TRD. Flag when a change looks like it needs one and does not have one.
- Every new export widens the surface available to every crate in Tock. Ask
  what stops a capsule from misusing it. Sensitive-but-necessary exports must
  be capability-guarded.
- New files need `//!`; new functions and structures need `///`.
- Check whether the change contradicts a markdown design document or TRD, and
  whether that document was updated alongside.

## `kernel/src/hil/`

- New HILs follow `doc/reference/trd3-hil-design.md`.
- A HIL must not be shaped around one piece of hardware. If the trait mirrors
  a specific peripheral's register layout or quirks, say so.
- Enumerate all valid errors; a HIL that returns a generic failure hides the
  cases implementers need to distinguish.
- Naming consistent with the other HILs.
- Any signature change fans out to every implementer - see "Ripple checks".

## `capsules/`

`capsules/core` holds infrastructure and virtualizers other capsules rely on
and is reviewed closer to kernel standards; `capsules/extra` and the
special-purpose crates (`capsules/system`, `capsules/aes_gcm`,
`capsules/ecdsa_sw`) are more forgiving. Comments should explain what a capsule
does, but capsules do not need to be rigorously documented.

**No `unsafe`, at all, in new capsule code.**

**Syscall drivers** (implementing `SyscallDriver`):

- Must tolerate calls from multiple processes. Full virtualization is not
  required - rejecting all but the first process is acceptable - but the driver
  must not break or misattribute state when a second process calls in.
- Must return `CommandReturn::SUCCESS` for `command_id == 0`.
- The first argument to an upcall is a return code.
- A syscall driver is a userspace veneer over a resource. Functionality that
  would also be useful in-kernel belongs in a separate capsule underneath it.

**Virtualizers:**

- The `Mux` handles all interrupts and routes callbacks to the right user.
- The virtualizer exposes the same HIL it consumes.

## `chips/`

Rarely testable by the reviewer - most review here is careful reading against
the datasheet.

- A peripheral file must implement real functionality. Register-only files, or
  files returning `ErrorCode::NOSUPPORT` from every method, give a false
  impression of support and are not mergeable.
- Register structs must match the datasheet exactly: offsets, reserved padding,
  access types, and field widths. See `bug-patterns.md`.
- Chip-variant `cfg`s are the one broadly accepted use of conditional
  compilation, and only when: confined to a single file, unambiguous from the
  physical hardware, and written as an explicit or'd list of chips.
  `cfg(not(...))` is essentially never right outside unit tests.
- Crate naming should reflect the chip family; nested crates are the norm for
  families sharing implementations.
- No `unsafe` in new chip code.

## `boards/`

Generally deferred to the board's maintainer or original contributor; boards
are examples and starting points and legitimately vary. But:

- Tier matters. `boards/README.md` defines three tiers; a change to a Tier 1
  board carries much more weight than the same change to a Tier 3 board.
- A new board must document how to obtain the hardware and how to run Tock and
  applications on it.
- Board `main.rs` structure: `SyscallDriver` instances belong in the platform
  struct so `with_driver` can dispatch to them. Non-`SyscallDriver` utilities
  do not have to.
- Initialization order is load-bearing and is not checked by the compiler.
  Moving initialization can silently break things a successful build will not
  reveal - for example, `debug!()` before the console is up, or a capsule used
  before its `.start()`.
- `static_init!()` allocations are per-board by construction; watch for
  attempts to hoist them into shared generic helpers.

## `arch/`

Uncommon and high-risk. Any assembly must be documented, including why it has
to be assembly. Interrupt entry/exit, stack setup, and the vector table are the
usual content - changes there deserve line-by-line reading.

## `libraries/`

Logically separable from the kernel and usable outside Tock, so changes can
affect downstream users who are not visible from this repository. Code adopted
from elsewhere must be clearly attributed. No `unsafe` in new code.

## `tools/`

The one tree not bound by the embedded restrictions - `std` is available. Still
needs license headers and formatting.

## Ripple checks

Each of these fans out along a path the compiler will not necessarily walk for
you, because the affected crate may not be in the build you ran.

| Change | What to verify |
| --- | --- |
| A HIL trait signature | Every implementer updated. Grep to find them, then `make ci-job-compilation` (all boards) to prove none were missed - a board build that excludes the changed crate compiles fine while an unbuilt implementer is broken. |
| A capsule's constructor or generic parameters | Its component under `boards/components/` and every board that instantiates it. |
| A `DRIVER_NUM` (`capsules/core/src/driver.rs`) | The numbering is a cross-repository ABI. Check `doc/syscalls/` for the matching document, and expect coordination with `libtock-c` / `libtock-rs`. |
| Any userspace-visible syscall behavior | `doc/syscalls/` and the syscall TRDs; backwards compatibility is an explicit release commitment. |
| A register struct in `chips/` | Every subsequent field's offset - a padding change shifts everything after it. |
| A new `kernel` export | Whether it needs a capability guard; who can now reach it (answer: every crate). |
| A component's `finalize()` | That no `static_init!()` moved into it. |
| Anything documented in `doc/` | The corresponding markdown or TRD updated in the same change. |
| A user-visible change near a release | Whether `CHANGELOG.md` should mention it. |
