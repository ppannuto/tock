Tock Code Review Checklist
==========================

A detailed review procedure for a Tock change set, for human reviewers and for
AI coding assistants alike.

[`doc/CodeReview.md`](../CodeReview.md) describes the *process* by which pull
requests are handled - who reviews, what counts as significant, how votes work.
This directory describes the *content* of a review: what to look for, how to
confirm it, and how to report it.

Most of what matters in a Tock review is invisible to `rustc` and `clippy`.
The rules are properties of the execution model - no dynamic allocation, no
unwinding, callbacks only from interrupts or deferred calls, static resource
ownership - rather than of the type system. Code that violates them compiles
cleanly, links, and boots.

The material is split so that a reviewer only reads what a given change calls
for:

- **[Mechanical checks](mechanical-checks.md)** - the `make` targets to run,
  which boards a given change has to be built into, license headers.
- **[Subsystem criteria](subsystem-criteria.md)** - what changes to `kernel/`,
  HILs, `capsules/`, `chips/`, `boards/`, `arch/`, and `libraries/` are each
  held to, plus the ripple checks a change fans out along.
- **[Defect classes](bug-patterns.md)** - twenty recurring Tock bugs, each with
  what it looks like, how to confirm it is real, and the direction of the fix.

## When to run this

This is a heavy-weight pass. It reads surrounding code, builds boards, and
produces a written report; that cost is only worth paying against a body of
work complete enough to judge. Appropriate occasions:

- A milestone worth reviewing as a unit is finished: a new capsule, a chip
  peripheral, a board, a refactor spanning several crates.
- A change is about to be submitted upstream, or an open pull request is about
  to be updated.
- Someone asks for a review of a branch, pull request, or diff.

It is not a per-edit check. `make prepush` fills that role, and this procedure
runs it rather than replacing it.

## Procedure

**1. Establish scope.** Identify what is under review and read all of it:

```sh
git fetch origin
git diff --stat $(git merge-base HEAD origin/master)..HEAD    # branch
git diff --stat                                               # working tree
```

Group the changed files by subsystem; the criteria genuinely differ per
directory. Read the surrounding code, not just the diff hunks - whether a
buffer is replaced on *every* return path, or whether a callback is reachable
from a downcall, is a property of the whole function, not of a hunk.

Note the change's weight class while you are here.
[`doc/CodeReview.md`](../CodeReview.md) splits pull requests into "upkeep" and
"significant"; a change that crosses into "significant" (new traits, kernel
components, new modules, build system changes) needs review by the whole core
team, which is worth knowing early.

**2. Run the mechanical checks.** See
[mechanical-checks.md](mechanical-checks.md). Doing this first keeps review
attention off what tooling would have caught, and avoids writing a review
against code that does not build.

**3. Subsystem pass.** Walk each changed subsystem against
[subsystem-criteria.md](subsystem-criteria.md).

**4. Defect-class pass.** Walk the change against
[bug-patterns.md](bug-patterns.md). This is where most real findings come from.

**5. Ripple check.** Tock changes propagate along paths the compiler will not
walk for you when a crate is outside the build you ran. Changed HIL traits,
capsule constructors, register structs, `DRIVER_NUM` values, and new kernel
exports each have a fan-out; the recipes are in
[subsystem-criteria.md](subsystem-criteria.md) under "Ripple checks".

**6. Verify every finding before reporting it.** This step decides whether the
review is useful or noise.

- Confirm each finding against the actual code. Pattern-matching on a diff
  produces confident, wrong findings; open the file and follow the path.
- State a concrete failure scenario: the inputs, hardware state, or call
  sequence that reaches the bug, and what goes wrong. If you cannot construct
  one, it is a suggestion or a style note, not a bug - label it as such, or
  drop it.
- Separate defects introduced by the change from pre-existing ones. Both are
  worth raising; conflating them wastes the author's time.
- Prefer dropping an uncertain finding over padding the report. A review whose
  every item survives scrutiny gets acted on; three real findings buried among
  nine speculative ones do not.
- Where a claim depends on hardware behavior that was not tested, say so rather
  than asserting it.

**7. Keep unrelated fixes out of the change under review.** A review commonly
turns up pre-existing convention violations near the code being changed. Those
belong in their own pull request, not folded into this one - a self-contained
change is the first thing `doc/CodeReview.md` asks for. Note them for the
author and move on.

## Reporting

Order findings by severity, most severe first. For each: a `file.rs:LINE`
anchor, one sentence stating the defect, the failure scenario, and a suggested
direction only where you are confident in it.

Close with what was checked and, explicitly, what was not: boards not built,
hardware unavailable, tests not run. Silence reads as "checked and fine", so
make the gaps visible.

Cite the rule a finding rests on ([`AGENTS.md`](../../AGENTS.md),
[`doc/CodeReview.md`](../CodeReview.md), [`doc/Style.md`](../Style.md), a TRD in
[`doc/reference/`](../reference)) so the author can check it rather than take it
on faith.

### A note for AI coding assistants

Under Tock's [AI policy](../../.github/CONTRIBUTING.md#ai-policy), the
contributor - not the tool - is responsible for reviewing AI-generated code for
correctness and for Tock's expectations, and must disclose in the pull request
description which tool was used, what portion of the patch it produced, and how
that output was reviewed.

A review produced by following this document is input to that person, not a
substitute for it. Deliver findings as technical points they can check and act
on. State the three disclosure facts plainly so they can write the disclosure
themselves; it is a statement about their process, and only they can make it.
