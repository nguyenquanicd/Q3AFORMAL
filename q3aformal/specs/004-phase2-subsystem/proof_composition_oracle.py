"""Independent exhaustive oracle for the proposed acyclic composition example."""

from itertools import product


def reachable(producer_holds_zero, invert_binding):
    seen = {(0, 0)}
    frontier = set(seen)
    while frontier:
        updated = set()
        for producer, consumer in frontier:
            for external in (0, 1):
                next_producer = (producer & external) if producer_holds_zero else external
                next_consumer = producer ^ invert_binding
                updated.add((next_producer, next_consumer))
        frontier = updated - seen
        seen.update(frontier)
    return seen


def check():
    assert all(
        producer != 0 or (producer & external) == 0
        for producer, external in product(range(2), repeat=2)
    )
    assert all(producer != 0 or (producer ^ 0) == 0 for producer in range(2))
    assert all(consumer == 0 for _, consumer in reachable(True, 0))

    producer_mutation = reachable(False, 0)
    wiring_mutation = reachable(True, 1)
    assert any(consumer == 1 for _, consumer in producer_mutation)
    assert any(consumer == 1 for _, consumer in wiring_mutation)

    # For x' = y and y' = x, each local assumption suffices for its own next-state claim.
    transitions = [((x, y), (y, x)) for x, y in product(range(2), repeat=2)]
    assert all(y != 0 or next_x == 0 for (_, y), (next_x, _) in transitions)
    assert all(x != 0 or next_y == 0 for (x, _), (_, next_y) in transitions)
    # The circular proof has no checked initiation for this legal initial state.
    assert ((1, 1), (1, 1)) in transitions
    print("PASS: valid acyclic composition, producer mutation, wiring mutation, and circular counterexample")


if __name__ == "__main__":
    check()

