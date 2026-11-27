#include "memory_proof.hpp"
#include "../lowering/state_transition.hpp"
#include "../replay/property_replay.hpp"
#include "../sat/transition_encoder.hpp"
#include "../bundle/indexed_trace.hpp"
#include "../bundle/windows_file_path.hpp"
#include "write_locked_input.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <fstream>

namespace q3a::memory_proof {
namespace {

void require_assertion(const lowering::TIRModule& model, const std::string& name) {
    const auto matches = std::count_if(model.properties.begin(), model.properties.end(),
        [&](const auto& item) { return item.name == name && item.kind == "assert"; });
    if (matches != 1 || std::count_if(model.properties.begin(), model.properties.end(),
            [&](const auto& item) { return item.name == name; }) != 1) {
        throw std::invalid_argument("expected one assertion named " + name);
    }
}

struct ProofTarget {
    std::string property;
    const char* folder;
    Outcome unproved;
};

constexpr std::array<const char*, 2> guards{lowering::kMemoryReadRange, lowering::kMemoryWriteRange};
using RangeProperties = std::array<const lowering::TIRProperty*, guards.size()>;

RangeProperties range_properties(const lowering::TIRModule& model) {
    RangeProperties properties{};
    for (std::size_t i = 0; i < guards.size(); ++i) {
        require_assertion(model, guards[i]);
        properties[i] = &*std::find_if(model.properties.begin(), model.properties.end(),
            [&](const auto& property) { return property.name == guards[i]; });
    }
    return properties;
}

std::vector<InvalidAccess> invalid_accesses(const RangeProperties& properties, const replay::Frame& frame) {
    std::vector<InvalidAccess> accesses;
    for (const auto* property : properties) {
        const auto& predicate = property->antecedent.terms.at(0).predicate;
        if (replay::evaluate_word(predicate, frame) != 0) continue;
        // The generated guard has the shape !enable || (address >= first && address <= last).
        const auto& range = predicate.operands.at(1);
        const auto& lower = range.operands.at(0);
        const auto& upper = range.operands.at(1);
        const auto& address = lower.operands.at(0);
        accesses.push_back({property->name, property->location, address.value,
            replay::evaluate_word(address, frame), replay::evaluate_word(lower.operands.at(1), frame),
            replay::evaluate_word(upper.operands.at(1), frame), predicate.operands.at(0).operands.at(0).value});
    }
    return accesses;
}

RangeWitness validate_range_prefix(const lowering::TIRModule& model, const RangeProperties& properties,
    const replay::FrameView& prefix, std::size_t candidate, const MemoryBudget& memory) {
    if (prefix.empty() || candidate != prefix.size() - 1 || candidate > pdr::kMaximumDepth) {
        throw std::invalid_argument("memory range trace must end at its first invalid access");
    }
    for (std::size_t frame = 0; frame < candidate; ++frame) {
        memory.check();
        if (!invalid_accesses(properties, prefix[frame]).empty()) {
            throw std::invalid_argument("memory range trace contains an earlier invalid access");
        }
    }
    auto accesses = invalid_accesses(properties, prefix[candidate]);
    if (accesses.empty()) throw std::invalid_argument("memory range candidate has no invalid access in replay");
    const auto replayed = replay::validate_bounded_counterexample_view(model, prefix, accesses.front().property, candidate);
    if (!replayed.validated) throw std::invalid_argument("memory range candidate failed prefix replay: " + replayed.message);
    return {candidate, replayed.boundary_incomplete, std::move(accesses)};
}

std::string range_trace_identity(const lowering::TIRModule& model, const std::string& property) {
    return "q3a-memory-range-v1:" + sha256_generated([&](auto& output) {
        output << property << '\n' << lowering::serialize_tir(model);
    });
}

void publish_range_trace(const std::filesystem::path& destination, const lowering::TIRModule& model,
    const std::string& property, const std::vector<replay::Frame>& prefix, const MemoryBudget& memory) {
    const auto target = bundle::detail::absolute_windows_file_path(destination);
    if (!target.has_filename() || std::filesystem::exists(target)) {
        throw std::invalid_argument("memory range trace requires an unused file path");
    }
    const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
    const auto stage = target.parent_path() /
        (".q3a-range-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(nonce));
    const auto staged_file = stage / "range.q3t";
    if (!std::filesystem::create_directory(stage)) throw std::runtime_error("cannot stage memory range trace");
    try {
        memory.check(model.signals.size() * 128);
        std::ofstream output(staged_file, std::ios::binary);
        trace::write_indexed_trace(output, model, prefix, range_trace_identity(model, property), prefix.size() - 1);
        output.close();
        if (!output) throw std::runtime_error("cannot write memory range trace");
        memory.check();
        if (!MoveFileW(staged_file.c_str(), target.c_str())) {
            throw std::runtime_error("cannot publish memory range trace without replacing an existing path");
        }
    } catch (...) {
        std::error_code ignored;
        std::filesystem::remove(staged_file, ignored);
        std::filesystem::remove(stage, ignored);
        throw;
    }
    std::error_code ignored;
    std::filesystem::remove(stage, ignored);
}

replay::Frame decode_frame(const std::map<std::string, std::vector<sat::Literal>>& encoded,
                          const sat::Result& solved) {
    replay::Frame frame;
    for (const auto& [name, bits] : encoded) {
        std::uint64_t value = 0;
        for (std::size_t bit = 0; bit < bits.size(); ++bit) {
            const auto literal = static_cast<std::int64_t>(bits[bit]);
            const auto assignment = solved.assignment.at(static_cast<std::size_t>(literal < 0 ? -literal : literal));
            if (assignment < 0) throw std::runtime_error("memory witness contains an unassigned bit");
            if ((literal > 0) == (assignment != 0)) value |= std::uint64_t{1} << bit;
        }
        frame.emplace(name, value);
    }
    return frame;
}

ActivationCheck check_activation(const lowering::TIRModule& model, const std::string& property,
                                 std::size_t bound, const MemoryBudget& memory) {
    sat::Solver solver([&](auto bytes) { memory.check(bytes); });
    sat::TransitionCnfEncoder encoder(solver, model);
    encoder.encode(bound);
    encoder.constrain_assumptions();
    const auto query = encoder.add_assertion_violation(property);
    const sat::Limits limits{1000000, 10000000};
    auto solved = solver.solve(limits);
    if (solved.status == sat::Status::Unsatisfiable) return {ActivationStatus::Inconsistent, bound};
    if (solved.status == sat::Status::Unknown) return {ActivationStatus::Unknown, bound};
    if (!query.always_active) {
        if (query.activation_literals.empty()) return {ActivationStatus::NotFoundWithinBound, bound};
        solver.add_clause(query.activation_literals);
        solved = solver.solve(limits);
        if (solved.status == sat::Status::Unsatisfiable) return {ActivationStatus::NotFoundWithinBound, bound};
        if (solved.status == sat::Status::Unknown) return {ActivationStatus::Unknown, bound};
    }
    std::vector<replay::Frame> frames;
    for (const auto& encoded : encoder.frames()) {
        memory.check(encoded.size() * 128);
        frames.push_back(decode_frame(encoded, solved));
    }
    const replay::FrameView view(frames.size(), [&](std::size_t index) -> const replay::Frame& {
        memory.check();
        return frames.at(index);
    });
    const auto replayed = replay::validate_bounded_activation(model, view, property);
    if (!replayed.result.validated || !replayed.frame) {
        throw std::runtime_error("memory activation candidate failed replay: " + replayed.result.message);
    }
    return {replayed.result.boundary_incomplete ? ActivationStatus::PendingAssumption : ActivationStatus::Activated,
            bound, replayed.frame};
}

std::optional<RangeWitness> replay_first_invalid(const lowering::TIRModule& model,
    const std::string& property, std::size_t depth, const MemoryBudget& memory,
    const std::filesystem::path& range_trace) {
    sat::Solver solver([&](auto bytes) { memory.check(bytes); });
    sat::TransitionCnfEncoder encoder(solver, model);
    encoder.encode(depth);
    encoder.constrain_assumptions();
    std::vector<sat::Literal> failed_range;
    for (const auto* guard : guards) {
        const auto query = encoder.add_assertion_violation(guard);
        failed_range.insert(failed_range.end(), query.violation_literals.begin(), query.violation_literals.end());
    }
    if (failed_range.empty()) return std::nullopt;
    solver.add_clause(failed_range);
    const auto solved = solver.solve({1000000, 10000000});
    if (solved.status != sat::Status::Satisfiable) return std::nullopt;

    const auto properties = range_properties(model);
    std::vector<replay::Frame> prefix;
    for (const auto& encoded : encoder.frames()) {
        memory.check();
        const auto& frame = prefix.emplace_back(decode_frame(encoded, solved));
        if (invalid_accesses(properties, frame).empty()) continue;
        const replay::FrameView view(prefix.size(), [&](std::size_t index) -> const replay::Frame& {
            memory.check();
            return prefix.at(index);
        });
        auto witness = validate_range_prefix(model, properties, view, prefix.size() - 1, memory);
        if (!range_trace.empty()) publish_range_trace(range_trace, model, property, prefix, memory);
        return witness;
    }
    throw std::runtime_error("memory range candidate has no invalid access in independent replay");
}

} // namespace

Result check(const lowering::TIRModule& model, const std::string& property,
             const std::filesystem::path& evidence, bool reopen,
             std::size_t maximum_depth, std::size_t maximum_search_queries,
             const MemoryBudget& memory, bool diagnose_range, const std::filesystem::path& range_trace,
             std::optional<std::size_t> activation_bound) {
    if (property == lowering::kMemoryReadRange || property == lowering::kMemoryWriteRange) {
        throw std::invalid_argument("the primary claim cannot be a generated range assertion");
    }
    const std::array<ProofTarget, 3> targets{{
        {lowering::kMemoryReadRange, "read-range", Outcome::RangeUnproved},
        {lowering::kMemoryWriteRange, "write-range", Outcome::RangeUnproved},
        {property, "property", Outcome::PropertyUnproved}}};
    for (const auto& target : targets) {
        require_assertion(model, target.property);
    }

    const auto activation_result = [&]() {
        Result result{Outcome::Proven, property};
        if (activation_bound) {
            result.activation = check_activation(model, property, *activation_bound, memory);
            if (result.activation->status == ActivationStatus::Inconsistent) {
                result.outcome = Outcome::Inconsistent;
                result.inconsistent_bound = *activation_bound;
            }
        }
        return result;
    };
    if (reopen) {
        for (const auto& target : targets) {
            memory.check();
            if (!pdr::verify(model, target.property, evidence / target.folder, memory)) {
                return {target.unproved, target.property};
            }
        }
        return activation_result();
    }

    // Resolve the three searches first. No certificate is written for an
    // unproved access or claim, and every search uses the same environment.
    std::vector<pdr::CertificateGroupEntry> entries;
    entries.reserve(targets.size());
    for (const auto& target : targets) {
        auto search = pdr::search(model, target.property, maximum_depth, maximum_search_queries, memory);
        if (search.status == pdr::Status::Inconsistent) {
            return {Outcome::Inconsistent, property, std::nullopt, search.depth};
        }
        if (search.status != pdr::Status::InvariantFound) {
            auto diagnostic = (diagnose_range || !range_trace.empty()) && target.unproved == Outcome::RangeUnproved &&
                search.status == pdr::Status::CounterexampleCandidate
                ? replay_first_invalid(model, property, search.depth, memory, range_trace) : std::nullopt;
            return {target.unproved, target.property, std::move(diagnostic)};
        }
        entries.push_back({target.property, target.folder, std::move(search.invariant)});
    }
    auto result = activation_result();
    if (result.outcome == Outcome::Inconsistent) return result;
    if (const auto unproved = pdr::certify_group(model, entries, evidence, memory)) {
        const auto outcome = *unproved == property ? Outcome::PropertyUnproved : Outcome::RangeUnproved;
        return {outcome, *unproved};
    }
    return result;
}

RangeWitness reopen_range_trace(const lowering::TIRModule& model, const std::string& property,
                               const std::filesystem::path& input, const MemoryBudget& memory) {
    WriteLockedInput trace_file(bundle::detail::absolute_windows_file_path(input));
    return reopen_range_trace(model, property, trace_file.stream(), memory);
}

RangeWitness reopen_range_trace(const lowering::TIRModule& model, const std::string& property,
                               std::istream& input, const MemoryBudget& memory) {
    require_assertion(model, property);
    const auto properties = range_properties(model);
    std::optional<RangeWitness> witness;
    trace::visit_indexed_witness(input, model, range_trace_identity(model, property),
        std::nullopt, [&](std::uint64_t bytes) { memory.check(bytes); },
        [&](const auto& frames, std::size_t candidate) {
            witness = validate_range_prefix(model, properties, frames, candidate, memory);
        });
    return std::move(witness.value());
}

} // namespace q3a::memory_proof
