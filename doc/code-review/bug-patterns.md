# Tock defect classes

The bugs that matter in this codebase mostly come from a handful of recurring
patterns. None of them are caught by rustc or clippy: the code compiles, the
board boots, and the driver wedges on the third error path six months later.

Each entry below gives what it looks like, how to confirm it is real, and the
direction of the fix. Confirm before reporting - several of these have benign
look-alikes.

---

## 1. Callback issued from within a downcall

**Rule.** A callback may only be issued in response to an interrupt or a
deferred call. Never synchronously from a downcall (a `command`, an `allow`, or
a HIL method call from above).

**Signature.** Inside `SyscallDriver::command`, or inside a HIL method
implementation, a path that reaches `upcall.schedule(...)` or
`self.client.map(|c| c.some_callback(...))` without going through an interrupt
or a `DeferredCall`. Typically on an early-return path: "the operation is
trivial / already complete / invalid, so just call the client back now."

**Confirm.** Trace every return path of the downcall. Any client or upcall
invocation reachable without leaving the call stack is a violation. Watch for
indirection - a helper that "completes the operation" may itself call back.

**Why it matters.** Callers do not expect re-entrancy at the point of the call.
This produces reentrancy bugs, inverted state machines, and stack growth that
depends on client behavior.

**Fix.** Schedule a `DeferredCall` and issue the callback from
`handle_deferred_call`.

---

## 2. Buffer lost from a `TakeCell` on an error path

**Signature.** `self.buffer.take()` (or a `.map()` that consumes the buffer),
passing it to a HIL call, then an early return on a path that does not put it
back.

**Confirm.** For every `.take()`, enumerate the return paths that follow. Each
one must either hand ownership onward to something that will return it via a
callback, or `.replace()` it. One path that does neither loses a
`&'static mut` buffer permanently.

**Why it matters.** There is no allocator. A lost static buffer is gone for the
lifetime of the board: the driver silently stops working, usually with no
panic, no log, and no obvious relationship to the operation that failed.

**Fix.** Replace the buffer before every early return, or restructure so the
buffer is only taken on the path that will actually use it.

---

## 3. Buffer returned inside an `Err` and then dropped

**Signature.** Tock HILs hand the buffer back on failure:

```rust
fn transmit_buffer(&self, tx_buffer: &'static mut [u8], tx_len: usize)
    -> Result<(), (ErrorCode, &'static mut [u8])>;
```

The bug is `let _ = uart.transmit_buffer(buf, len);`, or a match arm that reads
the `ErrorCode` and ignores the buffer beside it.

**Confirm.** Look for `let _ =`, `.ok()`, and `if let Err(e)` (binding only the
code) on any HIL call whose error type carries a buffer.

**Fix.** Destructure the buffer out of the error and return it to its cell.

---

## 4. Deferred call never registered

**Signature.** A capsule holds a `DeferredCall` and implements
`DeferredCallClient`, but nothing ever calls `register()`. `handle_deferred_call`
is then dead code and the callback never fires.

**Confirm.** `register()` is normally called from board or component setup.
Check the boards and components that instantiate the capsule for the
registration call.

**Fix.** Register in the component's `finalize()` or in board setup, alongside
the other client wiring.

---

## 5. Syscall driver breaks with a second process

**Rule.** Drivers need not be virtualized, but must not break when a second
process calls in.

**Signature.** Per-driver state that should be per-process: a
`current_process: OptionalCell<ProcessId>` that is set but never checked, a
single shared buffer handed to whichever process asked last, or a
`Grant::enter` result whose `Err` arm silently does nothing.

**Confirm.** Walk the driver as two processes: A starts an operation, B issues
the same command before A's callback arrives. Does B's request overwrite A's
state? Does A's callback go to B?

**Fix.** Put per-process state in the grant, and reject or queue concurrent
requests explicitly (`ErrorCode::BUSY`).

---

## 6. `command_id == 0` does not return `SUCCESS`

Command 0 is the existence check. A driver whose match falls through to
`CommandReturn::failure(ErrorCode::NOSUPPORT)` for command 0 reports itself as
absent, and userspace will not use it. Cheap to check, easy to get wrong on a
new driver.

---

## 7. Read-modify-write on an event or write-1-to-clear register

**Signature.** `regs.events_foo.modify(...)`, or a read-then-write sequence, on
a register whose hardware semantics are "write 1 to clear" or "event flags".

**Confirm.** Check the datasheet semantics of the register and its declared
type in the chip's register struct.

**Why it matters.** A read-modify-write reads pending bits that hardware set
after the read and writes them back as ones - clearing events the driver never
handled. The failure is intermittent, timing-dependent, and presents as "the
peripheral occasionally stops delivering interrupts."

**Fix.** Write only the target bit (`.write()` / `.set()`); never
read-modify-write a W1C register.

---

## 8. Interrupt pending-bit ordering

