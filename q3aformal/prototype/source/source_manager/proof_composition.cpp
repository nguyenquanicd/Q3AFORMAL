#include "proof_composition.hpp"

#include "lowering.hpp"
#include "platform_support.hpp"
#include "proof_artifact.hpp"
#include "transition_encoder.hpp"
#include "write_locked_input.hpp"
#include "../bundle/windows_file_path.hpp"

#include <algorithm>
#include <array>
#include <fstream>
#include <iomanip>
#include <map>
#include <set>
#include <sstream>

namespace q3a::composition {
namespace {
constexpr std::uint64_t kMaxProofBytes = 64ULL * 1024 * 1024;

struct Claim {
    std::string property;
    std::vector<std::string> imports;
    std::set<std::string> cuts;
};

struct Plan {
    std::string sha256;
    std::vector<Claim> producers;
    Claim target;
};

std::string read_small(const std::filesystem::path& path) {
    WriteLockedInput input(bundle::detail::absolute_windows_file_path(path));
    std::array<char, 65537> bytes{};
    auto& stream = input.stream();
    stream.read(bytes.data(), bytes.size());
    if (stream.bad() || stream.gcount() == bytes.size()) {
        throw std::invalid_argument("composition plan or completion record exceeds its read limit");
    }
    return {bytes.data(), static_cast<std::size_t>(stream.gcount())};
}

Plan read_plan(const std::filesystem::path& path) {
    const auto bytes = read_small(path);
    Plan plan;
    plan.sha256 = sha256_hex(bytes);
    std::istringstream lines(bytes);
    std::string text, kind, name;
    if (!std::getline(lines, text) || (text != "Q3AFORMAL_COMPOSITION 1" && text != "Q3AFORMAL_COMPOSITION 1\r")) {
        throw std::invalid_argument("expected Q3AFORMAL_COMPOSITION 1");
    }
    std::set<std::string> prior;
    while (std::getline(lines, text)) {
        std::istringstream line(text);
        if (!(line >> kind)) continue;
        if (!plan.target.property.empty() || !(line >> name)) {
            throw std::invalid_argument("invalid composition record after target or missing claim name");
        }
        if (kind == "cut") {
            auto claim = std::find_if(plan.producers.begin(), plan.producers.end(),
                [&](const auto& entry) { return entry.property == name; });
            std::string signal;
            if (claim == plan.producers.end() || !(line >> signal)) {
                throw std::invalid_argument("cut requires a declared producer and at least one signal");
            }
            do {
                if (!claim->cuts.insert(signal).second) throw std::invalid_argument("duplicate composition cut signal");
            } while (line >> signal);
            continue;
        }
        if ((kind != "prove" && kind != "target") || prior.count(name) != 0 || plan.producers.size() > 128) {
            throw std::invalid_argument("invalid or duplicate composition claim");
        }
        Claim claim{name, {}, {}};
        std::set<std::string> imports;
        std::string dependency;
        while (line >> dependency) {
            if (prior.count(dependency) == 0 || !imports.insert(dependency).second) {
                throw std::invalid_argument("each composition import must name a distinct earlier producer");
            }
            claim.imports.push_back(dependency);
        }
        if (kind == "target") {
            plan.target = std::move(claim);
        } else {
            if (plan.producers.size() == 128) throw std::invalid_argument("too many composition producers");
            prior.insert(name);
            plan.producers.push_back(std::move(claim));
        }
    }
    if (plan.target.property.empty() || plan.target.imports.empty()) {
        throw std::invalid_argument("composition requires a final target and at least one imported guarantee");
    }
    return plan;
}

void require_sample_property(const lowering::TIRProperty& property, const lowering::TIRModule& model) {
    const auto horizon = lowering::bounded_induction_property_horizon(property);
    if (model.clocks.size() != 1 || property.clock != model.clocks.front() || !horizon || *horizon != 0) {
        throw std::invalid_argument("composition requires one clock and same-sample predicates: " + property.name);
    }
}

class Cone {
public:
    explicit Cone(const lowering::TIRModule& model) : model_(model) {
        for (const auto& signal : model.signals) signals_.insert(signal.name);
        for (const auto& equation : model.combinational_equations) equations_.emplace(equation.target, &equation);
        for (const auto& equation : model.next_state_equations) equations_.emplace(equation.target, &equation);
    }

