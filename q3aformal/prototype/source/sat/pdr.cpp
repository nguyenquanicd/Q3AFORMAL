#include "pdr.hpp"
#include "../lowering/sequence_monitor.hpp"

#include "proof_artifact.hpp"
#include "transition_encoder.hpp"
#include "windows_file_path.hpp"
#include "write_locked_input.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <chrono>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <unordered_map>
#include <unordered_set>

namespace q3a::pdr {
namespace {

using sat::Literal;
using Clause = std::vector<Literal>;
using lowering::TypedExpression;
constexpr std::size_t kMaxStateBits = 65536;
constexpr std::size_t kMaxInvariantLiterals = 1000000;
constexpr std::size_t kMaxEvidenceLine = 512 * 1024;
constexpr std::streamoff kMaxProofBodyBytes = 8 * 1024 * 1024;
constexpr std::array<const char*, 3> kObligations{"initiation", "consecution", "safety"};

bool same_sample_cover(const lowering::TIRProperty& property) {
    if (!lowering::is_same_sample_sequence(property.antecedent)) return false;
    if (property.consequent) {
        return property.implication == "overlapped" &&
               lowering::is_same_sample_sequence(*property.consequent);
    }
    return property.implication.empty() || property.implication == "sequence";
}

struct PreparedModel {
    std::optional<lowering::TIRModule> monitored;
    std::uint64_t assumption_horizon = 0;
};

PreparedModel prepare_model(const lowering::TIRModule& model,
    const std::string& name, const MemoryBudget& memory) {
    const auto target = std::find_if(model.properties.begin(), model.properties.end(),
        [&](const auto& candidate) { return candidate.name == name; });
    if (target == model.properties.end() || (target->kind != "assert" && target->kind != "cover")) {
        throw std::invalid_argument("PDR requires an assertion or cover goal");
    }
    if (lowering::is_eventual_response(*target)) {
        throw std::invalid_argument("s_eventually requires the liveness engine");
    }
    const bool goal_needs_monitor = target->kind == "cover" ? !same_sample_cover(*target)
        : lowering::bounded_induction_property_horizon(*target) != 0;
    const auto needs_assumption_monitor = [](const auto& property) {
        return property.kind == "assume" && lowering::bounded_induction_property_horizon(property) != 0;
    };
    if (!goal_needs_monitor &&
        std::none_of(model.properties.begin(), model.properties.end(), needs_assumption_monitor)) {
        return {};
    }

    memory.check();
    PreparedModel prepared{model, 0};
    auto& monitored = *prepared.monitored;
    std::size_t generated_signals = 0;
    if (goal_needs_monitor) {
        auto& selected = monitored.properties.at(static_cast<std::size_t>(target - model.properties.begin()));
        lowering::lower_sequence_monitor(monitored, selected, generated_signals, kMaximumDepth);
    }
    for (auto& property : monitored.properties) {
        if (needs_assumption_monitor(property)) {
            memory.check();
            prepared.assumption_horizon = std::max(prepared.assumption_horizon,
                lowering::lower_sequence_monitor(monitored, property, generated_signals, kMaximumDepth));
        }
    }
    return prepared;
}

std::size_t bit_index(Literal lit) {
    const auto value = static_cast<std::int64_t>(lit);
    return static_cast<std::size_t>(value < 0 ? -value : value);
}

struct Problem {
    Problem(const lowering::TIRModule& original, const std::string& name,
            const MemoryBudget& memory)
        : prepared(prepare_model(original, name, memory)), original(original),
          model(prepared.monitored ? *prepared.monitored : original), property(name), memory(memory) {
        const auto target = std::find_if(model.properties.begin(), model.properties.end(),
            [&](const auto& candidate) { return candidate.name == name; });
        cover = target->kind == "cover";
        for (const auto& equation : model.next_state_equations) {
            if (equation.target_width > kMaxStateBits - state_bits) {
                throw MemoryBudgetExceeded("PDR state-bit limit reached");
            }
            state_bits += static_cast<std::size_t>(equation.target_width);
        }
    }
    const PreparedModel prepared;
    const lowering::TIRModule& original;
    const lowering::TIRModule& model;
    const std::string& property;
    const MemoryBudget& memory;
    std::size_t state_bits = 0;
    bool cover = false;
};

struct Query {
    Query(const Problem& problem, bool initial, bool transition, bool assumptions,
          const lowering::TIRModule* cone = nullptr, const std::vector<std::size_t>* positions = nullptr)
        : solver([&memory = problem.memory](std::uint64_t pending) { memory.check(pending); }),
          encoder(solver, cone ? *cone : problem.model) {
        encoder.encode(transition ? 1 : 0, initial);
        // A constraint on the current sample only. Successor input
        // admissibility is considered when that sample is explored.
        if (assumptions) encoder.constrain_assumptions(0);
        // Keep full-model literal positions even when this query omitted
        // entire state signals. The proof checker uses the same positions.
        const auto encode_positions = [&](std::size_t frame) {
            Clause bits(problem.state_bits, 0);
            std::size_t index = 0;
            const auto& equations = cone ? cone->next_state_equations : problem.model.next_state_equations;
            for (const auto& equation : equations) {
                for (const auto lit : encoder.frames()[frame].at(equation.target)) {
                    bits.at(positions ? positions->at(index) : index) = lit;
                    ++index;
                }
            }
            return bits;
        };
        current = encode_positions(0);
        if (transition) next = encode_positions(1);
    }

