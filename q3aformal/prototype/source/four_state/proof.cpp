#include "proof.hpp"
#include "../replay/replay_timing.hpp"
#include <iostream>

#include "encode.hpp"
#include "sequence.hpp"
#include "../bundle/windows_file_path.hpp"
#include "../source_manager/platform_support.hpp"
#include "../source_manager/vcd_import.hpp"
#include "../source_manager/write_locked_input.hpp"
#include "../../checker/proof_artifact.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <fstream>
#include <stdexcept>

namespace q3a::four_state {
namespace {

constexpr auto query_kind = "four-state-exact";
constexpr auto cover_witness_name = "cover.q3awitness";
constexpr auto counterexample_witness_name = "counterexample.q3awitness";
using lowering::TypedExpression;
using Rails = std::map<std::string, EncodedWord>;

EncodedWord resized(Encoder& encoder, EncodedWord value, std::size_t width, bool sign_extend) {
    if (width == 0 || width > 64 || value.empty()) throw std::invalid_argument("invalid symbolic packed width");
    const auto pad = sign_extend ? value.back() : encoder.constant(Word(1, 0, 0)).front();
    value.resize(width, pad);
    return value;
}

[[noreturn]] void unsupported(const TypedExpression& expression) {
    throw lowering::LoweringError(expression.location, "operator outside the four-state SAT profile: " +
        expression.kind + " " + expression.value, frontend::InputDiagnosticKind::Unsupported);
}

EncodedWord encode_expression(Encoder& encoder, const TypedExpression& expression, const Rails& signals) {
    const auto& operands = expression.operands;
    const auto& kind = expression.kind;
    const auto& op = expression.value;
    const auto operand = [&](std::size_t index) { return encode_expression(encoder, operands.at(index), signals); };
    const auto width = static_cast<std::size_t>(expression.width);
    if (kind == "signal" || kind == "history_ref") return signals.at(op);
    if (kind == "literal" || kind == "constant") return encoder.constant(decode_literal(expression));
    if (kind == "assignment_resize") return resized(encoder, operand(0), width, operands.at(0).is_signed);
    if (kind == "indexed_bit" || kind == "indexed_part") {
        return encoder.indexed_read(operand(0), operand(1), operands.at(1).is_signed,
            std::stoll(operands.at(2).value), std::stoll(operands.at(3).value),
            static_cast<unsigned>(width), op != "-:");
    }
    if (kind == "select") {
        const auto offset = decode_literal(operands.at(1));
        auto source = operand(0);
        if (offset.meta() || offset.data() >= source.size() || width > source.size() - offset.data()) {
            unsupported(expression);
        }
        return {source.begin() + offset.data(), source.begin() + offset.data() + width};
    }
    if (kind == "casez_match" && op == "four-state-z-wildcard") {
        return {encoder.wildcard_case(operand(0), operand(1), false)};
    }
    if (kind == "casex_match" && op == "four-state-xz-wildcard") {
        return {encoder.wildcard_case(operand(0), operand(1), true)};
    }
    if (kind == "concatenation") {
        EncodedWord word;
        for (std::size_t index = operands.size(); index != 0; --index) {
            const auto part = operand(index - 1);
            word.insert(word.end(), part.begin(), part.end());
        }
        return word;
    }
    if (kind == "conditional") {
        const bool sign = operands.at(1).is_signed && operands.at(2).is_signed;
        auto condition = operand(0);
        auto when_true = resized(encoder, operand(1), width, sign);
        auto when_false = resized(encoder, operand(2), width, sign);
        if (op == "if") condition = {encoder.procedural_true(condition)};
        return encoder.select(condition, when_true, when_false);
    }
    if (kind == "unary") {
        if (op == "~") return encoder.bit_not(resized(encoder, operand(0), width, operands.at(0).is_signed));
        if (op == "!") return {encoder.logical_not(operand(0))};
        if (op == "-") {
            return encoder.add_subtract(encoder.constant(Word(static_cast<unsigned>(width), 0, 0)),
                resized(encoder, operand(0), width, operands.at(0).is_signed), true);
        }
        if (frontend::is_reduction_operator(op)) {
            const auto reduction = op == "&" || op == "~&" ? Binary::And :
                op == "|" || op == "~|" ? Binary::Or : Binary::Xor;
            const auto result = encoder.reduce(reduction, operand(0));
            return {op.size() == 1 ? result : encoder.logical_not({result})};
        }
        unsupported(expression);
    }
    if (kind == "binary") {
        auto a = operand(0);
        auto b = operand(1);
        if (op == "&&" || op == "||") {
            return {encoder.logical_binary(op == "&&" ? Binary::And : Binary::Or, a, b)};
        }
        if (frontend::is_shift_operator(op)) {
            const auto direction = op.front() == '<' ? Shift::Left :
                op == ">>>" && expression.is_signed ? Shift::ArithmeticRight : Shift::Right;
            return encoder.shift(resized(encoder, std::move(a), width, expression.is_signed), b, direction);
        }
        const bool bitwise = op == "&" || op == "|" || op == "^" || op == "~^" || op == "^~";
        const bool arithmetic = op == "+" || op == "-" || op == "*" || op == "/" || op == "%";
        const auto common = bitwise || arithmetic ? width : std::max(a.size(), b.size());
        const bool sign = operands.at(0).is_signed && operands.at(1).is_signed;
        a = resized(encoder, std::move(a), common, sign);
        b = resized(encoder, std::move(b), common, sign);
        if (op == "*") return encoder.multiply(a, b);
        if (op == "/" || op == "%") return encoder.divide(a, b, sign, op == "%");
        if (arithmetic) return encoder.add_subtract(a, b, op == "-");
        if (op == "<") return {encoder.less_than(a, b, sign)};
        if (op == ">") return {encoder.less_than(b, a, sign)};
        if (op == "<=") return {encoder.logical_not({encoder.less_than(b, a, sign)})};
        if (op == ">=") return {encoder.logical_not({encoder.less_than(a, b, sign)})};
        if (bitwise) {
            const auto binary = op == "&" ? Binary::And : op == "|" ? Binary::Or : Binary::Xor;
            auto result = encoder.bitwise(binary, a, b);
            return op == "~^" || op == "^~" ? encoder.bit_not(result) : result;
        }
        if (op == "==?" || op == "!=?") {
            const auto result = encoder.wildcard_equality(a, b);
            return {op == "!=?" ? encoder.logical_not({result}) : result};
        }
        if (op == "==" || op == "!=" || op == "===" || op == "!==") {
            const auto result = encoder.equality(a, b, op.size() == 3);
            return {op.front() == '!' ? encoder.logical_not({result}) : result};
        }
    }
    unsupported(expression);
}

Word decoded(const EncodedWord& rails, const sat::Result& solved) {
    std::uint64_t meta = 0, data = 0;
    const auto value = [&](sat::Literal literal) {
        const auto index = static_cast<std::size_t>(literal > 0 ? literal : -static_cast<std::int64_t>(literal));
        const auto bit = solved.assignment.at(index);
        if (bit < 0) throw std::runtime_error("four-state SAT model has an unassigned rail");
        return static_cast<std::uint64_t>((bit != 0) == (literal > 0));
    };
    for (std::size_t bit = 0; bit < rails.size(); ++bit) {
        meta |= value(rails[bit].meta) << bit;
        data |= value(rails[bit].data) << bit;
    }
    return Word(static_cast<unsigned>(rails.size()), meta, data);
}

ProofResult verify(const std::filesystem::path& owner, const checker::ArtifactMetadata& meta,
                   const MemoryBudget& budget) {
    WriteLockedInput cnf(owner / "query.cnf");
    if (sha256_stream(cnf.stream()) != meta.query_sha256) {
        throw std::invalid_argument("four-state certificate query differs from the regenerated query");
    }
    cnf.rewind();
    WriteLockedInput proof(owner / "proof.q3adrat");
    checker::CheckerLimits limits;
    limits.check_memory = [&](std::uint64_t extra) { budget.check(extra); };
    const auto checked = checker::verify_drat_artifact(cnf.stream(), proof.stream(), meta, limits);
    if (checked.resource_limited) throw MemoryBudgetExceeded("four-state proof checker resource limit");
    if (!checked.accepted) throw std::invalid_argument("four-state certificate rejected: " + checked.message);
    proof.rewind();
    auto digest = sha256_stream(proof.stream());
    budget.check();
    return {ProofOutcome::Revalidated, meta.model_sha256, meta.query_sha256, std::move(digest), {}};
}

struct SequenceEncoding {
    SequenceExpansion expansion;
    std::vector<std::vector<sat::Literal>> predicates;
};

struct Failure {
    std::size_t start;
    std::size_t antecedent_end;
    std::size_t goal_start;
    std::size_t deadline;
    sat::Literal literal;
};

void encode_predicates(SequenceEncoding& encoded, const lowering::TIRSequence& sequence,
    Encoder& encoder, const Rails& signals, const MemoryBudget& budget) {
    std::vector<sat::Literal> row;
    row.reserve(sequence.terms.size());
    for (const auto& term : sequence.terms) {
        budget.check();
        row.push_back(encoder.procedural_true(encode_expression(encoder, term.predicate, signals)).data);
    }
    encoded.predicates.push_back(std::move(row));
}

std::vector<std::optional<sat::Literal>> encode_matches(const SequenceEncoding& sequence,
    std::size_t start, Encoder& encoder, sat::Literal always, std::size_t& work, const MemoryBudget& budget) {
    const auto last = sequence.predicates.size() - 1;
    std::vector<std::optional<sat::Literal>> ends(last + 1);
    for (const auto& path : sequence.expansion.paths) {
        const auto end = start + path.back().offset;
        if (end > last) continue;
        auto match = always;
        if (path.size() > 1000000 - work) throw MemoryBudgetExceeded("four-state sequence encoding term budget exceeded");
        work += path.size();
        budget.check();
        for (const auto& term : path) {
            match = encoder.conjunction(match, sequence.predicates[start + term.offset][term.term]);
        }
        ends[end] = ends[end] ? encoder.disjunction(*ends[end], match) : match;
    }
    return ends;
}

std::vector<Failure> assertion_failures(const SequenceEncoding& antecedent,
    const std::optional<SequenceEncoding>& consequent, std::size_t alignment, Encoder& encoder,
    sat::Literal always, const MemoryBudget& budget) {
    const auto last = antecedent.predicates.size() - 1;
    std::size_t work = 0;
    const auto match = [&](const SequenceEncoding& sequence, std::size_t start) {
        auto any = -always;
        for (const auto end : encode_matches(sequence, start, encoder, always, work, budget)) {
            if (end) any = encoder.disjunction(any, *end);
        }
        return any;
    };
    std::vector<Failure> failures;
    std::map<std::size_t, sat::Literal> resolved;
    for (std::size_t start = 0; start <= last; ++start) {
        if (!consequent) {
            if (start + antecedent.expansion.horizon <= last) {
                failures.push_back({start, start, start, start + antecedent.expansion.horizon,
                                    -match(antecedent, start)});
            }
            continue;
        }
        const auto ends = encode_matches(antecedent, start, encoder, always, work, budget);
        for (auto end = start; end <= last; ++end) {
            const auto goal_start = end + alignment;
            const auto deadline = goal_start + consequent->expansion.horizon;
            if (!ends[end] || deadline > last) continue;
            auto known = resolved.find(goal_start);
            if (known == resolved.end()) {
                known = resolved.emplace(goal_start, match(*consequent, goal_start)).first;
            }
            failures.push_back({start, end, goal_start, deadline,
                encoder.conjunction(*ends[end], -known->second)});
        }
    }
    return failures;
}

// A cover must have an actual sequence match. A false antecedent contributes no hit.
sat::Literal cover_hit_literal(const SequenceEncoding& antecedent,
    const std::optional<SequenceEncoding>& consequent, std::size_t alignment,
    Encoder& encoder, sat::Literal always, const MemoryBudget& budget) {
    const auto last = antecedent.predicates.size() - 1;
    std::size_t work = 0;
    auto hit = -always;
    std::map<std::size_t, sat::Literal> consequent_matches;
    for (std::size_t start = 0; start <= last; ++start) {
        const auto ends = encode_matches(antecedent, start, encoder, always, work, budget);
        for (auto end = start; end <= last; ++end) {
            if (!ends[end]) continue;
            if (!consequent) {
                hit = encoder.disjunction(hit, *ends[end]);
                continue;
            }
            const auto next = end + alignment;
            if (next > last) continue;
            auto [found, inserted] = consequent_matches.emplace(next, -always);
            if (inserted) {
                for (const auto match : encode_matches(*consequent, next, encoder, always, work, budget)) {
                    if (match) found->second = encoder.disjunction(found->second, *match);
                }
            }
            hit = encoder.disjunction(hit, encoder.conjunction(*ends[end], found->second));
        }
    }
    return hit;
}

struct EncodedProperty {
    const lowering::TIRProperty& property;
    SequenceEncoding antecedent;
    std::optional<SequenceEncoding> consequent;
    std::vector<Failure> failures;

