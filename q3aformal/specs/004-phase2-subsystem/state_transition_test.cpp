#include "../../prototype/source/lowering/state_transition.hpp"
#include "../../prototype/source/lowering/event_mask_source.hpp"
#include "../../prototype/source/lowering/sequence_monitor.hpp"
#include "../../prototype/source/bundle/event_witness.hpp"
#include "../../prototype/source/bundle/indexed_trace.hpp"
#include "../../prototype/source/replay/property_replay.hpp"
#include "../../prototype/source/sat/transition_encoder.hpp"
#include "../../prototype/source/sat/event_window.hpp"
#include "../../prototype/source/sat/pdr.hpp"
#include "../../prototype/source/source_manager/memory_proof.hpp"

#include <algorithm>
#include <array>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <limits>
#include <stdexcept>
#include <tuple>

using namespace q3a::lowering;
using q3a::replay::Frame;
using q3a::sat::Literal;

namespace {

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

TypedExpression signal(const char* name, std::uint64_t width) {
    return {"signal", name, width, false, {}, {}};
}

TIRModule global_model() {
    TIRModule model;
    model.name = "transition-test";
    model.clocks = {"global_step"};
    const TypedExpression true_value{"constant", "1", 1, false, {}, {}};
    TIRProperty cover;
    cover.name = "replay";
    cover.kind = "cover";
    cover.clock = model.clocks.front();
    cover.antecedent.terms.push_back({0, 1, 1, true_value, {}});
    cover.antecedent.automaton = {2, 0, 1, {{0, 1, 0, 1, 1, true_value, {}}}};
    model.properties.push_back(std::move(cover));
    return model;
}

void pin(std::vector<Literal>& assumptions, const std::vector<Literal>& bits, std::uint64_t value) {
    for (std::size_t bit = 0; bit < bits.size(); ++bit) {
        assumptions.push_back((value >> bit) & 1 ? bits[bit] : -bits[bit]);
    }
}

void check_transition(const TIRModule& model, const q3a::sat::Solver& solver,
                      const q3a::sat::TransitionCnfEncoder& encoder,
                      const std::vector<Frame>& trace, const std::vector<std::string>& derived) {
    auto replay = q3a::replay::validate_bounded_cover(model, trace, "replay", 1);
    if (!replay.validated) throw std::runtime_error(replay.message);

    std::vector<Literal> fixed;
    for (const auto& [name, value] : trace.front()) {
        if (name != "read_safe" && name != "write_safe" && name != "different") {
            pin(fixed, encoder.frames()[0].at(name), value);
        }
    }
    const auto possible = solver.solve({}, fixed);
    require(possible.status == q3a::sat::Status::Satisfiable, "oracle pre-state is inconsistent with the SAT encoding");
    for (const auto& name : derived) {
        const bool is_range = name == "read_safe" || name == "write_safe";
        const std::size_t frame = is_range ? 0 : 1;
        const auto expected = trace[frame].at(name);
        std::vector<Literal> expected_bits;
        pin(expected_bits, encoder.frames()[frame].at(name), expected);
        for (const auto bit : expected_bits) {
            fixed.push_back(-bit);
            require(solver.solve({}, fixed).status == q3a::sat::Status::Unsatisfiable,
                    "SAT admitted a value different from the independent transition");
            fixed.pop_back();
        }
    }
}

void prove_source(const q3a::sat::Solver& solver, const q3a::sat::TransitionCnfEncoder& encoder,
                  std::vector<Literal>& control, const std::string& target, const std::string& source) {
    const auto& next = encoder.frames()[1].at(target);
    const auto& before = encoder.frames()[0].at(source);
    for (std::size_t bit = 0; bit < next.size(); ++bit) {
        for (const auto direction : {1, -1}) {
            control.push_back(before[bit] * direction);
            control.push_back(-next[bit] * direction);
            require(solver.solve({}, control).status == q3a::sat::Status::Unsatisfiable,
                    "SAT admitted a wrong successor with unconstrained data or pre-state");
            control.pop_back();
            control.pop_back();
        }
    }
}

std::size_t memory_checks(std::uint64_t first_address) {
    auto model = global_model();
    const std::vector<TIRSignal> cells{{"cell0", 2, false, "state", {}},
        {"cell1", 2, false, "state", {}}, {"cell2", 2, false, "state", {}}};
    const TIRSignal read_target{"read_value", 2, false, "state", {}};
    const TIRSignal invalid{"invalid_read", 2, false, "input", {}};
    model.signals = {read_target, invalid, {"read_enable", 1, false, "input", {}},
        {"write_enable", 1, false, "input", {}}, {"read_address", 2, false, "input", {}},
        {"write_address", 2, false, "input", {}}, {"write_value", 2, false, "input", {}},
        {"read_safe", 1, false, "output", {}}, {"write_safe", 1, false, "output", {}}};
    model.signals.insert(model.signals.end(), cells.begin(), cells.end());
    const MemoryAccess read{signal("read_enable", 1), signal("read_address", 2), {}};
    const MemoryAccess write{signal("write_enable", 1), signal("write_address", 2), {}};
    auto exact = exact_read_old_memory(first_address, cells, read, write,
                                      signal("write_value", 2), read_target, invalid);
    model.next_state_equations = std::move(exact.equations);
    model.combinational_equations = {{"read_safe", 1, std::move(exact.read_in_range), {}},
                                     {"write_safe", 1, std::move(exact.write_in_range), {}}};
    q3a::sat::Solver solver;
    q3a::sat::TransitionCnfEncoder encoder(solver, model);
    encoder.encode(1);
    std::size_t checked = 0;
    for (unsigned read_address = 0; read_address < 4; ++read_address) {
        for (unsigned write_address = 0; write_address < 4; ++write_address) {
            for (unsigned enables = 0; enables < 4; ++enables) {
                for (unsigned value = 0; value < 4; ++value) {
                    const bool read_enable = (enables & 1) != 0;
                    const bool write_enable = (enables & 2) != 0;
                    const auto read_valid = read_address >= first_address && read_address < first_address + cells.size();
                    const auto write_valid = write_address >= first_address && write_address < first_address + cells.size();
                    Frame initial{{"cell0", 0}, {"cell1", 1}, {"cell2", 2}, {"read_value", 3}, {"invalid_read", value ^ 3U},
                        {"read_enable", read_enable}, {"write_enable", write_enable},
                        {"read_address", read_address}, {"write_address", write_address}, {"write_value", value},
                        {"read_safe", !read_enable || read_valid}, {"write_safe", !write_enable || write_valid}};
                    Frame next = initial;
                    if (read_enable) {
                        next["read_value"] = read_valid ? initial.at(cells[read_address - first_address].name)
                                                       : initial.at("invalid_read");
                    }
                    if (write_enable && write_valid) next[cells[write_address - first_address].name] = value;
                    check_transition(model, solver, encoder, {initial, next},
                                     {"cell0", "cell1", "cell2", "read_value", "read_safe", "write_safe"});
                    if (value == 0) {
                        std::vector<Literal> control;
                        const auto& prestate = encoder.frames()[0];
                        pin(control, prestate.at("read_enable"), read_enable);
                        pin(control, prestate.at("write_enable"), write_enable);
                        pin(control, prestate.at("read_address"), read_address);
                        pin(control, prestate.at("write_address"), write_address);
                        require(solver.solve({}, control).status == q3a::sat::Status::Satisfiable,
                                "the range predicates restricted an enabled access");
                        for (std::size_t index = 0; index < cells.size(); ++index) {
                            const auto& name = cells[index].name;
                            const bool written = write_enable && write_address == first_address + index;
                            prove_source(solver, encoder, control, name, written ? "write_value" : name);
                        }
                        const std::string* observed = &read_target.name;
                        if (read_enable) {
                            observed = read_valid ? &cells[read_address - first_address].name : &invalid.name;
                        }
                        prove_source(solver, encoder, control, read_target.name, *observed);
                    }
                    if (checked == 0) {
                        next["cell0"] ^= 1;
                        require(!q3a::replay::validate_bounded_cover(model, {initial, next}, "replay", 1).validated,
                                "replay accepted a changed next-state cell");
                    }
                    ++checked;
                }
            }
        }
    }
    return checked;
}

std::size_t event_checks() {
    auto model = global_model();
    const TIRSignal a{"a", 1, false, "state", {}};
    const TIRSignal b{"b", 1, false, "state", {}};
    model.signals = {a, b, {"a_edge", 1, false, "input", {}}, {"b_edge", 1, false, "input", {}}};
    model.next_state_equations = {
        sampled_assignment(a, signal("a_edge", 1), signal("b", 1), {}),
        sampled_assignment(b, signal("b_edge", 1), signal("a", 1), {})};
    q3a::sat::Solver solver;
    q3a::sat::TransitionCnfEncoder encoder(solver, model);
    encoder.encode(1);
    std::size_t checked = 0;
    for (unsigned controls = 0; controls < 4; ++controls) {
        for (unsigned state = 0; state < 4; ++state) {
            const Frame initial{{"a", state & 1}, {"b", state >> 1},
                                {"a_edge", controls & 1}, {"b_edge", controls >> 1}};
            Frame next = initial;
            if (initial.at("a_edge")) next["a"] = initial.at("b");
            if (initial.at("b_edge")) next["b"] = initial.at("a");
            check_transition(model, solver, encoder, {initial, next}, {"a", "b"});
            ++checked;
        }
    }
    return checked;
}


std::size_t boundary_checks() {
    auto model = global_model();
    const auto last = std::numeric_limits<std::uint64_t>::max();
    const TIRSignal cell{"last_cell", 1, false, "state", {}};
    const TIRSignal target{"read_value", 1, false, "state", {}};
    const TIRSignal invalid{"invalid_read", 1, false, "input", {}};
    model.signals = {cell, target, invalid, {"address", 64, false, "input", {}},
                     {"read_safe", 1, false, "output", {}}, {"write_safe", 1, false, "output", {}}};
    const TypedExpression enabled{"constant", "1", 1, false, {}, {}};
    const MemoryAccess access{enabled, signal("address", 64), {}};
    auto transition = exact_read_old_memory(last, {cell}, access, access, enabled, target, invalid);
    model.next_state_equations = std::move(transition.equations);
    model.combinational_equations = {{"read_safe", 1, std::move(transition.read_in_range), {}},
                                     {"write_safe", 1, std::move(transition.write_in_range), {}}};
    q3a::sat::Solver solver;
    q3a::sat::TransitionCnfEncoder encoder(solver, model);
    encoder.encode(1);
    for (const auto address : {last - 1, last}) {
        const bool valid = address == last;
        const Frame initial{{"last_cell", 0}, {"read_value", 1}, {"invalid_read", 1},
                            {"address", address}, {"read_safe", valid}, {"write_safe", valid}};
        Frame next = initial;
        next["last_cell"] = valid;
        next["read_value"] = !valid;
        check_transition(model, solver, encoder, {initial, next},
                         {"last_cell", "read_value", "read_safe", "write_safe"});
    }
    return 2;
}

void rejection_checks() {
    const TIRSignal cell{"cell", 1, false, "state", {}};
    const TIRSignal target{"read_value", 1, false, "state", {}};
    const TIRSignal invalid{"invalid", 1, false, "input", {}};
    const TypedExpression value{"constant", "1", 1, false, {}, {}};
    const MemoryAccess access{value, signal("address", 2), {}};
    const auto rejected = [](const auto& work) {
        try { work(); }
        catch (const LoweringError&) { return; }
        throw std::runtime_error("an invalid transition description was accepted");
    };
    rejected([&] { exact_read_old_memory(0, {}, access, access, value, target, invalid); });
    rejected([&] { exact_read_old_memory(3, {cell, cell}, access, access, value, target, invalid); });
    rejected([&] { exact_read_old_memory(0, {cell, cell}, access, access, value, target, invalid); });
    rejected([&] { exact_read_old_memory(0, {cell}, access, access, value, target, target); });
    rejected([&] { sampled_assignment(target, signal("invalid_edge", 2), value, {}); });

    std::vector<TIRSignal> cells;
    for (std::size_t index = 0; index < 257; ++index) {
        cells.push_back({"word_" + std::to_string(index), 1, false, "state", {}});
    }
    const MemoryAccess wide_access{value, signal("wide_address", 9), {}};
    std::size_t checkpoints = 0;
    const q3a::MemoryBudget budget([&] {
        // Reservation and two write batches precede the first read-tree checkpoint.
        if (++checkpoints == 4) throw q3a::MemoryBudgetExceeded("injected read-tree interruption");
    });
    bool stopped = false;
    try { exact_read_old_memory(0, cells, wide_access, wide_access, value, target, invalid, &budget); }
    catch (const q3a::MemoryBudgetExceeded& error) {
        stopped = std::string(error.what()) == "injected read-tree interruption";
    }
    require(stopped && checkpoints == 4, "memory lowering missed the read-tree interruption checkpoint");
    std::cout << "PASS: memory lowering polls the budget during balanced read-tree construction.\n";
}


TIRModule memory_proof_model(bool write_decoder) {
    auto model = global_model();
    const std::vector<TIRSignal> cells{{"word0", 1, false, "state", {}},
        {"word1", 1, false, "state", {}}, {"word2", 1, false, "state", {}}};
    const TIRSignal read_target{"read_value", 1, false, "state", {}};
    const TIRSignal invalid{"invalid_read", 1, false, "input", {}};
    model.signals = {read_target, invalid, {"read_enable", 1, false, "input", {}},
        {"write_request", 1, false, "input", {}}, {"read_address", 2, false, "input", {}},
        {"write_address", 2, false, "input", {}}, {"write_value", 1, false, "input", {}}};
    model.signals.insert(model.signals.end(), cells.begin(), cells.end());
    auto write_enable = signal("write_request", 1);
    if (write_decoder) {
        const TypedExpression valid{"binary", "!=", 1, false, {},
            {signal("write_address", 2), {"constant", "3", 2, false, {}, {}}}};
        write_enable = {"binary", "&&", 1, false, {}, {write_enable, valid}};
    }
    const MemoryAccess read{signal("read_enable", 1), signal("read_address", 2), {"memory.sv", 7, 5, 90}};
    const MemoryAccess write{write_enable, signal("write_address", 2), {"memory.sv", 8, 5, 115}};
    auto exact = exact_read_old_memory(0, cells, read, write, signal("write_value", 1), read_target, invalid);
    const auto properties = memory_range_assertions(model, exact, "global_step", "read_range", "write_range");
    require(properties[0].kind == "assert" && properties[1].kind == "assert" &&
            properties[0].location.line == 7 && properties[1].location.line == 8,
            "generated access targets lost their type or source locations");
    model.next_state_equations = std::move(exact.equations);
    model.properties.insert(model.properties.end(), properties.begin(), properties.end());

    // An independent environment contract restricts the upstream read address.
    // This assumption stays separate from the generated access target.
    auto environment = model.properties.front();
    environment.name = "source_environment";
    environment.kind = "assume";
    environment.implication = "sequence";
    const TypedExpression in_range{"binary", "!=", 1, false, {},
        {signal("read_address", 2), {"constant", "3", 2, false, {}, {}}}};
    environment.antecedent.terms.front().predicate = in_range;
    environment.antecedent.automaton.transitions.front().predicate = in_range;
    model.properties.push_back(std::move(environment));
    return model;
}

void certificate_checks(const std::filesystem::path& root) {
    const auto model = memory_proof_model(true);
    const q3a::MemoryBudget memory;
    for (const auto* name : {"read_range", "write_range"}) {
        const auto proof = q3a::pdr::search(model, name, 4, 1000, memory);
        require(proof.status == q3a::pdr::Status::InvariantFound, "PDR did not prove a legal memory access");
        const auto folder = root / name;
        const auto checked = q3a::pdr::certify(model, name, proof.invariant, folder, memory);
        const auto reopened = q3a::pdr::verify(model, name, folder, memory);
        require(checked && reopened && checked->model_sha256 == reopened->model_sha256 &&
                checked->obligations.size() == 3 && reopened->obligations.size() == 3,
                "PDR range certificate did not reopen");
        std::cout << "MEMORY_RANGE_CERTIFICATE " << name << ' ' << checked->model_sha256 << '\n';
    }
    auto unrestricted_read = model;
    unrestricted_read.properties.pop_back();
    auto unrestricted_write = memory_proof_model(false);
    for (const auto& [candidate, name, access] :
         {std::tuple{&unrestricted_read, "read_range", "read"},
          std::tuple{&unrestricted_write, "write_range", "write"}}) {
        const auto failure = q3a::pdr::search(*candidate, name, 4, 1000, memory);
        require(failure.status == q3a::pdr::Status::CounterexampleCandidate,
                "PDR did not flag a reachable invalid access");
        q3a::sat::Solver solver;
        q3a::sat::TransitionCnfEncoder encoder(solver, *candidate);
        encoder.encode(0);
        encoder.constrain_assumptions();
        const auto violation = encoder.add_assertion_violation(name);
        require(violation.violation_literals.size() == 1 && violation.violation_frames.front() == 0,
                "expected a same-sample violation of the memory access guard");
        const auto witness = solver.solve({}, violation.violation_literals);
        require(witness.status == q3a::sat::Status::Satisfiable, "invalid access has no concrete sample");
        Frame before;
        for (const auto& [signal_name, bits] : encoder.frames().front()) {
            std::uint64_t value = 0;
            for (std::size_t bit = 0; bit < bits.size(); ++bit) {
                const auto literal = bits[bit];
                const auto assignment = witness.assignment.at(literal > 0 ? literal : -literal);
                require(assignment >= 0, "invalid access trace has an unassigned signal");
                const bool asserted = literal > 0 ? assignment == 1 : assignment == 0;
                if (asserted) value |= std::uint64_t{1} << bit;
            }
            before.emplace(signal_name, value);
        }
        require(before.at(std::string(access) + "_address") == 3 &&
                q3a::replay::validate_bounded_counterexample(*candidate, {before}, name, 0).validated,
                "replay could not revalidate the first invalid access");
        bool rejected = false;
        try { q3a::pdr::verify(*candidate, name, root / name, memory); }
        catch (const std::runtime_error&) { rejected = true; }
        require(rejected, "a certificate accepted a changed access context");
    }
}


std::string memory_source(bool descending, const std::string& writes = "if (we) words[wa] <= din;",
                          const std::string& properties = {}) {
    const std::string read = "if (re) dout <= words[ra];";
    return "module mem #(parameter BASE = 0) (input logic clk, re, we, "
           "input logic [1:0] ra, wa, din, output logic [1:0] dout);\n"
           "    logic [1:0] words" + std::string(descending ? "[3:BASE]" : "[BASE:3]") + ";\n"
           "    always_ff @(posedge clk) begin\n        " +
           (descending ? read + "\n        " + writes : writes + "\n        " + read) +
           "\n    end\n" + properties + "\nendmodule\n";
}

struct SourceMemory {
    std::vector<q3a::frontend::SyntaxUnit> units;
    q3a::elaboration::ElaborationResult elaboration;
};

SourceMemory source_memory(const std::string& source, const std::string& base = "0") {
    SourceMemory result;
    result.units.push_back(q3a::frontend::parse_source(
        q3a::frontend::tokenize(source, "memory-from-source.sv"), false,
        q3a::frontend::SyntaxProfile::ExactMemoryDevelopment));
    result.elaboration = q3a::elaboration::elaborate_top(
        result.units, "mem", {{"BASE", base}}, "Q3A-EXACT-MEMORY-DEVELOPMENT", q3a::sha256_hex(source));
    return result;
}

void source_memory_checks() {
    const q3a::MemoryBudget memory;
    for (const bool descending : {false, true}) {
        const auto source = memory_source(descending);
        const auto design = source_memory(source);
        const auto& typed = design.elaboration.top.memories.at(0);
        require(typed.element.width == 2 && typed.left == (descending ? 3U : 0U) &&
                typed.right == (descending ? 0U : 3U), "the elaborated memory lost its source index direction");
        const auto& unit = design.units.front();
        auto model = lower_exact_memory_source(unit, design.elaboration, 4);
        require(model.next_state_equations.size() == 5 && model.clocks == std::vector<std::string>{"clk"} &&
                model.input_hash == q3a::sha256_hex(source) &&
                model.properties[0].location.line == (descending ? 4U : 5U),
                "source lowering lost the clock, memory image, input digest or read location");
        for (const auto& property : model.properties) {
            const auto proof = q3a::pdr::search(model, property.name, 4, 1000, memory);
            require(proof.status == q3a::pdr::Status::InvariantFound, "finite source memory range did not prove");
        }

        auto cover = global_model().properties.front();
        cover.clock = "clk";
        model.properties.push_back(std::move(cover));
        q3a::sat::Solver solver;
        q3a::sat::TransitionCnfEncoder encoder(solver, model);
        encoder.encode(1);
        const Frame before{{"clk", 0}, {"re", 1}, {"we", 1}, {"ra", 2}, {"wa", 2}, {"din", 3},
                           {"dout", 2}, {"words[0]", 0}, {"words[1]", 1}, {"words[2]", 1},
                           {"words[3]", 2}, {"__q3a_invalid_read_words", 0}};
        Frame after = before;
        after["dout"] = 1;
        after["words[2]"] = 3;
        check_transition(model, solver, encoder, {before, after}, {"dout", "words[2]"});
    }

    const auto offset = source_memory(memory_source(true), "1");
    const auto model = lower_exact_memory_source(offset.units.front(), offset.elaboration, 3);
    require(model.next_state_equations.front().target == "words[1]" &&
            model.next_state_equations.size() == 4, "parameter override lost the offset memory range");
    for (const auto& property : model.properties) {
        require(q3a::pdr::search(model, property.name, 4, 1000, memory).status ==
                q3a::pdr::Status::CounterexampleCandidate, "PDR missed address zero in an offset memory");
    }

    const auto rejects_lowering = [](const auto& work) {
        try { work(); }
        catch (const LoweringError&) { return; }
        throw std::runtime_error("the memory source path silently accepted unsupported semantics");
    };
    rejects_lowering([&] { lower_exact_memory_source(offset.units.front(), offset.elaboration, 2); });
    rejects_lowering([&] { lower_continuous_assignments(offset.units, offset.elaboration); });
    const auto blocking = source_memory(memory_source(false, "if (we) words[wa] = din;"));
    rejects_lowering([&] { lower_exact_memory_source(blocking.units.front(), blocking.elaboration, 4); });
    bool released_rejected = false;
    try { q3a::frontend::parse_source(q3a::frontend::tokenize(memory_source(true), "released.sv")); }
    catch (const q3a::frontend::ParseError&) { released_rejected = true; }
    require(released_rejected, "the released parser accepted the development syntax");

    std::cout << "PASS: ascending, descending and parameterized memory declarations parsed and lowered from RTL; "
                 "read-old replay, source-derived range properties and profile rejection checked.\n";
}


void memory_group_checks(const std::filesystem::path& root) {
    using q3a::memory_proof::Outcome;
    const std::string write = "if (we) words[wa] <= din;";
    const std::string named_claim =
        "property hold_output; @(posedge clk) (!re) |=> (dout == $past(dout)); endproperty\n"
        "read_state_contract: assert property (hold_output);";
    const q3a::MemoryBudget memory;
    auto from_source = [&](const std::string& checks, const std::string& base = "0") {
        const auto design = source_memory(memory_source(false, write, checks), base);
        return lower_exact_memory_source(design.units.front(), design.elaboration, base == "0" ? 4 : 3);
    };
    const auto model = from_source(named_claim);
    require(model.properties.size() == 3 && model.properties.back().location.file == "memory-from-source.sv" &&
            !model.history_guards.empty(), "the compiled source assertion lost its provenance or history");
    const auto path = root / "source-proof-group";
    const char* property = "read_state_contract";
    auto check = [&](const TIRModule& source_model, const std::filesystem::path& destination, bool reopen) {
        return q3a::memory_proof::check(source_model, property, destination, reopen, 4, 1000, memory);
    };
    require(check(model, path, false).outcome == Outcome::Proven &&
            check(model, path, true).outcome == Outcome::Proven,
            "the source proof group did not prove and reopen");

    const auto group_staging = [&]() -> std::optional<std::filesystem::path> {
        for (const auto& entry : std::filesystem::directory_iterator(root)) {
            if (entry.path().filename().u8string().rfind(".q3apdr-group-", 0) == 0) return entry.path();
        }
        return std::nullopt;
    };

    const auto interrupted = root / "interrupted-proof-group";
    std::optional<std::filesystem::path> pending;
    bool stopped_after_read = false;
    const q3a::MemoryBudget interrupt([&] {
        if (!pending) pending = group_staging();
        if (pending && std::filesystem::exists(*pending / "read-range" / "invariant.txt")) {
            require(!std::filesystem::exists(interrupted), "read proof was published before group commit");
            stopped_after_read = true;
            throw q3a::MemoryBudgetExceeded("injected interruption after the first checked certificate");
        }
    });
    bool caught_interruption = false;
    try { q3a::memory_proof::check(model, property, interrupted, false, 4, 1000, interrupt); }
    catch (const q3a::MemoryBudgetExceeded&) { caught_interruption = true; }
    require(stopped_after_read && caught_interruption && !std::filesystem::exists(interrupted) &&
            !group_staging(), "cancelled memory group remained published or staged");

    const auto occupied = root / "occupied-proof-group";
    pending.reset();
    bool created_competitor = false;
    const q3a::MemoryBudget race([&] {
        if (created_competitor) return;
        if (!pending) pending = group_staging();
        if (pending && std::filesystem::exists(*pending / "property" / "invariant.txt")) {
            require(!std::filesystem::exists(occupied), "memory result appeared before group commit");
            require(std::filesystem::create_directory(occupied), "failed to create a competing destination");
            std::ofstream marker(occupied / "owner.txt");
            marker << "competitor";
            marker.close();
            require(static_cast<bool>(marker), "failed to write the competing owner marker");
            created_competitor = true;
        }
    });
    bool caught_conflict = false;
    try { q3a::memory_proof::check(model, property, occupied, false, 4, 1000, race); }
    catch (const std::runtime_error& error) {
        caught_conflict = std::string(error.what()).rfind("cannot publish checked PDR evidence:", 0) == 0;
    }
    std::ifstream marker(occupied / "owner.txt");
    std::string owner;
    marker >> owner;
    require(created_competitor && caught_conflict && owner == "competitor" &&
            std::distance(std::filesystem::directory_iterator(occupied), std::filesystem::directory_iterator{}) == 1 &&
            !group_staging(),
            "competing destination was replaced or an uncommitted proof survived");
    std::cout << "PASS: memory proof-group interruption and publication conflict left no partial evidence.\n";

    const auto invalid_read = from_source(named_claim, "1");
    const auto blocked_path = root / "blocked-read";
    const auto read_block = check(invalid_read, blocked_path, false);
    require(read_block.outcome == Outcome::RangeUnproved && read_block.property == kMemoryReadRange &&
            !std::filesystem::exists(blocked_path),
            "primary proof accepted with an unproved read condition");

    auto delayed = invalid_read;
    const auto& history_ready = delayed.history_guards.front().valid_signal;
    const TypedExpression after_start{"binary", "==", 1, false, {},
        {signal("re", 1), signal(history_ready.c_str(), 1)}};
    const TypedExpression zero_address{"binary", "==", 1, false, {},
        {signal("ra", 2), {"constant", "0", 2, false, {}, {}}}};
    const TypedExpression no_read{"unary", "!", 1, false, {}, {signal("re", 1)}};
    const TypedExpression no_write{"unary", "!", 1, false, {}, {signal("we", 1)}};
    const TypedExpression read_zero{"binary", "||", 1, false, {}, {no_read, zero_address}};
    const TypedExpression read_policy{"binary", "&&", 1, false, {}, {after_start, read_zero}};
    const TypedExpression environment{"binary", "&&", 1, false, {}, {read_policy, no_write}};
    auto startup = delayed.properties.front();
    startup.name = "startup_then_invalid_read";
    startup.kind = "assume";
    startup.antecedent.terms.front().predicate = environment;
    startup.antecedent.automaton.transitions.front().predicate = environment;
    delayed.properties.push_back(std::move(startup));
    const auto delayed_path = root / "blocked-after-legal-step";
    const auto saved_prefix = root / "invalid-range-prefix.q3t";
    const auto diagnostic = q3a::memory_proof::check(delayed, property, delayed_path, false, 4, 1000,
                                                    memory, true, saved_prefix);
    require(diagnostic.outcome == Outcome::RangeUnproved && diagnostic.range_witness &&
            diagnostic.range_witness->frame == 1 && !diagnostic.range_witness->boundary_incomplete &&
            diagnostic.range_witness->accesses.size() == 1 &&
            diagnostic.range_witness->accesses.front().property == kMemoryReadRange &&
            diagnostic.range_witness->accesses.front().address == 0 && !std::filesystem::exists(delayed_path),
            "memory range diagnostic did not independently replay the legal transition before the first invalid read");
    const auto reopened_range = q3a::memory_proof::reopen_range_trace(delayed, property, saved_prefix, memory);
    require(reopened_range.frame == 1 && reopened_range.accesses.size() == 1 &&
            reopened_range.accesses.front().address == 0 &&
            !reopened_range.boundary_incomplete, "saved range witness did not reopen");
    const auto trace_id = "q3a-memory-range-v1:" + q3a::sha256_hex(
        std::string(property) + "\n" + serialize_tir(delayed));
    std::vector<Frame> range_frames;
    {
        std::ifstream saved(saved_prefix, std::ios::binary);
        q3a::trace::visit_indexed_witness(saved, delayed, trace_id, 2, [](auto) {},
            [&](const auto& frames, auto) {
                for (std::size_t i = 0; i < frames.size(); ++i) range_frames.push_back(frames[i]);
            });
    }
    const auto edited_prefix = root / "edited-range-prefix.q3t";
    range_frames[0]["re"] = 1;
    range_frames[0]["ra"] = 0;
    {
        std::ofstream edited(edited_prefix, std::ios::binary);
        q3a::trace::write_indexed_trace(edited, delayed, range_frames, trace_id, 1);
    }
    bool earlier_rejected = false;
    try { q3a::memory_proof::reopen_range_trace(delayed, property, edited_prefix, memory); }
    catch (const std::invalid_argument& error) {
        earlier_rejected = std::string(error.what()).find("earlier invalid access") != std::string::npos;
    }
    require(earlier_rejected, "a saved range witness with an illegal prefix was accepted");
    std::cout << "PASS: memory range diagnosis replayed the legal prefix before the first invalid access.\n";
    std::cout << "PASS: indexed memory range trace reopened and rejected an edited earlier violation.\n";

    const auto invalid_write = from_source(named_claim +
        "\nread_address_contract: assume property (@(posedge clk) ra != 2'd0);", "1");
    const auto write_path = root / "blocked-write";
    const auto write_block = check(invalid_write, write_path, false);
    require(write_block.outcome == Outcome::RangeUnproved && write_block.property == kMemoryWriteRange &&
            !std::filesystem::exists(write_path),
            "primary proof accepted with an unproved write condition");

    const auto false_claim = from_source(
        "read_state_contract: assert property (@(posedge clk) re |=> (dout == $past(dout)));");
    const auto false_path = root / "false-primary";
    const auto failed = check(false_claim, false_path, false);
    require(failed.outcome == Outcome::PropertyUnproved && failed.property == property &&
            !std::filesystem::exists(false_path), "range proofs were mistaken for a proved primary claim");

    const auto rejected = [](const auto& work) {
        try { work(); }
        catch (const std::runtime_error&) { return true; }
        return false;
    };
    require(rejected([&] { check(invalid_read, path, true); }),
            "old proof group was accepted after the source bound changed");
    const auto guard_file = path / "read-range" / "safety.cnf";
    const auto saved_guard = path / "read-range" / "safety.test-backup";
    std::filesystem::rename(guard_file, saved_guard);
    const auto missing_rejected = rejected([&] { check(model, path, true); });
    std::filesystem::rename(saved_guard, guard_file);
    require(missing_rejected && check(model, path, true).outcome == Outcome::Proven,
            "an incomplete range certificate did not stop proof reopen");

    for (const auto& [name, folder] :
         {std::pair{kMemoryReadRange, "read-range"}, std::pair{kMemoryWriteRange, "write-range"},
          std::pair{property, "property"}}) {
        const auto proof = q3a::pdr::verify(model, name, path / folder, memory);
        require(proof && proof->obligations.size() == 3, "source proof group artifact could not be inspected");
        std::cout << "MEMORY_GROUP_CERTIFICATE " << folder << ' ' << proof->model_sha256 << '\n';
    }
    for (const auto* invalid : {
            "different_clock: assert property (@(posedge we) 1'b1);",
            "__q3a_read_in_range: assert property (@(posedge clk) 1'b1);",
            "hidden_state: assert property (@(posedge clk) (__q3a_invalid_read_words == 2'd0));"}) {
        require(rejected([&] { from_source(invalid); }), "unsupported memory property was admitted");
    }
    std::cout << "PASS: source assertions and assumptions compile with history; unsafe access, false assertion, "
                 "changed source, missing evidence and invalid property bindings rejected.\n";
}


void source_clock_checks() {
    const std::string rtl = R"SV(module crossing_fixture(input logic clk_a, clk_b, rst_a, rst_b,
    output logic x, y, different);
assign different = x ^ y;
always_ff @(posedge clk_a) begin if (rst_a) x <= 1'b0; else x <= y; end
always_ff @(posedge clk_b) begin if (rst_b) y <= 1'b0; else y <= x; end
endmodule
)SV";
    auto from_source = [](const std::string& source) {
        std::vector<q3a::frontend::SyntaxUnit> units{
            q3a::frontend::parse_source(q3a::frontend::tokenize(source, "event-clock.sv"))};
        auto design = q3a::elaboration::elaborate_top(units, "crossing_fixture", {},
            "Q3A-P0-R0.9.1", q3a::sha256_hex(source));
        return std::make_pair(std::move(units), std::move(design));
    };
    const auto [units, design] = from_source(rtl);
    auto scheduled = lower_free_event_mask(units, design);
    require(scheduled.state_domains == std::map<std::string, std::string>{{"x", "clk_a"}, {"y", "clk_b"}} &&
            scheduled.edge_inputs.size() == 2, "source-derived domain mapping differs");
    auto& model = scheduled.transition;
    require(model.clocks == std::vector<std::string>{kGlobalEventStep} &&
            model.semantic_profile == kFreeEventMaskProfile &&
            model.input_hash == q3a::sha256_hex(rtl), "the clock schedule or source identity was lost");
    auto cover = global_model().properties.front();
    cover.clock = kGlobalEventStep;
    model.properties.push_back(std::move(cover));
    q3a::sat::Solver solver;
    q3a::sat::TransitionCnfEncoder encoder(solver, model);
    encoder.encode(1);
    const auto& a = scheduled.edge_inputs.at("clk_a");
    const auto& b = scheduled.edge_inputs.at("clk_b");
    std::size_t transitions = 0;
    for (unsigned mask = 0; mask < 4; ++mask) {
        for (unsigned resets = 0; resets < 4; ++resets) {
            for (unsigned state = 0; state < 4; ++state) {
                const auto x = state & 1;
                const auto y = state >> 1;
                const Frame before{{"x", x}, {"y", y}, {"different", x ^ y},
                    {"rst_a", resets & 1}, {"rst_b", resets >> 1}, {a, mask & 1}, {b, mask >> 1}};
                auto after = before;
                if (before.at(a)) after["x"] = before.at("rst_a") ? 0 : y;
                if (before.at(b)) after["y"] = before.at("rst_b") ? 0 : x;
                after["different"] = after.at("x") ^ after.at("y");
                check_transition(model, solver, encoder, {before, after}, {"x", "y", "different"});
                if (mask == 3 && state == 2 && resets == 0) {
                    auto wrong_event = before;
                    wrong_event[a] = 0;
                    require(!q3a::replay::validate_bounded_cover(model, {wrong_event, after}, "replay", 1).validated,
                            "replay accepted a changed source event");
                }
                ++transitions;
            }
        }
    }
    const auto rejects = [](const auto& operation) {
        try { operation(); }
        catch (const LoweringError&) { return; }
        throw std::runtime_error("a source clock diagnostic was silently bypassed");
    };
    rejects([&] { lower_continuous_assignments(units, design); });
    auto clock_as_data = rtl;
    clock_as_data.replace(clock_as_data.find("x ^ y"), 5, "clk_a ^ y");
    const auto [data_units, data_design] = from_source(clock_as_data);
    rejects([&] { lower_free_event_mask(data_units, data_design); });
    auto duplicate_owner = rtl;
    duplicate_owner.replace(duplicate_owner.find("else y <= x"), 11, "else x <= y");
    const auto [duplicate_units, duplicate_design] = from_source(duplicate_owner);
    rejects([&] { lower_free_event_mask(duplicate_units, duplicate_design); });
    std::cout << "PASS: " << transitions << " RTL-derived event, reset and state combinations; "
                 "clock-as-data, multiple drivers, and changed event replay rejected." << std::endl;
}