    static Literal translate(Literal lit, const Clause& variables) {
        const auto variable = variables.at(bit_index(lit) - 1);
        if (variable == 0) throw std::logic_error("PDR clause refers to a state bit outside the query cone");
        return lit < 0 ? -variable : variable;
    }

    void constrain(const Invariant& clauses, const Clause& variables) {
        for (const auto& clause : clauses) constrain_clause(clause, variables);
    }

    void constrain_clause(const Clause& clause, const Clause& variables) {
        Clause encoded;
        encoded.reserve(clause.size());
        for (const auto lit : clause) encoded.push_back(translate(lit, variables));
        solver.add_clause(encoded);
    }

    sat::Result solve_cube(const Clause& cube, const Clause& variables, const sat::Limits& limits) const {
        Clause assumptions;
        assumptions.reserve(cube.size());
        for (const auto lit : cube) assumptions.push_back(translate(lit, variables));
        return solver.solve(limits, assumptions);
    }

    void constrain_target(const Problem& problem) {
        if (!problem.cover) {
            solver.add_clause({-encoder.encode_induction_assertion_at_frame(problem.property, 0)});
            return;
        }
        // Search for the actual cover hit. Bounded cover encoding supplies the
        // same history guards and nonvacuous implication semantics for sample 0.
        const auto hit = encoder.add_cover_hit(problem.property);
        if (encoder.frames().size() != 1 || hit.boundary_limited ||
            hit.hit_frames.size() != 1 || hit.hit_frames.front() != 0 ||
            hit.hit_literals.size() != 1) {
            throw std::logic_error("PDR cover encoding did not yield one complete sample-zero hit");
        }
        solver.add_clause({hit.hit_literals.front()});
    }

    void violate(const Invariant& clauses, const Clause& variables) {
        Clause selectors;
        for (const auto& clause : clauses) {
            const auto selector = static_cast<Literal>(solver.new_variable());
            selectors.push_back(selector);
            for (const auto lit : clause) {
                solver.add_clause({-selector, -translate(lit, variables)});
            }
        }
        solver.add_clause(selectors);
    }

    Clause state(const sat::Result& result, const std::vector<std::size_t>& projection) const {
        Clause cube;
        cube.reserve(projection.size());
        for (const auto index : projection) {
            const auto value = result.assignment.at(current.at(index));
            if (value < 0) throw std::logic_error("PDR SAT model has an unassigned state bit");
            const auto position = static_cast<Literal>(index + 1);
            cube.push_back(value == 0 ? -position : position);
        }
        return cube;
    }

