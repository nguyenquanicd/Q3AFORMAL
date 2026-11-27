"""Small exact checks for memory collision and paired-model observation semantics."""

from itertools import product


def advance(memory, readout, event, read, write):
    if not event:
        return memory, readout
    if read is not None and not 0 <= read < len(memory):
        raise ValueError("enabled read exceeds depth")
    if write is not None and not 0 <= write[0] < len(memory):
        raise ValueError("enabled write exceeds depth")
    observed = memory[read] if read is not None else readout
    next_memory = list(memory)
    if write is not None:
        next_memory[write[0]] = write[1]
    return tuple(next_memory), observed


def check():
    cases = 0
    for memory, event, read, write_addr, data in product(
        product(range(4), repeat=3), (False, True), (None, 0, 1, 2), (None, 0, 1, 2), range(4)
    ):
        write = None if write_addr is None else (write_addr, data)
        next_memory, observed = advance(memory, 3, event, read, write)
        assert observed == (memory[read] if event and read is not None else 3)
        assert all(
            value == (data if event and address == write_addr else memory[address])
            for address, value in enumerate(next_memory)
        )
        cases += 1
    for read, write in ((3, None), (None, (3, 0))):
        try:
            advance((0, 0, 0), 0, True, read, write)
        except ValueError:
            continue
        raise AssertionError("out-of-range access was accepted")

    histories = 0
    for inputs in product((0, 1), repeat=6):
        reference, encoded, delayed = 0, 1, 0
        mismatch = False
        for data in (1, *inputs):
            assert reference == (1 - encoded)
            reference, encoded, delayed = data, 1 - data, reference
            mismatch |= reference != delayed
        assert mismatch
        histories += 1
    assert 1 != (1 - 1)  # An unconstrained initial pair can violate the observation relation.
    print(f"PASS: {cases} memory transitions, two invalid accesses, and {histories} paired-model histories")


if __name__ == "__main__":
    check()