    lowering::TIRModule project(const Claim& claim) const {
        std::set<std::string> selected{claim.property};
        selected.insert(claim.imports.begin(), claim.imports.end());
        lowering::TIRModule local;
        local.schema_version = model_.schema_version;
        local.name = model_.name;
        local.input_hash = model_.input_hash;
        local.semantic_profile = model_.semantic_profile;
        local.clocks = model_.clocks;
        local.parameters = model_.parameters;
        local.history_guards = model_.history_guards;
        std::set<std::string> retained;
        std::vector<std::string> work;
        const auto visit = [&](const std::string& signal) {
            if (signals_.count(signal) == 0) throw std::logic_error("T-IR has an unknown signal: " + signal);
            if (retained.insert(signal).second) work.push_back(signal);
        };
        const auto expression = [&](const auto& self, const lowering::TypedExpression& typed) -> void {
            if (typed.kind == "signal" || typed.kind == "history_ref") visit(typed.value);
            for (const auto& operand : typed.operands) self(self, operand);
        };
        for (const auto& guard : local.history_guards) {
            for (const auto& signal : guard.state_chain) {
                if (claim.cuts.count(signal)) throw std::invalid_argument("composition may not cut history validity");
                visit(signal);
            }
        }
        for (const auto& clock : local.clocks) {
            if (claim.cuts.count(clock)) throw std::invalid_argument("composition may not cut the clock");
            visit(clock);
        }
        for (const auto& property : model_.properties) {
            if (property.kind != "assume" && selected.count(property.name) == 0) continue;
            if (property.kind != "assume") {
                if (property.kind != "assert") throw std::invalid_argument("composition claims must be assertions");
                selected.erase(property.name);
            }
            require_sample_property(property, model_);
            for (const auto* sequence : {&property.antecedent, property.consequent ? &*property.consequent : nullptr}) {
                if (!sequence) continue;
                for (const auto& term : sequence->automaton.transitions) expression(expression, term.predicate);
            }
            for (const auto* guard : {&lowering::antecedent_history_guard(property),
                                     &lowering::consequent_history_guard(property)}) {
                if (!guard->empty()) visit(*guard);
            }
            local.properties.push_back(property);
        }
        if (!selected.empty()) throw std::invalid_argument("unknown composition assertion: " + *selected.begin());
        for (std::size_t i = 0; i < work.size(); ++i) {
            const auto& name = work[i];
            if (claim.cuts.count(name)) continue;
            const auto equation = equations_.find(name);
            if (equation != equations_.end()) expression(expression, equation->second->expression);
        }
        for (const auto& cut : claim.cuts) {
            if (retained.count(cut) == 0 || equations_.count(cut) == 0) {
                throw std::invalid_argument("composition cut is not a driven signal in the claim cone: " + cut);
            }
        }
        for (const auto& signal : model_.signals) {
            if (retained.count(signal.name)) {
                local.signals.push_back(signal);
                if (claim.cuts.count(signal.name)) local.signals.back().role = "input";
            }
        }
        const auto keep = [&](const auto& equation) {
            return retained.count(equation.target) != 0 && claim.cuts.count(equation.target) == 0;
        };
        for (const auto& equation : model_.combinational_equations) {
            if (keep(equation)) local.combinational_equations.push_back(equation);
        }
        for (const auto& equation : model_.next_state_equations) {
            if (keep(equation)) local.next_state_equations.push_back(equation);
        }
        return local;
    }

private:
    const lowering::TIRModule& model_;
    std::set<std::string> signals_;
    std::map<std::string, const lowering::TIREquation*> equations_;
};

enum class Obligation { Initial, Transition, Target };

struct ProofCheck {
    const std::filesystem::path& root;
    const MemoryBudget& memory;
    std::string model_digest;
    bool reopen;

