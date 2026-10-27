#!/usr/bin/env bash

# Licensed under the Apache License, Version 2.0 or the MIT License.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright Tock Contributors 2026.

# For each arch/* crate, print one representative board: the
# alphabetically-first board that depends on it, directly or via its chip.
#
# Reasonably aware of arch dependencies (i.e., `cortexm` picked up by `cortexm7`), and
# avoids duplicates where unneeded (but, e.g., `cortexm4` also necessarily repeats `cortexm`).
#
# Variants of another board (extra feature/policy configs, tutorial
# copies) are skipped, same as boards/README.md's own tooling, since
# they're not independent ports and would just be redundant picks.
# Sorted once so the loop below can stop at the first (alphabetical) match.
boards=($(./tools/build/list_boards.sh | sort | grep -vE '^(configurations|tutorials)/'))

# True if $board depends on arch/$arch, directly or via its chip.
board_depends_on_arch() {
    local board="$1" arch="$2"
    local board_toml="boards/$board/Cargo.toml"
    # Matches a `path = "…/arch/$arch"` dependency line; some Cargo.toml
    # files omit the whitespace around `=`.
    local pattern="path[[:space:]]*=[[:space:]]*\"[^\"]*/arch/$arch\""

    grep -qE "$pattern" "$board_toml" && return 0

    local chip_path chip_toml
    # Pulls the path out of each `chips/*` dependency the board declares.
    for chip_path in $(grep -oE 'path[[:space:]]*=[[:space:]]*"[^"]*/chips/[^"]*"' "$board_toml" | sed -E 's/.*"(.*)"/\1/'); do
        chip_toml="boards/$board/$chip_path/Cargo.toml"
        [ -f "$chip_toml" ] && grep -qE "$pattern" "$chip_toml" && return 0
    done
    return 1
}

# Collected rather than printed as we go, so a failure partway through
# (see below) leaves nothing on stdout instead of an incomplete board list
# -- callers using `$(shell ...)` can't see a nonzero exit status, only
# empty-vs-nonempty output.
found_boards=""

for arch in $(./tools/build/list_archs.sh); do
    found=""
    for board in "${boards[@]}"; do
        if board_depends_on_arch "$board" "$arch"; then
            found="$board"
            break
        fi
    done
    if [ -n "$found" ]; then
        found_boards="$found_boards$found
"
        continue
    fi

    # No board uses this arch directly -- fine if another arch crate does
    # (e.g. cortex-m, picked up by cortex-m4), since it then gets compiled,
    # and so checked, as a side effect of building that arch's own board.
    grep -qE "path[[:space:]]*=[[:space:]]*\"\.\./$arch\"" arch/*/Cargo.toml 2>/dev/null && continue

    echo "error: no board or arch crate depends on arch/$arch" >&2
    exit 1
done

printf '%s' "$found_boards" | sort -u
