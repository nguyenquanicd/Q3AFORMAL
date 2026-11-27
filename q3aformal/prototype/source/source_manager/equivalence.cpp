#include "equivalence.hpp"

#include "pdr.hpp"
#include "platform_support.hpp"
#include "property_replay.hpp"
#include "transition_encoder.hpp"
#include "vcd_import.hpp"
#include "write_locked_input.hpp"
#include "../bundle/windows_file_path.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <fstream>
#include <iomanip>
#include <map>
#include <set>
#include <sstream>

namespace q3a::equivalence {
namespace {
using Pair = std::pair<std::string, std::string>;
using Expression = lowering::TypedExpression;
constexpr const char* kProperty = "__q3a_equivalence";
constexpr const char* kStarted = "control.started";
constexpr const char* kStateProperty = "__q3a_state_relation";

struct StatePair {
    Pair signals;
    bool inverted = false;
    std::uint64_t mask = 0;
};

enum class InitialScope { Unspecified, Independent, Matched, Reset };

struct Plan {
    Pair clock;
    std::vector<Pair> inputs;
    std::vector<Pair> outputs;
    std::vector<StatePair> states;
    std::string reset;
    bool reset_high = false;
    InitialScope initial = InitialScope::Unspecified;
    std::string sha256;
};

std::filesystem::path native(const std::filesystem::path& path) {
    return bundle::detail::absolute_windows_file_path(path);
}

Plan read_plan(const std::filesystem::path& path) {
    WriteLockedInput file(native(path));
    std::array<char, 65537> bytes{};
    auto& input = file.stream();
    input.read(bytes.data(), bytes.size());
    if (input.bad() || input.gcount() == bytes.size()) {
        throw std::invalid_argument("equivalence plan exceeds its read limit");
    }
    const std::string text(bytes.data(), static_cast<std::size_t>(input.gcount()));
    Plan out;
    out.sha256 = sha256_hex(text);
    std::istringstream lines(text);
    std::string line, kind, extra;
    if (!std::getline(lines, line) || (line != "Q3AFORMAL_EQUIVALENCE 1" && line != "Q3AFORMAL_EQUIVALENCE 1\r")) {
        throw std::invalid_argument("expected Q3AFORMAL_EQUIVALENCE 1");
    }
    while (std::getline(lines, line)) {
        std::istringstream field(line);
        if (!(field >> kind)) continue;
        Pair pair;
        if (kind == "initial" && out.initial == InitialScope::Unspecified) {
            std::string scope;
            if (!(field >> scope) || (scope != "independent" && scope != "matched") || field >> extra) {
                throw std::invalid_argument("expected initial independent|matched");
            }
            out.initial = scope == "independent" ? InitialScope::Independent : InitialScope::Matched;
            continue;
        }
        if (kind == "reset" && out.initial == InitialScope::Unspecified) {
            if (!(field >> out.reset >> extra) || (extra != "high" && extra != "low")) {
                throw std::invalid_argument("expected reset REFERENCE_INPUT high|low");
            }
            out.initial = InitialScope::Reset;
            out.reset_high = extra == "high";
            if (field >> extra) throw std::invalid_argument("malformed reset rule");
            continue;
        }
        if (kind == "state") {
            std::string relation;
            if (!(field >> pair.first >> pair.second >> relation) ||
                (relation != "equal" && relation != "invert") || field >> extra) {
                throw std::invalid_argument("expected state REFERENCE IMPLEMENTATION equal|invert");
            }
            out.states.push_back({std::move(pair), relation == "invert", 0});
            continue;
        }
        if (!(field >> pair.first >> pair.second) || field >> extra) {
            throw std::invalid_argument("expected clock, input or output with two port names");
        }
        if (kind == "clock" && out.clock.first.empty()) out.clock = std::move(pair);
        else if (kind == "input") out.inputs.push_back(std::move(pair));
        else if (kind == "output") out.outputs.push_back(std::move(pair));
        else throw std::invalid_argument("invalid equivalence plan record");
    }
    if (out.clock.first.empty() || out.outputs.empty() || out.initial == InitialScope::Unspecified) {
        throw std::invalid_argument("equivalence requires a clock mapping, outputs and an initial-state scope");
    }
    if (out.initial == InitialScope::Matched && out.states.empty()) {
        throw std::invalid_argument("initial matched requires at least one declared state relation");
    }
    return out;
}

Expression literal(bool value) {
    return {"literal", value ? "1'b1" : "1'b0", 1, false, {}, {}};
}

Expression signal(const lowering::TIRSignal& signal) {
    return {"signal", signal.name, signal.width, signal.is_signed, signal.location, {}};
}

Expression unary_not(Expression value) {
    return {"unary", "!", 1, false, {}, {std::move(value)}};
}

Expression binary(std::string op, Expression left, Expression right) {
    return {"binary", std::move(op), 1, false, {}, {std::move(left), std::move(right)}};
}

lowering::TIRProperty predicate(std::string name, std::string kind, const std::string& clock, Expression value) {
    lowering::TIRProperty property;
    property.name = std::move(name);
    property.kind = std::move(kind);
    property.clock = clock;
    property.implication = "sequence";
    property.antecedent.terms.push_back({0, 1, 1, value, {}});
    property.antecedent.automaton = {2, 0, 1, {{0, 1, 0, 1, 1, std::move(value), {}}}};
    property.antecedent.path_lengths = {1};
    return property;
}

Expression conjunction(std::vector<Expression> values) {
    // Keep the predicate tree balanced for wide interfaces.
    while (values.size() > 1) {
        std::vector<Expression> level;
        for (std::size_t i = 0; i < values.size(); i += 2) {
            if (i + 1 == values.size()) level.push_back(std::move(values[i]));
            else level.push_back(binary("&&", std::move(values[i]), std::move(values[i + 1])));
        }
        values = std::move(level);
    }
    return std::move(values.front());
}

struct Product {
    lowering::TIRModule model;
    std::vector<Pair> observations;
    std::vector<StatePair> relations;
};

Product build_product(const Design& reference, const Design& implementation, const Plan& plan) {
    using Direction = frontend::PortDirection;
    const auto port_index = [](const Design& design, const std::string& clock) {
        if ((!design.model.clocks.empty() && design.model.clocks != std::vector<std::string>{clock}) ||
            std::any_of(design.model.properties.begin(), design.model.properties.end(),
                        [](const auto& property) { return property.kind == "assume"; })) {
            throw std::invalid_argument("equivalence requires the mapped single clock and a common plan environment without RTL assumptions");
        }
        std::map<std::string, const elaboration::TypedSignal*> index;
        for (const auto& port : design.ports) index.emplace(port.name, &port);
        return index;
    };
    if (reference.model.semantic_profile != implementation.model.semantic_profile) {
        throw std::invalid_argument("equivalence requires identical semantic profiles");
    }
    const auto ref_ports = port_index(reference, plan.clock.first);
    const auto imp_ports = port_index(implementation, plan.clock.second);
    std::set<std::string> used_ref, used_imp;
    std::map<std::string, std::string> shared_ref, shared_imp;
    const auto bind_port = [&](const Pair& pair, Direction direction) -> const elaboration::TypedSignal& {
        const auto left = ref_ports.find(pair.first), right = imp_ports.find(pair.second);
        if (left == ref_ports.end() || right == imp_ports.end() ||
            left->second->direction != direction || right->second->direction != direction ||
            left->second->width != right->second->width || left->second->is_signed != right->second->is_signed ||
            left->second->packed_left_index != right->second->packed_left_index ||
            left->second->packed_right_index != right->second->packed_right_index ||
            !used_ref.insert(pair.first).second || !used_imp.insert(pair.second).second) {
            throw std::invalid_argument("invalid equivalence port binding: " + pair.first + " " + pair.second);
        }
        return *left->second;
    };
    const auto bind_input = [&](const Pair& pair) {
        const auto& port = bind_port(pair, Direction::Input);
        shared_ref.emplace(pair.first, "shared." + pair.first);
        shared_imp.emplace(pair.second, "shared." + pair.first);
        return port.width;
    };
    if (bind_input(plan.clock) != 1) throw std::invalid_argument("equivalence clock must be one bit");
    for (const auto& pair : plan.inputs) bind_input(pair);
    Product product;
    for (const auto& pair : plan.outputs) {
        bind_port(pair, Direction::Output);
        product.observations.emplace_back("reference." + pair.first, "implementation." + pair.second);
    }
    if (used_ref.size() != ref_ports.size() || used_imp.size() != imp_ports.size()) {
        throw std::invalid_argument("equivalence requires complete one-to-one top port mapping");
    }

    auto& model = product.model;
    model.name = "__q3a_equivalence_product";
    model.semantic_profile = reference.model.semantic_profile;
    const auto model_digest = [](const Design& design) { return sha256_hex(lowering::serialize_tir(design.model)); };
    const auto identity = std::string("Q3AFORMAL_EQUIVALENCE 1\n") + model_digest(reference) + '\n' +
        reference.manifest_sha256 + '\n' + model_digest(implementation) + '\n' +
        implementation.manifest_sha256 + '\n' + plan.sha256 + '\n';
    model.input_hash = sha256_hex(identity);
    const auto clock = shared_ref.at(plan.clock.first);
    model.clocks = {clock};
    const auto add_side = [&](const Design& side, const std::string& prefix, const auto& shared, bool add_inputs) {
        const auto rename = [&](const std::string& name) {
            const auto found = shared.find(name);
            return found != shared.end() ? found->second : prefix + name;
        };
        for (auto entry : side.model.signals) {
            if (!add_inputs && shared.count(entry.name)) continue;
            entry.name = rename(entry.name);
            model.signals.push_back(std::move(entry));
        }
        const auto rename_expression = [&](const auto& self, Expression& value) -> void {
            if (value.kind == "signal" || value.kind == "history_ref") value.value = rename(value.value);
            for (auto& operand : value.operands) self(self, operand);
        };
        const auto add_equations = [&](const auto& source, auto& destination) {
            for (auto eq : source) {
                eq.target = rename(eq.target);
                rename_expression(rename_expression, eq.expression);
                destination.push_back(std::move(eq));
            }
        };
        add_equations(side.model.combinational_equations, model.combinational_equations);
        add_equations(side.model.next_state_equations, model.next_state_equations);
        for (auto guard : side.model.history_guards) {
            guard.clock = clock;
            guard.valid_signal = rename(guard.valid_signal);
            for (auto& name : guard.state_chain) name = rename(name);
            model.history_guards.push_back(std::move(guard));
        }
    };
    add_side(reference, "reference.", shared_ref, true);
    add_side(implementation, "implementation.", shared_imp, false);
    const auto find_signal = [&](const std::string& name) {
        const auto it = std::find_if(model.signals.begin(), model.signals.end(),
                                     [&](const auto& entry) { return entry.name == name; });
        if (it == model.signals.end()) throw std::logic_error("missing mapped model signal: " + name);
        return signal(*it);
    };
    std::vector<Expression> comparisons;
    for (const auto& pair : product.observations) {
        comparisons.push_back(binary("==", find_signal(pair.first), find_signal(pair.second)));
    }
    auto observation = conjunction(std::move(comparisons));
    std::vector<Expression> relations;
    std::set<std::string> ref_states, imp_states;
    const auto driven_state = [](const Design& design, const std::string& name) -> const lowering::TIRSignal* {
        const auto entry = std::find_if(design.model.signals.begin(), design.model.signals.end(),
                                        [&](const auto& signal) { return signal.name == name; });
        if (entry == design.model.signals.end() || entry->role != "state") return nullptr;
        const auto& updates = design.model.next_state_equations;
        if (std::none_of(updates.begin(), updates.end(), [&](const auto& eq) { return eq.target == name; })) return nullptr;
        return &*entry;
    };
    for (const auto& pair : plan.states) {
        const auto& names = pair.signals;
        const auto* lhs = driven_state(reference, names.first);
        const auto* rhs = driven_state(implementation, names.second);
        if (!lhs || !rhs || lhs->width == 0 || lhs->width > 64 || lhs->width != rhs->width || lhs->is_signed != rhs->is_signed ||
            lhs->packed_left_index != rhs->packed_left_index || lhs->packed_right_index != rhs->packed_right_index ||
            !ref_states.insert(names.first).second || !imp_states.insert(names.second).second) {
            throw std::invalid_argument("invalid equivalence state binding: " + names.first + " " + names.second);
        }
        const auto width = lhs->width;
        const auto mask = width == 64 ? ~std::uint64_t{0} : (std::uint64_t{1} << width) - 1;
        const Pair mapped{"reference." + names.first, "implementation." + names.second};
        product.relations.push_back({mapped, pair.inverted, mask});
        auto value = find_signal(mapped.second);
        if (pair.inverted) {
            value = {"unary", "~", value.width, value.is_signed, value.location, {std::move(value)}};
        }
        relations.push_back(binary("==", find_signal(mapped.first), std::move(value)));
    }
    if (plan.initial == InitialScope::Reset || plan.initial == InitialScope::Matched) {
        model.signals.emplace_back(kStarted, 1, false, "history_valid", frontend::SourceLocation{});
        model.history_guards.push_back({clock, 1, kStarted, {kStarted}});
        model.next_state_equations.push_back({kStarted, 1, literal(true), {}});
    }
    if (plan.initial == InitialScope::Reset) {
        if (plan.reset == plan.clock.first || shared_ref.count(plan.reset) == 0) {
            throw std::invalid_argument("equivalence reset must be a mapped non-clock input");
        }
        auto reset = find_signal(shared_ref.at(plan.reset));
        if (reset.width != 1) throw std::invalid_argument("equivalence reset must be one bit");
        if (!plan.reset_high) reset = unary_not(std::move(reset));
        model.properties.push_back(predicate("__q3a_reset_environment", "assume", clock,
            binary("||", find_signal(kStarted), std::move(reset))));
        observation = binary("||", unary_not(find_signal(kStarted)), std::move(observation));
    }
    if (!relations.empty()) {
        auto relation = conjunction(std::move(relations));
        if (plan.initial == InitialScope::Matched) {
            // The independently initialized flag is false at sample zero and true thereafter.
            model.properties.push_back(predicate("__q3a_initial_pair_environment", "assume", clock,
                binary("||", find_signal(kStarted), relation)));
        } else if (plan.initial == InitialScope::Reset) {
            relation = binary("||", unary_not(find_signal(kStarted)), std::move(relation));
        }
        model.properties.push_back(predicate(kStateProperty, "assert", clock, std::move(relation)));
    }
    model.properties.push_back(predicate(kProperty, "assert", clock, std::move(observation)));
    return product;
}

bool literal_value(sat::Literal literal, const sat::Result& solved) {
    const auto value = solved.assignment.at(literal < 0 ? -literal : literal);
    if (value < 0) throw std::runtime_error("equivalence SAT assignment is incomplete");
    return (value != 0) == (literal > 0);
}

using Trace = std::vector<replay::Frame>;
struct Witness {
    Trace trace;
    std::size_t frame = 0;
    bool has_waveform = true;
};

std::optional<Witness> find_witness(const Product& product, const char* property, std::size_t depth, const MemoryBudget& memory) {
    sat::Solver solver([&](auto bytes) { memory.check(bytes); });
    sat::TransitionCnfEncoder encoder(solver, product.model);
    encoder.encode(depth);
    encoder.constrain_assumptions();
    const auto query = encoder.add_assertion_violation(property);
    solver.add_clause(query.violation_literals);
    const auto result = solver.solve({1000000, 10000000});
    if (result.status == sat::Status::Unknown) return std::nullopt;
    if (result.status != sat::Status::Satisfiable) throw std::runtime_error("candidate cannot be reproduced on the exact paired model");
    Witness witness;
    witness.trace.resize(encoder.frames().size());
    for (std::size_t t = 0; t < witness.trace.size(); ++t) {
        memory.check();
        for (const auto& [name, bits] : encoder.frames()[t]) {
            std::uint64_t value = 0;
            for (std::size_t i = 0; i < bits.size(); ++i) {
                if (literal_value(bits[i], result)) value |= std::uint64_t{1} << i;
            }
            witness.trace[t].emplace(name, value);
        }
    }
    for (std::size_t i = 0; i < query.violation_literals.size(); ++i) {
        if (literal_value(query.violation_literals[i], result)) {
            witness.frame = query.violation_frames[i];
            return witness;
        }
    }
    throw std::runtime_error("candidate has no failing paired observation");
}

void validate_witness(const Product& product, const char* property, const Witness& witness, const MemoryBudget& memory) {
    const replay::FrameView frames(witness.trace.size(), [&](std::size_t index) -> const replay::Frame& {
        memory.check();
        return witness.trace.at(index);
    });
    const auto result = replay::validate_bounded_counterexample_view(product.model, frames, property, witness.frame);
    if (!result.validated) throw std::runtime_error("paired witness replay rejected: " + result.message);
}

std::filesystem::path waveform_path(std::filesystem::path witness) {
    return witness.replace_extension(".vcd");
}

void render_waveform(const Product& product, const Witness& witness, const MemoryBudget& memory, std::ostream& out) {
    trace::CaptureSignals signals;
    signals.reserve(product.model.signals.size());
    for (const auto& signal : product.model.signals) signals.push_back(&signal);
    const replay::FrameView frames(witness.trace.size(), [&](std::size_t index) -> const replay::Frame& {
        memory.check();
        return witness.trace.at(index);
    });
    trace::write_witness_vcd(out, product.model, frames, signals, witness.frame);
}

void verify_waveform(const std::filesystem::path& path, const Product& product,
                     const Witness& witness, const MemoryBudget& memory) {
    if (!witness.has_waveform) return;
    WriteLockedInput input(native(waveform_path(path)));
    const auto expected = sha256_generated([&](auto& out) { render_waveform(product, witness, memory, out); });
    if (sha256_stream(input.stream()) != expected) {
        throw std::invalid_argument("equivalence waveform differs from the replayed witness");
    }
}

void write_witness(const std::filesystem::path& path, const Product& product, const Witness& witness,
                   const MemoryBudget& memory) {
    std::ofstream waveform(native(waveform_path(path)), std::ios::binary);
    render_waveform(product, witness, memory, waveform);
    waveform.close();
    if (!waveform) throw std::runtime_error("cannot publish equivalence waveform");
    std::ofstream out(native(path), std::ios::binary);
    out << "Q3AFORMAL_EQ_WITNESS 2\n" << product.model.input_hash << '\n'
        << witness.trace.size() << ' ' << witness.frame << '\n';
    for (const auto& frame : witness.trace) {
        for (const auto& signal : product.model.signals) out << frame.at(signal.name) << ' ';
        out << '\n';
    }
    out.close();
    if (!out) throw std::runtime_error("cannot publish paired witness");
    WriteLockedInput content(native(path));
    auto digest_path = path;
    digest_path += ".sha256";
    std::ofstream digest(native(digest_path), std::ios::binary);
    digest << sha256_stream(content.stream()) << '\n';
    digest.close();
    if (!digest) throw std::runtime_error("cannot publish paired witness digest");
}

Witness read_witness(const std::filesystem::path& path, const Product& product, const MemoryBudget& memory) {
    const auto input = native(path);
    if (std::filesystem::file_size(input) > 64ULL * 1024 * 1024) throw std::invalid_argument("paired witness exceeds its read limit");
    WriteLockedInput file(input);
    auto& stream = file.stream();
    auto digest_path = path;
    digest_path += ".sha256";
    WriteLockedInput recorded(native(digest_path));
    std::array<char, 66> bytes{};
    recorded.stream().read(bytes.data(), bytes.size());
    if (recorded.stream().bad() || recorded.stream().gcount() != 65 || bytes[64] != '\n' ||
        std::string_view(bytes.data(), 64) != sha256_stream(stream)) {
        throw std::invalid_argument("paired witness digest differs");
    }
    file.rewind();
    std::string marker, digest, token;
    std::size_t count = 0, failed = 0;
    if (!std::getline(stream, marker) || (marker != "Q3AFORMAL_EQ_WITNESS 1" && marker != "Q3AFORMAL_EQ_WITNESS 2") ||
        !std::getline(stream, digest) || digest != product.model.input_hash ||
        !(stream >> count >> failed) || count == 0 || count > pdr::kMaximumDepth + 1 || failed >= count) {
        throw std::invalid_argument("invalid paired witness header or source identity");
    }
    Witness witness;
    witness.frame = failed;
    witness.has_waveform = marker == "Q3AFORMAL_EQ_WITNESS 2";
    for (std::size_t i = 0; i < count; ++i) {
        memory.check();
        replay::Frame frame;
        for (const auto& signal : product.model.signals) {
            std::uint64_t value = 0;
            if (!(stream >> token) || token.size() > 20) throw std::invalid_argument("invalid paired witness token");
            const auto decoded = std::from_chars(token.data(), token.data() + token.size(), value);
            if (decoded.ec != std::errc{} || decoded.ptr != token.data() + token.size() ||
                (signal.width < 64 && value >= (std::uint64_t{1} << signal.width))) {
                throw std::invalid_argument("invalid paired witness signal value");
            }
            frame.emplace(signal.name, value);
        }
        witness.trace.push_back(std::move(frame));
    }
    if (stream >> token || !stream.eof() || stream.bad()) throw std::invalid_argument("trailing data in paired witness");
    return witness;
}
} // namespace

int check(const Design& reference, const Design& implementation, const std::filesystem::path& plan_path,
          const std::filesystem::path& evidence, bool reopen, std::size_t depth, const MemoryBudget& memory,
          std::ostream& output) {
    const auto plan = read_plan(plan_path);
    memory.check();
    const auto product = build_product(reference, implementation, plan);
    const auto witness_path = evidence / "paired-witness.txt";
    const auto certificate = evidence / "certificate";
    const auto state_witness = evidence / "state-witness.txt";
    const auto state_certificate = evidence / "state-certificate";
    if (!reopen && !std::filesystem::create_directory(native(evidence))) {
        throw std::invalid_argument("equivalence output directory already exists");
    }
    std::string relation_model;
    const auto scope = plan.initial == InitialScope::Reset ? "AFTER_FIRST_RESET_EDGE" :
        plan.initial == InitialScope::Matched ? "MATCHED_INITIAL_STATES" : "INDEPENDENT_INITIAL_STATES";
    const std::size_t first_observed = plan.initial == InitialScope::Reset ? 1 : 0;
    const auto report = [&](const char* status, const Witness* witness, bool state_failure = false,
                            const std::string& model_digest = {}) {
        output << "{\"status\":" << std::quoted(status)
               << ",\"context_sha256\":" << std::quoted(product.model.input_hash)
               << ",\"scope\":" << std::quoted(scope);
        if (!model_digest.empty()) output << ",\"certificate_model_sha256\":" << std::quoted(model_digest);
        if (!relation_model.empty()) {
            output << ",\"state_certificate_model_sha256\":" << std::quoted(relation_model);
        }
        if (witness) {
            const auto& frame = witness->trace.at(witness->frame);
            if (state_failure) {
                output << ",\"failed_obligation\":" << std::quoted(witness->frame == first_observed
                    ? "STATE_INITIALIZATION" : "STATE_PRESERVATION");
            }
            if (witness->has_waveform) {
                output << ",\"waveform_file\":" << std::quoted(state_failure ? "state-witness.vcd" : "paired-witness.vcd");
            }
            output << ",\"frame\":" << witness->frame << ",\"mismatches\":[";
            const char* separator = "";
            const auto mismatch = [&](const Pair& pair, bool inverted, std::uint64_t mask) {
                const auto left = frame.at(pair.first), right = frame.at(pair.second);
                if (left == (inverted ? (right ^ mask) : right)) return;
                output << separator << "{\"reference_signal\":" << std::quoted(pair.first)
                       << ",\"implementation_signal\":" << std::quoted(pair.second)
                       << ",\"reference_value\":" << std::quoted(std::to_string(left))
                       << ",\"implementation_value\":" << std::quoted(std::to_string(right));
                if (state_failure) output << ",\"relation\":" << std::quoted(inverted ? "invert" : "equal");
                output << '}';
                separator = ",";
            };
            if (state_failure) {
                for (const auto& pair : product.relations) mismatch(pair.signals, pair.inverted, pair.mask);
            } else {
                for (const auto& pair : product.observations) mismatch(pair, false, 0);
            }
            output << ']';
        }
        output << "}\n";
    };
    const auto exists = [](const auto& path) { return std::filesystem::exists(native(path)); };

    if (reopen) {
        if (exists(state_witness)) {
            if (product.relations.empty() || exists(state_certificate) || exists(witness_path) || exists(certificate)) {
                throw std::invalid_argument("ambiguous state correspondence evidence");
            }
            const auto witness = read_witness(state_witness, product, memory);
            validate_witness(product, kStateProperty, witness, memory);
            verify_waveform(state_witness, product, witness, memory);
            report("STATE_WITNESS_REVALIDATED", &witness, true);
            return 0;
        }
        if (!product.relations.empty()) {
            const auto relation = pdr::verify(product.model, kStateProperty, state_certificate, memory);
            if (!relation) {
                report("RESOURCE_LIMIT", nullptr);
                return 1;
            }
            relation_model = relation->model_sha256;
        } else if (exists(state_certificate)) {
            throw std::invalid_argument("unexpected state certificate for an output-only plan");
        }
        if (exists(witness_path)) {
            if (exists(certificate)) throw std::invalid_argument("ambiguous equivalence evidence");
            const auto witness = read_witness(witness_path, product, memory);
            validate_witness(product, kProperty, witness, memory);
            verify_waveform(witness_path, product, witness, memory);
            report("WITNESS_REVALIDATED", &witness);
            return 0;
        }
        const auto checked = pdr::verify(product.model, kProperty, certificate, memory);
        if (!checked) {
            report("RESOURCE_LIMIT", nullptr);
            return 1;
        }
        report("CERTIFICATE_REVALIDATED", nullptr, false, checked->model_sha256);
        return 0;
    }

    const auto run = [&](bool state, const auto& proof_path, const auto& trace_path, std::string& digest) {
        const auto* property = state ? kStateProperty : kProperty;
        const auto result = pdr::search(product.model, property, depth, pdr::kDefaultSearchQueries, memory);
        if (result.status == pdr::Status::InvariantFound) {
            const auto checked = pdr::certify(product.model, property, result.invariant, proof_path, memory);
            if (checked) {
                digest = checked->model_sha256;
                return std::optional<int>{};
            }
        } else if (result.status == pdr::Status::CounterexampleCandidate) {
            const auto witness = find_witness(product, property, result.depth, memory);
            if (witness) {
                validate_witness(product, property, *witness, memory);
                write_witness(trace_path, product, *witness, memory);
                report(state ? "STATE_RELATION_VIOLATED" : "NOT_EQUIVALENT", &*witness, state);
                return std::optional<int>{0};
            }
        } else if (result.status == pdr::Status::Unknown || result.status == pdr::Status::Inconsistent) {
            report(result.status == pdr::Status::Inconsistent ? "INCONSISTENT_ENVIRONMENT" : "UNKNOWN", nullptr);
            return std::optional<int>{1};
        }
        report("RESOURCE_LIMIT", nullptr);
        return std::optional<int>{1};
    };
    if (!product.relations.empty()) {
        if (const auto code = run(true, state_certificate, state_witness, relation_model)) return *code;
    }
    std::string output_digest;
    if (const auto code = run(false, certificate, witness_path, output_digest)) return *code;
    report("EQUIVALENT", nullptr, false, output_digest);
    return 0;
}

} // namespace q3a::equivalence
