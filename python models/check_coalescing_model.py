"""Design-level truth-table check; this does not compile or simulate RTL."""
from itertools import product


def proposed_masks(lines, active):
    """Boolean equations used by the proposed four-representative coalescer."""
    equal = lambda a, b: lines[a] == lines[b]
    masks = [0, 0, 0, 0]
    if active[0]:
        masks[0] = 1
        for tap in (1, 2, 3):
            masks[0] |= int(active[tap] and equal(0, tap)) << tap
    if active[1] and not (active[0] and equal(0, 1)):
        masks[1] = 2
        for tap in (2, 3):
            masks[1] |= int(active[tap] and equal(1, tap)) << tap
    if active[2] and not (active[0] and equal(0, 2)) and not (active[1] and equal(1, 2)):
        masks[2] = 4 | (int(active[3] and equal(2, 3)) << 3)
    if active[3] and not any(active[tap] and equal(tap, 3) for tap in (0, 1, 2)):
        masks[3] = 8
    return masks


def partition_reference(lines, active):
    """Independent specification: equivalence classes, anchored at minimum tap."""
    classes = {}
    for tap, (line, enabled) in enumerate(zip(lines, active)):
        if enabled:
            classes.setdefault(line, []).append(tap)
    result = [0] * 4
    for members in classes.values():
        result[min(members)] = sum(1 << tap for tap in members)
    return result


def main():
    checked = 0
    for lines in product(range(4), repeat=4):
        for active in product((False, True), repeat=4):
            masks = proposed_masks(lines, active)
            expected = partition_reference(lines, active)
            assert masks == expected, (lines, active, masks, expected)
            assert sum(mask.bit_count() for mask in masks) == sum(active)
            for a in range(4):
                for b in range(a + 1, 4):
                    assert (masks[a] & masks[b]) == 0
            checked += 1
    print(f"PASS: {checked} grouping-equation cases match the independent partition reference.")
    print("This is Boolean-model validation, not a SystemVerilog compile or simulation.")


if __name__ == "__main__":
    main()
