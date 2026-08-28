#!/usr/bin/env bash

# Licensed under the Apache License, Version 2.0 or the MIT License.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright Tock Contributors 2026.

# For each arch/* crate actually depended on by some board or its chip,
# print one representative board: the alphabetically-first board that
# depends on that arch crate (directly, or via its chip).
#
# Any *other* arch crate a found one in turn depends on (e.g. cortexm4f
# on cortexv7m on cortexm) gets compiled -- and so checked -- as a side
# effect of building it, without needing its own separate pick.
#
# Variants of another board (extra feature/policy configs, tutorial
# copies) are skipped, same as boards/README.md's own tooling, since
# they're not independent ports and would just be redundant picks.

declare -A arch_board

record_arch_deps() {
    local board="$1" toml="$2"
    local arch_path arch
    for arch_path in $(grep -oE 'path[[:space:]]*=[[:space:]]*"[^"]*/arch/[^"]*"' "$toml" | sed -E 's/.*"(.*)"/\1/'); do
        arch=$(basename "$arch_path")
        if [ -z "${arch_board[$arch]}" ] || [[ "$board" < "${arch_board[$arch]}" ]]; then
            arch_board[$arch]="$board"
        fi
    done
}

for board in $(./tools/build/list_boards.sh); do
    case "$board" in
        configurations/*|tutorials/*) continue ;;
    esac

    board_toml="boards/$board/Cargo.toml"
    # A board can depend on an arch crate directly (some do, alongside
    # their chip -- e.g. for board-specific interrupt/startup code), not
    # just transitively through its chip.
    record_arch_deps "$board" "$board_toml"
    for chip_path in $(grep -oE 'path[[:space:]]*=[[:space:]]*"[^"]*/chips/[^"]*"' "$board_toml" | sed -E 's/.*"(.*)"/\1/'); do
        chip_toml="boards/$board/$chip_path/Cargo.toml"
        [ -f "$chip_toml" ] && record_arch_deps "$board" "$chip_toml"
    done
done

for arch in "${!arch_board[@]}"; do
    echo "${arch_board[$arch]}"
done | sort -u
