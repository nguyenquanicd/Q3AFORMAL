"""Finite-state oracle for the proposed Phase 2 event-mask review."""

from itertools import product

A, B = 1, 2


def transition(state, events, resets=(False, False)):
    x, y = state
    return (
        (0 if resets[0] else y) if events & A else x,
        (0 if resets[1] else x) if events & B else y,
    )


def observe(history, state, events):
    return tuple(
        (value, *samples)[:2] if events & domain else samples
        for domain, value, samples in zip((A, B), state, history)
    )


def check():
    initial = (0, 1)
    assert transition(initial, A | B) == (1, 0)
    assert transition(transition(initial, A), B) == (1, 1)
    assert transition(transition(initial, B), A) == (0, 0)

    atomic_checks = 0
    for state, resets, events in product(product(range(2), repeat=2), product((False, True), repeat=2), range(4)):
        result = transition(state, events, resets)
        for index, domain in enumerate((A, B)):
            expected = state[index]
            if events & domain:
                expected = 0 if resets[index] else state[1 - index]
            assert result[index] == expected
            atomic_checks += 1

    # Compare every five-step schedule against explicit local sampling histories.
    schedules = 0
    for events in product(range(4), repeat=5):
        state = initial
        history = ((), ())
        expected = [[], []]
        for mask in events:
            for index, domain in enumerate((A, B)):
                if mask & domain:
                    expected[index].insert(0, state[index])
            history = observe(history, state, mask)
            assert history == tuple(tuple(samples[:2]) for samples in expected)
            state = transition(state, mask)
        schedules += 1
    print(f"PASS: {atomic_checks} atomic update checks and {schedules} domain-history schedules")


if __name__ == "__main__":
    check()