**Signature.** In an interrupt path: clearing the chip-level interrupt flag, or
the interrupt controller's pending bit, at the wrong point relative to
servicing the peripheral.

**Confirm.** Establish the intended order: clear the peripheral's source flag,
service the peripheral, then handle the controller-level pending state.
Clearing a controller pending bit *after* the handler runs discards an
interrupt that re-asserted during the handler; clearing the peripheral source
*after* servicing can re-enter for an event already handled.

**Why it matters.** A dropped re-assertion is a hang - the driver waits forever
for an interrupt that already happened.

---

## 9. Register struct offset drift

**Signature.** A field added, removed, or resized in a `#[repr(C)]` register
struct or a `register_structs!` block without the padding being adjusted.

**Confirm.** For a manual `#[repr(C)]` struct with `_reservedN: [u32; N]`
padding, recompute the offsets from the datasheet base for every field *after*
the change - one wrong padding entry silently shifts everything below it.
`register_structs!` with explicit offsets and `@END` checks this at compile
time; a manual struct does not.

**Why it matters.** Reads and writes go to the wrong registers, on hardware the
reviewer usually cannot test.

**Fix.** Prefer `register_structs!` with explicit offsets for new code.

---

## 10. New panicking paths

**Signature.** `unwrap()`, `expect()`, direct slice indexing `buf[i]`, `+`/`-`
on values derived from userspace or hardware, division by a computed value,
slicing with computed ranges.

**Confirm.** Can the panicking condition be reached after boot, from userspace
input, or from a hardware value? Board `main()` is where panics are tolerated -
a misconfigured board should fail loudly at boot. A capsule servicing a syscall
is not.

**Why it matters.** Tock does not unwind. A kernel panic takes the whole system
down, including unrelated processes.

**Fix.** `Result`/`ErrorCode` propagation, `get()` over indexing, and
`checked_`/`saturating_`/`wrapping_` arithmetic chosen deliberately.

---

## 11. Time arithmetic without wrapping semantics

**Signature.** Comparing or subtracting `Ticks` values with `<`, `>`, or `-`.

**Confirm.** The counter wraps. `Ticks` provides `wrapping_add`,
`wrapping_sub`, and `within_range` precisely because naive comparison breaks
across the wrap point. `Alarm::set_alarm` takes `reference` and `dt` separately
so it can distinguish an alarm that just passed from one in the far future;
code that collapses those into a single absolute value has reintroduced the
bug.

**Why it matters.** It fires once per wrap period - an alarm that never fires,
or fires immediately, at an interval nobody reproduces during review.

---

## 12. `unsafe` where it is banned, or unexplained

- Any `unsafe` in new `capsules/`, `chips/`, or `libraries/` code is a hard
  violation - report it regardless of justification.