    sat::Status run(const lowering::TIRModule& local, const Claim& claim, Obligation type,
                    const std::string& name) const {
        sat::Solver solver([&](auto bytes) { memory.check(bytes); });
        sat::TransitionCnfEncoder encoder(solver, local);
        const bool step = type == Obligation::Transition;
        encoder.encode(step ? 1 : 0, type == Obligation::Initial);
        encoder.constrain_assumptions();
        for (const auto& dep : claim.imports) {
            solver.add_clause({encoder.encode_induction_assertion_at_frame(dep, 0)});
            if (step) solver.add_clause({encoder.encode_induction_assertion_at_frame(dep, 1)});
        }
        if (step) solver.add_clause({encoder.encode_induction_assertion_at_frame(claim.property, 0)});
        const auto target = encoder.encode_induction_assertion_at_frame(claim.property, step ? 1 : 0);
        solver.add_clause({static_cast<sat::Literal>(-target)});
        const auto cnf_path = root / (name + ".cnf");
        const auto proof_path = root / (name + ".q3adrat");
        const auto digest = sha256_generated([&](auto& out) { solver.write_dimacs(out); });
        const checker::ArtifactMetadata identity{"composition-" + name, checker::kCheckerId, model_digest, digest};
        if (!reopen) {
            std::ofstream cnf(cnf_path, std::ios::binary);
            solver.write_dimacs(cnf);
            cnf.close();
            if (!cnf) throw std::runtime_error("cannot write composition CNF");
            const auto body_path = root / (name + ".body");
            std::fstream body(body_path, std::ios::in | std::ios::out | std::ios::binary | std::ios::trunc);
            if (!body) throw std::runtime_error("cannot stage composition proof");
            sat::Limits limits{1000000, 10000000, true, checker::kMaximumCheckerProofRecords};
            limits.proof_sink = [&](const auto& clause) {
                for (auto literal : clause) body << literal << ' ';
                body << "0\n";
                if (!body) throw std::runtime_error("cannot write composition proof records");
                if (body.tellp() > std::streampos(kMaxProofBytes)) throw MemoryBudgetExceeded("composition proof staging limit");
            };
            const auto proof = solver.solve(limits);
            if (proof.status != sat::Status::Unsatisfiable) {
                body.close();
                std::filesystem::remove(body_path);
                return proof.status;
            }
            body.seekg(0);
            std::ofstream artifact(proof_path, std::ios::binary);
            const auto written = checker::write_drat_artifact(body, proof.proof_record_count, identity, artifact);
            artifact.close();
            body.close();
            if (!written.accepted || !artifact) throw std::runtime_error("cannot publish composition proof");
            std::filesystem::remove(body_path);
        }
        WriteLockedInput cnf(cnf_path);
        if (sha256_stream(cnf.stream()) != digest) throw std::runtime_error("composition CNF differs from the source-derived query: " + name);
        cnf.rewind();
        WriteLockedInput proof(proof_path);
        checker::CheckerLimits limits;
        limits.check_memory = [&](auto bytes) { memory.check(bytes); };
        const auto validated = checker::verify_drat_artifact(cnf.stream(), proof.stream(), identity, limits);
        if (validated.resource_limited) return sat::Status::Unknown;
        if (!validated.accepted) throw std::runtime_error("composition proof rejected: " + name + ": " + validated.message);
        return sat::Status::Unsatisfiable;
    }
};

int unresolved(std::ostream& output, std::string_view status, const std::string& obligation, std::size_t checked) {
    output << "{\"status\":" << std::quoted(std::string(status))
           << ",\"obligation\":" << std::quoted(obligation) << ",\"checked_obligations\":" << checked << "}\n";
    return 1;
}
} // namespace

int check(const lowering::TIRModule& model, const std::filesystem::path& path,
          const std::filesystem::path& evidence, std::string_view manifest_sha256, bool reopen,
          const MemoryBudget& memory, std::ostream& output) {
    const auto plan = read_plan(path);
    const auto root = bundle::detail::absolute_windows_file_path(evidence);
    const auto model_digest = sha256_hex(lowering::serialize_tir(model));
    const auto context_digest = sha256_hex(std::string("Q3AFORMAL_COMPOSITION 1\n") + model_digest + '\n' +
        std::string(manifest_sha256) + '\n' + plan.sha256 + '\n' + checker::kCheckerId + '\n');
    const auto complete = root / "composition.complete";
    if (reopen && read_small(complete) != context_digest + '\n') {
        throw std::invalid_argument("composition completion identity differs from the current model or plan");
    }
    const Cone cone(model);
    for (const auto& claim : plan.producers) {
        memory.check();
        cone.project(claim);
    }
    memory.check();
    cone.project(plan.target);
    {
        sat::Solver solver([&](auto bytes) { memory.check(bytes); });
        sat::TransitionCnfEncoder encoder(solver, model);
        encoder.encode(0);
        encoder.constrain_assumptions();
        const auto status = solver.solve({1000000, 10000000}).status;
        if (status == sat::Status::Unknown) return unresolved(output, "RESOURCE_LIMIT", "environment-initial", 0);
        if (status == sat::Status::Unsatisfiable) return unresolved(output, "INCONSISTENT_ENVIRONMENT", "environment-initial", 0);
    }
    if (!reopen && !std::filesystem::create_directory(root)) {
        throw std::invalid_argument("composition evidence directory already exists");
    }
    const ProofCheck proofs{root, memory, context_digest, reopen};
    std::size_t checked = 0;
    for (std::size_t i = 0; i < plan.producers.size(); ++i) {
        memory.check();
        const auto local = cone.project(plan.producers[i]);
        for (const auto step : {false, true}) {
            const auto name = "node-" + std::to_string(i + 1) + (step ? "-step" : "-initial");
            const auto status = proofs.run(local, plan.producers[i], step ? Obligation::Transition : Obligation::Initial, name);
            if (status != sat::Status::Unsatisfiable) {
                return unresolved(output, status == sat::Status::Satisfiable ? "UNPROVEN" : "RESOURCE_LIMIT", name, checked);
            }
            ++checked;
        }
    }
    const auto status = proofs.run(cone.project(plan.target), plan.target, Obligation::Target, "target");
    if (status != sat::Status::Unsatisfiable) {
        return unresolved(output, status == sat::Status::Satisfiable ? "UNPROVEN" : "RESOURCE_LIMIT", "target", checked);
    }
    if (!reopen) {
        const auto pending = root / "composition.pending";
        std::ofstream result(pending, std::ios::binary);
        result << context_digest << '\n';
        result.close();
        if (!result) throw std::runtime_error("cannot record composition completion");
        std::filesystem::rename(pending, complete);
    }
    output << "{\"status\":\"" << (reopen ? "REVALIDATED" : "PROVEN")
           << "\",\"target\":" << std::quoted(plan.target.property)
           << ",\"checked_obligations\":" << checked + 1
           << ",\"model_sha256\":" << std::quoted(model_digest)
           << ",\"plan_sha256\":" << std::quoted(plan.sha256)
           << ",\"context_sha256\":" << std::quoted(context_digest)
           << ",\"environment_feasibility\":\"INITIAL_SAT\"}\n";
    return 0;
}

} // namespace q3a::composition