    sat::Solver solver;
    sat::TransitionCnfEncoder encoder;
    Clause current;
    Clause next;
};

void append_references(const TypedExpression& expression, std::vector<std::string_view>& pending) {
    if (expression.kind == "signal" || expression.kind == "history_ref") {
        pending.push_back(expression.value);
    }
    for (const auto& operand : expression.operands) append_references(operand, pending);
}

struct SearchCone {
    lowering::TIRModule model;
    std::vector<std::size_t> positions;
    std::vector<bool> initially_zero;
    std::size_t signal_bits = 0;
    std::size_t full_signal_bits = 0;
};

SearchCone build_search_cone(const Problem& problem) {
    const auto& model = problem.model;
    std::unordered_map<std::string_view, const TypedExpression*> drivers;
    for (const auto* equations : {&model.combinational_equations, &model.next_state_equations}) {
        for (const auto& equation : *equations) {
            drivers.emplace(equation.target, &equation.expression);
        }
    }
    std::vector<std::string_view> pending(model.clocks.begin(), model.clocks.end());
    std::unordered_set<std::string_view> initially_zero;
    for (const auto& guard : model.history_guards) {
        pending.insert(pending.end(), guard.state_chain.begin(), guard.state_chain.end());
        initially_zero.insert(guard.state_chain.begin(), guard.state_chain.end());
    }
    for (const auto& property : model.properties) {
        if (property.name != problem.property && property.kind != "assume") continue;
        const auto add_sequence = [&](const auto& sequence) {
            for (const auto& edge : sequence.automaton.transitions) append_references(edge.predicate, pending);
        };
        add_sequence(property.antecedent);
        if (property.consequent) add_sequence(*property.consequent);
        for (const auto* guard : {&property.history_guard_signal, &lowering::antecedent_history_guard(property),
                &lowering::consequent_history_guard(property)}) {
            if (!guard->empty()) pending.push_back(*guard);
        }
    }
    std::unordered_set<std::string_view> cone;
    while (!pending.empty()) {
        const auto name = pending.back();
        pending.pop_back();
        if (!cone.insert(name).second) continue;
        const auto producer = drivers.find(name);
        if (producer != drivers.end()) append_references(*producer->second, pending);
    }
    SearchCone slice;
    slice.model.schema_version = model.schema_version;
    slice.model.semantic_profile = model.semantic_profile;
    slice.model.input_hash = model.input_hash;
    slice.model.name = model.name;
    slice.model.parameters = model.parameters;
    slice.model.clocks = model.clocks;
    slice.model.history_guards = model.history_guards;
    slice.initially_zero.resize(problem.state_bits);
    for (const auto& property : model.properties) {
        if (property.name == problem.property || property.kind == "assume") {
            slice.model.properties.push_back(property);
        }
    }
    for (const auto& signal : model.signals) {
        slice.full_signal_bits += static_cast<std::size_t>(signal.width);
        if (cone.count(signal.name)) {
            slice.signal_bits += static_cast<std::size_t>(signal.width);
            slice.model.signals.push_back(signal);
        }
    }
    for (const auto& equation : model.combinational_equations) {
        if (cone.count(equation.target)) slice.model.combinational_equations.push_back(equation);
    }
    std::size_t index = 0;
    for (const auto& equation : model.next_state_equations) {
        const auto width = static_cast<std::size_t>(equation.target_width);
        if (cone.count(equation.target)) {
            slice.model.next_state_equations.push_back(equation);
            // The transition encoder constrains bit zero of each validity
            // register to false at the initial sample.
            if (initially_zero.count(equation.target)) slice.initially_zero.at(index) = true;
            for (std::size_t bit = 0; bit < width; ++bit) slice.positions.push_back(index + bit);
        }
        index += width;
    }
    return slice;
}

class SearchLimit {};

sat::Limits proof_limits() {
    sat::Limits limits;
    limits.decisions = 100000;
    limits.propagations = 2000000;
    limits.proof_records = 100000;
    return limits;
}

class Frames {
public:
    Frames(const Problem& problem, std::size_t depth, std::size_t maximum_search_queries)
        : problem_(problem), frames_(depth + 2), cone_(build_search_cone(problem)),
          maximum_search_queries_(maximum_search_queries) {}

    Result run(std::size_t maximum_depth, std::size_t minimum_feasibility_bound) {
        {
            ++cnf_builds_;
            // Validate the complete model and initial environment before
            // entering the reduced search.
            Query feasible(problem_, true, false, true);
            if (solve(feasible).status == sat::Status::Unsatisfiable) {
                return {Status::Inconsistent, 0, {}};
            }
            feasible_prefix_bound_ = 0;
        }
        const auto horizon = std::max<std::uint64_t>(minimum_feasibility_bound,
            std::min<std::uint64_t>(problem_.prepared.assumption_horizon, maximum_depth));
        if (horizon != 0) {
            sat::Solver solver([&memory = problem_.memory](std::uint64_t pending) { memory.check(pending); });
            sat::TransitionCnfEncoder original(solver, problem_.original);
            ++cnf_builds_;
            original.encode(horizon);
            original.constrain_assumptions();
            if (solve(solver).status == sat::Status::Unsatisfiable) {
                return {Status::Inconsistent, static_cast<std::size_t>(horizon), {}};
            }
            feasible_prefix_bound_ = static_cast<std::size_t>(horizon);
        }
        if (bad_state(0)) return {Status::CounterexampleCandidate, 0, {}};
        bad_query_.reset();
        for (depth_ = 1; depth_ <= maximum_depth; ++depth_) {
            while (const auto bad = bad_state(depth_)) {
                if (!block(*bad, depth_)) return {Status::CounterexampleCandidate, candidate_depth_, {}};
            }
            bad_query_.reset();
            for (std::size_t level = 1; level <= depth_; ++level) {
                for (const auto& clause : frames_[level]) {
                    if (frames_[level + 1].count(clause)) continue;
                    auto& push = transition_query(level);
                    Clause violation;
                    violation.reserve(clause.size());
                    for (const auto lit : clause) violation.push_back(-lit);
                    if (solve_cube(push, violation, push.next).status == sat::Status::Unsatisfiable) {
                        add(level + 1, clause);
                    }
                }
                if (frames_[level] == frames_[level + 1]) {
                    return {Status::InvariantFound, depth_, std::move(frames_[level])};
                }
            }
        }
        return {Status::Unknown, maximum_depth, {}};
    }