void source_domain_sva_checks(const std::filesystem::path& root) {
    const std::string rtl = R"SV(module event_sva(input logic clk_a, clk_b, data, allow_a, trigger, output logic x, y);
always_ff @(posedge clk_a) begin x <= data; end
logic prior_b;
always_ff @(posedge clk_b) begin prior_b <= data; y <= prior_b; end
property capture_a; @(posedge clk_a) (x == $past(data)); endproperty
p_a: assert property (capture_a);
p_b: assert property (@(posedge clk_b) (y == $past(data, 2)));
bad_a: assert property (@(posedge clk_a) (x != $past(data)));
only_a: assume property (@(posedge clk_a) (1'b1 ##0 allow_a));
c_peer: cover property (@(posedge clk_b) (!allow_a ##0 x));
p_delay: assert property (@(posedge clk_a) data |=> x);
p_overlap: assert property (@(posedge clk_a) data |-> (1'b1 ##1 x));
only_b: assume property (@(posedge clk_b) data |=> allow_a);
c_gap: cover property (@(posedge clk_a) trigger ##[1:2] !data);
endmodule
)SV";
    auto lower = [](const std::string& source) {
        const std::vector<q3a::frontend::SyntaxUnit> units{
            q3a::frontend::parse_source(q3a::frontend::tokenize(source, "event-sva.sv"))};
        auto design = q3a::elaboration::elaborate_top(units, "event_sva", {},
            "Q3A-P0-R0.9.1", q3a::sha256_hex(source));
        return lower_free_event_mask(units, design);
    };
    const auto scheduled = lower(rtl);
    const auto& model = scheduled.transition;
    const auto find_property = [&](const char* name) -> const TIRProperty& {
        const auto found = std::find_if(model.properties.begin(), model.properties.end(),
            [&](const auto& property) { return property.name == name; });
        require(found != model.properties.end(), "compiled event property is missing");
        return *found;
    };
    const auto& guard_a = antecedent_history_guard(find_property("p_a"));
    const auto& guard_b = antecedent_history_guard(find_property("p_b"));
    require(!guard_a.empty() && !guard_b.empty() && guard_a != guard_b &&
            scheduled.state_domains.at(guard_a) == "clk_a" &&
            scheduled.state_domains.at(guard_b) == "clk_b" &&
            scheduled.property_domains.at("only_a") == "clk_a" &&
            scheduled.property_domains.at("c_peer") == "clk_b",
            "two domains shared history validity or lost property ownership");

    const q3a::MemoryBudget memory;
    for (const auto* name : {"p_a", "p_b", "p_delay", "p_overlap"}) {
        const auto answer = q3a::pdr::search(model, name, 6, 1000, memory);
        require(answer.status == q3a::pdr::Status::InvariantFound, "clock-local history assertion did not prove");
        const auto folder = root / name;
        const auto certified = q3a::pdr::certify(model, name, answer.invariant, folder, memory);
        const auto checked = q3a::pdr::verify(model, name, folder, memory);
        require(certified && checked && checked->obligations.size() == 3 &&
                certified->model_sha256 == checked->model_sha256, "clock-local safety proof did not reopen");
        std::cout << "EVENT_SVA_CERTIFICATE " << name << ' ' << checked->model_sha256 << std::endl;
    }
    require(q3a::pdr::search(model, "bad_a", 6, 1000, memory).status == q3a::pdr::Status::CounterexampleCandidate,
            "PDR accepted a deliberately false clock-local history assertion");

    q3a::sat::Solver solver;
    q3a::sat::TransitionCnfEncoder encoder(solver, model);
    encoder.encode(0);
    encoder.constrain_assumptions();
    const auto cover = encoder.add_cover_hit("c_peer");
    const auto& a = scheduled.edge_inputs.at("clk_a");
    const auto& b = scheduled.edge_inputs.at("clk_b");
    const auto& first = encoder.frames().front();
    const auto a_edge = first.at(a).front();
    const auto b_edge = first.at(b).front();
    const auto allow_a = first.at("allow_a").front();
    const auto x = first.at("x").front();
    require(cover.hit_literals.size() == 1 &&
            solver.solve({}, {cover.hit_literals.front(), -a_edge, b_edge, -allow_a, x}).status ==
                q3a::sat::Status::Satisfiable &&
            solver.solve({}, {cover.hit_literals.front(), a_edge, b_edge, -allow_a, x}).status ==
                q3a::sat::Status::Unsatisfiable &&
            solver.solve({}, {cover.hit_literals.front(), -a_edge, -b_edge, -allow_a, x}).status ==
                q3a::sat::Status::Unsatisfiable, "domain-local assumption or cover is active on the wrong edge");
    Frame frame;
    for (const auto& item : model.signals) frame.emplace(item.name, 0);
    frame[b] = 1;
    frame["x"] = 1;
    require(q3a::replay::validate_bounded_cover(model, {frame}, "c_peer", 0).validated,
            "the peer-domain cover did not replay");
    frame[b] = 0;
    require(!q3a::replay::validate_bounded_cover(model, {frame}, "c_peer", 0).validated,
            "replay accepted the cover while its clock was inactive");

    for (bool use_late_endpoint : {false, true}) {
        q3a::sat::Solver timed_solver;
        q3a::sat::TransitionCnfEncoder trace_encoder(timed_solver, model);
        trace_encoder.encode(5);
        trace_encoder.constrain_assumptions();
        const auto timed_cover = trace_encoder.add_cover_hit("c_gap");
        std::vector<Literal> schedule;
        for (std::size_t f = 0; f <= 5; ++f) {
            const auto& signals = trace_encoder.frames()[f];
            pin(schedule, signals.at(a), f == 0 || f == 3 || f == 5);
            pin(schedule, signals.at(b), f == 1);
            pin(schedule, signals.at("trigger"), f == 0);
            pin(schedule, signals.at("allow_a"), f == 0 || f == 3 || f == 5);
            pin(schedule, signals.at("data"), f == 0 || (use_late_endpoint && f == 3));
        }
        const std::size_t expected = use_late_endpoint ? 5 : 3;
        for (const auto f : {std::size_t{1}, std::size_t{2}, std::size_t{3}, std::size_t{5}}) {
            auto query = schedule;
            const auto hit = std::find(timed_cover.hit_frames.begin(), timed_cover.hit_frames.end(), f);
            require(hit != timed_cover.hit_frames.end(), "normalized cover dropped a global frame");
            query.push_back(timed_cover.hit_literals.at(static_cast<std::size_t>(hit - timed_cover.hit_frames.begin())));
            const auto result = timed_solver.solve({}, query);
            const bool allowed = f == expected || (!use_late_endpoint && f == 5);
            require(result.status == (allowed ? q3a::sat::Status::Satisfiable : q3a::sat::Status::Unsatisfiable),
                    "ranged delay used global steps or the wrong local endpoint");
            if (f != expected) continue;
            std::vector<Frame> trace;
            for (const auto& signals : trace_encoder.frames()) {
                Frame snapshot;
                for (const auto& [name, bits] : signals) {
                    std::uint64_t value = 0;
                    for (std::size_t bit = 0; bit < bits.size(); ++bit) {
                        const auto literal = bits[bit];
                        const auto assignment = result.assignment.at(literal > 0 ? literal : -literal);
                        require(assignment >= 0, "cover witness was incomplete");
                        if ((literal > 0) == (assignment == 1)) value |= std::uint64_t{1} << bit;
                    }
                    snapshot.emplace(name, value);
                }
                trace.push_back(std::move(snapshot));
            }
            require(q3a::replay::validate_bounded_cover(model, trace, "c_gap", f).validated,
                    "domain-ranged cover witness failed verification");
            auto archived = trace;
            const Frame stalled = trace.at(2);
            archived.insert(archived.begin() + 2, 315, stalled);
            const auto step = f + 315;
            const auto sample = use_late_endpoint ? 2U : 1U;
            std::ostringstream indexed(std::ios::binary), schedule;
            const auto written = q3a::trace::write_event_witness(indexed, schedule, scheduled, "c_gap",
                archived, step, memory);
            require(written.global_step == step && written.domain == "clk_a" && written.domain_sample == sample,
                    "stored candidate did not preserve the global step and local sample");
            const auto schedule_text = schedule.str();
            const auto indexed_values = indexed.str();
            const auto reopen = [&](const EventMaskModel& source_model, const std::string& metadata,
                                    const std::string& binary) {
                std::istringstream indexed_stream(binary, std::ios::binary);
                std::istringstream schedule_stream(metadata);
                return q3a::trace::verify_event_witness(indexed_stream, schedule_stream, source_model, "c_gap", memory);
            };
            const auto reopened = reopen(scheduled, schedule_text, indexed_values);
            require(reopened.global_step == step && reopened.domain_sample == sample && reopened.domain == "clk_a",
                    "the saved event witness did not reopen across trace blocks");
            if (!use_late_endpoint) {
                std::ostringstream failure_values(std::ios::binary), failure_schedule;
                const auto failed = q3a::trace::write_event_witness(failure_values, failure_schedule,
                    scheduled, "bad_a", archived, step, memory);
                std::istringstream failure_index_input(failure_values.str(), std::ios::binary);
                std::istringstream failure_schedule_input(failure_schedule.str());
                const auto checked = q3a::trace::verify_event_witness(failure_index_input, failure_schedule_input,
                    scheduled, "bad_a", memory);
                require(failed.global_step == step && checked.domain_sample == sample &&
                        failure_schedule.str().find("kind assert") != std::string::npos,
                        "an indexed assertion counterexample did not reopen at its local sample");
            }
            const auto candidate_row = "step " + std::to_string(step) + " " + std::to_string(sample) + " -";
            auto modified = schedule_text;
            const auto row = modified.find(candidate_row);
            require(row != std::string::npos, "the schedule has no canonical candidate row");
            modified[row + candidate_row.size() - 3] = '9';

            const auto reject = [](const auto& operation) {
                try { operation(); }
                catch (const std::invalid_argument&) { return; }
                throw std::runtime_error("an altered event witness was accepted");
            };
            reject([&] { reopen(scheduled, modified, indexed_values); });
            reject([&] { reopen(scheduled, schedule_text + "surplus", indexed_values); });
            const auto edited_source = lower(rtl + "// Changed source bytes.");
            reject([&] { reopen(edited_source, schedule_text, indexed_values); });
            archived[step][a] = 0;
            std::ostringstream altered_values(std::ios::binary);
            q3a::trace::write_indexed_trace(altered_values, model, archived, "c_gap", step);
            reject([&] { reopen(scheduled, schedule_text, altered_values.str()); });

            const auto tag = use_late_endpoint ? "event-late" : "event-early";
            std::ofstream stored_index(root / (std::string(tag) + ".q3t"), std::ios::binary);
            std::ofstream stored_schedule(root / (std::string(tag) + ".schedule"), std::ios::binary);
            stored_index << indexed_values;
            stored_schedule << schedule_text;
            stored_index.close();
            stored_schedule.close();
            require(stored_index && stored_schedule, "failed to retain event witness evidence");

            trace[f][a] = 0;
            require(!q3a::replay::validate_bounded_cover(model, trace, "c_gap", f).validated,
                    "domain-ranged cover replay accepted the wrong sampling event");
        }
    }

    q3a::sat::Solver constrained;
    q3a::sat::TransitionCnfEncoder assumed(constrained, model);
    assumed.encode(2);
    assumed.constrain_assumptions();
    std::vector<Literal> environment;
    for (const auto& step : assumed.frames()) pin(environment, step.at(a), 0);
    pin(environment, assumed.frames()[0].at(b), 1);
    pin(environment, assumed.frames()[0].at("data"), 1);
    pin(environment, assumed.frames()[1].at(b), 0);
    pin(environment, assumed.frames()[1].at("allow_a"), 0);
    pin(environment, assumed.frames()[2].at(b), 1);
    const auto last_allow = assumed.frames()[2].at("allow_a").front();
    environment.push_back(last_allow);
    require(constrained.solve({}, environment).status == q3a::sat::Status::Satisfiable,
            "a temporal assumption constrained a global step without its clock");
    environment.back() = -last_allow;
    require(constrained.solve({}, environment).status == q3a::sat::Status::Unsatisfiable,
            "a temporal assumption missed its next local sample");


    using q3a::sat::EventWindowOutcome;
    const auto check_window = [&](const char* property, const std::vector<std::array<unsigned, 5>>& stimulus) {
        q3a::sat::Solver bounded;
        q3a::sat::TransitionCnfEncoder encoded(bounded, model);
        encoded.encode(stimulus.size() - 1);
        encoded.constrain_assumptions();
        const std::array<std::string, 5> names{a, b, "data", "allow_a", "trigger"};
        for (std::size_t f = 0; f < stimulus.size(); ++f) {
            std::vector<Literal> fixed;
            for (std::size_t i = 0; i < names.size(); ++i) {
                pin(fixed, encoded.frames()[f].at(names[i]), stimulus.at(f)[i]);
            }
            for (const auto literal : fixed) bounded.add_clause({literal});
        }
        return q3a::sat::classify_event_window(scheduled, property, encoded, bounded);
    };
    const std::array<unsigned, 5> launch{1, 0, 1, 1, 1};
    const std::array<unsigned, 5> peer{0, 1, 0, 0, 0};
    const std::array<unsigned, 5> idle{0, 0, 0, 0, 0};
    const std::array<unsigned, 5> resume{1, 0, 0, 1, 0};
    const std::array<unsigned, 5> cover_miss{1, 0, 1, 1, 0};
    const std::array<unsigned, 5> assumption_launch{0, 1, 1, 0, 0};
    require(check_window("p_delay", {launch}).outcome == EventWindowOutcome::Incomplete &&
            check_window("p_delay", {launch, peer, idle}).outcome == EventWindowOutcome::Incomplete &&
            check_window("p_delay", {launch, peer, idle, resume}).outcome == EventWindowOutcome::Complete,
            "the next-edge obligation was completed by an idle or peer-domain step");
    require(check_window("c_gap", {idle, peer}).outcome == EventWindowOutcome::Complete &&
            check_window("c_gap", {launch, peer, cover_miss}).outcome == EventWindowOutcome::Incomplete &&
            check_window("c_gap", {launch, peer, cover_miss, idle, cover_miss}).outcome == EventWindowOutcome::Complete,
            "the cover window did not distinguish an inactive, pending, or exhausted range");
    require(check_window("p_a", {assumption_launch, idle}).outcome == EventWindowOutcome::Incomplete &&
            check_window("p_a", {{1, 0, 0, 0, 0}}).outcome == EventWindowOutcome::Inconsistent,
            "an open or inconsistent environment was classified as a completed result");
    const auto failed = check_window("bad_a", {launch, peer, resume});
    require(failed.outcome == EventWindowOutcome::Witness && failed.witness_frame == 2 &&
            !failed.assignment.empty() && !failed.witness_has_open_assumption,
            "a completed assertion violation was not retained as a witness");
    const auto provisional = check_window("c_peer", {assumption_launch});
    require(provisional.outcome == EventWindowOutcome::Witness && provisional.witness_frame == 0 &&
            provisional.witness_has_open_assumption,
            "the cover witness lost the unresolved environment obligation");
    std::cout << "PASS: finite event windows distinguish completed, pending, inconsistent, and witness outcomes." << std::endl;

    auto delayed = rtl;
    const auto position = delayed.find("1'b1 ##0 allow_a");
    delayed.replace(position, std::string("1'b1 ##0 allow_a").size(), "1'b1 ##129 allow_a");
    bool rejected = false;
    try { lower(delayed); } catch (const LoweringError&) { rejected = true; }
    require(rejected, "a delay beyond the monitor horizon was admitted");
    std::cout << "PASS: local fixed and ranged sequences, overlapped and nonoverlapped implications, "
                 "assumptions, history, and ranged cover replay." << std::endl;
    std::cout << "PASS: two indexed 321-step event witnesses reopened with domain samples; "
                 "changed indices, source, mask and trailing metadata rejected." << std::endl;
}

void check_fixed_edge_embedding() {
    const std::string source = R"SV(module fixed_edge(
        input logic clk, rst, d, gate, output logic q, out);
        always_ff @(posedge clk) begin
            if (rst) q <= 1'b0;
            else if (gate) q <= d;
        end
        assign out = q ^ d;
        p_same: assert property (@(posedge clk) out == (q ^ d));
        p_history: assert property (@(posedge clk) q != $past(d, 2));
        p_overlap: assert property (@(posedge clk) gate |-> d ##1 q);
        p_delay: assert property (@(posedge clk) gate |=> d[*1:2] ##[1:2] q);
        env: assume property (@(posedge clk) rst |=> !q);
        c_range: cover property (@(posedge clk) d ##[1:2] !q);
    endmodule
)SV";
    const std::vector<q3a::frontend::SyntaxUnit> units{
        q3a::frontend::parse_source(q3a::frontend::tokenize(source, "fixed-edge.sv"))};
    const auto design = q3a::elaboration::elaborate_top(
        units, "fixed_edge", {}, "Q3A-P0-R0.9.1", q3a::sha256_hex(source));
    auto synchronous = lower_continuous_assignments(units, design);
    auto scheduled = lower_free_event_mask(units, design);

    // Compare at monitor completion samples. The baseline PDR monitor
    // advances on every sample and the event monitor advances on an edge.
    std::size_t monitors = 0;
    for (auto& property : synchronous.properties) {
        if (property.consequent || !is_same_sample_sequence(property.antecedent)) {
            lower_sequence_monitor(synchronous, property, monitors, 128);
        }
    }
    for (auto* model : {&synchronous, &scheduled.transition}) {
        for (auto& property : model->properties) {
            if (property.kind == "assume") property.kind = "assert";
        }
    }

    q3a::sat::Solver solver;
    q3a::sat::TransitionCnfEncoder baseline(solver, synchronous);
    q3a::sat::TransitionCnfEncoder event(solver, scheduled.transition);
    constexpr std::size_t transitions = 6;
    baseline.encode(transitions);
    event.encode(transitions);

    const auto tie = [&](Literal left, Literal right) {
        solver.add_clause({-left, right});
        solver.add_clause({left, -right});
    };
    const auto differs = [&](Literal left, Literal right) {
        for (const auto& polarity : {std::vector<Literal>{left, -right},
                                    std::vector<Literal>{-left, right}}) {
            require(solver.solve({}, polarity).status == q3a::sat::Status::Unsatisfiable,
                    "fixed-edge and synchronous models admit different results");
        }
    };
    tie(baseline.frames()[0].at("q").front(), event.frames()[0].at("q").front());
    for (std::size_t sample = 0; sample <= transitions; ++sample) {
        const auto& fixed = baseline.frames()[sample];
        const auto& mask = event.frames()[sample];
        solver.add_clause({mask.at(scheduled.edge_inputs.at("clk")).front()});
        for (const auto* input : {"rst", "d", "gate"}) {
            tie(fixed.at(input).front(), mask.at(input).front());
        }
    }
    require(solver.solve().status == q3a::sat::Status::Satisfiable,
            "fixed-edge comparison constraints are inconsistent");
    const auto baseline_cover = baseline.add_cover_hit("c_range");
    const auto event_cover = event.add_cover_hit("c_range");
    require(baseline_cover.hit_frames == event_cover.hit_frames &&
            baseline_cover.hit_frames.size() == transitions + 1,
            "fixed-edge cover completion samples differ");
    for (std::size_t sample = 0; sample <= transitions; ++sample) {
        for (const auto* signal : {"q", "out"}) {
            differs(baseline.frames()[sample].at(signal).front(), event.frames()[sample].at(signal).front());
        }
        for (const auto* property : {"p_same", "p_history", "p_overlap", "p_delay", "env"}) {
            differs(baseline.encode_induction_assertion_at_frame(property, sample),
                    event.encode_induction_assertion_at_frame(property, sample));
        }
        differs(baseline_cover.hit_literals[sample], event_cover.hit_literals[sample]);
    }
    std::cout << "PASS: 56 fixed-edge transition and property observations matched across seven samples.\n";
}

} // namespace

int main(int argc, char** argv) {
    try {
        const auto memories = memory_checks(0) + memory_checks(1);
        const auto events = event_checks();
        const auto boundaries = boundary_checks();
        rejection_checks();
        require(argc == 2, "expected a certificate output directory");
        certificate_checks(argv[1]);
        source_memory_checks();
        memory_group_checks(argv[1]);
        source_clock_checks();
        source_domain_sva_checks(argv[1]);
        check_fixed_edge_embedding();
        std::cout << "PASS: " << memories + boundaries << " exact memory and " << events
                  << " event-mask transitions validated by SAT and replay, with five invalid descriptions rejected.\n"
                  << "PASS: memory successors proved for arbitrary pre-state and data across 128 address and enable combinations.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
