#include "sat_solver.hpp"

#include <algorithm>
#include <cstdlib>
#include <deque>
#include <limits>
#include <ostream>
#include <stdexcept>
#include <utility>

namespace q3a::sat {
namespace {

std::size_t literal_index(Literal literal) {
    const auto variable = static_cast<std::uint32_t>(
        literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
    return static_cast<std::size_t>(variable - 1) * 2 + (literal < 0 ? 1 : 0);
}

enum class PropagationKind {
    Stable,
    Conflict,
    LimitReached
};

struct PropagationResult {
    PropagationKind kind = PropagationKind::Stable;
    std::size_t conflict_clause = std::numeric_limits<std::size_t>::max();
};

constexpr std::size_t kNoClause = std::numeric_limits<std::size_t>::max();

struct ClauseView {
    const Literal* first;
    const Literal* last;

    const Literal* begin() const noexcept { return first; }
    const Literal* end() const noexcept { return last; }
    std::size_t size() const noexcept { return static_cast<std::size_t>(last - first); }
    Literal front() const noexcept { return *first; }
    Literal operator[](std::size_t position) const noexcept { return first[position]; }
};

struct WatchPositions {
    // A normalized clause contains at most one literal per DIMACS variable.
    std::uint32_t watch_a = 0;
    std::uint32_t watch_b = 0;
};

} // namespace

std::uint32_t Solver::new_variable() {
    poll_memory();
    if (variable_count_ == static_cast<std::uint32_t>(
            std::numeric_limits<Literal>::max())) {
        throw std::overflow_error("SAT variable identifier exceeds DIMACS literal range");
    }
    return ++variable_count_;
}

void Solver::add_clause(const std::vector<Literal>& input_literals) {
    poll_memory(input_literals.size() * sizeof(Literal));
    std::vector<Literal> literals = input_literals;
    for (const auto literal : literals) {
        if (literal == 0) {
            throw std::invalid_argument("SAT clauses cannot contain the DIMACS terminator 0");
        }
        const auto variable = static_cast<std::uint64_t>(
            literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
        if (variable == 0 || variable > variable_count_) {
            throw std::invalid_argument("SAT clause references an undeclared variable");
        }
    }

    std::sort(literals.begin(), literals.end(), [](Literal left, Literal right) {
        const auto left_var = std::abs(static_cast<std::int64_t>(left));
        const auto right_var = std::abs(static_cast<std::int64_t>(right));
        return left_var == right_var ? left < right : left_var < right_var;
    });
    literals.erase(std::unique(literals.begin(), literals.end()), literals.end());
    for (std::size_t index = 1; index < literals.size(); ++index) {
        if (literals[index - 1] == -literals[index]) {
            return; // A tautology is always satisfied and need not be stored.
        }
    }

    if (literals.empty()) {
        contains_empty_clause_ = true;
        return;
    }

    const auto reserve_append = [this](auto& storage, std::size_t count) {
        if (count > storage.max_size() - storage.size()) {
            throw std::length_error("SAT clause arena exceeds its storage limit");
        }
        const auto required = storage.size() + count;
        if (required <= storage.capacity()) return;
        const auto current = storage.capacity();
        const auto growth = current + std::min(current, storage.max_size() - current);
        const auto capacity = std::max(required, growth);
        if (memory_check_) memory_check_(capacity * sizeof(storage.front()));
        storage.reserve(capacity);
    };
    reserve_append(clause_offsets_, 1);
    reserve_append(clause_literals_, literals.size());
    clause_offsets_.push_back(clause_literals_.size());
    clause_literals_.insert(clause_literals_.end(), literals.begin(), literals.end());
}

void Solver::write_dimacs(std::ostream& output) const {
    output << "p cnf " << variable_count_ << ' ' << clause_count() << '\n';
    for (std::size_t index = 0; index < clause_offsets_.size(); ++index) {
        const auto end = index + 1 < clause_offsets_.size()
            ? clause_offsets_[index + 1] : clause_literals_.size();
        for (auto offset = clause_offsets_[index]; offset < end; ++offset) {
            output << clause_literals_[offset] << ' ';
        }
        output << "0\n";
    }
    if (contains_empty_clause_) output << "0\n";
}

void Solver::poll_memory(std::uint64_t pending_bytes) const {
    if (memory_check_ &&
        (++memory_operations_ % 1024 == 0 || pending_bytes >= 1024 * 1024)) {
        memory_check_(pending_bytes);
    }
}

Result Solver::solve_with_temporary_clause(const std::vector<Literal>& literals) {
    const auto original_offsets = clause_offsets_.size();
    const auto original_literals = clause_literals_.size();
    const auto had_empty_clause = contains_empty_clause_;
    add_clause(literals);
    const auto restore = [&]() noexcept {
        clause_offsets_.resize(original_offsets);
        clause_literals_.resize(original_literals);
        contains_empty_clause_ = had_empty_clause;
    };
    try {
        auto result = solve();
        restore();
        return result;
    } catch (...) {
        restore();
        throw;
    }
}

Result Solver::solve(const Limits& limits,
                     const std::vector<Literal>& assumptions) const {
    return solve_internal(limits, assumptions, nullptr);
}

Result Solver::solve_incremental() {
    return solve_internal({}, {}, &retained_clauses_);
}

Result Solver::solve_internal(const Limits& limits, const std::vector<Literal>& assumptions,
                              std::vector<std::vector<Literal>>* retained) const {
    const auto reused = retained ? retained->size() : 0;
    if (memory_check_) {
        const std::uint64_t variable_slots = std::uint64_t{variable_count_} + 1;
        const auto variable_storage = variable_slots *
            (2 * sizeof(std::vector<std::size_t>) + sizeof(std::size_t) + sizeof(std::uint32_t) +
             sizeof(std::uint64_t) + sizeof(Literal) + sizeof(std::int8_t));
        memory_check_(variable_storage + (clause_offsets_.size() + reused) * sizeof(WatchPositions));
    }
    Result result;
    result.reused_clauses = reused;
    result.assignment.assign(static_cast<std::size_t>(variable_count_) + 1, -1);
    for (const auto literal : assumptions) {
        const auto variable = static_cast<std::uint64_t>(
            literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
        if (literal == 0 || variable > variable_count_) {
            throw std::invalid_argument("SAT assumption references an invalid variable");
        }
    }
    if (limits.record_drat_proof && !assumptions.empty()) {
        throw std::invalid_argument(
            "DRAT recording requires assumptions to be encoded as CNF unit clauses");
    }
    if (limits.proof_sink && !limits.record_drat_proof) {
        throw std::invalid_argument("a DRAT proof sink requires proof recording");
    }
    const auto record_clause = [&](const std::vector<Literal>& clause) {
        if (limits.proof_records != 0 &&
            result.proof_record_count >= limits.proof_records) {
            return false;
        }
        if (limits.proof_sink) limits.proof_sink(clause);
        else result.drat_additions.push_back(clause);
        ++result.proof_record_count;
        return true;
    };
    const auto discard_partial_proof = [&result]() {
        result.drat_additions.clear();
        result.proof_record_count = 0;
    };
    const auto finish_unsat = [&]() {
        if (limits.record_drat_proof && !record_clause({})) {
            discard_partial_proof();
            result.status = Status::Unknown;
        } else {
            result.status = Status::Unsatisfiable;
        }
    };
    if (contains_empty_clause_) {
        result.conflicts = 1;
        finish_unsat();
        return result;
    }

    // Permanent clauses already have offsets in the immutable literal arena.
    // Keep only the watch positions per clause and construct the view on demand.
    std::deque<std::vector<Literal>> learned_literals;
    const auto permanent = clause_offsets_.size();
    const auto literals_at = [&](std::size_t index) -> ClauseView {
        if (index < permanent) {
            const auto start = clause_offsets_[index];
            const auto end = index + 1 < permanent ? clause_offsets_[index + 1] : clause_literals_.size();
            return {clause_literals_.data() + start, clause_literals_.data() + end};
        }
        const auto extra = index - permanent;
        const auto& literals = extra < reused ? (*retained)[extra] : learned_literals[extra - reused];
        return {literals.data(), literals.data() + literals.size()};
    };
    std::vector<WatchPositions> watch_positions;
    watch_positions.reserve(permanent + reused);
    std::vector<std::vector<std::size_t>> watchers(
        static_cast<std::size_t>(variable_count_) * 2);
    const auto attach_clause = [&](std::size_t clause_index, ClauseView literals) {
        const auto second = literals.size() > 1 ? 1U : 0U;
        watch_positions.push_back({0, second});
        watchers[literal_index(literals.front())].push_back(clause_index);
        if (second != 0) {
            watchers[literal_index(literals[second])].push_back(clause_index);
        }
    };
    for (std::size_t clause_index = 0; clause_index < permanent + reused; ++clause_index) {
        poll_memory();
        attach_clause(clause_index, literals_at(clause_index));
    }

    // A decision assigns one variable, so the DIMACS variable limit also bounds the level.
    std::vector<std::uint32_t> decision_level(
        static_cast<std::size_t>(variable_count_) + 1, 0);
    std::vector<std::size_t> reason(
        static_cast<std::size_t>(variable_count_) + 1, kNoClause);
    std::vector<std::uint64_t> activity(
        static_cast<std::size_t>(variable_count_) + 1, 0);
    std::vector<Literal> trail;
    trail.reserve(variable_count_);
    // Each entry stores the trail boundary at which that decision level began.
    std::vector<std::size_t> trail_limits;
    std::size_t propagation_head = 0;
    const auto value_of = [&result](Literal literal) -> std::int8_t {
        const auto variable = static_cast<std::size_t>(
            literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
        const auto value = result.assignment[variable];
        if (value < 0) return -1;
        return static_cast<std::int8_t>((literal > 0) == (value != 0) ? 1 : 0);
    };
    const auto enqueue = [&result, &trail, &value_of, &decision_level,
                          &reason, &trail_limits](Literal literal,
                                                   std::size_t reason_clause) {
        const auto existing = value_of(literal);
        if (existing >= 0) return existing == 1;
        const auto variable = static_cast<std::size_t>(
            literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
        result.assignment[variable] = literal > 0 ? 1 : 0;
        decision_level[variable] = static_cast<std::uint32_t>(trail_limits.size());
        reason[variable] = reason_clause;
        trail.push_back(literal);
        return true;
    };
    const auto propagate = [&]() {
        while (propagation_head < trail.size()) {
            poll_memory();
            if (limits.propagations != 0 &&
                result.propagations >= limits.propagations) {
                return PropagationResult{PropagationKind::LimitReached, kNoClause};
            }
            const auto assigned = trail[propagation_head++];
            ++result.propagations;
            const auto falsified = static_cast<Literal>(-assigned);
            auto& watching_falsified = watchers[literal_index(falsified)];
            std::size_t index = 0;
            while (index < watching_falsified.size()) {
                poll_memory();
                const auto clause_index = watching_falsified[index];
                auto& clause = watch_positions[clause_index];
                const auto literals = literals_at(clause_index);
                const bool watch_a_is_falsified =
                    literals[clause.watch_a] == falsified;
                const auto false_watch = watch_a_is_falsified
                    ? clause.watch_a : clause.watch_b;
                const auto other_watch = watch_a_is_falsified
                    ? clause.watch_b : clause.watch_a;
                const auto other_literal = literals[other_watch];

                if (value_of(other_literal) == 1) {
                    ++index;
                    continue;
                }

                std::size_t replacement = literals.size();
                for (std::size_t candidate = 0;
                     candidate < literals.size(); ++candidate) {
                    if (candidate == false_watch || candidate == other_watch) continue;
                    if (value_of(literals[candidate]) != 0) {
                        replacement = candidate;
                        break;
                    }
                }
                if (replacement < literals.size()) {
                    if (watch_a_is_falsified) {
                        clause.watch_a = static_cast<std::uint32_t>(replacement);
                    } else {
                        clause.watch_b = static_cast<std::uint32_t>(replacement);
                    }
                    watchers[literal_index(literals[replacement])].push_back(
                        clause_index);
                    watching_falsified[index] = watching_falsified.back();
                    watching_falsified.pop_back();
                    continue;
                }

                if (!enqueue(other_literal, clause_index)) {
                    return PropagationResult{PropagationKind::Conflict, clause_index};
                }
                ++index;
            }
        }
        return PropagationResult{PropagationKind::Stable, kNoClause};
    };

    for (std::size_t clause_index = 0; clause_index < watch_positions.size(); ++clause_index) {
        const auto literals = literals_at(clause_index);
        if (literals.size() == 1 && !enqueue(literals.front(), clause_index)) {
            result.conflicts = 1;
            finish_unsat();
            return result;
        }
    }
    for (const auto assumption : assumptions) {
        if (!enqueue(assumption, kNoClause)) {
            result.conflicts = 1;
            finish_unsat();
            return result;
        }
    }

    auto propagation = propagate();
    if (propagation.kind == PropagationKind::LimitReached) {
        result.status = Status::Unknown;
        discard_partial_proof();
        return result;
    }
    if (propagation.kind == PropagationKind::Conflict) {
        result.conflicts = 1;
        finish_unsat();
        return result;
    }

    // Keep the root assignments (level zero) and discard every decision level
    // above the conflict-analysis target before asserting the learned clause.
    const auto backtrack = [&result, &trail, &propagation_head,
                            &trail_limits, &decision_level, &reason](
                               std::size_t target_level) {
        if (target_level >= trail_limits.size()) {
            throw std::logic_error("SAT conflict analysis requested an invalid backtrack level");
        }
        const auto target_trail_size = trail_limits[target_level];
        while (trail.size() > target_trail_size) {
            const auto literal = trail.back();
            trail.pop_back();
            const auto variable = static_cast<std::size_t>(
                literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
            result.assignment[variable] = -1;
            decision_level[variable] = 0;
            reason[variable] = kNoClause;
        }
        trail_limits.resize(target_level);
        propagation_head = std::min(propagation_head, trail.size());
    };

    const auto bump_activity = [&activity](std::size_t variable) {
        if (activity[variable] == std::numeric_limits<std::uint64_t>::max()) {
            for (auto& score : activity) score /= 2;
        }
        ++activity[variable];
    };

    // Resolve the conflict graph backward through the trail until one current
    // decision-level literal remains (the 1-UIP asserting literal).
    const auto analyze_conflict = [&](std::size_t conflict_clause) {
        const auto current_level = trail_limits.size();
        std::vector<std::uint8_t> seen(
            static_cast<std::size_t>(variable_count_) + 1, 0);
        std::vector<Literal> learned(1, 0);
        std::size_t paths_at_current_level = 0;
        std::size_t trail_index = trail.size();
        Literal resolved = 0;
        auto clause_index = conflict_clause;

        do {
            if (clause_index >= watch_positions.size()) {
                throw std::logic_error("SAT conflict analysis referenced a missing reason clause");
            }
            for (const auto literal : literals_at(clause_index)) {
                const auto variable = static_cast<std::size_t>(
                    literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
                if ((resolved != 0 && variable == static_cast<std::size_t>(
                        resolved < 0 ? -static_cast<std::int64_t>(resolved) : resolved)) ||
                    seen[variable] != 0 || decision_level[variable] == 0) {
                    continue;
                }
                seen[variable] = 1;
                bump_activity(variable);
                if (decision_level[variable] == current_level) {
                    ++paths_at_current_level;
                } else {
                    learned.push_back(literal);
                }
            }

            do {
                if (trail_index == 0) {
                    throw std::logic_error("SAT conflict analysis exhausted the assignment trail");
                }
                resolved = trail[--trail_index];
            } while (seen[static_cast<std::size_t>(resolved < 0
                ? -static_cast<std::int64_t>(resolved) : resolved)] == 0);

            const auto resolved_variable = static_cast<std::size_t>(
                resolved < 0 ? -static_cast<std::int64_t>(resolved) : resolved);
            seen[resolved_variable] = 0;
            if (paths_at_current_level == 0) {
                throw std::logic_error("SAT conflict analysis found no current-level path");
            }
            --paths_at_current_level;
            if (paths_at_current_level != 0) {
                clause_index = reason[resolved_variable];
                if (clause_index == kNoClause) {
                    throw std::logic_error("SAT conflict analysis reached a decision before the UIP");
                }
            }
        } while (paths_at_current_level != 0);

        learned[0] = static_cast<Literal>(-resolved);
        std::size_t backtrack_level = 0;
        if (learned.size() > 1) {
            std::size_t highest = 1;
            for (std::size_t index = 1; index < learned.size(); ++index) {
                const auto variable = static_cast<std::size_t>(
                    learned[index] < 0
                        ? -static_cast<std::int64_t>(learned[index])
                        : learned[index]);
                if (decision_level[variable] > backtrack_level) {
                    backtrack_level = decision_level[variable];
                    highest = index;
                }
            }
            std::swap(learned[1], learned[highest]);
        }
        return std::pair<std::vector<Literal>, std::size_t>{
            std::move(learned), backtrack_level};
    };

    std::uint32_t next_unassigned = 1;
    for (;;) {
        poll_memory();
        propagation = propagate();
        if (propagation.kind == PropagationKind::LimitReached) {
            result.status = Status::Unknown;
            discard_partial_proof();
            return result;
        }
        if (propagation.kind == PropagationKind::Conflict) {
            ++result.conflicts;
            if (trail_limits.empty()) {
                finish_unsat();
                return result;
            }
            auto learned = analyze_conflict(propagation.conflict_clause);
            const auto current_level = trail_limits.size();
            const auto target_level = learned.second;
            if (target_level < current_level) {
                ++result.backjumps;
                if (current_level - target_level > 1) {
                    ++result.nonchronological_backjumps;
                }
            }
            backtrack(learned.second);
            learned_literals.push_back(std::move(learned.first));
            const auto& literals = learned_literals.back();
            const auto learned_index = watch_positions.size();
            attach_clause(learned_index, {literals.data(), literals.data() + literals.size()});
            ++result.learned_clauses;
            if (limits.record_drat_proof && !record_clause(literals)) {
                result.status = Status::Unknown;
                discard_partial_proof();
                return result;
            }
            if (!enqueue(literals.front(), learned_index)) {
                throw std::logic_error("SAT learned clause is not asserting after backtracking");
            }
            continue;
        }

        std::uint32_t selected = 0;
        if (result.conflicts == 0) {
            // Activity scores are zero and no assignment has been undone.
            // Continue from the first possible unassigned variable.
            while (next_unassigned <= variable_count_ && result.assignment[next_unassigned] >= 0) {
                ++next_unassigned;
            }
            if (next_unassigned <= variable_count_) selected = next_unassigned;
        } else {
            std::uint64_t best_activity = 0;
            for (std::uint32_t variable = 1; variable <= variable_count_; ++variable) {
                if (result.assignment[variable] < 0 &&
                    (selected == 0 || activity[variable] > best_activity)) {
                    selected = variable;
                    best_activity = activity[variable];
                }
            }
        }
        if (selected == 0) {
            for (std::size_t clause_index = 0; clause_index < watch_positions.size(); ++clause_index) {
                bool satisfied = false;
                for (const auto literal : literals_at(clause_index)) {
                    if (value_of(literal) == 1) {
                        satisfied = true;
                        break;
                    }
                }
                if (!satisfied) {
                    throw std::logic_error(
                        "SAT solver produced a model that violates a stored clause");
                }
            }
            for (const auto assumption : assumptions) {
                if (value_of(assumption) != 1) {
                    throw std::logic_error(
                        "SAT solver produced a model that violates an assumption");
                }
            }
            result.status = Status::Satisfiable;
            discard_partial_proof();
            if (retained) {
                // No watches or clause views are read after this point. Reuse
                // only globally entailed clauses from permanent-formula solves.
                constexpr std::size_t maximum_clauses = 1024;
                constexpr std::size_t maximum_literals = 16384;
                std::size_t stored_literals = 0;
                for (const auto& clause : *retained) stored_literals += clause.size();
                for (auto& clause : learned_literals) {
                    if (retained->size() == maximum_clauses) break;
                    if (clause.size() > maximum_literals - stored_literals) continue;
                    stored_literals += clause.size();
                    retained->push_back(std::move(clause));
                }
            }
            return result;
        }
        if (limits.decisions != 0 && result.decisions >= limits.decisions) {
            result.status = Status::Unknown;
            discard_partial_proof();
            return result;
        }
        const auto literal = static_cast<Literal>(selected); // Stable positive-first phase.
        trail_limits.push_back(trail.size());
        ++result.decisions;
        if (!enqueue(literal, kNoClause)) {
            throw std::logic_error("SAT decision attempted to contradict an assigned variable");
        }
    }
}

const char* status_name(Status status) noexcept {
    switch (status) {
    case Status::Satisfiable: return "SAT";
    case Status::Unsatisfiable: return "UNSAT";
    case Status::Unknown: return "UNKNOWN";
    }
    return "UNKNOWN";
}

} // namespace q3a::sat