    std::size_t depth() const noexcept { return depth_; }
    std::size_t queries() const noexcept { return queries_; }
    std::size_t initial_zero_rejections() const noexcept { return initial_zero_rejections_; }
    std::size_t cnf_builds() const noexcept { return cnf_builds_; }
    std::size_t projected_bits() const noexcept { return cone_.positions.size(); }
    std::size_t signal_bits() const noexcept { return cone_.signal_bits; }
    std::size_t full_signal_bits() const noexcept { return cone_.full_signal_bits; }
    std::optional<std::size_t> feasible_prefix_bound() const noexcept { return feasible_prefix_bound_; }

private:
    std::unique_ptr<Query> make_query(bool initial, bool transition, bool assumptions) {
        ++cnf_builds_;
        return std::make_unique<Query>(problem_, initial, transition, assumptions, &cone_.model, &cone_.positions);
    }

    void begin_query() {
        if (queries_ == maximum_search_queries_) throw SearchLimit{};
        ++queries_;
    }

    static sat::Result require_decision(sat::Result result) {
        if (result.status == sat::Status::Unknown) throw SearchLimit{};
        return result;
    }

    sat::Result solve(Query& query) {
        return solve(query.solver);
    }

    sat::Result solve(sat::Solver& solver) {
        begin_query();
        return require_decision(solver.solve(proof_limits()));
    }

    sat::Result solve_cube(const Query& query, const Clause& cube, const Clause& variables) {
        begin_query();
        return require_decision(query.solve_cube(cube, variables, proof_limits()));
    }

    std::optional<Clause> bad_state(std::size_t level) {
        if (!bad_query_) {
            bad_query_ = make_query(level == 0, false, true);
            bad_query_->constrain(frames_[level], bad_query_->current);
            bad_query_->constrain_target(problem_);
        }
        auto& query = *bad_query_;
        const auto result = solve(query);
        if (result.status == sat::Status::Unsatisfiable) return std::nullopt;
        return query.state(result, cone_.positions);
    }

    bool intersects_initial(const Clause& cube) {
        // A positive literal for a known-zero bit makes this cube disjoint
        // from the initial states. Use the SAT query for every other case.
        if (std::any_of(cube.begin(), cube.end(), [&](Literal lit) {
                return lit > 0 && cone_.initially_zero.at(bit_index(lit) - 1);
            })) {
            ++initial_zero_rejections_;
            return false;
        }
        if (!initial_query_) initial_query_ = make_query(true, false, false);
        return solve_cube(*initial_query_, cube, initial_query_->current).status == sat::Status::Satisfiable;
    }

    Query& transition_query(std::size_t level) {
        if (!transition_query_ || transition_level_ != level) {
            transition_query_.reset();
            transition_query_ = make_query(level == 0, true, true);
            transition_query_->constrain(frames_[level], transition_query_->current);
            transition_level_ = level;
        }
        return *transition_query_;
    }

    std::optional<Clause> predecessor(const Clause& cube, std::size_t level) {
        auto& query = transition_query(level);
        const auto result = solve_cube(query, cube, query.next);
        if (result.status == sat::Status::Unsatisfiable) return std::nullopt;
        return query.state(result, cone_.positions);
    }

    bool block(Clause cube, std::size_t level) {
        if (intersects_initial(cube)) {
            candidate_depth_ = depth_ - level;
            return false;
        }
        if (level == 0) throw std::logic_error("PDR predecessor missed initial-state restriction");
        while (const auto prior = predecessor(cube, level - 1)) {
            if (!block(*prior, level - 1)) return false;
        }
        const auto group_size = cube.size() < 8 ? std::size_t{1} : cube.size() / 2;
        for (std::size_t first = 0; first < cube.size();) {
            const auto size = std::min(group_size, cube.size() - first);
            first += retain_required_literals(cube, first, size, level - 1);
        }
        for (auto& lit : cube) lit = -lit;
        for (std::size_t i = 1; i <= level; ++i) add(i, cube);
        return true;
    }