- Missing `# Safety` doc section on an `unsafe fn`, or a missing `// SAFETY:`
  on an unsafe block, is a finding on its own. Judge new code as if
  `clippy::missing_safety_doc` and `clippy::undocumented_unsafe_blocks` were
  denied tree-wide. They are not yet - both are `allow` today, so **CI will not
  catch this** and review is the only thing that will - but
  [tock/tock#5003](https://github.com/tock/tock/pull/5003) turns
  `missing_safety_doc` into a hard error for the kernel crate, and the direction
  is tree-wide.
- A `# Safety` doc section on a function that is *not* `unsafe` is also a
  defect (`clippy::unnecessary_safety_doc`, which is enabled): either the
  section is wrong or the signature is.
- Write `# Safety` and `// SAFETY:` exactly. Clippy is looser than that - it
  accepts a `Safety` heading at any level and matches `SAFETY:`
  case-insensitively - so `### Safety` and `// safety:` pass the lint while
  still being wrong. Correct them in a separate pull request, not in the change
  under review.
- A `SAFETY:` comment that describes *what* the code does rather than *why the
  precondition is satisfied* does not discharge the requirement.
- `unsafe` on a function with no actual memory- or type-safety precondition is
  a defect in the other direction: it should be safe, or the invariant belongs
  in a capability.

---

## 13. Code size and RAM regressions

**Signature.** A generic parameter added to a widely-instantiated type
(monomorphized per instantiation); `debug!()` with formatting arguments added
to a common path (pulls in formatting machinery); a large `const` table; a
buffer sized generously "to be safe".

**Confirm.** Build an affected board before and after and compare - `make -C
boards/<board>` reports size, and `make -C boards/<board> stack-analysis`
covers stack. Do not assert a size regression you have not measured.

**Why it matters.** Some targets sit near their flash and RAM limits; a change
that is free on one board can make another unbuildable.

---

## 14. `static_init!()` misplacement

**Signature.** `static_init!()` or `static_buf!()` outside a board crate, or
inside a component's `finalize()`, or inside a function that can be called more
than once.

**Why it matters.** Each expansion is a distinct static allocation. Calling it
twice hands out two "singletons" that each believe they own the hardware.

**Note.** `static_init!()`'s type argument cannot name the type parameter of an
enclosing generic function (`E0401`), which is why boards that share code via
generics still keep their own allocations. A change that appears to consolidate
these deserves a close look.

**Known exception - check before reporting.** The rule is "board crates only",
but `arch/x86` calls `static_init!()` from `unsafe fn init()` in
`segmentation.rs` and `interrupts/idt.rs`, where call-once is a documented
safety precondition of the function rather than a structural guarantee. That is
the accepted shape for a non-board use: `unsafe fn`, with `/// # Safety` stating
that calling it twice is the caller's problem. Judge new non-board uses against
that bar instead of rejecting them on sight.

---

## 15. Busy-wait in an interrupt-driven kernel

**Signature.** `while !regs.status.is_set(...) {}` outside board or chip
initialization.

**Why it matters.** Tock's kernel is non-blocking. A spin loop in a capsule or
in an interrupt-driven driver path blocks every process and every other
peripheral for its duration.

**Acceptable.** Early hardware init (clock startup, calibration) before the
scheduler runs, where the wait is bounded and documented.

---

## 16. Client never set, callback never delivered

**Signature.** A capsule with `set_client()` that no board or component calls,
or a component `finalize()` that wires some clients but not all of them.

**Confirm.** The client is stored in an `OptionalCell` and the callback site is
`self.client.map(...)`, so an unset client is a silent no-op - it compiles,
boots, and does nothing.

---

## 17. Swallowed errors

**Signature.** `let _ = ...;` on a fallible call, an empty `Err(_) => {}` arm,
or a `Result` from a HIL call that is dropped.

**Confirm.** Distinguish deliberate from accidental. Deliberate is fine when
the call genuinely cannot fail meaningfully - but it should say so in a
comment. Accidental swallowing hides exactly the hardware failures that are
hardest to debug in the field.

---

## 18. Initialization-order dependencies in board setup

**Signature.** Initialization code moved, reordered, or extracted into a helper
during a refactor.

**Confirm.** Board `main()` has ordering constraints the type system does not
express: the console must exist before `debug!()` produces output, a capsule's
`.start()` must follow the setup it depends on, and interrupts should not be
enabled before their handlers are wired. A successful build proves none of
this.

**Fix.** Verify by running the board (QEMU where available) rather than by
reading, and say in the report which way you checked.

---

## 19. Aliasing a buffer handed to hardware

**Signature.** A `&'static mut [u8]` passed to a DMA engine while a reference
to the same memory is still live in the driver; taking `&mut` of a
`static mut`; constructing a slice over a hardware-owned region.

**Confirm.** After handing a buffer to hardware, the driver must not touch it
until the completion interrupt. Also check that the pointer and length actually
programmed into the registers are the ones the buffer describes.

---

## 20. `ErrorCode` misuse

**Signature.** `NOSUPPORT` where `INVAL` is meant, `FAIL` as a catch-all, or a
new HIL method whose error cases are not enumerated in its documentation.

**Why it matters.** `ErrorCode` values cross into userspace, and callers make
recovery decisions on them; a driver that returns `FAIL` for everything gives
them nothing to act on. `NOSUPPORT` from every method of a peripheral is also a
merge blocker in `chips/` - it advertises hardware support that does not exist.

---

## Sweep recipes

Starting points, not conclusions - every hit needs the confirmation step from
its section above. These greps are deliberately over-broad; on the tree as a
whole each returns dozens to hundreds of hits, most of them macro definitions,
doc-comment examples, and generic bounds. Run them over the *changed files*,
not the repository, unless you are specifically hunting for a pattern.

```sh
# Dropped results and swallowed errors in the changed files
grep -n "let _ =\|\.ok()\|Err(_) => {}" <changed-file>

# Panicking constructs
grep -n "unwrap()\|expect(\|panic!\|unreachable!" <changed-file>

# unsafe in trees where new code may not use it
grep -rn "unsafe" --include=*.rs capsules chips libraries

# take() without a matching replace() in a changed file
grep -n "\.take()\|\.replace(" <changed-file>

# static_init! outside board crates - filter out the macro definition in
# kernel/src/utilities/static_init.rs and hits inside comment blocks
grep -rn "static_init!(\|static_buf!(" --include=*.rs kernel capsules chips arch

# Implementers of a changed HIL trait. This also matches generic bounds
# ("impl<'a, A: Alarm<'a>> SomethingElse for ..."), so read each hit: only the
# trait immediately preceding `for` is an implementation.
grep -rn "impl.*<Trait><.*> for" --include=*.rs chips capsules boards
```

For a trait signature change, grep is the wrong instrument for the final
answer: `make ci-job-compilation` builds every board and will fail on every
implementer that was missed. Use the grep to find them, and the all-boards build
to prove none were missed - a board build that does not include the changed
crate will happily compile while an unbuilt implementer is broken.