    std::size_t alignment() const { return property.implication == "nonoverlapped" ? 1 : 0; }
};

EncodedProperty prepare(const lowering::TIRProperty& property, std::size_t last_sample,
                        const MemoryBudget& budget) {
    const bool shape = property.consequent
        ? property.implication == "overlapped" || property.implication == "nonoverlapped"
        : property.implication.empty() || property.implication == "sequence";
    if (!shape || property.history_guard_delay != 0) {
        throw std::invalid_argument("four-state SVA requires finite scalar sequences and default-sampled history: " + property.name);
    }
    EncodedProperty result{
        property, {expand_sequence(property.antecedent, last_sample, budget), {}}, std::nullopt, {}};
    if (property.consequent) {
        result.consequent.emplace(SequenceEncoding{
            expand_sequence(*property.consequent, last_sample, budget), {}});
    }
    return result;
}

void encode_property_sample(EncodedProperty& item, Encoder& encoder, const Rails& signals,
                            const MemoryBudget& budget) {
    encode_predicates(item.antecedent, item.property.antecedent, encoder, signals, budget);
    if (item.consequent) {
        encode_predicates(*item.consequent, *item.property.consequent, encoder, signals, budget);
    }
}

std::vector<Frame> replay_trace(const lowering::TIRModule& model,
    const std::vector<const lowering::TIREquation*>& ordered, const std::vector<Rails>& inputs,
    const sat::Result& solved, const MemoryBudget& budget) {
    std::vector<Frame> trace;
    auto state = initialized_state(model);
    for (std::size_t frame = 0; frame < inputs.size(); ++frame) {
        budget.check();
        Frame input;
        for (const auto& [name, rails] : inputs[frame]) input.emplace(name, decoded(rails, solved));
        trace.push_back(evaluate_sample(model, ordered, std::move(input), state));
        if (frame + 1 < inputs.size()) state = advance_state(model, trace.back());
    }
    return trace;
}

const Failure* replay_failures(const EncodedProperty& item, const std::vector<Frame>& trace,
    const sat::Result* solved, sat::Literal zero, const MemoryBudget& budget) {
    using Matches = std::map<std::size_t, std::vector<bool>>;
    Matches antecedent, consequent;
    const auto ends = [&](Matches& cache, const auto& sequence, std::size_t start) -> const auto& {
        auto seen = cache.find(start);
        if (seen == cache.end()) seen = cache.emplace(start, matched_ends(sequence, trace, start, budget)).first;
        return seen->second;
    };
    const Failure* first_failure = nullptr;
    for (const auto& candidate : item.failures) {
        const auto& first = ends(antecedent, item.property.antecedent, candidate.start);
        const bool triggered = !item.property.consequent || first[candidate.antecedent_end];
        const auto& target = item.property.consequent
            ? ends(consequent, *item.property.consequent, candidate.goal_start) : first;
        const bool replayed = triggered && std::none_of(target.begin(), target.end(), [](bool matched) {
            return matched;
        });
        if (solved && (decoded({{zero, candidate.literal}}, *solved).data() != 0) != replayed) {
            throw std::logic_error("four-state SVA disagrees with source replay");
        }
        if (replayed && (!first_failure || candidate.deadline < first_failure->deadline)) first_failure = &candidate;
    }
    return first_failure;
}

struct CoverMatch {
    std::size_t start;
    std::size_t end;
    std::optional<std::size_t> antecedent_end;
};

std::optional<CoverMatch> replay_cover(const EncodedProperty& item, const std::vector<Frame>& trace,
                                      const MemoryBudget& budget) {
    std::optional<CoverMatch> earliest;
    std::map<std::size_t, std::optional<std::size_t>> consequent_matches;
    for (std::size_t start = 0; start < trace.size(); ++start) {
        const auto ends = matched_ends(item.property.antecedent, trace, start, budget);
        for (auto end = start; end < trace.size(); ++end) {
            if (!ends[end]) continue;
            if (!item.property.consequent) {
                if (!earliest || end < earliest->end) earliest = CoverMatch{start, end, std::nullopt};
                break;
            }
            const auto next = end + item.alignment();
            if (next >= trace.size()) continue;
            auto [found, inserted] = consequent_matches.emplace(next, std::nullopt);
            if (inserted) {
                const auto matches = matched_ends(*item.property.consequent, trace, next, budget);
                const auto first = std::find(matches.begin(), matches.end(), true);
                if (first != matches.end()) found->second = static_cast<std::size_t>(first - matches.begin());
            }
            if (found->second && (!earliest || *found->second < earliest->end)) {
                earliest = CoverMatch{start, *found->second, end};
            }
        }
    }
    return earliest;
}

void require_output(std::ofstream& out) {
    out.close();
    if (!out) throw std::runtime_error("cannot write staged four-state evidence");
}

std::string witness_header(const checker::ArtifactMetadata& meta, bool cover) {
    const auto* version = cover ? "Q3A_FOUR_STATE_COVER_WITNESS_1\n" : "Q3A_FOUR_STATE_COUNTEREXAMPLE_WITNESS_1\n";
    return version + meta.model_sha256 + "\n" + meta.query_sha256 + "\n";
}

// The bound and ordered input widths are bound by the regenerated query. Fixed-width
// records avoid trusting an artifact-supplied count, signal name, width, or match index.
ProofResult verify_witness(const std::filesystem::path& path, const checker::ArtifactMetadata& meta,
    const lowering::TIRModule& model, const std::vector<const lowering::TIREquation*>& ordered,
    const EncodedProperty* goal, const Claim& claim, const std::vector<EncodedProperty>& assumptions,
    std::size_t last, bool cover, bool boundary_open, const MemoryBudget& budget,
    const replay::ReplayTiming* timing) {
    using Duration = replay::ReplayTiming::Duration;
    const auto start = [&] { return timing ? timing->start() : replay::ReplayTiming::Clock::time_point{}; };
    const auto elapsed = [&](auto since) { return timing ? timing->elapsed(since) : Duration{}; };
    auto since = start();
    Duration decode{};
    Duration evaluate{};
    WriteLockedInput artifact(path);
    auto& in = artifact.stream();
    const std::string label = cover ? "four-state cover witness" : "four-state counterexample witness";
    for (const auto ch : witness_header(meta, cover)) {
        if (in.get() != ch) throw std::invalid_argument(label + " identity differs from the regenerated query");
    }

    const auto clock = model.clocks.empty() ? std::string{} : model.clocks.front();
    std::array<char, 64> bits{};
    std::vector<Frame> trace;
    auto state = initialized_state(model);
    decode += elapsed(since);
    for (std::size_t sample = 0; sample <= last; ++sample) {
        since = start();
        budget.check();
        Frame input;
        if (!clock.empty()) input.emplace(clock, Word(1, 0, 1));
        for (const auto& signal : model.signals) {
            if (signal.role != "input" || signal.name == clock) continue;
            const auto width = signal.width;
            if (width == 0 || width > bits.size() || !in.read(bits.data(), static_cast<std::streamsize>(width))) {
                throw std::invalid_argument("truncated or invalid-width " + label);
            }
            const auto word = Word::parse(std::string_view(bits.data(), width));
            if (word.bits() != std::string_view(bits.data(), width)) {
                throw std::invalid_argument("noncanonical " + label + " value");
            }
            input.emplace(signal.name, word);
        }
        if (in.get() != '\n') throw std::invalid_argument("invalid " + label + " sample boundary");
        decode += elapsed(since);
        since = start();
        trace.push_back(evaluate_sample(model, ordered, std::move(input), state));
        if (sample < last) state = advance_state(model, trace.back());
        evaluate += elapsed(since);
    }
    since = start();
    if (in.peek() != std::char_traits<char>::eof() || in.bad()) {
        throw std::invalid_argument("unexpected data following " + label);
    }
    decode += elapsed(since);
    since = start();
    for (const auto& assumption : assumptions) {
        if (replay_failures(assumption, trace, nullptr, 0, budget)) {
            throw std::invalid_argument(label + " violates an assumption");
        }
    }
    std::optional<std::size_t> attempt, failure, antecedent_end, match_sample;
    if (cover) {
        const auto match = replay_cover(*goal, trace, budget);
        if (!match) throw std::invalid_argument(label + " does not reach the selected property");
        attempt = match->start;
        antecedent_end = match->antecedent_end;
        match_sample = match->end;
    } else if (goal) {
        const auto* violation = replay_failures(*goal, trace, nullptr, 0, budget);
        if (!violation) throw std::invalid_argument(label + " does not violate the selected assertion");
        attempt = violation->start;
        failure = violation->deadline;
        if (goal->consequent) antecedent_end = violation->antecedent_end;
    } else if (case_match(trace.back().at(claim.signal), *claim.expected)) {
        throw std::invalid_argument(label + " agrees with the claimed output");
    }
    const auto property = elapsed(since);
    since = start();
    artifact.rewind();
    auto hash = sha256_stream(in);
    budget.check();
    if (timing) {
        const auto digest = elapsed(since);
        timing->write(std::cerr, "witness_decode", decode);
        timing->write(std::cerr, "rtl_evaluation", evaluate);
        timing->write(std::cerr, "property_check", property);
        timing->write(std::cerr, "witness_digest", digest);
    }
    return {cover ? ProofOutcome::CoverHit : ProofOutcome::Counterexample,
        meta.model_sha256, meta.query_sha256, {}, std::move(trace), attempt, failure,
        antecedent_end, boundary_open, match_sample, cover, std::move(hash), true};
}

template <typename Stage>
ProofResult publish_evidence(const std::filesystem::path& directory, Stage stage) {
    const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
    const auto staging = directory.parent_path() /
        (".q3a-four-" + std::to_string(q3a::process_id()) + "-" + std::to_string(nonce));
    if (!std::filesystem::create_directory(staging)) throw std::runtime_error("cannot stage four-state evidence");
    try {
        auto result = stage(staging);
        if (q3a::publish_no_replace(staging, directory)) throw std::runtime_error("cannot publish four-state evidence");
        return result;
    } catch (...) {
        std::error_code ignored;
        for (const auto* name : {"query.cnf", "proof.q3adrat", cover_witness_name, counterexample_witness_name}) {
            std::filesystem::remove(staging / name, ignored);
        }
        std::filesystem::remove(staging, ignored);
        throw;
    }
}

} // namespace

ProofResult check_exact(const lowering::TIRModule& model, const Claim& claim,
    std::string_view model_identity, const std::filesystem::path& evidence,
    const MemoryBudget& budget, bool reopen, bool save_counterexample, const replay::ReplayTiming* timing) {
    const auto started = timing ? timing->start() : replay::ReplayTiming::Clock::time_point{};
    const auto ordered = schedule_combinational(model);
    if (claim.sample.has_value() != !model.clocks.empty()) {
        throw std::invalid_argument("a sample bound is required for clocked four-state models only");
    }
    const auto last = claim.sample.value_or(0);
    if (last > 128) throw std::invalid_argument("four-state sample index exceeds 128");

    std::optional<EncodedProperty> goal;
    bool cover = false;
    std::vector<EncodedProperty> assumptions;
    bool assumption_boundary_open = false;
    for (const auto& item : model.properties) {
        if (item.kind != "assume") continue;
        if (model.clocks.empty() || item.clock != model.clocks.front()) {
            throw std::invalid_argument("four-state assumptions must use the project sampling clock");
        }
        auto assumption = prepare(item, last, budget);
        assumption_boundary_open |= assumption.alignment() != 0 ||
            assumption.antecedent.expansion.horizon != 0 ||
            (assumption.consequent && assumption.consequent->expansion.horizon != 0);
        assumptions.push_back(std::move(assumption));
    }
    if (claim.expected) {
        const auto target = std::find_if(model.signals.begin(), model.signals.end(), [&](const auto& signal) {
            return signal.name == claim.signal &&
                (signal.role == "output" || (claim.sample && signal.role == "state"));
        });
        if (target == model.signals.end() || target->width != claim.expected->width()) {
            throw std::invalid_argument("four-state claim requires an output with the exact expected width");
        }
    } else {
        const auto found = std::find_if(model.properties.begin(), model.properties.end(),
            [&](const auto& item) { return item.name == claim.signal; });
        if (found == model.properties.end() || (found->kind != "assert" && found->kind != "cover") ||
            model.clocks.empty() || found->clock != model.clocks.front()) {
            throw std::invalid_argument("expected a named assertion or cover on the four-state sampling clock");
        }
        cover = found->kind == "cover";
        goal.emplace(prepare(*found, last, budget));
    }
    sat::Solver solver([&](std::uint64_t extra) { budget.check(extra); });
    Encoder encoder(solver);
    Rails state;
    for (const auto& [name, word] : initialized_state(model)) state.emplace(name, encoder.constant(word));
    std::vector<Rails> inputs(last + 1);
    Rails signals;
    const auto always = encoder.constant(Word(1, 0, 1)).front();
    for (std::size_t frame = 0; frame <= last; ++frame) {
        budget.check();
        for (const auto& signal : model.signals) {
            if (signal.role != "input") continue;
            const bool clock = claim.sample && signal.name == model.clocks.front();
            auto rails = clock ? encoder.constant(Word(1, 0, 1)) :
                encoder.fresh(static_cast<unsigned>(signal.width));
            inputs[frame].emplace(signal.name, std::move(rails));
        }
        signals = inputs[frame];
        signals.insert(state.begin(), state.end());
        for (const auto* equation : ordered) {
            budget.check();
            auto rails = encode_expression(encoder, equation->expression, signals);
            if (rails.size() != equation->target_width) throw std::invalid_argument("four-state SAT equation width mismatch");
            signals.emplace(equation->target, std::move(rails));
        }
        if (goal) encode_property_sample(*goal, encoder, signals, budget);
        for (auto& assumption : assumptions) encode_property_sample(assumption, encoder, signals, budget);
        if (frame == last) break;
        state.clear();
        for (const auto& equation : model.next_state_equations) {
            budget.check();
            auto rails = encode_expression(encoder, equation.expression, signals);
            if (rails.size() != equation.target_width) throw std::invalid_argument("four-state next-state width mismatch");
            state.emplace(equation.target, std::move(rails));
        }
    }
    const auto binding = sha256_hex(std::string(goal ? "Q3A-FOUR-STATE-SVA-1\n" : "Q3A-FOUR-STATE-EXACT-1\n") +
        std::string(model_identity) + "\n" + claim.signal + "\n" +
        (claim.expected ? claim.expected->bits() : cover ? "cover" : "assertion") +
        (claim.sample ? "\nsampled " + std::to_string(last) : ""));
    const auto digest_query = [&] {
        return sha256_generated([&](auto& out) { solver.write_dimacs(out); });
    };
    const auto check_environment = [&](const auto& trace, const auto& solved) {
        for (const auto& assumption : assumptions) {
            if (replay_failures(assumption, trace, &solved, always.meta, budget)) {
                throw std::logic_error("four-state sample violates an environment assumption");
            }
        }
    };
    for (auto& item : assumptions) {
        item.failures = assertion_failures(item.antecedent, item.consequent, item.alignment(), encoder, always.data, budget);
        for (const auto& failure : item.failures) solver.add_clause({-failure.literal});
    }
    const auto hit = cover ? cover_hit_literal(goal->antecedent, goal->consequent, goal->alignment(),
                                                encoder, always.data, budget) : -always.data;
    if (goal && !cover) {
        goal->failures = assertion_failures(goal->antecedent, goal->consequent, goal->alignment(), encoder, always.data, budget);
        if (goal->failures.empty()) throw std::invalid_argument("no assertion attempt completes within the sample bound");
    }
    const auto query_type = cover ? "four-state-sampled-cover" : goal ? "four-state-sampled-sva" :
        claim.sample ? "four-state-sampled-exact" : query_kind;
    const auto directory = bundle::detail::absolute_windows_file_path(evidence);
    const auto add_goal_clause = [&] {
        if (cover) {
            solver.add_clause({hit});
        } else if (goal) {
            std::vector<sat::Literal> clause;
            for (const auto& failure : goal->failures) clause.push_back(failure.literal);
            solver.add_clause(clause);
        } else {
            const auto matches = encoder.equality(signals.at(claim.signal), encoder.constant(*claim.expected), true);
            solver.add_clause({-matches.data});
        }
    };
    const auto* witness_name = cover ? cover_witness_name : counterexample_witness_name;
    const auto replay_saved = [&](const auto& path, const auto& meta) {
        return verify_witness(path, meta, model, ordered, goal ? &*goal : nullptr, claim, assumptions,
            last, cover, assumption_boundary_open, budget, timing);
    };
    if (reopen) {
        const auto* other = cover ? counterexample_witness_name : cover_witness_name;
        if (std::filesystem::exists(directory / other)) {
            throw std::invalid_argument("four-state evidence contains a witness of another claim kind");
        }
        if (std::filesystem::exists(directory / witness_name)) {
            if (std::filesystem::exists(directory / "query.cnf") || std::filesystem::exists(directory / "proof.q3adrat")) {
                throw std::invalid_argument("ambiguous four-state witness evidence directory");
            }
            add_goal_clause();
            const checker::ArtifactMetadata meta{query_type, checker::kCheckerId, binding, digest_query()};
            if (timing) timing->write(std::cerr, "query_regeneration", timing->elapsed(started));
            return replay_saved(directory / witness_name, meta);
        }
    }

    sat::Limits limits;
    limits.decisions = 1000000;
    if (!assumptions.empty()) {
        const auto environment = solver.solve(limits);
        if (environment.status != sat::Status::Satisfiable) {
            const auto outcome = environment.status == sat::Status::Unsatisfiable
                ? ProofOutcome::Inconsistent : ProofOutcome::Unknown;
            ProofResult result{outcome, binding, digest_query(), {}, {}};
            result.cover = cover;
            return result;
        }
        check_environment(replay_trace(model, ordered, inputs, environment, budget), environment);
    }
    add_goal_clause();
    const auto query_hash = digest_query();
    const checker::ArtifactMetadata meta{query_type, checker::kCheckerId, binding, query_hash};
    if (reopen) {
        auto result = verify(directory, meta, budget);
        result.cover = cover;
        return result;
    }
    if (std::filesystem::exists(directory)) throw std::invalid_argument("four-state evidence directory already exists");

    limits.record_drat_proof = true;
    limits.proof_records = 250000;
    auto solved = solver.solve(limits);
    if (solved.status == sat::Status::Unknown) {
        ProofResult result{ProofOutcome::Unknown, binding, query_hash, {}, {}};
        result.cover = cover;
        return result;
    }
    if (solved.status == sat::Status::Satisfiable) {
        auto trace = replay_trace(model, ordered, inputs, solved, budget);
        check_environment(trace, solved);
        const auto save_witness = [&] {
            return publish_evidence(directory, [&](const auto& staged) {
                const auto path = staged / witness_name;
                std::ofstream artifact(path, std::ios::binary);
                artifact << witness_header(meta, cover);
                const auto clock = model.clocks.empty() ? std::string{} : model.clocks.front();
                for (const auto& frame : trace) {
                    budget.check();
                    for (const auto& signal : model.signals) {
                        if (signal.role == "input" && signal.name != clock) {
                            artifact << frame.at(signal.name).bits();
                        }
                    }
                    artifact << '\n';
                }
                require_output(artifact);
                trace.clear();
                auto result = replay_saved(path, meta);
                result.witness_revalidated = false;
                return result;
            });
        };
        if (cover) return save_witness();
        std::optional<std::size_t> attempt, failure, antecedent_end;
        if (goal) {
            const auto* witness = replay_failures(*goal, trace, &solved, always.meta, budget);
            if (!witness) throw std::logic_error("four-state assertion violation failed source replay");
            attempt = witness->start;
            failure = witness->deadline;
            if (goal->consequent) antecedent_end = witness->antecedent_end;
        } else {
            const auto actual = trace.back().at(claim.signal);
            if (case_match(actual, *claim.expected) ||
                !case_match(actual, decoded(signals.at(claim.signal), solved))) {
                throw std::logic_error("four-state counterexample failed independent source replay");
            }
        }
        budget.check();
        if (save_counterexample) return save_witness();
        return {ProofOutcome::Counterexample, binding, query_hash, {}, std::move(trace),
            attempt, failure, antecedent_end, assumption_boundary_open};
    }

    return publish_evidence(directory, [&](const auto& staging) {
        std::ofstream query(staging / "query.cnf", std::ios::binary);
        solver.write_dimacs(query);
        require_output(query);
        std::ofstream artifact(staging / "proof.q3adrat", std::ios::binary);
        checker::ProofResult proof{checker::ProofStatus::Unsatisfiable, 0, std::move(solved.drat_additions), {}};
        if (!checker::write_drat_artifact(proof, meta, artifact).accepted) {
            throw std::logic_error("cannot create four-state proof artifact");
        }
        require_output(artifact);
        auto result = verify(staging, meta, budget);
        result.outcome = ProofOutcome::Proven;
        result.cover = cover;
        return result;
    });
}

std::string save_waveform(const std::filesystem::path& path, const lowering::TIRModule& model,
                          const ProofResult& result, const MemoryBudget& budget) {
    const auto target = bundle::detail::absolute_windows_file_path(path);
    if (!target.has_filename() || std::filesystem::exists(target) || result.trace.empty()) {
        throw std::invalid_argument("four-state waveform requires a replayed trace and an unused output path");
    }

    std::string scope = "__q3a_diagnostic";
    const auto occupied = [&](const std::string& name) {
        return std::any_of(model.signals.begin(), model.signals.end(), [&](const auto& signal) {
            return signal.name == name || signal.name.compare(0, name.size() + 1, name + ".") == 0;
        });
    };
    for (std::size_t suffix = 1; occupied(scope); ++suffix) scope = "__q3a_diagnostic_" + std::to_string(suffix);

    std::vector<lowering::TIRSignal> markers;
    std::map<std::string, std::size_t> marker_samples;
    const auto add_marker = [&](const char* name, const auto& sample) {
        if (!sample) return;
        auto full_name = scope + "." + name;
        marker_samples.emplace(full_name, *sample);
        markers.emplace_back(std::move(full_name), 1, false, "diagnostic", frontend::SourceLocation{});
    };
    add_marker("attempt_sample", result.attempt_sample);
    add_marker("antecedent_end_sample", result.antecedent_end_sample);
    add_marker("match_sample", result.match_sample);
    add_marker("failure_sample", result.failure_sample);

    trace::CaptureSignals emitted;
    for (const auto& signal : model.signals) {
        if (std::find(model.clocks.begin(), model.clocks.end(), signal.name) == model.clocks.end()) {
            emitted.push_back(&signal);
        }
    }
    for (const auto& marker : markers) emitted.push_back(&marker);
    constexpr std::uint64_t maximum_payload = 128 * 1024 * 1024;
    std::uint64_t bytes_per_sample = 32 + 16 * model.clocks.size();
    for (const auto* signal : emitted) bytes_per_sample += signal->width + 24;
    if (emitted.size() + model.clocks.size() > 100000 ||
        result.trace.size() > maximum_payload / bytes_per_sample) {
        throw MemoryBudgetExceeded("four-state waveform exceeds the export size limit");
    }

    const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
    const auto staging = target.parent_path() /
        (".q3a-four-vcd-" + std::to_string(q3a::process_id()) + "-" + std::to_string(nonce));
    if (!std::filesystem::create_directory(staging)) throw std::runtime_error("cannot stage four-state waveform");
    const auto file = staging / "result.vcd";
    try {
        std::ofstream out(file, std::ios::binary);
        trace::write_logic_vcd(out, model, result.trace.size(), emitted, [&](std::size_t sample, const auto& signal) {
            if (&signal == emitted.front()) budget.check();
            if (signal.role == "diagnostic") {
                return std::string(1, marker_samples.at(signal.name) == sample ? '1' : '0');
            }
            return result.trace.at(sample).at(signal.name).bits();
        });
        require_output(out);
        std::string digest;
        {
            WriteLockedInput checked(file);
            digest = sha256_stream(checked.stream());
        }
        budget.check();
        if (q3a::publish_no_replace(file, target)) throw std::runtime_error("cannot publish four-state waveform");
        std::error_code ignored;
        std::filesystem::remove(staging, ignored);
        return digest;
    } catch (...) {
        std::error_code ignored;
        std::filesystem::remove(file, ignored);
        std::filesystem::remove(staging, ignored);
        throw;
    }
}

} // namespace q3a::four_state