    // Return the number of retained literals so the caller can find the next group
    // after erasures. A failed group is split until each remaining literal is needed.
    std::size_t retain_required_literals(Clause& cube, std::size_t first,
                                         std::size_t count, std::size_t predecessor_level) {
        auto reduced = cube;
        reduced.erase(reduced.begin() + first, reduced.begin() + first + count);
        if (!intersects_initial(reduced) && !predecessor(reduced, predecessor_level)) {
            cube = std::move(reduced);
            return 0;
        }
        if (count == 1) return 1;

        const auto half = count / 2;
        const auto retained = retain_required_literals(cube, first, half, predecessor_level);
        return retained + retain_required_literals(
            cube, first + retained, count - half, predecessor_level);
    }

    void add(std::size_t level, const Clause& clause) {
        if (clause.size() > kMaxInvariantLiterals - stored_literals_) throw SearchLimit{};
        problem_.memory.check(clause.size() * sizeof(Literal));
        if (!frames_[level].insert(clause).second) return;
        stored_literals_ += clause.size();
        if (bad_query_ && level == depth_) bad_query_->constrain_clause(clause, bad_query_->current);
        if (transition_query_ && level == transition_level_) {
            transition_query_->constrain_clause(clause, transition_query_->current);
        }
    }

    const Problem& problem_;
    std::vector<Invariant> frames_;
    const SearchCone cone_;
    const std::size_t maximum_search_queries_;
    std::unique_ptr<Query> bad_query_;
    std::unique_ptr<Query> initial_query_;
    std::unique_ptr<Query> transition_query_;
    std::size_t transition_level_ = 0;
    std::size_t queries_ = 0;
    std::size_t cnf_builds_ = 0;
    std::size_t stored_literals_ = 0;
    std::size_t initial_zero_rejections_ = 0;
    std::size_t depth_ = 0;
    std::size_t candidate_depth_ = 0;
    std::optional<std::size_t> feasible_prefix_bound_;
};

void build_obligation(Query& query, const Problem& problem,
                      const Invariant& invariant, std::size_t id) {
    if (id == 0) {
        query.violate(invariant, query.current);
    } else if (id == 1) {
        query.constrain(invariant, query.current);
        query.violate(invariant, query.next);
    } else {
        query.constrain(invariant, query.current);
        query.constrain_target(problem);
    }
}

std::string model_hash(const Problem& problem) {
    return sha256_hex(lowering::serialize_tir(problem.model));
}

void require_output(std::ofstream& output) {
    output.close();
    if (!output) throw std::runtime_error("PDR evidence could not be written");
}

void remove_certificate_payload(const std::filesystem::path& path) {
    std::error_code ignored;
    if (bundle::detail::canonical_directory(path, ignored) != path || ignored) return;
    for (const auto* name : kObligations) {
        std::filesystem::remove(path / (std::string(name) + ".cnf"), ignored);
        std::filesystem::remove(path / (std::string(name) + ".q3adrat"), ignored);
    }
    std::filesystem::remove(path / "proof-body.tmp", ignored);
    std::filesystem::remove(path / "invariant.txt", ignored);
    std::filesystem::remove(path / kCertificateRunConfigurationFile, ignored);
    std::filesystem::remove(path, ignored);
}

class CertificateStaging {
public:
    explicit CertificateStaging(const std::filesystem::path& destination, std::vector<std::string> children = {})
        : children_(std::move(children)) {
        auto absolute = bundle::detail::absolute_windows_file_path(destination);
        if (absolute.has_relative_path() && absolute.filename().empty()) {
            absolute = absolute.parent_path();
        }
        if (absolute.filename().empty()) throw std::runtime_error("PDR evidence needs a directory name");
        std::error_code error;
        const auto parent = bundle::detail::canonical_directory(absolute.parent_path(), error);
        if (error) throw std::runtime_error("cannot resolve PDR evidence parent directory: " + error.message());
        destination_ = parent / absolute.filename();
        if (std::filesystem::exists(destination_)) {
            throw std::runtime_error("PDR evidence directory already exists");
        }
        static std::atomic<std::uint64_t> sequence{0};
        const auto nonce = std::chrono::high_resolution_clock::now().time_since_epoch().count();
        const std::string prefix = children_.empty() ? ".q3apdr-" : ".q3apdr-group-";
        path_ = parent / (prefix + std::to_string(nonce) + "-" + std::to_string(sequence.fetch_add(1)));
        if (!std::filesystem::create_directory(path_)) {
            throw std::runtime_error("cannot create temporary PDR evidence directory");
        }
    }

    CertificateStaging(const CertificateStaging&) = delete;
    CertificateStaging& operator=(const CertificateStaging&) = delete;

    ~CertificateStaging() {
        if (published_) return;
        try {
            if (children_.empty()) {
                remove_certificate_payload(path_);
                return;
            }
            std::error_code ignored;
            if (bundle::detail::canonical_directory(path_, ignored) != path_ || ignored) return;
            for (const auto& child : children_) remove_certificate_payload(path_ / child);
            std::filesystem::remove(path_, ignored);
        } catch (...) {
            // Cleanup must preserve the original error during exception unwinding.
        }
    }

    const std::filesystem::path& path() const noexcept { return path_; }

    void publish() {
        if (!MoveFileW(path_.c_str(), destination_.c_str())) {
            const std::error_code error(static_cast<int>(GetLastError()), std::system_category());
            throw std::runtime_error("cannot publish checked PDR evidence: " + error.message());
        }
        published_ = true;
    }

private:
    std::filesystem::path destination_;
    std::filesystem::path path_;
    std::vector<std::string> children_;
    bool published_ = false;
};

std::string invariant_header(const Problem& problem, const std::string& digest) {
    return "Q3A_PDR_INVARIANT 1\n" + digest + "\n" + problem.property + "\n";
}

Invariant read_invariant(const Problem& problem, const std::string& digest,
                         const std::filesystem::path& path) {
    WriteLockedInput locked(path);
    auto& input = locked.stream();
    auto header = invariant_header(problem, digest);
    std::string actual(header.size(), '\0');
    if (!input.read(actual.data(), actual.size()) || actual != header) {
        throw std::runtime_error("PDR certificate model or property identity does not match");
    }
    Invariant invariant;
    std::size_t literals = 0;
    std::string line;
    problem.memory.check(kMaxEvidenceLine);
    std::vector<char> buffer(kMaxEvidenceLine);
    while (input.getline(buffer.data(), buffer.size())) {
        if (input.eof()) throw std::runtime_error("PDR invariant line must end with a newline");
        problem.memory.check(static_cast<std::uint64_t>(input.gcount()) * 2);
        line.assign(buffer.data(), static_cast<std::size_t>(input.gcount() - 1));
        std::istringstream row(line);
        Clause clause;
        std::string token;
        std::size_t previous = 0;
        bool ended = false;
        while (row >> token) {
            Literal literal = 0;
            const auto parsed = std::from_chars(token.data(), token.data() + token.size(), literal);
            if (parsed.ec != std::errc() || parsed.ptr != token.data() + token.size()) {
                throw std::runtime_error("invalid PDR invariant literal");
            }
            if (literal == 0) {
                ended = !(row >> token);
                break;
            }
            const auto position = bit_index(literal);
            if (position <= previous || position > problem.state_bits || ++literals > kMaxInvariantLiterals) {
                throw std::runtime_error("PDR invariant literal is out of range, repeated, or unordered");
            }
            previous = position;
            clause.push_back(literal);
        }
        if (!ended || !invariant.insert(std::move(clause)).second) {
            throw std::runtime_error("invalid or duplicate PDR invariant clause");
        }
    }
    if (!input.eof() || input.bad()) throw std::runtime_error("invalid PDR invariant input");
    return invariant;
}

checker::ArtifactMetadata metadata(std::size_t id, const std::string& model,
                                   const std::string& query) {
    return {std::string("pdr-") + kObligations[id], checker::kCheckerId, model, query};
}

checker::CheckerLimits checker_limits(const MemoryBudget& memory) {
    checker::CheckerLimits limits;
    limits.check_memory = [&memory](std::uint64_t pending) { memory.check(pending); };
    return limits;
}

void check_result(const checker::CheckResult& result) {
    if (result.accepted) return;
    if (result.resource_limited) throw SearchLimit{};
    throw std::runtime_error("independent PDR DRAT check failed: " + result.message);
}

} // namespace

lowering::TIRModule activation_model(const lowering::TIRModule& model, const std::string& property) {
    const auto source = std::find_if(model.properties.begin(), model.properties.end(),
        [&](const auto& candidate) { return candidate.name == property && candidate.kind == "assert"; });
    if (source == model.properties.end()) {
        throw std::invalid_argument("PDR activation analysis requires an assertion");
    }
    auto derived = model;
    auto& assertion = derived.properties.at(static_cast<std::size_t>(source - model.properties.begin()));
    auto& sequence = assertion.consequent ? *assertion.consequent : assertion.antecedent;
    // Retain every sampling offset and validity guard. Force the obligation
    // to fail only when the original assertion was eligible for evaluation.
    for (auto& term : sequence.terms) {
        term.predicate = {"literal", "1'b0", 1, false, term.predicate.location, {}};
    }
    for (auto& edge : sequence.automaton.transitions) {
        edge.predicate = {"literal", "1'b0", 1, false, edge.predicate.location, {}};
    }
    derived.input_hash = sha256_hex("Q3A-PDR-ASSERTION-ACTIVATION-1\n" + model.input_hash);
    return derived;
}

Result search(const lowering::TIRModule& model, const std::string& property,
              std::size_t maximum_depth, std::size_t maximum_search_queries,
              const MemoryBudget& memory, std::size_t minimum_feasibility_bound) {
    if (maximum_depth == 0 || maximum_depth > kMaximumDepth) {
        throw std::invalid_argument("PDR depth must be in 1..128");
    }
    if (maximum_search_queries == 0) throw std::invalid_argument("PDR search query limit must be positive");
    if (minimum_feasibility_bound > kMaximumDepth) {
        throw std::invalid_argument("PDR feasibility bound must be in 0..128");
    }
    const Problem problem(model, property, memory);
    Frames frames(problem, maximum_depth, maximum_search_queries);
    try {
        auto result = frames.run(maximum_depth, minimum_feasibility_bound);
        result.search_queries = frames.queries();
        result.search_cnf_builds = frames.cnf_builds();
        result.search_state_bits = frames.projected_bits();
        result.full_state_bits = problem.state_bits;
        result.search_signal_bits = frames.signal_bits();
        result.full_signal_bits = frames.full_signal_bits();
        result.initial_zero_rejections = frames.initial_zero_rejections();
        result.feasible_prefix_bound = frames.feasible_prefix_bound();
        return result;
    } catch (const SearchLimit&) {
        return {Status::ResourceLimited, frames.depth(), {}, frames.queries(), frames.cnf_builds(),
            frames.projected_bits(), problem.state_bits, frames.signal_bits(), frames.full_signal_bits(),
            frames.initial_zero_rejections(), frames.feasible_prefix_bound()};
    }
}

std::optional<CheckedCertificate> certify(const lowering::TIRModule& model, const std::string& property,
             const Invariant& invariant, const std::filesystem::path& directory,
             const MemoryBudget& memory, std::string_view run_configuration) {
    const Problem problem(model, property, memory);
    CheckedCertificate certificate{model_hash(problem), {}, {}};
    certificate.obligations.reserve(kObligations.size());
    const auto& digest = certificate.model_sha256;
    CertificateStaging staging(directory);
    const auto body_path = staging.path() / "proof-body.tmp";
    try {
        for (std::size_t id = 0; id < kObligations.size(); ++id) {
            Query query(problem, id == 0, id == 1, id != 0);
            build_obligation(query, problem, invariant, id);
            const auto prefix = staging.path() / kObligations[id];
            auto cnf_path = prefix;
            cnf_path += ".cnf";
            auto artifact_path = prefix;
            artifact_path += ".q3adrat";
            std::ofstream cnf_out(cnf_path, std::ios::binary);
            query.solver.write_dimacs(cnf_out);
            require_output(cnf_out);
            WriteLockedInput cnf(cnf_path);
            const auto identity = metadata(id, digest, sha256_stream(cnf.stream()));
            cnf.rewind();

            std::fstream body(body_path, std::ios::in | std::ios::out | std::ios::binary | std::ios::trunc);
            if (!body) throw std::runtime_error("cannot stage PDR proof records");
            auto limits = proof_limits();
            limits.record_drat_proof = true;
            limits.proof_sink = [&](const auto& clause) {
                memory.check(clause.size() * sizeof(Literal));
                for (const auto lit : clause) body << lit << ' ';
                body << "0\n";
                const auto bytes = body.tellp();
                if (!body || bytes == std::streampos(-1)) throw std::runtime_error("cannot record PDR proof");
                if (bytes > std::streampos(kMaxProofBodyBytes)) throw SearchLimit{};
            };
            const auto proof = query.solver.solve(limits);
            if (proof.status == sat::Status::Unknown) throw SearchLimit{};
            if (proof.status != sat::Status::Unsatisfiable || proof.proof_record_count == 0) {
                throw std::runtime_error("PDR invariant failed the regenerated proof obligation");
            }
            body.seekg(0);
            if (!body) throw std::runtime_error("cannot rewind staged PDR proof");
            std::ofstream artifact_out(artifact_path, std::ios::binary);
            check_result(checker::write_drat_artifact(body, proof.proof_record_count, identity, artifact_out));
            require_output(artifact_out);
            body.clear();
            body.close();
            if (!body) throw std::runtime_error("cannot close staged PDR proof");
            std::filesystem::remove(body_path);
            WriteLockedInput artifact(artifact_path);
            check_result(checker::verify_drat_artifact(
                cnf.stream(), artifact.stream(), identity, checker_limits(memory)));
            artifact.rewind();
            certificate.obligations.push_back({
                identity.query_kind, identity.query_sha256, sha256_stream(artifact.stream())});
        }
        std::ofstream invariant_out(staging.path() / "invariant.txt", std::ios::binary);
        invariant_out << invariant_header(problem, digest);
        for (const auto& clause : invariant) {
            for (const auto lit : clause) invariant_out << lit << ' ';
            invariant_out << "0\n";
        }
        require_output(invariant_out);
        if (!run_configuration.empty()) {
            std::ostringstream record;
            record << "{\"schema_version\":1,\"model_sha256\":\"" << digest << "\",\"obligations\":[";
            const char* separator = "";
            for (const auto& obligation : certificate.obligations) {
                record << separator << "{\"kind\":\"" << obligation.kind
                       << "\",\"query_sha256\":\"" << obligation.query_sha256
                       << "\",\"proof_sha256\":\"" << obligation.proof_sha256 << "\"}";
                separator = ",";
            }
            record << "],\"run_configuration\":" << run_configuration << "}\n";
            const auto contents = record.str();
            std::ofstream out(staging.path() / kCertificateRunConfigurationFile, std::ios::binary);
            out << contents;
            require_output(out);
            certificate.run_configuration_sha256 = sha256_hex(contents);
        }
        memory.check();
        staging.publish();
        return certificate;
    } catch (const SearchLimit&) {
        return std::nullopt;
    }
}

std::optional<std::string> certify_group(const lowering::TIRModule& model,
    const std::vector<CertificateGroupEntry>& entries, const std::filesystem::path& directory,
    const MemoryBudget& memory) {
    if (entries.empty()) throw std::invalid_argument("PDR certificate group is empty");
    std::vector<std::string> folders;
    folders.reserve(entries.size());
    for (const auto& entry : entries) {
        const auto& folder = entry.folder;
        if (folder.empty() || !std::all_of(folder.begin(), folder.end(), [](char ch) {
                return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-';
            }) || std::find(folders.begin(), folders.end(), folder) != folders.end()) {
            throw std::invalid_argument("invalid or repeated PDR certificate group folder");
        }
        folders.push_back(folder);
    }
    CertificateStaging group(directory, std::move(folders));
    for (const auto& entry : entries) {
        memory.check();
        if (!certify(model, entry.property, entry.invariant, group.path() / entry.folder, memory)) {
            return entry.property;
        }
    }
    memory.check();
    group.publish();
    return std::nullopt;
}

std::optional<CheckedCertificate> verify(const lowering::TIRModule& model, const std::string& property,
            const std::filesystem::path& directory, const MemoryBudget& memory) {
    const Problem problem(model, property, memory);
    CheckedCertificate certificate{model_hash(problem), {}, {}};
    certificate.obligations.reserve(kObligations.size());
    const auto& digest = certificate.model_sha256;
    const auto root = bundle::detail::absolute_windows_file_path(directory);
    const auto invariant = read_invariant(problem, digest, root / "invariant.txt");
    try {
        for (std::size_t id = 0; id < kObligations.size(); ++id) {
            Query query(problem, id == 0, id == 1, id != 0);
            build_obligation(query, problem, invariant, id);
            const auto expected = sha256_generated([&](std::ostream& out) { query.solver.write_dimacs(out); });
            auto cnf_path = root / kObligations[id];
            auto proof_path = cnf_path;
            cnf_path += ".cnf";
            proof_path += ".q3adrat";
            WriteLockedInput cnf(cnf_path);
            if (sha256_stream(cnf.stream()) != expected) {
                throw std::runtime_error("saved PDR query differs from the regenerated obligation");
            }
            cnf.rewind();
            WriteLockedInput artifact(proof_path);
            const auto identity = metadata(id, digest, expected);
            check_result(checker::verify_drat_artifact(cnf.stream(), artifact.stream(),
                identity, checker_limits(memory)));
            artifact.rewind();
            certificate.obligations.push_back({
                identity.query_kind, identity.query_sha256, sha256_stream(artifact.stream())});
        }
        return certificate;
    } catch (const SearchLimit&) {
        return std::nullopt;
    }
}

} // namespace q3a::pdr
