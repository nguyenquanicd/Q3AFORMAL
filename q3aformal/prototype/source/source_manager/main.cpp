#include "source_manager.hpp"
#include "batch_worker.hpp"
#include "proof_composition.hpp"
#include "equivalence.hpp"
#include "vcd_import.hpp"
#include "indexed_trace.hpp"
#include "induction_feasibility.hpp"
#include "trace_capture.hpp"
#include "write_locked_input.hpp"
#include "../bundle/windows_file_path.hpp"
#include "lexer.hpp"
#include "parser.hpp"
#include "preprocessor.hpp"
#include "elaborator.hpp"
#include "lowering.hpp"
#include "dimacs.hpp"
#include "sat_solver.hpp"
#include "transition_encoder.hpp"
#include "pdr.hpp"
#include "property_replay.hpp"
#include "drat_prover.hpp"
#include "proof_artifact.hpp"
#include "run_bundle.hpp"
#include "verify_bundle.hpp"
#include "native_debug_win32.hpp"
#include "../cache/proof_cache.hpp"
#include "q3a_build_info.hpp"
#ifdef Q3A_ENABLE_DEVELOPMENT_FOUR_STATE
#include "../four_state/proof.hpp"
#include "../replay/replay_timing.hpp"
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_LIVENESS
#include "../liveness/evidence.hpp"
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_EVENT_MASK
#include "../bundle/event_witness.hpp"
#include "../bundle/event_debug.hpp"
#include "../sat/event_window.hpp"
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_MEMORY
#include "../bundle/memory_debug.hpp"
#include "memory_proof.hpp"
#include "state_transition.hpp"
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <system_error>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

std::filesystem::path gExecutablePath;

enum class ProofExit { Conclusive = 0, Inconclusive = 1, SetupError = 2, EngineError = 3 };

// A run-control signal bypasses component error translators and unwinds staged evidence.
enum class ProofStop { Timeout, CancelFile, CtrlC, CtrlBreak, ControlError };

constexpr DWORD kNoConsoleEvent = std::numeric_limits<DWORD>::max();
std::atomic<DWORD> gConsoleEvent{kNoConsoleEvent};

BOOL WINAPI proof_console_handler(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) return FALSE;
    auto expected = kNoConsoleEvent;
    gConsoleEvent.compare_exchange_strong(expected, event, std::memory_order_relaxed);
    return TRUE;
}

std::string_view cancellation_cause(std::optional<ProofStop> stop) {
    if (stop == ProofStop::CancelFile) return "cancel_file";
    if (stop == ProofStop::CtrlC) return "ctrl_c";
    if (stop == ProofStop::CtrlBreak) return "ctrl_break";
    return {};
}

std::filesystem::file_type control_path_type(const std::filesystem::path& path) {
    std::error_code error;
    const auto type = std::filesystem::symlink_status(
        q3a::bundle::detail::windows_file_path(path), error).type();
    if (type == std::filesystem::file_type::not_found) return type;
    if (error) throw std::system_error(error, "cannot inspect run-control path");
    return type;
}

std::filesystem::path default_witness_directory() {
    static std::atomic<std::uint64_t> sequence{0};
    const auto nonce = std::chrono::high_resolution_clock::now().time_since_epoch().count();
    return std::filesystem::current_path() / "q3aformal-results" /
        ("witness-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(nonce) +
         "-" + std::to_string(sequence.fetch_add(1)));
}

struct ProofCommand {
    explicit ProofCommand(bool product_cli = false)
        : progress(product_cli ? std::cerr : std::cout), product_cli(product_cli) {}

    std::ostream& progress;
    bool product_cli;
    ProofExit exit = ProofExit::SetupError;
    std::string status = "SETUP_ERROR";
    std::string_view resource_limit;
    using Clock = std::chrono::steady_clock;
    Clock::time_point started = Clock::now();
    std::chrono::milliseconds timeout{0};
    std::string_view stage = "setup";
    std::filesystem::path cancel_file;
    std::filesystem::path run_record;
    std::filesystem::path saved_bundle;
    std::filesystem::path certificate_dir;
    std::optional<q3a::pdr::CheckedCertificate> certificate;
    std::string run_configuration;
    std::string interruption_configuration;
    mutable Clock::time_point next_cancel_poll = started;
    std::vector<std::string_view> completed_work;
    std::string source_identity;
    std::string engine;
    bool console_control = false;
    std::uint64_t job_memory_mib = 0;

    struct Activation {
        std::optional<std::uint64_t> bound;
        std::optional<bool> incomplete_boundary;
        std::string_view feasibility = "NOT_CHECKED";
        std::string_view activity = "NOT_CHECKED";
        bool complete = false;
    };
    std::optional<Activation> activation;
    bool activation_analysis = false;

    struct EnvironmentFeasibility {
        std::uint64_t bound;
        q3a::sat::Status status;
    };
    std::optional<EnvironmentFeasibility> environment_feasibility;

    struct InputFailure {
        std::string_view code;
        q3a::frontend::SourceLocation location;
        std::string message;
    };
    std::optional<InputFailure> input_diagnostic;

    bool has_control() const {
        return console_control || timeout.count() != 0 || !cancel_file.empty();
    }

    void check_control(bool force_poll = false) const {
        if (!has_control()) return;
        if (console_control) {
            const auto event = gConsoleEvent.load(std::memory_order_relaxed);
            if (event == CTRL_C_EVENT) throw ProofStop::CtrlC;
            if (event == CTRL_BREAK_EVENT) throw ProofStop::CtrlBreak;
        }
        if (timeout.count() == 0 && cancel_file.empty()) return;
        const auto now = Clock::now();
        if (!cancel_file.empty() && (force_poll || now >= next_cancel_poll)) {
            next_cancel_poll = now + std::chrono::milliseconds(20);
            std::filesystem::file_type type;
            try {
                type = control_path_type(cancel_file);
            } catch (const std::system_error&) {
                throw ProofStop::ControlError;
            }
            if (type == std::filesystem::file_type::regular) throw ProofStop::CancelFile;
            if (type != std::filesystem::file_type::not_found) throw ProofStop::ControlError;
        }
        if (timeout.count() != 0 && now - started >= timeout) throw ProofStop::Timeout;
    }

    void enter_stage(std::string_view next) {
        stage = next;
        if (product_cli && console_control && next == "elaboration") {
            progress << "Q3A_PROVE_STAGE ELABORATION\n" << std::flush;
        }
        check_control(true);
    }

    q3a::MemoryBudget budget() const {
        if (!has_control()) return q3a::MemoryBudget{{}, job_memory_mib};
        return q3a::MemoryBudget{[this] { check_control(); }, job_memory_mib};
    }

    void completed(std::string_view item) {
        if ((!run_record.empty() || has_control()) &&
            std::find(completed_work.begin(), completed_work.end(), item) == completed_work.end()) {
            completed_work.push_back(item);
        }
    }

    void loaded(const q3a::ProjectInput& project) {
        if (!run_record.empty() || has_control()) source_identity = project.input_hash;
        completed("project_loaded");
    }

    void bundle_created(const std::filesystem::path& path) {
        if (product_cli) saved_bundle = std::filesystem::absolute(path).lexically_normal();
        progress << "Q3A_BUNDLE_CREATED " << std::quoted(path.u8string()) << '\n';
    }

    int finish(int legacy_exit, ProofExit product_exit, std::string property_status) {
        exit = product_exit;
        status = std::move(property_status);
        resource_limit = {};
        return legacy_exit;
    }

    int finish_resource(int legacy_exit, std::string_view kind) {
        finish(legacy_exit, ProofExit::Inconclusive, "RESOURCE_LIMIT");
        resource_limit = kind;
        return legacy_exit;
    }

    int reject_input(const char* status, std::string_view code,
                     const q3a::frontend::SourceLocation& location, const char* message) {
        if (product_cli) input_diagnostic = InputFailure{code, location, message};
        return finish(1, ProofExit::SetupError, status);
    }

    int reject_input(const q3a::frontend::LexError& error) {
        return reject_input("SETUP_ERROR", "Q3A_LEX_ERROR", error.location(), error.what());
    }

    int reject_input(const q3a::frontend::ParseError& error) {
        const bool unsupported = error.kind() == q3a::frontend::InputDiagnosticKind::Unsupported;
        return reject_input(unsupported ? "UNSUPPORTED" : "SETUP_ERROR",
            "Q3A_PARSE_ERROR", error.location(), error.what());
    }

    int reject_input(const q3a::elaboration::ElaborationError& error) {
        return reject_input("ELABORATION_ERROR", "Q3A_ELABORATION_ERROR", error.location(), error.what());
    }

    int reject_input(const q3a::lowering::LoweringError& error) {
        const bool unsupported = error.kind() == q3a::frontend::InputDiagnosticKind::Unsupported;
        return reject_input(unsupported ? "UNSUPPORTED" : "ELABORATION_ERROR",
            "Q3A_LOWERING_ERROR", error.location(), error.what());
    }

    int reject_bit_blast(const q3a::sat::BitBlastError& error) {
        if (error.unsupported()) {
            return reject_input("UNSUPPORTED", "Q3A_BITBLAST_ERROR", error.location(), error.what());
        }
        return finish(1, ProofExit::EngineError, "ENGINE_ERROR");
    }
};

q3a::ProjectInput load_proof_project(const std::filesystem::path& path, ProofCommand& command) {
    if (command.job_memory_mib != 0) {
        command.enter_stage("source_loading");
        const auto memory = command.budget();
        return q3a::SourceManager::load(path, [&memory] { memory.check(); });
    }
    if (!command.has_control()) return q3a::SourceManager::load(path);
    command.enter_stage("source_loading");
    return q3a::SourceManager::load(path, [&command] { command.check_control(); });
}

void set_proof_configuration(ProofCommand& command, const q3a::ProjectInput& project,
                                     const q3a::lowering::TIRModule& model,
                                     const q3a::lowering::TIRProperty& selected,
                                     const q3a::MemoryBudget& memory, std::string_view engine,
                                     std::uint64_t depth, bool activation = false,
                                     std::optional<std::uint64_t> maximum_search_queries = std::nullopt,
                                     std::uint64_t minimum_feasibility_bound = 0);

q3a::replay::FrameView proof_replay_view(const std::vector<q3a::replay::Frame>& trace,
                                        const ProofCommand& command) {
    if (!command.has_control()) return q3a::replay::FrameView(trace);
    return {trace.size(), [&trace, &command](std::size_t index) -> const q3a::replay::Frame& {
        command.check_control();
        return trace.at(index);
    }};
}

void write_run_record(const std::filesystem::path& destination, std::string_view payload) {
    const auto stage = destination.parent_path() /
        (".q3a-record-" + std::to_string(GetCurrentProcessId()) + "-" +
         std::to_string(ProofCommand::Clock::now().time_since_epoch().count()));
    const auto native_stage = q3a::bundle::detail::windows_file_path(stage);
    const auto native_target = q3a::bundle::detail::windows_file_path(destination);
    const auto file = CreateFileW(native_stage.c_str(), GENERIC_WRITE, 0, nullptr,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("cannot stage run record");
    DWORD written = 0;
    const auto complete = WriteFile(file, payload.data(), static_cast<DWORD>(payload.size()), &written, nullptr) &&
        written == payload.size() && FlushFileBuffers(file);
    const auto closed = CloseHandle(file);
    if (!complete || !closed || !MoveFileExW(native_stage.c_str(), native_target.c_str(), MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(native_stage.c_str());
        throw std::runtime_error("cannot publish run record without replacing an existing path");
    }
}

std::string read_text_file(const std::filesystem::path& path,
                           const std::string& description) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot read " + description);
    const std::string content((std::istreambuf_iterator<char>(input)),
                              std::istreambuf_iterator<char>());
    if (input.bad()) throw std::runtime_error("failed while reading " + description);
    return content;
}

void copy_evidence_to_stream(const std::filesystem::path& path, std::ostream& output) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot open staged evidence for copying");
    std::array<char, 64 * 1024> buffer;
    do {
        input.read(buffer.data(), buffer.size());
        output.write(buffer.data(), input.gcount());
        if (!output) throw std::runtime_error("failed while writing evidence copy");
    } while (input);
    if (input.bad() || !input.eof()) {
        throw std::runtime_error("failed while reading staged evidence");
    }
}

std::vector<q3a::bundle::ComponentFingerprint> component_fingerprints() {
    return {
        {"source_manager", q3a::build_info::kComponentHash_source_manager},
        {"frontend", q3a::build_info::kComponentHash_frontend},
        {"elaborator", q3a::build_info::kComponentHash_elaborator},
        {"lowering_sva", q3a::build_info::kComponentHash_lowering_sva},
        {"sat_bit_blaster", q3a::build_info::kComponentHash_sat_bit_blaster},
        {"witness_replay", q3a::build_info::kComponentHash_witness_replay},
        {"proof_checker", q3a::build_info::kComponentHash_proof_checker},
        {"result_bundle", q3a::build_info::kComponentHash_result_bundle},
        {"proof_cache", q3a::build_info::kComponentHash_proof_cache}
    };
}

void populate_bundle_identity(
    q3a::bundle::RunBundleRequest& request,
    const ProofCommand& command,
    const q3a::lowering::TIRModule& model,
    const std::filesystem::path& manifest_path,
    std::string serialized_model,
    bool proof_checker_used) {
    request.executable_path = gExecutablePath;
    request.compiler = q3a::build_info::kCompiler;
    request.build_id = q3a::build_info::kBuildId;
    request.components = component_fingerprints();
    request.run_configuration = command.run_configuration;
    request.model_schema = model.schema_version;
    request.model_json = std::move(serialized_model);
    request.project_manifest_content = read_text_file(manifest_path, "project manifest");
    for (const auto& property : model.properties) {
        if (property.kind == "assume") request.assumptions.push_back(property.name);
        if (property.name == request.property && property.kind != "assume") {
            request.sampling_clock = property.clock;
            request.property_signals = q3a::trace::PropertySignalIndex(model).for_property(property);
        }
    }
    request.checker_id = proof_checker_used
        ? q3a::checker::kCheckerId : "q3a-property-replay-0.1";
    request.checker_fingerprint = proof_checker_used
        ? q3a::build_info::kComponentHash_proof_checker
        : q3a::build_info::kComponentHash_witness_replay;
    request.checker_artifact_schema = proof_checker_used
        ? std::to_string(q3a::checker::kProofArtifactSchema) : "";
}

void write_bounded_feasibility_bundle(
    const q3a::ProjectInput& project, const q3a::lowering::TIRModule& model,
    const std::filesystem::path& manifest_path, const std::filesystem::path& destination,
    const std::string& property_name, std::uint64_t bound, bool boundary_incomplete,
    q3a::sat::Status feasibility, ProofCommand::Clock::time_point started,
    const q3a::sat::Solver& solver, const ProofCommand& command) {
    const bool inconsistent = feasibility == q3a::sat::Status::Unsatisfiable;
    q3a::bundle::RunBundleRequest request;
    request.output_directory = destination;
    request.command = "bmc";
    request.status = inconsistent ? "INCONSISTENT_MODEL_OR_ASSUMPTIONS" : "UNKNOWN";
    request.property = property_name;
    request.algorithm = "bounded-model-checking";
    request.detail = inconsistent
        ? "bounded model or assumptions are inconsistent before the property query"
        : "bounded model feasibility could not be decided within resource limits";
    request.boundary_obligations = boundary_incomplete ? "INCOMPLETE" : "COMPLETE";
    request.bound = bound;
    request.duration_ms = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            ProofCommand::Clock::now() - started).count());
    const q3a::sat::Limits default_limits;
    request.decision_limit = default_limits.decisions;
    request.propagation_limit = default_limits.propagations;
    populate_bundle_identity(request, command, model, manifest_path, q3a::lowering::serialize_tir(model), false);
    request.queries.push_back({
        "feasibility", "model-feasibility", "bounded-model-checking",
        property_name, bound, inconsistent ? "UNSAT" : "UNKNOWN",
        "queries/" + property_name + ".feasibility.cnf", {},
        [&](std::ostream& output) { solver.write_dimacs(output); }});
    command.check_control(true);
    q3a::bundle::write_result_bundle(project, request);
}

void report_instances(
    const std::vector<q3a::elaboration::ElaboratedInstance>& instances,
    const std::string& parent_path = {}) {
    for (const auto& instance : instances) {
        const auto path = parent_path.empty()
            ? instance.instance_name
            : parent_path + "." + instance.instance_name;
        std::cout << "instance " << path << " module="
                  << instance.module_type << '\n';
        for (const auto& parameter : instance.parameters) {
            std::cout << "  parameter " << parameter.name << " value="
                      << q3a::elaboration::integral_value_text(parameter.value, parameter.is_signed)
                      << " width=" << parameter.width << '\n';
        }
        for (const auto& localparam : instance.localparams) {
            std::cout << "  localparam " << localparam.name << " value="
                      << q3a::elaboration::integral_value_text(localparam.value, localparam.is_signed)
                      << " width=" << localparam.width << '\n';
        }
        for (const auto& port : instance.ports) {
            std::cout << "  port "
                      << (port.direction == q3a::frontend::PortDirection::Input
                              ? "input " : "output ")
                      << port.name << " width=" << port.width << '\n';
        }
        for (const auto& connection : instance.connections) {
            std::cout << "  connection " << connection.formal_port << " <- "
                      << connection.actual_expression << " width="
                      << connection.actual_width << " direction="
                      << (connection.direction == q3a::frontend::PortDirection::Input
                              ? "input" : "output") << '\n';
        }
        report_instances(instance.child_instances, path);
    }
}

void report_syntax(const q3a::frontend::SyntaxUnit& syntax, const std::string& name) {
    std::cout << "Q3A_SYNTAX_OK " << std::quoted(name) << " modules="
              << syntax.modules.size() << '\n';
    for (const auto& module : syntax.modules) {
        std::cout << "module " << module.name << ' '
                  << module.location.line << ':' << module.location.column
                  << " continuous_assignments=" << module.continuous_assignments.size()
                  << " processes=" << module.processes.size()
                  << " property_declarations=" << module.property_declarations.size()
                  << " property_checks=" << module.property_checks.size()
                  << " generate_items=" << module.generate_items.size() << '\n';
    }
    for (const auto& binding : syntax.binds) {
        std::cout << "bind " << binding.target << ' ' << binding.instance.module_type
                  << ' ' << binding.instance.instance_name << ' '
                  << binding.location.line << ':' << binding.location.column << '\n';
    }
    if (!syntax.standalone_declarations.empty() || !syntax.standalone_checks.empty()) {
        std::cout << "standalone property_declarations=" << syntax.standalone_declarations.size()
                  << " property_checks=" << syntax.standalone_checks.size() << '\n';
    }
}

int parse_and_report(const std::string& source, const std::string& name) {
    try {
        report_syntax(q3a::frontend::parse_source(q3a::frontend::tokenize(source, name)), name);
        return 0;
    } catch (const q3a::frontend::LexError& error) {
        std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
    } catch (const q3a::frontend::ParseError& error) {
        std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
    }
    return 1;
}

std::vector<q3a::frontend::SyntaxUnit> parse_project_units(
    const q3a::ProjectInput& project,
    std::optional<q3a::frontend::SyntaxProfile> requested_profile = std::nullopt) {
    const auto declared_profile = q3a::frontend::project_syntax_profile(project.profile_id).value();
    if (requested_profile && declared_profile != q3a::frontend::SyntaxProfile::Released) {
        throw std::invalid_argument("the selected command requires a baseline project profile");
    }
    const auto profile = requested_profile.value_or(declared_profile);
    std::vector<q3a::frontend::SyntaxUnit> units;
    units.reserve(project.sources.size());
    if (!project.preprocessed_units.empty()) {
        for (const auto& tokens : project.preprocessed_units) {
            units.push_back(q3a::frontend::parse_source(tokens, project.manifest_version == 2, profile));
        }
        return units;
    }
    q3a::frontend::Preprocessor preprocessor(project.macros);
    for (const auto& file : project.sources) {
        const std::string source(file.contents.begin(), file.contents.end());
        auto tokens = project.manifest_version == 2 ? preprocessor.tokenize_unit(source, file.relative_path)
            : q3a::frontend::tokenize(source, file.relative_path);
        units.push_back(q3a::frontend::parse_source(std::move(tokens), project.manifest_version == 2, profile));
    }
    return units;
}

int elaborate_and_report(const q3a::ProjectInput& project) {
    try {
        const auto units = parse_project_units(project);
        const auto result = q3a::elaboration::elaborate_top(
            units, project.top_module, project.parameters,
            project.profile_id, project.input_hash);
        std::cout << "Q3A_ELABORATED 1\n"
                  << "profile " << result.profile_id << '\n'
                  << "input_sha256 " << result.input_hash << '\n'
                  << "top " << result.top.name << '\n';
        for (const auto& parameter : result.top.parameters) {
            std::cout << "parameter " << parameter.name << " value="
                      << q3a::elaboration::integral_value_text(parameter.value, parameter.is_signed)
                      << " type="
                      << q3a::elaboration::scalar_type_name(parameter.type)
                      << " width=" << parameter.width
                      << " signed=" << (parameter.is_signed ? 1 : 0) << '\n';
        }
        for (const auto& localparam : result.top.localparams) {
            std::cout << "localparam " << localparam.name << " value="
                      << q3a::elaboration::integral_value_text(localparam.value, localparam.is_signed)
                      << " type="
                      << q3a::elaboration::scalar_type_name(localparam.type)
                      << " width=" << localparam.width
                      << " signed=" << (localparam.is_signed ? 1 : 0) << '\n';
        }
        for (const auto& port : result.top.ports) {
            std::cout << "port "
                      << (port.direction == q3a::frontend::PortDirection::Input
                              ? "input " : "output ")
                      << port.name << " width=" << port.width
                      << " type=" << q3a::elaboration::scalar_type_name(port.type)
                      << " signed=" << (port.is_signed ? 1 : 0) << '\n';
        }
        for (const auto& signal : result.top.signals) {
            std::cout << "signal " << signal.name << " width=" << signal.width
                      << " type=" << q3a::elaboration::scalar_type_name(signal.type)
                      << " signed=" << (signal.is_signed ? 1 : 0) << '\n';
        }
        for (const auto& scope : result.top.generate_scopes) {
            std::cout << "generate " << scope.kind << " path="
                      << std::quoted(scope.path) << " selected="
                      << (scope.selected ? 1 : 0);
            if (scope.iteration_value) {
                std::cout << " index=" << *scope.iteration_value;
            }
            if (scope.kind == "for") {
                std::cout << " iterations=" << scope.iteration_count;
            }
            for (const auto& genvar : scope.genvar_values) {
                std::cout << " genvar " << genvar.first << "=" << genvar.second;
            }
            std::cout << '\n';
        }
        report_instances(result.top.instances);
        return 0;
    } catch (const q3a::frontend::LexError& error) {
        std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
    } catch (const q3a::frontend::ParseError& error) {
        std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
    } catch (const q3a::elaboration::ElaborationError& error) {
        std::cerr << "Q3A_ELABORATION_ERROR " << error.what() << '\n';
    } catch (const std::exception& error) {
        std::cerr << "Q3A_ELABORATION_ERROR " << error.what() << '\n';
    }
    return 1;
}

q3a::lowering::TIRModule lower_project_tir(const q3a::ProjectInput& project,
                                           std::vector<q3a::elaboration::TypedSignal>* ports = nullptr) {
    if (project.profile_id == q3a::frontend::kFourStateProfile) {
        throw q3a::lowering::LoweringError({std::string{}, 1, 1, 0},
            "four-state profile requires a four-state development command", q3a::frontend::InputDiagnosticKind::Unsupported);
    }
    const auto units = parse_project_units(project);
    const auto elaborated = q3a::elaboration::elaborate_top(
        units, project.top_module, project.parameters,
        project.profile_id, project.input_hash);
    if (ports) *ports = elaborated.top.ports;
    return q3a::lowering::lower_continuous_assignments(units, elaborated);
}

int lower_and_report(const q3a::ProjectInput& project) {
    try {
        const auto lowered = lower_project_tir(project);
        std::cout << q3a::lowering::serialize_tir(lowered) << '\n';
        return 0;
    } catch (const q3a::frontend::LexError& error) {
        std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
    } catch (const q3a::frontend::ParseError& error) {
        std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
    } catch (const q3a::elaboration::ElaborationError& error) {
        std::cerr << "Q3A_ELABORATION_ERROR " << error.what() << '\n';
    } catch (const q3a::lowering::LoweringError& error) {
        std::cerr << "Q3A_LOWERING_ERROR " << error.what() << '\n';
    } catch (const std::exception& error) {
        std::cerr << "Q3A_LOWERING_ERROR " << error.what() << '\n';
    }
    return 1;
}

int transition_cnf_project(const q3a::ProjectInput& project,
                           std::uint64_t transition_count) {
    try {
        const auto lowered = lower_project_tir(project);
        q3a::sat::Solver solver;
        q3a::sat::TransitionCnfEncoder encoder(solver, lowered);
        encoder.encode(transition_count);

        std::cout << "c q3a_transition_cnf schema=" << lowered.schema_version
                  << " top=" << lowered.name
                  << " transitions=" << transition_count
                  << " frames=" << (transition_count + 1)
                  << " input_sha256=" << lowered.input_hash << '\n';
        for (std::size_t frame = 0; frame < encoder.frames().size(); ++frame) {
            for (const auto& signal : encoder.frames()[frame]) {
                for (std::size_t bit = 0; bit < signal.second.size(); ++bit) {
                    std::cout << "c q3a_signal frame=" << frame
                              << " name=" << signal.first
                              << " bit=" << bit
                              << " var=" << signal.second[bit] << '\n';
                }
            }
        }
        solver.write_dimacs(std::cout);
        return std::cout ? 0 : 1;
    } catch (const q3a::frontend::LexError& error) {
        std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
    } catch (const q3a::frontend::ParseError& error) {
        std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
    } catch (const q3a::elaboration::ElaborationError& error) {
        std::cerr << "Q3A_ELABORATION_ERROR " << error.what() << '\n';
    } catch (const q3a::lowering::LoweringError& error) {
        std::cerr << "Q3A_LOWERING_ERROR " << error.what() << '\n';
    } catch (const q3a::sat::BitBlastError& error) {
        std::cerr << "Q3A_BITBLAST_ERROR " << error.what() << '\n';
    } catch (const std::exception& error) {
        std::cerr << "Q3A_TRANSITION_CNF_ERROR " << error.what() << '\n';
    }
    return 1;
}

struct InductionObligation {
    q3a::checker::ProofStatus status = q3a::checker::ProofStatus::Unknown;
    std::uint64_t search_nodes = 0;
    std::uint64_t proof_records = 0;
    bool replay_validated = false;
    bool engine_error = false;
    std::string_view resource_limit;
    std::string cache_key;
    std::string cache_status;
    std::string cache_diagnostic;
    std::size_t failure_frame = static_cast<std::size_t>(-1);
    std::filesystem::path staged_cnf;
    std::filesystem::path staged_artifact;
    // Keep verified staging files write-locked through result publication.
    std::unique_ptr<q3a::WriteLockedInput> locked_cnf;
    std::unique_ptr<q3a::WriteLockedInput> locked_artifact;
    std::filesystem::path staged_witness;
    std::filesystem::path staged_index;
    std::string diagnostic;
};

class InductionProofStaging {
public:
    explicit InductionProofStaging(const std::filesystem::path& prefix) {
        auto requested_parent = prefix.parent_path();
        if (const auto* scratch = _wgetenv(L"Q3A_SCRATCH_DIR"); scratch && *scratch) {
            requested_parent = scratch;
        }
        const auto absolute = std::filesystem::absolute(
            requested_parent.empty() ? std::filesystem::path(".") : requested_parent);
        std::error_code parent_error;
        const auto parent = q3a::bundle::detail::canonical_directory(absolute, parent_error);
        if (parent_error) {
            throw std::system_error(parent_error,
                "cannot resolve the induction proof staging parent: " + absolute.u8string());
        }
        const auto nonce = std::chrono::high_resolution_clock::now().time_since_epoch().count();
        for (int attempt = 0; attempt < 8; ++attempt) {
            auto path = parent / (".q3ap-" + std::to_string(nonce) + "-" + std::to_string(attempt));
            if (std::filesystem::create_directory(path)) {
                directory_ = std::move(path);
                return;
            }
        }
        throw std::runtime_error("cannot create an exclusive induction proof staging directory");
    }

    InductionProofStaging(const InductionProofStaging&) = delete;
    InductionProofStaging& operator=(const InductionProofStaging&) = delete;

    ~InductionProofStaging() {
        std::error_code ignored;
        for (const auto* name : {"base.raw", "step.raw", "base.checked", "step.checked",
                                 "base.cnf", "step.cnf", "base.witness.txt", "step.witness.txt",
                                 "base.trace.q3atrace", "step.trace.q3atrace"}) {
            std::filesystem::remove(directory_ / name, ignored);
        }
        std::filesystem::remove(directory_, ignored);
    }

    std::filesystem::path body(bool base) const {
        return directory_ / (base ? "base.raw" : "step.raw");
    }

    std::filesystem::path artifact(bool base) const {
        return directory_ / (base ? "base.checked" : "step.checked");
    }

    std::filesystem::path cnf(bool base) const {
        return directory_ / (base ? "base.cnf" : "step.cnf");
    }

    std::filesystem::path witness(bool base) const {
        return directory_ / (base ? "base.witness.txt" : "step.witness.txt");
    }

    std::filesystem::path indexed_witness(bool base) const {
        return directory_ / (base ? "base.trace.q3atrace" : "step.trace.q3atrace");
    }

private:
    std::filesystem::path directory_;
};

bool is_supported_induction_property(
    const q3a::lowering::TIRProperty& property) {
    return q3a::lowering::bounded_induction_property_horizon(property).has_value();
}

int prove_inductive_project(const q3a::ProjectInput& project,
                            const std::filesystem::path& manifest_path,
                            const std::string& property_name,
                            const std::filesystem::path& output_prefix,
                            const std::filesystem::path& bundle_directory,
                            const std::filesystem::path& cache_directory,
                            std::uint64_t induction_depth,
                            const q3a::trace::CaptureRequest& capture,
                            ProofCommand& command) {
    try {
        const auto run_started = std::chrono::steady_clock::now();
        command.loaded(project);
        command.enter_stage("elaboration");
        const auto memory_budget = command.budget();
        memory_budget.check();
        q3a::checker::CheckerLimits checker_limits;
        checker_limits.check_memory = [&](std::uint64_t pending) { memory_budget.check(pending); };
        if (induction_depth == 0 || induction_depth > 10000) {
            throw std::invalid_argument(
                "induction depth must be between 1 and the transition-frame limit 10000");
        }
        const auto lowered = lower_project_tir(project);
        command.completed("model_elaborated");
        memory_budget.check();
        const auto target = std::find_if(
            lowered.properties.begin(), lowered.properties.end(),
            [&](const q3a::lowering::TIRProperty& candidate) {
                return candidate.name == property_name;
            });
        if (target == lowered.properties.end()) {
            throw std::invalid_argument("unknown property name '" + property_name + "'");
        }
        if (target->kind != "assert") {
            throw std::invalid_argument(
                "k-induction target must be an assertion property");
        }
        if (!is_supported_induction_property(*target)) {
            constexpr auto message =
                "k-induction supports scalar and bounded fixed-delay linear sequence assertions/implications with positive repetition; delayed properties cannot use guarded $past";
            std::cerr << "Q3A_INDUCTION_ERROR " << message << '\n';
            return command.reject_input("UNSUPPORTED", "Q3A_INDUCTION_PROFILE", target->location, message);
        }
        if (command.product_cli) {
            set_proof_configuration(command,
                project, lowered, *target, memory_budget, "induction", induction_depth);
        }
        command.enter_stage("induction_obligations");
        const auto feasibility_bound = q3a::induction_feasibility_bound(lowered, *target, induction_depth);

        // The induction queries include the negated goal. Their UNSAT
        // results alone cannot distinguish a proof from an empty environment.
        {
            q3a::sat::Solver feasibility_solver([&memory_budget](std::uint64_t pending) {
                memory_budget.check(pending);
            });
            q3a::sat::TransitionCnfEncoder feasibility_encoder(feasibility_solver, lowered);
            feasibility_encoder.encode(feasibility_bound);
            feasibility_encoder.constrain_assumptions();
            std::optional<q3a::sat::TransitionCnfEncoder::AssertionQuery> activation_query;
            if (command.product_cli || !bundle_directory.empty()) {
                activation_query = feasibility_encoder.add_assertion_violation(property_name);
            }
            if (command.product_cli) {
                command.activation = ProofCommand::Activation{feasibility_bound,
                    feasibility_encoder.boundary_incomplete(*activation_query)};
            }
            const auto feasible = feasibility_solver.solve_incremental();
            command.environment_feasibility = ProofCommand::EnvironmentFeasibility{
                feasibility_bound, feasible.status};
            if (feasible.status == q3a::sat::Status::Unsatisfiable) {
                if (command.activation) command.activation->feasibility = "UNSAT";
                if (!bundle_directory.empty()) {
                    write_bounded_feasibility_bundle(project, lowered, manifest_path, bundle_directory,
                        property_name, feasibility_bound, feasibility_encoder.boundary_incomplete(*activation_query),
                        feasible.status, run_started, feasibility_solver, command);
                    command.bundle_created(bundle_directory);
                }
                command.progress << "Q3A_INDUCTION_STATUS INCONSISTENT_MODEL_OR_ASSUMPTIONS\n"
                                 << "Q3A_INDUCTION_FEASIBILITY_BOUND " << feasibility_bound << '\n';
                return command.finish(1, ProofExit::Inconclusive, "INCONSISTENT_MODEL_OR_ASSUMPTIONS");
            }
            if (feasible.status == q3a::sat::Status::Unknown) {
                if (command.activation) command.activation->feasibility = "UNKNOWN";
                command.progress << "Q3A_INDUCTION_FEASIBILITY UNKNOWN\n";
                return command.finish_resource(3, "search");
            }
            if (command.activation) {
                command.activation->feasibility = "SAT";
                const auto result = feasibility_encoder.assertion_activity(*activation_query, feasible.assignment);
                command.activation->activity = result == q3a::sat::Status::Satisfiable ? "REACHED" :
                    result == q3a::sat::Status::Unsatisfiable ? "NOT_REACHED" : "UNKNOWN";
            }
        }

        q3a::trace::CaptureSignals capture_signals;
        if (!bundle_directory.empty() || command.product_cli) {
            capture_signals = q3a::trace::select_capture_signals(lowered, *target, capture);
        }
        std::string serialized_model = q3a::lowering::serialize_tir(lowered);
        const auto model_hash = q3a::sha256_hex(serialized_model);
        const InductionProofStaging proof_staging(output_prefix);

        const auto build_obligation = [&](bool base) {
            InductionObligation result;
            q3a::sat::Solver solver([&memory_budget](std::uint64_t pending) {
                memory_budget.check(pending);
            });
            q3a::sat::TransitionCnfEncoder encoder(solver, lowered);
            encoder.encode_induction_obligation(
                *target, induction_depth, base);
            result.staged_cnf = proof_staging.cnf(base);
            {
                std::ofstream cnf_output(result.staged_cnf, std::ios::binary);
                if (!cnf_output) throw std::runtime_error("cannot open staged induction CNF");
                solver.write_dimacs(cnf_output);
                cnf_output.close();
                if (!cnf_output) throw std::runtime_error("failed while writing staged induction CNF");
            }
            const auto cnf_hash = q3a::sha256_generated(
                [&](std::ostream& output) { solver.write_dimacs(output); });
            result.locked_cnf = std::make_unique<q3a::WriteLockedInput>(result.staged_cnf);
            if (q3a::sha256_stream(result.locked_cnf->stream()) != cnf_hash) {
                throw std::runtime_error("staged induction CNF differs from the solver query");
            }
            result.locked_cnf->rewind();
            const auto query_kind = induction_depth == 1
                ? (base ? std::string("induction-base") : std::string("induction-step"))
                : ("induction-k" + std::to_string(induction_depth) +
                   (base ? "-base" : "-step"));
            const q3a::checker::ArtifactMetadata metadata{
                query_kind, q3a::checker::kCheckerId,
                model_hash, cnf_hash};
            q3a::cache::ProofIdentity cache_identity;
            cache_identity.profile_id = project.profile_id;
            cache_identity.input_sha256 = lowered.input_hash;
            cache_identity.manifest_sha256 = project.manifest_sha256;
            cache_identity.model_sha256 = model_hash;
            cache_identity.model_schema = lowered.schema_version;
            cache_identity.build_id = q3a::build_info::kBuildId;
            cache_identity.checker_fingerprint =
                q3a::build_info::kComponentHash_proof_checker;
            cache_identity.algorithm = "k-induction-cdcl-rup";
            cache_identity.property = property_name;
            cache_identity.obligation = base ? "base" : "step";
            cache_identity.solver_options =
                "decisions=1000000;propagations=10000000;proof_records=1000000;drat=1";
            cache_identity.depth = induction_depth;
            bool proof_cache_hit = false;
            if (!cache_directory.empty()) {
                const auto cached_proof_path = proof_staging.artifact(base);
                auto cached = q3a::cache::lookup_checked_proof(
                    cache_directory, cache_identity, result.staged_cnf, metadata,
                    checker_limits, cached_proof_path);
                result.cache_key = cached.key;
                if (cached.state == q3a::cache::LookupState::Hit) {
                    result.locked_artifact =
                        std::make_unique<q3a::WriteLockedInput>(cached_proof_path);
                    if (q3a::sha256_stream(result.locked_artifact->stream()) !=
                        cached.artifact_sha256) {
                        throw std::runtime_error("staged cache proof differs from the checked artifact");
                    }
                    result.status = q3a::checker::ProofStatus::Unsatisfiable;
                    result.staged_artifact = cached_proof_path;
                    result.proof_records = cached.proof_records;
                    result.cache_status = "HIT";
                    result.cache_diagnostic = cached.message;
                    result.diagnostic =
                        "cached DRAT proof passed current independent checker";
                    proof_cache_hit = true;
                } else if (cached.state == q3a::cache::LookupState::ResourceLimited) {
                    result.cache_status = "RESOURCE_LIMIT";
                    result.resource_limit = "proof_check";
                    result.diagnostic = cached.message;
                    return result;
                } else {
                    result.cache_status = cached.state == q3a::cache::LookupState::Rejected
                        ? "REJECTED" : "MISS";
                    result.cache_diagnostic = cached.message;
                }
            } else {
                result.cache_status = "DISABLED";
            }
            if (proof_cache_hit) return result;

            q3a::sat::Limits sat_limits;
            sat_limits.decisions = 1000000;
            sat_limits.propagations = 10000000;
            sat_limits.record_drat_proof = true;
            sat_limits.proof_records = 1000000;
            const auto body_path = proof_staging.body(base);
            std::ofstream proof_body(body_path, std::ios::binary);
            if (!proof_body) throw std::runtime_error("cannot open staged proof body");
            sat_limits.proof_sink = [&](const std::vector<q3a::sat::Literal>& clause) {
                for (const auto literal : clause) proof_body << literal << ' ';
                proof_body << "0\n";
                if (!proof_body) throw std::runtime_error("failed while recording staged proof");
            };
            const auto sat_result = solver.solve(sat_limits);
            proof_body.close();
            if (!proof_body) throw std::runtime_error("failed while closing staged proof");
            if (sat_result.status == q3a::sat::Status::Satisfiable) {
                std::vector<q3a::replay::Frame> replay_trace;
                replay_trace.reserve(encoder.frames().size());
                for (std::size_t frame = 0; frame < encoder.frames().size(); ++frame) {
                    q3a::replay::Frame decoded_frame;
                    for (const auto& signal : encoder.frames()[frame]) {
                        std::uint64_t value = 0;
                        for (std::size_t bit = 0; bit < signal.second.size(); ++bit) {
                            const auto literal = signal.second[bit];
                            const auto variable = static_cast<std::size_t>(
                                literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
                            if (sat_result.assignment[variable] < 0) {
                                throw std::logic_error(
                                    "SAT solver left a T-IR signal bit unassigned");
                            }
                            const bool bit_value = sat_result.assignment[variable] != 0;
                            if (literal < 0 ? !bit_value : bit_value) {
                                value |= std::uint64_t{1} << bit;
                            }
                        }
                        decoded_frame.emplace(signal.first, value);
                    }
                    replay_trace.push_back(std::move(decoded_frame));
                }
                const auto obligation = base ? q3a::replay::InductionObligation::Base
                                             : q3a::replay::InductionObligation::Step;
                const auto replay = q3a::replay::validate_induction_countermodel_view(
                    lowered, proof_replay_view(replay_trace, command), property_name,
                    static_cast<std::size_t>(induction_depth), obligation);
                if (!replay.validated) {
                    result.status = q3a::checker::ProofStatus::Unknown;
                    result.search_nodes = sat_result.decisions;
                    result.engine_error = true;
                    result.diagnostic =
                        "SAT model failed independent induction witness replay: " +
                        replay.message;
                    return result;
                }
                result.status = q3a::checker::ProofStatus::Satisfiable;
                result.replay_validated = true;
                result.failure_frame = replay.failure_frame;
                result.staged_witness = proof_staging.witness(base);
                std::ofstream text_output(result.staged_witness, std::ios::binary);
                q3a::bundle::write_induction_witness_text(text_output, lowered, replay_trace,
                    property_name, obligation, induction_depth, replay.failure_frame,
                    model_hash, metadata.query_sha256);
                text_output.close();
                if (!text_output) throw std::runtime_error("cannot close staged induction witness");
                if (!bundle_directory.empty() || (base && command.product_cli)) {
                    result.staged_index = proof_staging.indexed_witness(base);
                    std::ofstream indexed_output(result.staged_index, std::ios::binary);
                    q3a::trace::write_indexed_trace(indexed_output, lowered, replay_trace,
                                                   property_name, replay.failure_frame);
                    indexed_output.close();
                    if (!indexed_output) throw std::runtime_error("cannot close staged indexed induction witness");
                }
                result.search_nodes = sat_result.decisions;
                result.diagnostic = "SAT model independently replayed and saved as witness";
                return result;
            }
            if (sat_result.status == q3a::sat::Status::Unknown) {
                result.status = q3a::checker::ProofStatus::Unknown;
                result.search_nodes = sat_result.decisions;
                result.diagnostic = "induction query SAT search limit reached";
                result.resource_limit = "search";
                return result;
            }
            result.search_nodes = sat_result.decisions + sat_result.conflicts;
            if (sat_result.proof_record_count == 0) {
                result.engine_error = true;
                result.diagnostic = "CDCL SAT query did not provide a complete RUP refutation";
                return result;
            }

            const auto artifact_path = proof_staging.artifact(base);
            {
                std::ifstream body_input(body_path, std::ios::binary);
                std::ofstream artifact_output(artifact_path, std::ios::binary);
                if (!body_input || !artifact_output) {
                    throw std::runtime_error("cannot open staged induction proof");
                }
                const auto written = q3a::checker::write_drat_artifact(
                    body_input, sat_result.proof_record_count, metadata, artifact_output);
                artifact_output.close();
                if (!written.accepted || !artifact_output) {
                    throw std::runtime_error("cannot write induction proof artifact: " + written.message);
                }
            }
            result.locked_artifact = std::make_unique<q3a::WriteLockedInput>(artifact_path);
            const auto checked = q3a::checker::verify_drat_artifact(
                result.locked_cnf->stream(), result.locked_artifact->stream(),
                metadata, checker_limits);
            if (!checked.accepted) {
                if (checked.resource_limited) {
                    result.resource_limit = "proof_check";
                    result.diagnostic = checked.message;
                    return result;
                }
                throw std::runtime_error(
                    "independent DRAT checker rejected generated obligation: " + checked.message);
            }
            result.status = q3a::checker::ProofStatus::Unsatisfiable;
            result.proof_records = checked.proof_records;
            result.staged_artifact = artifact_path;
            result.diagnostic = "CDCL RUP refutation passed independent DRAT checking";
            if (!cache_directory.empty()) {
                try {
                    const auto saved = q3a::cache::store_checked_proof(
                        cache_directory, cache_identity, result.staged_cnf, artifact_path,
                        metadata, checker_limits);
                    result.cache_status = saved.stored ? "STORED" : "STORE_FAILED";
                    result.cache_diagnostic = saved.message;
                } catch (const q3a::MemoryBudgetExceeded& error) {
                    result.cache_status = "STORE_FAILED";
                    result.cache_diagnostic = error.what();
                }
            }
            return result;
        };

        auto base = build_obligation(true);
        if (base.status != q3a::checker::ProofStatus::Unknown) command.completed("induction_base_resolved");
        auto step = build_obligation(false);
        if (step.status != q3a::checker::ProofStatus::Unknown) command.completed("induction_step_resolved");
        memory_budget.check();
        std::filesystem::path base_cnf_path = output_prefix;
        base_cnf_path += ".base.cnf";
        std::filesystem::path base_proof_path = output_prefix;
        base_proof_path += ".base.q3adrat";
        std::filesystem::path step_cnf_path = output_prefix;
        step_cnf_path += ".step.cnf";
        std::filesystem::path step_proof_path = output_prefix;
        step_proof_path += ".step.q3adrat";
        std::filesystem::path base_witness_path = output_prefix;
        base_witness_path += ".base.witness.txt";
        std::filesystem::path step_witness_path = output_prefix;
        step_witness_path += ".step.witness.txt";
        const std::vector<std::filesystem::path> output_paths{
            base_cnf_path, base_proof_path, step_cnf_path, step_proof_path,
            base_witness_path, step_witness_path};
        const auto native_output = [](const std::filesystem::path& path) {
            return q3a::bundle::detail::absolute_windows_file_path(path);
        };
        for (const auto& path : output_paths) {
            std::error_code error;
            if (std::filesystem::exists(native_output(path), error) && !error) {
                throw std::runtime_error(
                    "induction output already exists: " + path.u8string());
            }
            if (error) {
                throw std::system_error(error, "cannot inspect induction output path: " + path.u8string());
            }
        }

        command.check_control(true);
        std::filesystem::copy_file(base.staged_cnf, native_output(base_cnf_path));
        std::filesystem::copy_file(step.staged_cnf, native_output(step_cnf_path));
        const auto publish_proof = [&](const auto& path, const InductionObligation& obligation) {
            if (obligation.status != q3a::checker::ProofStatus::Unsatisfiable) return;
            std::filesystem::copy_file(obligation.staged_artifact, native_output(path));
        };
        publish_proof(base_proof_path, base);
        publish_proof(step_proof_path, step);
        if (!base.staged_witness.empty())
            std::filesystem::copy_file(base.staged_witness, native_output(base_witness_path));
        if (!step.staged_witness.empty())
            std::filesystem::copy_file(step.staged_witness, native_output(step_witness_path));

        const auto save_result_bundle = [&](const std::string& status,
                                            const std::string& detail) {
            q3a::bundle::RunBundleRequest request;
            request.output_directory = bundle_directory;
            if (request.output_directory.empty()) {
                if (!command.product_cli || status != "FAIL") return;
                request.output_directory = default_witness_directory();
            }
            request.command = "k-induction";
            request.status = status;
            request.property = property_name;
            request.algorithm = "k-induction";
            request.detail = detail;
            request.bound = induction_depth;
            request.duration_ms = static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - run_started).count());
            request.decision_limit = 1000000;
            request.propagation_limit = 10000000;
            request.checker_id = q3a::checker::kCheckerId;
            request.checker_fingerprint = q3a::build_info::kComponentHash_proof_checker;
            request.checker_artifact_schema =
                std::to_string(q3a::checker::kProofArtifactSchema);
            populate_bundle_identity(
                request, command, lowered, manifest_path, std::move(serialized_model), true);
            for (auto* entry : {&base, &step}) {
                const bool is_base = entry == &base;
                const auto name = is_base ? std::string("base") : std::string("step");
                const auto query_kind = induction_depth == 1
                    ? (is_base ? std::string("induction-base") : std::string("induction-step"))
                    : ("induction-k" + std::to_string(induction_depth) +
                       (is_base ? "-base" : "-step"));
                const auto query_status = entry->status == q3a::checker::ProofStatus::Unsatisfiable
                    ? std::string("UNSAT_CHECKED")
                    : entry->status == q3a::checker::ProofStatus::Satisfiable
                        ? std::string("SAT_REPLAY_VALIDATED") : std::string("UNKNOWN");
                request.queries.push_back({
                        name, query_kind, "k-induction", property_name,
                    induction_depth, query_status,
                    "queries/" + property_name + "." + name + ".cnf", {},
                    [entry](std::ostream& output) {
                        copy_evidence_to_stream(entry->staged_cnf, output);
                    }});
                if (!entry->staged_artifact.empty()) {
                    request.artifacts.push_back({
                        "properties/" + property_name + "/" + name + ".q3adrat",
                        "checked_drat_proof", [entry](std::ostream& output) {
                            copy_evidence_to_stream(entry->staged_artifact, output);
                        }});
                }
                if (!entry->staged_witness.empty()) {
                    request.artifacts.push_back({
                        "properties/" + property_name + "/" + name + ".witness.txt",
                        "replay_validated_witness", [entry](std::ostream& output) {
                            copy_evidence_to_stream(entry->staged_witness, output);
                        }});
                }
                if (!entry->staged_index.empty()) {
                    request.artifacts.push_back({
                        "properties/" + property_name + "/" + name + ".trace.q3atrace",
                        q3a::trace::kIndexedInductionRole, [entry](std::ostream& output) {
                            copy_evidence_to_stream(entry->staged_index, output);
                        }});
                }
            }
            if (!base.staged_index.empty() || !step.staged_index.empty()) {
                request.artifacts.push_back({
                    "trace/capture.json", q3a::trace::kCaptureRole, [&](std::ostream& output) {
                        q3a::trace::write_capture_manifest(output, property_name, capture, capture_signals);
                    }});
            }
            q3a::bundle::write_result_bundle(project, request);
            command.bundle_created(request.output_directory);
        };

        const auto report_obligation = [&command](const char* name,
                                          const InductionObligation& obligation) {
            const char* status = obligation.status == q3a::checker::ProofStatus::Unsatisfiable
                ? "UNSAT" : obligation.status == q3a::checker::ProofStatus::Satisfiable
                ? "SAT" : "UNKNOWN";
            command.progress << "Q3A_INDUCTION_OBLIGATION " << name << ' ' << status << '\n';
            if (!obligation.cache_status.empty()) {
                command.progress << "Q3A_INDUCTION_CACHE " << name << ' '
                          << obligation.cache_status;
                if (!obligation.cache_key.empty()) {
                    command.progress << " key=" << obligation.cache_key;
                }
                if (!obligation.cache_diagnostic.empty()) {
                    command.progress << " detail=" << std::quoted(obligation.cache_diagnostic);
                }
                command.progress << '\n';
            }
            if (obligation.status == q3a::checker::ProofStatus::Unsatisfiable) {
                command.progress << "Q3A_INDUCTION_OBLIGATION " << name << " CHECKED records="
                          << obligation.proof_records << '\n';
            } else if (obligation.status == q3a::checker::ProofStatus::Satisfiable &&
                       obligation.replay_validated) {
                command.progress << "Q3A_INDUCTION_REPLAY " << name << " VALIDATED frame="
                          << obligation.failure_frame << '\n';
            } else if (!obligation.diagnostic.empty()) {
                command.progress << "Q3A_INDUCTION_DIAGNOSTIC " << name << ' '
                          << obligation.diagnostic << '\n';
            }
        };
        report_obligation("base", base);
        report_obligation("step", step);
        command.progress << "Q3A_INDUCTION_DEPTH " << induction_depth << '\n'
                  << "Q3A_INDUCTION_BASE_FRAMES 0.." << (induction_depth - 1) << '\n'
                  << "Q3A_INDUCTION_STEP_FRAMES 0.." << induction_depth << '\n'
                  << "Q3A_INDUCTION_PROPERTY " << std::quoted(property_name) << '\n'
                  << "Q3A_INDUCTION_MODEL_SHA256 " << model_hash << '\n'
                  << "Q3A_INDUCTION_INPUT_SHA256 " << lowered.input_hash << '\n'
                  << "Q3A_INDUCTION_CHECKER_ID " << q3a::checker::kCheckerId << '\n'
                  << "Q3A_INDUCTION_MODEL_SCHEMA " << lowered.schema_version << '\n'
                  << "Q3A_INDUCTION_CNF_BASE " << std::quoted(base_cnf_path.u8string()) << '\n'
                  << "Q3A_INDUCTION_CNF_STEP " << std::quoted(step_cnf_path.u8string()) << '\n';
        if (!base.staged_witness.empty()) {
            command.progress << "Q3A_INDUCTION_WITNESS_BASE "
                      << std::quoted(base_witness_path.u8string()) << '\n';
        }
        if (!step.staged_witness.empty()) {
            command.progress << "Q3A_INDUCTION_WITNESS_STEP "
                      << std::quoted(step_witness_path.u8string()) << '\n';
        }
        if (base.status == q3a::checker::ProofStatus::Unsatisfiable &&
            step.status == q3a::checker::ProofStatus::Unsatisfiable) {
            save_result_bundle("PROVEN", "base and induction step are UNSAT and checked");
            command.progress << "Q3A_INDUCTION_STATUS PROVEN\n"
                      << "Q3A_INDUCTION_CERTIFICATE INDUCTIVE_PROOF_ACCEPTED\n"
                      << "Q3A_INDUCTION_SCOPE GENERATED_TIR_MODEL\n"
                      << "Q3A_INDUCTION_PROOF_BASE "
                      << std::quoted(base_proof_path.u8string()) << '\n'
                      << "Q3A_INDUCTION_PROOF_STEP "
                      << std::quoted(step_proof_path.u8string()) << '\n';
            return command.finish(0, ProofExit::Conclusive, "PROVEN");
        }
        if (base.status == q3a::checker::ProofStatus::Satisfiable &&
            base.replay_validated) {
            save_result_bundle("FAIL", "base counterexample passed independent replay");
            command.progress << "Q3A_INDUCTION_STATUS FAIL\n"
                      << "Q3A_INDUCTION_CERTIFICATE COUNTEREXAMPLE_REPLAYED\n"
                      << "Q3A_INDUCTION_SCOPE GENERATED_TIR_MODEL\n"
                      << "Q3A_INDUCTION_COUNTEREXAMPLE_FRAME "
                      << base.failure_frame << '\n';
            return command.finish(0, ProofExit::Conclusive, "FAIL");
        }
        if (base.status == q3a::checker::ProofStatus::Unknown ||
            step.status == q3a::checker::ProofStatus::Unknown) {
            save_result_bundle("UNKNOWN", "an induction obligation is inconclusive");
            command.progress << "Q3A_INDUCTION_STATUS UNKNOWN\n";
            if (base.status == q3a::checker::ProofStatus::Unknown &&
                !base.diagnostic.empty()) {
                command.progress << "Q3A_INDUCTION_BASE_DIAGNOSTIC "
                          << std::quoted(base.diagnostic) << '\n';
            }
            if (step.status == q3a::checker::ProofStatus::Unknown &&
                !step.diagnostic.empty()) {
                command.progress << "Q3A_INDUCTION_STEP_DIAGNOSTIC "
                          << std::quoted(step.diagnostic) << '\n';
            }
            const bool engine_error = base.engine_error || step.engine_error;
            const auto limit = !base.resource_limit.empty() ? base.resource_limit : step.resource_limit;
            if (!engine_error && !limit.empty()) return command.finish_resource(3, limit);
            return command.finish(3, engine_error ? ProofExit::EngineError : ProofExit::Inconclusive,
                engine_error ? "ENGINE_ERROR" : "UNKNOWN");
        }
        save_result_bundle("NOT_" + std::to_string(induction_depth) + "_INDUCTIVE",
            "induction step is satisfiable; model may be unreachable");
        command.progress << "Q3A_INDUCTION_STATUS NOT_" << induction_depth
                  << "_INDUCTIVE\n";
        return command.finish(0, ProofExit::Inconclusive,
            "NOT_" + std::to_string(induction_depth) + "_INDUCTIVE");
    } catch (const q3a::MemoryBudgetExceeded& error) {
        command.progress << "Q3A_INDUCTION_STATUS UNKNOWN\n";
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
        return command.finish_resource(3, "memory");
    } catch (const q3a::frontend::LexError& error) {
        std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
        return command.reject_input(error);
    } catch (const q3a::frontend::ParseError& error) {
        std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
        return command.reject_input(error);
    } catch (const q3a::elaboration::ElaborationError& error) {
        std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
        return command.reject_input(error);
    } catch (const q3a::lowering::LoweringError& error) {
        std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
        return command.reject_input(error);
    } catch (const q3a::sat::BitBlastError& error) {
        std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
        return command.reject_bit_blast(error);
    } catch (const std::invalid_argument& error) {
        std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
    } catch (const std::bad_alloc& error) {
        std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
        return command.finish_resource(1, "memory");
    } catch (const std::exception& error) {
        std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
        return command.finish(1, ProofExit::EngineError, "ENGINE_ERROR");
    }
    return 1;
}

void validate_trace_output_path(
    const std::filesystem::path& output_path, const std::filesystem::path& manifest_path,
    const q3a::ProjectInput& project, const std::string& format) {
    const auto normalized_output = std::filesystem::absolute(output_path).lexically_normal();
    const auto normalized_manifest = std::filesystem::absolute(manifest_path).lexically_normal();
    std::error_code path_error;
    if (!std::filesystem::exists(normalized_output, path_error) || path_error) return;
    if (std::filesystem::equivalent(normalized_output, normalized_manifest, path_error) && !path_error) {
        throw std::invalid_argument(format + " output path must not overwrite the project manifest");
    }
    for (const auto* roster : {&project.sources, &project.headers}) {
        for (const auto& source : *roster) {
            path_error.clear();
            const auto source_path = std::filesystem::weakly_canonical(
                normalized_manifest.parent_path() / std::filesystem::u8path(source.relative_path), path_error);
            if (path_error) {
                throw std::runtime_error("cannot resolve an RTL source while checking " + format + " output path");
            }
            if (std::filesystem::equivalent(normalized_output, source_path, path_error) && !path_error) {
                throw std::invalid_argument(format + " output path must not overwrite an RTL source file");
            }
        }
    }
}

void write_bounded_trace_vcd(
    const std::filesystem::path& output_path,
    const std::filesystem::path& manifest_path,
    const q3a::ProjectInput& project,
    const q3a::lowering::TIRModule& module,
    const std::vector<q3a::replay::Frame>& trace,
    const q3a::trace::CaptureSignals& emitted_signals) {
    validate_trace_output_path(output_path, manifest_path, project, "VCD");

    std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
    if (!output) throw std::runtime_error("cannot open VCD output path");
    q3a::trace::write_witness_vcd(output, module, q3a::replay::FrameView(trace), emitted_signals);
    output.close();
    if (!output) throw std::runtime_error("failed while closing VCD trace");
}

std::string html_escape(const std::string& value) {
    std::string result;
    result.reserve(value.size());
    for (const char character : value) {
        switch (character) {
        case '&': result += "&amp;"; break;
        case '<': result += "&lt;"; break;
        case '>': result += "&gt;"; break;
        case '"': result += "&quot;"; break;
        case '\'': result += "&#39;"; break;
        default: result += character; break;
        }
    }
    return result;
}

std::string javascript_string(const std::string& value) {
    std::ostringstream output;
    output << '"';
    for (const unsigned char character : value) {
        switch (character) {
        case '"': output << "\\\""; break;
        case '\\': output << "\\\\"; break;
        case '\b': output << "\\b"; break;
        case '\f': output << "\\f"; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        case '<': output << "\\u003c"; break;
        case '>': output << "\\u003e"; break;
        case '&': output << "\\u0026"; break;
        default:
            if (character < 0x20) {
                output << "\\u00" << std::hex << std::setw(2)
                       << std::setfill('0') << static_cast<unsigned>(character)
                       << std::dec << std::setfill(' ');
            } else {
                output << static_cast<char>(character);
            }
            break;
        }
    }
    output << '"';
    return output.str();
}

void write_bounded_trace_html(
    const std::filesystem::path& output_path,
    const std::filesystem::path& manifest_path,
    const q3a::ProjectInput& project,
    const q3a::lowering::TIRModule& module,
    const std::vector<q3a::replay::Frame>& trace,
    std::size_t candidate_frame,
    const q3a::trace::CaptureSignals& emitted_signals) {
    validate_trace_output_path(output_path, manifest_path, project, "HTML");

    std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
    if (!output) throw std::runtime_error("cannot open waveform HTML output path");
    const std::unordered_set<std::string> clocks(module.clocks.begin(), module.clocks.end());

    output << "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
           << "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
           << "<title>Q3AFormal waveform — " << html_escape(module.name) << "</title>\n"
           << R"HTML(<style>
:root{color-scheme:light;--ink:#18212f;--muted:#5c6675;--line:#d5dbe3;--accent:#147d78;--paper:#fff;--wash:#f4f7fa}
*{box-sizing:border-box}body{margin:0;background:var(--wash);color:var(--ink);font:14px/1.45 system-ui,Segoe UI,Arial,sans-serif}
header{padding:18px 22px;background:var(--paper);border-bottom:1px solid var(--line)}h1{font-size:20px;margin:0 0 4px}.sub{color:var(--muted)}
.toolbar{position:sticky;top:0;z-index:2;display:flex;flex-wrap:wrap;gap:12px;align-items:center;padding:12px 22px;background:#fff;border-bottom:1px solid var(--line)}
input[type=search]{width:min(360px,90vw);padding:8px 10px;border:1px solid #aeb9c7;border-radius:5px;font:inherit}
input[type=range]{width:min(420px,65vw);accent-color:var(--accent)}button{padding:7px 11px;border:1px solid #aeb9c7;border-radius:5px;background:#fff;color:var(--ink);cursor:pointer}
#cursor{font-variant-numeric:tabular-nums;font-weight:650;min-width:118px}.hint{color:var(--muted)}main{padding:16px 22px}.status{margin:0 0 10px;color:var(--muted)}
.viewport{overflow:auto;background:#fff;border:1px solid var(--line);border-radius:6px;max-height:72vh}.wave{display:block}.lane{fill:#fff}.grid{stroke:#e5e9ee;stroke-width:1}.axis{stroke:#9aa6b5;stroke-width:1}.waveform{fill:none;stroke:#101820;stroke-width:2}.bus{fill:#fff;stroke:#101820;stroke-width:1.6}.cursorline{stroke:var(--accent);stroke-width:2}.label{fill:#263241;font-size:13px}.value{fill:#17212d;font-size:12px;font-family:ui-monospace,Consolas,monospace}.tick{fill:#586577;font-size:11px}.cursorbox{fill:#e8f5f2;stroke:var(--accent)}
@media(max-width:640px){header,.toolbar,main{padding-left:12px;padding-right:12px}}
</style></head><body><header><h1>Q3AFormal waveform</h1><div class=\"sub\">Module: )HTML"
           << html_escape(module.name)
           << R"HTML( · Sampling events represent abstract positive edges. Sampled clock bits are shown separately.</div></header>
<div class="toolbar"><input id="filter" type="search" placeholder="Filter signals by name" aria-label="Filter signals">
<label for="frame">Cursor</label><input id="frame" type="range" min="0" value="0">
<span id="cursor">Frame 0</span><button id="home" type="button">First frame</button><button id="witness" type="button">Witness frame</button>
<span class="hint">Click the waveform to move the cursor. Vector values are shown in hexadecimal.</span></div>
<main><p id="status" class="status"></p><div class="viewport" id="viewport"><svg id="wave" class="wave" role="img" aria-label="Digital signal waveforms"></svg></div></main>
<script>
const traceFrames = )HTML" << trace.size() << R"HTML(;
const witnessFrame = )HTML" << candidate_frame << R"HTML(;
const sampleClockNames = [)HTML";
    for (std::size_t i = 0; i < module.clocks.size(); ++i) {
        if (i != 0) output << ',';
        output << javascript_string(module.clocks[i]);
    }
    output << R"HTML(];
const signalData = [)HTML";
    for (std::size_t signal_index = 0;
         signal_index < emitted_signals.size(); ++signal_index) {
        const auto& signal = *emitted_signals[signal_index];
        if (signal_index != 0) output << ',';
        output << "{name:" << javascript_string(clocks.count(signal.name)
                       ? signal.name + " (sampled bit)" : signal.name)
               << ",width:" << signal.width << ",values:[";
        for (std::size_t frame = 0; frame < trace.size(); ++frame) {
            if (frame != 0) output << ',';
            const auto value = trace.at(frame).at(signal.name);
            std::string bits(static_cast<std::size_t>(signal.width), '0');
            for (std::size_t bit = 0; bit < bits.size(); ++bit) {
                if (((value >> bit) & 1U) != 0) bits[bits.size() - 1 - bit] = '1';
            }
            output << javascript_string(bits);
        }
        output << "]}";
    }
    output << R"HTML(];
const svg=document.getElementById('wave'), slider=document.getElementById('frame');
const filter=document.getElementById('filter'), status=document.getElementById('status');
const cursor=document.getElementById('cursor'), spacing=28, left=220, top=34, lane=72, maxVisible=64;
slider.max=String(Math.max(0,traceFrames-1));
slider.value=String(witnessFrame);
const eventRows=sampleClockNames.map(clock=>({name:'posedge '+clock,event:true}));
const escapeText=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function hex(bits){let n=BigInt('0b'+bits);return '0x'+n.toString(16).toUpperCase().padStart(Math.ceil(bits.length/4),'0')}
function render(){
 const selected=Math.max(0,Math.min(traceFrames-1,Number(slider.value)||0));
 cursor.textContent=`Frame ${selected} · ${selected} ns`;
 const query=filter.value.trim().toLowerCase();
 const matches=eventRows.concat(signalData).filter(s=>s.name.toLowerCase().includes(query));
 const visible=matches.slice(0,maxVisible), width=Math.max(900,left+40+Math.max(1,traceFrames-1)*spacing);
 const height=top+visible.length*lane+32;
 status.textContent=`${matches.length} matching signals · showing ${visible.length}${matches.length>maxVisible?' (first 64; filter to narrow the list)':''} · ${traceFrames} frames`;
 let out=`<rect x="0" y="0" width="${width}" height="${height}" fill="#fff"/>`;
 for(let f=0;f<traceFrames;f+=Math.max(1,Math.ceil(traceFrames/40))){const x=left+f*spacing;out+=`<line class="grid" x1="${x}" y1="${top-12}" x2="${x}" y2="${height-15}"/><text class="tick" x="${x+3}" y="18">${f}</text>`}
 out+=`<line class="axis" x1="${left}" y1="${top-10}" x2="${left}" y2="${height-15}"/>`;
 visible.forEach((s,row)=>{
   const y=top+row*lane, yHigh=y+14, yLow=y+48;
   const displayName=s.name.length>24?s.name.slice(0,21)+'…':s.name;
   if(s.event){
     out+=`<text class="label" x="10" y="${y+27}">${escapeText(displayName)}</text><text class="value" x="10" y="${y+48}">sampling event</text>`;
     let marks='';
     for(let f=0;f<traceFrames;f++){
       const x=left+f*spacing;
       marks+=` M ${x} ${yHigh+20} V ${yHigh} m -4 4 l 4 -4 l 4 4`;
     }
     out+=`<path class="waveform" d="${marks}"/>`;
     return;
   }
   const current=s.width===1?`1'b${s.values[selected]}`:hex(s.values[selected]);
   out+=`<line class="grid" x1="0" y1="${y+lane-3}" x2="${width}" y2="${y+lane-3}"/><text class="label" x="10" y="${y+27}" title="${escapeText(s.name)}">${escapeText(displayName)}</text><text class="value" x="10" y="${y+48}">${current}</text>`;
   if(s.width===1){let d=`M ${left} ${s.values[0]==='1'?yHigh:yLow}`;for(let f=1;f<traceFrames;f++){const x=left+f*spacing,prev=s.values[f-1]==='1'?yHigh:yLow,next=s.values[f]==='1'?yHigh:yLow;d+=` L ${x} ${prev} L ${x} ${next}`}d+=` L ${left+Math.max(1,traceFrames-1)*spacing+12} ${s.values[traceFrames-1]==='1'?yHigh:yLow}`;out+=`<path class="waveform" d="${d}"/>`}
   else{let start=0;for(let f=1;f<=traceFrames;f++){if(f<traceFrames&&s.values[f]===s.values[start])continue;const x1=left+start*spacing,x2=left+Math.max(start+1,f)*spacing,w=Math.max(1,x2-x1);out+=`<rect class="bus" x="${x1}" y="${y+12}" width="${w}" height="38" rx="3"/>`;if(w>38)out+=`<text class="value" text-anchor="middle" x="${(x1+x2)/2}" y="${y+36}">${hex(s.values[start])}</text>`;start=f}}
   const cx=left+selected*spacing;out+=`<line class="cursorline" x1="${cx}" y1="${y+4}" x2="${cx}" y2="${y+lane-8}"/>`;
 });
 const witnessX=left+witnessFrame*spacing;
 out+=`<line x1="${witnessX}" y1="24" x2="${witnessX}" y2="${height-15}" stroke="#ae5020" stroke-dasharray="4 4"><title>Witness frame ${witnessFrame}</title></line>`;
 svg.setAttribute('width',String(width));svg.setAttribute('height',String(height));svg.setAttribute('viewBox',`0 0 ${width} ${height}`);svg.innerHTML=out;
}
slider.addEventListener('input',render);filter.addEventListener('input',render);
document.getElementById('home').addEventListener('click',()=>{slider.value='0';render()});
document.getElementById('witness').addEventListener('click',()=>{slider.value=String(witnessFrame);render()});
svg.addEventListener('click',event=>{const point=svg.createSVGPoint();point.x=event.clientX;point.y=event.clientY;const p=point.matrixTransform(svg.getScreenCTM().inverse());slider.value=String(Math.max(0,Math.min(traceFrames-1,Math.round((p.x-left)/spacing))));render()});
render();
</script></body></html>
)HTML";
    if (!output) throw std::runtime_error("failed while writing waveform HTML output");
}

int bounded_check_project(const q3a::ProjectInput& project,
                          const std::filesystem::path& manifest_path,
                          const std::string& property_name,
                          std::uint64_t transition_count,
                          const std::filesystem::path& vcd_output,
                          const std::filesystem::path& html_output,
                          const std::filesystem::path& bundle_directory,
                          const q3a::trace::CaptureRequest& capture,
                          ProofCommand& command,
                          const q3a::lowering::TIRModule* derived_model = nullptr,
                          const q3a::lowering::TIRModule* source_model = nullptr,
                          bool archive_contradiction_only = false) {
    try {
        const auto run_started = std::chrono::steady_clock::now();
        command.loaded(project);
        command.enter_stage("elaboration");
        const auto memory_budget = command.budget();
        memory_budget.check();
        const bool activation = derived_model != nullptr;
        if ((activation && !source_model) ||
            (activation && (!vcd_output.empty() || !html_output.empty()))) {
            throw std::logic_error("invalid source or export configuration for activation replay");
        }
        std::optional<q3a::lowering::TIRModule> original_model;
        if (!source_model) original_model.emplace(lower_project_tir(project));
        const auto& source_tir = source_model ? *source_model : *original_model;
        const auto& lowered = activation ? *derived_model : source_tir;
        command.completed("model_elaborated");
        memory_budget.check();
        const auto selected_property = std::find_if(
            source_tir.properties.begin(), source_tir.properties.end(),
            [&](const q3a::lowering::TIRProperty& candidate) {
                return candidate.name == property_name &&
                    (candidate.kind == "assert" || candidate.kind == "cover");
            });
        if (selected_property == source_tir.properties.end()) {
            const auto named_property = std::find_if(
                lowered.properties.begin(), lowered.properties.end(),
                [&](const q3a::lowering::TIRProperty& candidate) {
                    return candidate.name == property_name;
                });
            if (named_property == lowered.properties.end()) {
                throw std::invalid_argument("unknown assertion or cover property name '" +
                    property_name + "'");
            }
            throw std::invalid_argument(
                "bounded query target must have kind 'assert' or 'cover'");
        }
        if (q3a::lowering::is_eventual_response(*selected_property)) {
            return command.reject_input("UNSUPPORTED", "Q3A_BMC_PROFILE", selected_property->location,
                "s_eventually requires dev-check-liveness");
        }
        const bool is_cover = selected_property->kind == "cover";
        q3a::trace::CaptureSignals capture_signals;
        const bool save_default_witness = command.product_cli && !is_cover && !activation;
        if (!vcd_output.empty() || !html_output.empty() || !bundle_directory.empty() || save_default_witness) {
            capture_signals = q3a::trace::select_capture_signals(source_tir, *selected_property, capture);
        }
        if (command.product_cli && command.engine == "bmc") {
            set_proof_configuration(command,
                project, source_tir, *selected_property, memory_budget, "bmc", transition_count);
        }
        command.enter_stage("bounded_query");
        q3a::sat::Solver solver([&memory_budget](std::uint64_t pending) {
            memory_budget.check(pending);
        });
        q3a::sat::TransitionCnfEncoder encoder(solver, lowered);
        encoder.encode(transition_count);
        encoder.constrain_assumptions();
        q3a::sat::TransitionCnfEncoder::AssertionQuery assertion_query;
        q3a::sat::TransitionCnfEncoder::CoverQuery cover_query;
        if (is_cover) {
            cover_query = encoder.add_cover_hit(property_name);
        } else {
            assertion_query = encoder.add_assertion_violation(property_name);
        }
        const bool boundary_incomplete = is_cover
            ? encoder.boundary_incomplete(cover_query)
            : encoder.boundary_incomplete(assertion_query);
        if (command.product_cli && !is_cover) {
            command.activation = ProofCommand::Activation{transition_count, boundary_incomplete};
        }

        std::filesystem::path written_bundle;
        const auto report_bundle_created = [&] {
            if (!written_bundle.empty()) command.bundle_created(written_bundle);
        };
        const auto save_feasibility_bundle = [&](q3a::sat::Status status) {
            if (bundle_directory.empty() || activation) return;
            write_bounded_feasibility_bundle(project, lowered, manifest_path, bundle_directory,
                property_name, transition_count, boundary_incomplete, status, run_started, solver, command);
            written_bundle = bundle_directory;
        };

        auto feasibility = solver.solve_incremental();
        const auto& prior_feasibility = command.environment_feasibility;
        if (!archive_contradiction_only &&
            (feasibility.status == q3a::sat::Status::Unsatisfiable ||
            !prior_feasibility || prior_feasibility->status != q3a::sat::Status::Satisfiable ||
            (feasibility.status == q3a::sat::Status::Satisfiable &&
             transition_count > prior_feasibility->bound))) {
            command.environment_feasibility = ProofCommand::EnvironmentFeasibility{
                transition_count, feasibility.status};
        }
        if (feasibility.status != q3a::sat::Status::Unknown) command.completed("feasibility_decided");
        memory_budget.check();
        if (feasibility.status == q3a::sat::Status::Unsatisfiable) {
            if (command.activation) command.activation->feasibility = "UNSAT";
            save_feasibility_bundle(feasibility.status);
            command.progress << "Q3A_BMC_STATUS INCONSISTENT_MODEL_OR_ASSUMPTIONS\n"
                      << "Q3A_BMC_PROPERTY " << std::quoted(property_name) << '\n'
                      << "Q3A_BMC_BOUND transitions=" << transition_count
                      << " frames=" << (transition_count + 1) << '\n'
                      << "Q3A_BMC_BOUNDARY_OBLIGATIONS "
                      << (boundary_incomplete ? "INCOMPLETE" : "COMPLETE") << '\n';
            report_bundle_created();
            return command.finish(0, ProofExit::Inconclusive, "INCONSISTENT_MODEL_OR_ASSUMPTIONS");
        }
        if (feasibility.status == q3a::sat::Status::Unknown) {
            if (command.activation) command.activation->feasibility = "UNKNOWN";
            if (!archive_contradiction_only) save_feasibility_bundle(feasibility.status);
            command.progress << "Q3A_BMC_STATUS UNKNOWN\n"
                      << "Q3A_BMC_PROPERTY " << std::quoted(property_name) << '\n'
                      << "Q3A_BMC_BOUNDARY_OBLIGATIONS "
                      << (boundary_incomplete ? "INCOMPLETE" : "COMPLETE") << '\n';
            report_bundle_created();
            return command.finish_resource(3, "search");
        }
        if (archive_contradiction_only) {
            throw std::runtime_error("PDR environment contradiction did not reproduce in the source prefix");
        }

        std::string vacuity = "NOT_APPLICABLE";
        if (!is_cover) {
            const auto activity = encoder.assertion_activity(assertion_query, feasibility.assignment);
            vacuity = activity == q3a::sat::Status::Satisfiable ? "NONVACUOUS" :
                activity == q3a::sat::Status::Unsatisfiable ? "VACUOUS" : "UNKNOWN";
            if (command.activation) {
                command.activation->feasibility = "SAT";
                command.activation->activity = activity == q3a::sat::Status::Satisfiable ? "REACHED" :
                    activity == q3a::sat::Status::Unsatisfiable ? "NOT_REACHED" : "UNKNOWN";
            }
        }
        feasibility = {};

        solver.add_clause(is_cover ? cover_query.hit_literals :
            assertion_query.violation_literals);
        const auto result = solver.solve_incremental();
        memory_budget.check();
        std::vector<q3a::replay::Frame> decoded_trace;
        std::size_t candidate_frame = 0;
        bool has_candidate = false;
        bool waveform_written = false;
        bool waveform_html_written = false;
        if (result.status == q3a::sat::Status::Satisfiable) {
            const auto& goal_literals = is_cover
                ? cover_query.hit_literals : assertion_query.violation_literals;
            const auto& goal_frames = is_cover
                ? cover_query.hit_frames : assertion_query.violation_frames;
            for (std::size_t index = 0; index < goal_literals.size(); ++index) {
                const auto literal = goal_literals[index];
                const auto variable = static_cast<std::size_t>(
                    literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
                if ((literal > 0 && result.assignment[variable] == 1) ||
                    (literal < 0 && result.assignment[variable] == 0)) {
                    candidate_frame = goal_frames[index];
                    has_candidate = true;
                    break;
                }
            }
            if (!has_candidate) {
                std::cerr << "Q3A_BMC_REPLAY_ERROR SAT model has no active property-goal literal\n";
                return command.finish(1, ProofExit::EngineError, "ENGINE_ERROR");
            }
            decoded_trace.resize(encoder.frames().size());
            for (std::size_t frame = 0; frame < encoder.frames().size(); ++frame) {
                for (const auto& signal : encoder.frames()[frame]) {
                    std::uint64_t value = 0;
                    for (std::size_t bit = 0; bit < signal.second.size(); ++bit) {
                        const auto variable = static_cast<std::size_t>(signal.second[bit]);
                        if (result.assignment[variable] < 0) {
                            std::cerr << "Q3A_BMC_REPLAY_ERROR SAT model left a signal bit unassigned\n";
                            return command.finish(1, ProofExit::EngineError, "ENGINE_ERROR");
                        }
                        if (result.assignment[variable] != 0) {
                            value |= std::uint64_t{1} << bit;
                        }
                    }
                    decoded_trace[frame].emplace(signal.first, value);
                }
            }
            command.completed("bounded_query_decided");
            command.enter_stage("witness_replay");
            const auto replay_view = proof_replay_view(decoded_trace, command);
            const auto replay = is_cover
                ? q3a::replay::validate_bounded_cover_view(
                    lowered, replay_view, property_name, candidate_frame)
                : q3a::replay::validate_bounded_counterexample_view(
                    lowered, replay_view, property_name, candidate_frame);
            if (!replay.validated) {
                std::cerr << "Q3A_BMC_REPLAY_ERROR " << replay.message << '\n';
                return command.finish(1, ProofExit::EngineError, "ENGINE_ERROR");
            }
            if (replay.boundary_incomplete != boundary_incomplete) {
                std::cerr << "Q3A_BMC_REPLAY_ERROR inconsistent temporal boundary\n";
                return command.finish(1, ProofExit::EngineError, "ENGINE_ERROR");
            }
            if (!is_cover) {
                vacuity = "NONVACUOUS";
                if (command.activation) command.activation->activity = "REACHED";
            }
            command.completed("witness_replayed");
            command.check_control(true);
            memory_budget.check();
            if (!vcd_output.empty()) {
                write_bounded_trace_vcd(
                    vcd_output, manifest_path, project, lowered, decoded_trace, capture_signals);
                waveform_written = true;
            }
            if (!html_output.empty()) {
                write_bounded_trace_html(
                    html_output, manifest_path, project, lowered, decoded_trace, candidate_frame, capture_signals);
                waveform_html_written = true;
            }
        }
        const char* status = is_cover
            ? result.status == q3a::sat::Status::Satisfiable
                ? "COVERED"
                : "UNKNOWN"
            : result.status == q3a::sat::Status::Satisfiable
                ? activation ? "ACTIVATION_REACHED" : "BOUNDED_FAIL"
                : result.status == q3a::sat::Status::Unsatisfiable
                    ? "BOUNDED_PASS" : "UNKNOWN";
        if (result.status != q3a::sat::Status::Satisfiable) {
            if (result.status == q3a::sat::Status::Unsatisfiable) command.completed("bounded_query_decided");
            command.check_control(true);
        }
        const bool satisfiable = result.status == q3a::sat::Status::Satisfiable;
        if ((!bundle_directory.empty() && (!activation || satisfiable)) ||
            (save_default_witness && satisfiable)) {
            q3a::bundle::RunBundleRequest request;
            request.output_directory = bundle_directory.empty()
                ? default_witness_directory() : bundle_directory;
            request.command = "bmc";
            request.status = status;
            request.property = property_name;
            request.algorithm = "bounded-model-checking";
            request.detail = activation ? "replay-validated assertion activation" : "validated bounded query result";
            request.vacuity = vacuity;
            request.boundary_obligations = boundary_incomplete ? "INCOMPLETE" : "COMPLETE";
            request.bound = transition_count;
            request.duration_ms = static_cast<std::uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - run_started).count());
            const q3a::sat::Limits default_limits;
            request.decision_limit = default_limits.decisions;
            request.propagation_limit = default_limits.propagations;
            populate_bundle_identity(
                request, command, source_tir, manifest_path,
                q3a::lowering::serialize_tir(source_tir), false);
            const auto query_status = result.status == q3a::sat::Status::Satisfiable
                ? "SAT_REPLAY_VALIDATED" : result.status == q3a::sat::Status::Unsatisfiable
                    ? "UNSAT" : "UNKNOWN";
            request.queries.push_back({
                "property", activation ? "assertion-activation" : is_cover ? "cover" : "assertion",
                "bounded-model-checking", property_name, transition_count,
                query_status, "queries/" + property_name + ".cnf", {},
                [&](std::ostream& output) { solver.write_dimacs(output); }});
            if (result.status == q3a::sat::Status::Satisfiable) {
                request.artifacts.push_back({
                    "trace/capture.json", q3a::trace::kCaptureRole,
                    [&](std::ostream& output) {
                        q3a::trace::write_capture_manifest(output, property_name, capture, capture_signals);
                    }});
                request.artifacts.push_back({
                    "properties/" + property_name + "/trace.json",
                    "replay_validated_trace",
                    [&](std::ostream& output) {
                        q3a::bundle::write_trace_json(
                            output, decoded_trace, property_name, candidate_frame);
                    }});
                request.artifacts.push_back({
                    "properties/" + property_name + "/trace.q3atrace",
                    q3a::trace::kIndexedTraceRole,
                    [&](std::ostream& output) {
                        q3a::trace::write_indexed_trace(
                            output, source_tir, decoded_trace, property_name, candidate_frame);
                    }});
            }
            if (waveform_written && !vcd_output.empty()) {
                request.artifacts.push_back({
                    "trace/" + property_name + ".vcd", "vcd_export",
                    [&](std::ostream& output) { copy_evidence_to_stream(vcd_output, output); }});
            }
            if (waveform_html_written && !html_output.empty()) {
                request.artifacts.push_back({
                    "trace/" + property_name + ".html", "waveform_html_viewer",
                    [&](std::ostream& output) { copy_evidence_to_stream(html_output, output); }});
            }
            q3a::bundle::write_result_bundle(project, request);
            written_bundle = request.output_directory;
        }
        command.progress << "Q3A_BMC_STATUS " << status << '\n'
                  << "Q3A_BMC_PROPERTY " << std::quoted(property_name) << '\n'
                  << "Q3A_BMC_BOUND transitions=" << transition_count
                  << " frames=" << (transition_count + 1) << '\n'
                  << "Q3A_BMC_STATS variables=" << solver.variable_count()
                  << " clauses=" << solver.clause_count()
                  << " decisions=" << result.decisions
                  << " propagations=" << result.propagations
                  << " conflicts=" << result.conflicts
                  << " learned=" << result.learned_clauses
                  << " backjumps=" << result.backjumps
                  << " nonchrono_backjumps=" << result.nonchronological_backjumps << '\n';
        if (is_cover) {
            command.progress << "Q3A_BMC_COVER_SCOPE BOUNDED"
                      << " boundary_limited="
                      << (boundary_incomplete ? "yes" : "no") << '\n'
                      << "Q3A_BMC_COVER_RESULT "
                      << (result.status == q3a::sat::Status::Satisfiable
                          ? "WITNESS_FOUND"
                          : result.status == q3a::sat::Status::Unsatisfiable
                              ? "NOT_FOUND_WITHIN_BOUND" : "INCONCLUSIVE") << '\n';
        } else {
            command.progress << "Q3A_BMC_VACUITY " << vacuity << '\n'
                      << "Q3A_BMC_BOUNDARY_OBLIGATIONS "
                      << (boundary_incomplete ? "INCOMPLETE" : "COMPLETE") << '\n';
        }
        if (!vcd_output.empty()) {
            if (waveform_written) {
                command.progress << "Q3A_BMC_WAVEFORM WRITTEN\n"
                          << "Q3A_BMC_WAVEFORM_PATH "
                          << std::quoted(vcd_output.u8string()) << '\n';
            } else {
                command.progress << "Q3A_BMC_WAVEFORM NOT_WRITTEN reason=no_validated_witness\n";
            }
        }
        if (!html_output.empty()) {
            if (waveform_html_written) {
                command.progress << "Q3A_BMC_WAVEFORM_HTML WRITTEN\n"
                          << "Q3A_BMC_WAVEFORM_HTML_PATH "
                          << std::quoted(html_output.u8string()) << '\n';
            } else {
                command.progress << "Q3A_BMC_WAVEFORM_HTML NOT_WRITTEN reason=no_validated_witness\n";
            }
        }
        if (result.status == q3a::sat::Status::Satisfiable) {
            command.progress << "Q3A_BMC_REPLAY VALIDATED\n"
                      << (activation ? "Q3A_BMC_ACTIVATION_WITNESS frame=" :
                          is_cover ? "Q3A_BMC_COVER_WITNESS frame="
                                   : "Q3A_BMC_COUNTEREXAMPLE_CANDIDATE frame=")
                      << candidate_frame << '\n';
            for (std::size_t frame = 0; frame < decoded_trace.size(); ++frame) {
                command.progress << "Q3A_BMC_TRACE_FRAME frame=" << frame << '\n';
                for (const auto& signal : lowered.signals) {
                    command.progress << "Q3A_BMC_TRACE_SIGNAL frame=" << frame
                              << " name=" << signal.name
                              << " width=" << signal.width
                              << " value=0x" << std::hex
                              << decoded_trace[frame].at(signal.name)
                              << std::dec << '\n';
                }
            }
        }
        report_bundle_created();
        if (result.status == q3a::sat::Status::Satisfiable) {
            return command.finish(0, ProofExit::Conclusive, status);
        }
        if (result.status == q3a::sat::Status::Unknown) {
            return command.finish_resource(3, "search");
        }
        return command.finish(0, ProofExit::Inconclusive,
            is_cover ? "BOUNDED_COVER_MISS" : status);
    } catch (const q3a::MemoryBudgetExceeded& error) {
        command.progress << "Q3A_BMC_STATUS UNKNOWN\n";
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
        return command.finish_resource(3, "memory");
    } catch (const q3a::frontend::LexError& error) {
        std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
        return command.reject_input(error);
    } catch (const q3a::frontend::ParseError& error) {
        std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
        return command.reject_input(error);
    } catch (const q3a::elaboration::ElaborationError& error) {
        std::cerr << "Q3A_ELABORATION_ERROR " << error.what() << '\n';
        return command.reject_input(error);
    } catch (const q3a::lowering::LoweringError& error) {
        std::cerr << "Q3A_LOWERING_ERROR " << error.what() << '\n';
        return command.reject_input(error);
    } catch (const q3a::sat::BitBlastError& error) {
        std::cerr << "Q3A_BITBLAST_ERROR " << error.what() << '\n';
        return command.reject_bit_blast(error);
    } catch (const std::invalid_argument& error) {
        std::cerr << "Q3A_BMC_ERROR " << error.what() << '\n';
    } catch (const std::bad_alloc& error) {
        std::cerr << "Q3A_BMC_ERROR " << error.what() << '\n';
        return command.finish_resource(1, "memory");
    } catch (const std::exception& error) {
        std::cerr << "Q3A_BMC_ERROR " << error.what() << '\n';
        return command.finish(1, ProofExit::EngineError, "ENGINE_ERROR");
    }
    return 1;
}

bool parse_limit(const std::string& text, std::uint64_t& value) {
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
    return !text.empty() && parsed.ec == std::errc{} &&
        parsed.ptr == text.data() + text.size();
}

bool parse_pdr_query_limit(const std::string& text, std::uint64_t& value) {
    return parse_limit(text, value) && value != 0 && value <= std::numeric_limits<std::size_t>::max();
}

int solve_dimacs_file(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "Q3A_SAT_ERROR --sat-dimacs requires an input file\n";
        return 2;
    }
    q3a::sat::Limits limits;
    std::vector<q3a::sat::Literal> assumptions;
    for (int index = 3; index < argc;) {
        const std::string option(argv[index++]);
        if (option == "--assume") {
            if (index >= argc) {
                std::cerr << "Q3A_SAT_ERROR --assume requires a signed literal\n";
                return 2;
            }
            std::int64_t literal = 0;
            const std::string text(argv[index++]);
            const auto parsed = std::from_chars(
                text.data(), text.data() + text.size(), literal);
            if (text.empty() || parsed.ec != std::errc{} ||
                parsed.ptr != text.data() + text.size() || literal == 0 ||
                literal < std::numeric_limits<q3a::sat::Literal>::min() ||
                literal > std::numeric_limits<q3a::sat::Literal>::max()) {
                std::cerr << "Q3A_SAT_ERROR invalid signed assumption literal '"
                          << text << "'\n";
                return 2;
            }
            assumptions.push_back(static_cast<q3a::sat::Literal>(literal));
            continue;
        }
        if (index >= argc) {
            std::cerr << "Q3A_SAT_ERROR option '" << option
                      << "' is missing its value\n";
            return 2;
        }
        std::uint64_t value = 0;
        if (!parse_limit(argv[index++], value)) {
            std::cerr << "Q3A_SAT_ERROR invalid non-negative limit '"
                      << argv[index - 1] << "'\n";
            return 2;
        }
        if (option == "--decision-limit") {
            limits.decisions = value;
        } else if (option == "--propagation-limit") {
            limits.propagations = value;
        } else {
            std::cerr << "Q3A_SAT_ERROR unknown SAT option '" << option << "'\n";
            return 2;
        }
    }

    const std::filesystem::path path = std::filesystem::u8path(argv[2]);
    std::ifstream input(path);
    if (!input) {
        std::cerr << "Q3A_SAT_ERROR cannot open DIMACS input\n";
        return 1;
    }
    try {
        auto solver = q3a::sat::read_dimacs(input);
        const auto result = solver.solve(limits, assumptions);
        std::cout << "Q3A_SAT_STATUS " << q3a::sat::status_name(result.status) << '\n'
                  << "Q3A_SAT_STATS variables=" << solver.variable_count()
                  << " clauses=" << solver.clause_count()
                  << " assumptions=" << assumptions.size()
                  << " decisions=" << result.decisions
                  << " propagations=" << result.propagations
                  << " conflicts=" << result.conflicts
                  << " learned=" << result.learned_clauses
                  << " backjumps=" << result.backjumps
                  << " nonchrono_backjumps=" << result.nonchronological_backjumps << '\n';
        if (result.status == q3a::sat::Status::Satisfiable) {
            std::cout << "Q3A_SAT_MODEL v";
            for (std::uint32_t variable = 1;
                 variable <= solver.variable_count(); ++variable) {
                std::cout << ' ' << (result.assignment[variable] == 0
                    ? -static_cast<std::int64_t>(variable)
                    : static_cast<std::int64_t>(variable));
            }
            std::cout << " 0\n";
        }
        return result.status == q3a::sat::Status::Unknown ? 3 : 0;
    } catch (const q3a::sat::DimacsError& error) {
        std::cerr << "Q3A_SAT_INPUT_ERROR " << error.what() << '\n';
    } catch (const std::exception& error) {
        std::cerr << "Q3A_SAT_ERROR " << error.what() << '\n';
    }
    return 1;
}

int run_proof_command(int argc, const char* const* argv, ProofCommand& command,
                      const q3a::ProjectInput* preloaded = nullptr) {
    if (argc >= 2 && std::string(argv[1]) == "--prove-inductive") {
        if (argc < 7 || std::string(argv[3]) != "--property") {
            std::cerr << "Q3A_INDUCTION_ERROR usage: --prove-inductive <project.q3a> "
                         "--property <scalar-assertion> [--k <positive-depth>] "
                         "--output-prefix <path-prefix> [--bundle-dir <directory>] "
                         "[--cache-dir <directory>] [--trace-all] [--trace-signal <name> ...]\n";
            return 2;
        }
        std::uint64_t induction_depth = 1;
        int option_index = 5;
        if (option_index < argc && std::string(argv[option_index]) == "--k") {
            if (option_index + 1 >= argc ||
                !parse_limit(argv[option_index + 1], induction_depth) || induction_depth == 0 ||
                induction_depth > 10000) {
                std::cerr << "Q3A_INDUCTION_ERROR induction depth must be between 1 and 10000\n";
                return 2;
            }
            option_index += 2;
        }
        if (option_index + 1 >= argc ||
            std::string(argv[option_index]) != "--output-prefix") {
            std::cerr << "Q3A_INDUCTION_ERROR usage: --prove-inductive <project.q3a> "
                         "--property <scalar-assertion> [--k <positive-depth>] "
                         "--output-prefix <path-prefix> [--bundle-dir <directory>] "
                         "[--cache-dir <directory>] [--trace-all] [--trace-signal <name> ...]\n";
            return 2;
        }
        const auto output_prefix = std::filesystem::u8path(argv[option_index + 1]);
        option_index += 2;
        std::filesystem::path bundle_directory;
        std::filesystem::path cache_directory;
        q3a::trace::CaptureRequest capture;
        bool bundle_seen = false;
        bool cache_seen = false;
        while (option_index < argc) {
            const std::string option(argv[option_index++]);
            if (option == "--trace-all" && !capture.all) {
                capture.all = true;
                continue;
            }
            if (option_index >= argc) {
                std::cerr << "Q3A_INDUCTION_ERROR option is missing its value\n";
                return 2;
            }
            if (option == "--trace-signal") {
                capture.extra.emplace_back(argv[option_index++]);
                continue;
            }
            const auto value = std::filesystem::u8path(argv[option_index++]);
            if (option == "--bundle-dir" && !bundle_seen) {
                bundle_directory = value;
                bundle_seen = true;
            } else if (option == "--cache-dir" && !cache_seen) {
                cache_directory = value;
                cache_seen = true;
            } else {
                std::cerr << "Q3A_INDUCTION_ERROR unknown or duplicate option '"
                          << option << "'\n";
                return 2;
            }
        }
        if ((capture.all || !capture.extra.empty()) && bundle_directory.empty()) {
            std::cerr << "Q3A_INDUCTION_ERROR trace selection requires a witness bundle output\n";
            return 2;
        }
        try {
            const auto manifest_path = std::filesystem::u8path(argv[2]);
            std::optional<q3a::ProjectInput> loaded;
            if (!preloaded) loaded.emplace(load_proof_project(manifest_path, command));
            return prove_inductive_project(
                preloaded ? *preloaded : *loaded, manifest_path, argv[4], output_prefix,
                bundle_directory, cache_directory, induction_depth, capture, command);
        } catch (const q3a::MemoryBudgetExceeded& error) {
            std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
            return command.finish_resource(1, "memory");
        } catch (const std::bad_alloc& error) {
            std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
            return command.finish_resource(1, "memory");
        } catch (const q3a::frontend::LexError& error) {
            std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
            return command.reject_input(error);
        } catch (const q3a::frontend::ParseError& error) {
            std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
            return command.reject_input(error);
        } catch (const std::exception& error) {
            std::cerr << "Q3A_INDUCTION_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    if (argc >= 2 && std::string(argv[1]) == "--bmc") {
        if (argc < 7 ||
            std::string(argv[3]) != "--property" ||
            std::string(argv[5]) != "--frames") {
            std::cerr << "Q3A_BMC_ERROR usage: --bmc <project.q3a> "
                         "--property <property-name> --frames <transition-count> "
                         "[--vcd <output.vcd>] [--html <output.html>] "
                         "[--bundle-dir <directory>] [--trace-all] [--trace-signal <name> ...]\n";
            return 2;
        }
        std::uint64_t transition_count = 0;
        if (!parse_limit(argv[6], transition_count)) {
            std::cerr << "Q3A_BMC_ERROR invalid transition count\n";
            return 2;
        }
        std::filesystem::path vcd_path;
        std::filesystem::path html_path;
        std::filesystem::path bundle_directory;
        q3a::trace::CaptureRequest capture;
        bool vcd_seen = false;
        bool html_seen = false;
        bool bundle_seen = false;
        for (int option_index = 7; option_index < argc;) {
            const std::string option(argv[option_index++]);
            if (option == "--trace-all" && !capture.all) {
                capture.all = true;
                continue;
            }
            if (option_index >= argc) {
                std::cerr << "Q3A_BMC_ERROR option is missing its value\n";
                return 2;
            }
            if (option == "--trace-signal") {
                capture.extra.emplace_back(argv[option_index++]);
                continue;
            }
            const auto value = std::filesystem::u8path(argv[option_index++]);
            if (option == "--vcd" && !vcd_seen) {
                vcd_path = value;
                vcd_seen = true;
            } else if (option == "--html" && !html_seen) {
                html_path = value;
                html_seen = true;
            } else if (option == "--bundle-dir" && !bundle_seen) {
                bundle_directory = value;
                bundle_seen = true;
            } else {
                std::cerr << "Q3A_BMC_ERROR unknown or duplicate option '"
                          << option << "'\n";
                return 2;
            }
        }
        if ((capture.all || !capture.extra.empty()) &&
            vcd_path.empty() && html_path.empty() && bundle_directory.empty()) {
            std::cerr << "Q3A_BMC_ERROR trace selection requires VCD, HTML, or a bundle output\n";
            return 2;
        }
        if (!vcd_path.empty() && !html_path.empty() &&
            std::filesystem::absolute(vcd_path).lexically_normal() ==
                std::filesystem::absolute(html_path).lexically_normal()) {
            std::cerr << "Q3A_BMC_ERROR VCD and HTML output paths must be different\n";
            return 2;
        }
        try {
            const auto manifest_path = std::filesystem::u8path(argv[2]);
            std::optional<q3a::ProjectInput> loaded;
            if (!preloaded) loaded.emplace(load_proof_project(manifest_path, command));
            return bounded_check_project(
                preloaded ? *preloaded : *loaded, manifest_path, argv[4], transition_count, vcd_path,
                html_path, bundle_directory, capture, command);
        } catch (const q3a::MemoryBudgetExceeded& error) {
            std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
            return command.finish_resource(1, "memory");
        } catch (const std::bad_alloc& error) {
            std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
            return command.finish_resource(1, "memory");
        } catch (const q3a::frontend::LexError& error) {
            std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
            return command.reject_input(error);
        } catch (const q3a::frontend::ParseError& error) {
            std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
            return command.reject_input(error);
        } catch (const std::exception& error) {
            std::cerr << "Q3A_BMC_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    return 2;
}

void set_proof_configuration(ProofCommand& command, const q3a::ProjectInput& project,
                                     const q3a::lowering::TIRModule& model,
                                     const q3a::lowering::TIRProperty& selected,
                                     const q3a::MemoryBudget& memory, std::string_view engine,
                                     std::uint64_t depth, bool activation,
                                     std::optional<std::uint64_t> maximum_search_queries,
                                     std::uint64_t minimum_feasibility_bound) {
    using q3a::bundle::json_string;
    std::ostringstream out;
    const auto write_settings = [&](const std::map<std::string, std::string>& settings) {
        const char* separator = "";
        out << '{';
        for (const auto& [name, value] : settings) {
            out << separator << json_string(name) << ':' << json_string(value);
            separator = ",";
        }
        out << '}';
    };
    const auto write_sources = [&](const std::vector<q3a::SourceFile>& sources) {
        const char* separator = "";
        out << '[';
        for (const auto& source : sources) {
            out << separator << "{\"path\":" << json_string(source.relative_path)
                << ",\"sha256\":" << std::quoted(source.sha256) << '}';
            separator = ",";
        }
        out << ']';
    };
    const auto* goal = activation ? "activation" : selected.kind == "cover" ? "cover" : "safety";
    std::ostringstream limits;
    if (engine == "bmc") limits << ",\"transition_count\":" << depth;
    if (engine == "induction") limits << ",\"induction_depth\":" << depth;
    if (maximum_search_queries) {
        limits << ",\"maximum_depth\":" << depth
               << ",\"maximum_search_queries\":" << *maximum_search_queries
               << ",\"minimum_feasibility_bound\":" << minimum_feasibility_bound;
    }
    limits << ",\"search_private_limit_bytes\":" << memory.private_limit_bytes()
           << ",\"search_physical_reserve_bytes\":" << memory.physical_reserve_bytes();
    const auto resolved_limits = limits.str();
    out << "{\"engine\":" << std::quoted(engine)
        << ",\"build_id\":" << std::quoted(q3a::build_info::kBuildId)
        << ",\"source_set_sha256\":" << std::quoted(project.input_hash)
        << ",\"project_manifest_sha256\":" << std::quoted(project.manifest_sha256)
        << ",\"manifest_version\":" << project.manifest_version
        << ",\"top_module\":" << json_string(project.top_module)
        << ",\"semantic_profile\":" << json_string(model.semantic_profile)
        << ",\"property\":" << json_string(selected.name)
        << ",\"property_kind\":" << json_string(selected.kind)
        << ",\"goal\":" << std::quoted(goal)
        << ",\"clock\":" << json_string(selected.clock)
        << ",\"reset_initial_policy\":" << json_string(q3a::bundle::kResetInitialPolicy)
        << ",\"workers\":1" << resolved_limits
        << ",\"timeout_ms\":" << command.timeout.count() << ",\"parameters\":";
    write_settings(project.parameters);
    out << ",\"macros\":";
    write_settings(project.macros);
    out << ",\"include_dirs\":[";
    const char* separator = "";
    for (const auto& dir : project.include_dirs) {
        out << separator << json_string(dir);
        separator = ",";
    }
    out << "],\"sources\":";
    write_sources(project.sources);
    out << ",\"headers\":";
    write_sources(project.headers);
    out << ",\"assumptions\":[";
    separator = "";
    for (const auto& property : model.properties) {
        if (property.kind != "assume") continue;
        out << separator << json_string(property.name);
        separator = ",";
    }
    out << "]}";
    command.run_configuration = out.str();

    if (command.has_control()) {
        // The complete source roster can exceed the interruption reader's size limit.
        std::ostringstream compact;
        compact << "{\"project_manifest_sha256\":" << std::quoted(project.manifest_sha256)
                << ",\"manifest_version\":" << project.manifest_version
                << ",\"configuration_sha256\":" << std::quoted(q3a::sha256_hex(command.run_configuration))
                << ",\"goal\":" << std::quoted(goal)
                << resolved_limits << '}';
        command.interruption_configuration = compact.str();
    }
}

void run_pdr_command(const q3a::ProjectInput& project, const std::filesystem::path& manifest,
                     const std::string& property, const std::vector<const char*>& options,
                     ProofCommand& command) {
    std::uint64_t depth = 32;
    std::uint64_t maximum_search_queries = q3a::pdr::kDefaultSearchQueries;
    std::uint64_t minimum_feasibility_bound = 0;
    std::filesystem::path evidence;
    std::filesystem::path witness_bundle;
    q3a::trace::CaptureRequest capture;
    std::unordered_set<std::string_view> seen;
    for (std::size_t i = 0; i < options.size();) {
        const std::string_view key = options[i++];
        if (key == "--trace-all" && !capture.all) {
            capture.all = true;
            continue;
        }
        if (key == "--check-activation" && seen.insert(key).second) {
            command.activation_analysis = true;
            continue;
        }
        if (i == options.size() || (key != "--trace-signal" && !seen.insert(key).second) || !*options[i]) {
            throw std::invalid_argument("missing value or duplicate PDR option");
        }
        const char* value = options[i++];
        if (key == "--max-depth") {
            if (!parse_limit(value, depth) || depth == 0 || depth > q3a::pdr::kMaximumDepth) {
                throw std::invalid_argument("PDR depth must be in 1..128");
            }
        } else if (key == "--max-queries") {
            if (!parse_pdr_query_limit(value, maximum_search_queries)) {
                throw std::invalid_argument("PDR search query limit must be a positive integer");
            }
        } else if (key == "--feasibility-frames") {
            if (!parse_limit(value, minimum_feasibility_bound) ||
                minimum_feasibility_bound > q3a::pdr::kMaximumDepth) {
                throw std::invalid_argument("PDR feasibility bound must be in 0..128");
            }
        } else if (key == "--evidence-dir") {
            evidence = std::filesystem::u8path(value);
        } else if (key == "--bundle-dir") {
            witness_bundle = std::filesystem::u8path(value);
        } else if (key == "--trace-signal") {
            capture.extra.emplace_back(value);
        } else {
            throw std::invalid_argument("unsupported PDR option: " + std::string(key));
        }
    }
    if (evidence.empty()) throw std::invalid_argument("PDR requires --evidence-dir");
    if ((capture.all || !capture.extra.empty()) && witness_bundle.empty()) {
        throw std::invalid_argument("PDR trace selection requires a witness bundle output");
    }
    command.loaded(project);
    command.enter_stage("elaboration");
    const auto model = lower_project_tir(project);
    command.completed("model_elaborated");
    command.check_control(true);
    const auto selected = std::find_if(model.properties.begin(), model.properties.end(),
        [&](const auto& candidate) { return candidate.name == property; });
    if (selected != model.properties.end() && q3a::lowering::is_eventual_response(*selected)) {
        command.reject_input("UNSUPPORTED", "Q3A_PDR_PROFILE", selected->location,
            "s_eventually requires dev-check-liveness");
        return;
    }
    const bool cover = selected != model.properties.end() && selected->kind == "cover";
    if (!cover && selected != model.properties.end() && selected->kind == "assert") command.activation.emplace();
    if (!capture.extra.empty() && selected != model.properties.end()) {
        q3a::trace::select_capture_signals(model, *selected, capture);
    }
    try {
        const auto memory = command.budget();
        if (selected != model.properties.end() && (selected->kind == "assert" || cover)) {
            set_proof_configuration(command,
                project, model, *selected, memory, "pdr", depth,
                command.activation_analysis, maximum_search_queries, minimum_feasibility_bound);
        }
        command.enter_stage("pdr_search");
        memory.check();
        std::optional<q3a::lowering::TIRModule> activation_model;
        if (command.activation_analysis) activation_model.emplace(q3a::pdr::activation_model(model, property));
        const auto& query_model = activation_model ? *activation_model : model;
        const auto result = q3a::pdr::search(query_model, property, static_cast<std::size_t>(depth),
            static_cast<std::size_t>(maximum_search_queries), memory,
            static_cast<std::size_t>(minimum_feasibility_bound));
        if (result.status == q3a::pdr::Status::Inconsistent) {
            command.environment_feasibility = ProofCommand::EnvironmentFeasibility{
                result.depth, q3a::sat::Status::Unsatisfiable};
        } else if (result.feasible_prefix_bound) {
            command.environment_feasibility = ProofCommand::EnvironmentFeasibility{
                *result.feasible_prefix_bound, q3a::sat::Status::Satisfiable};
        }
        if (result.status == q3a::pdr::Status::InvariantFound ||
            result.status == q3a::pdr::Status::CounterexampleCandidate ||
            result.status == q3a::pdr::Status::Inconsistent) command.completed("pdr_search_resolved");
        command.check_control(true);
        command.progress << "Q3A_PDR_DEPTH " << result.depth << '\n';
        command.progress << "Q3A_PDR_SEARCH_STATS queries=" << result.search_queries
                         << " cnf_builds=" << result.search_cnf_builds
                         << " state_bits=" << result.search_state_bits
                         << " full_state_bits=" << result.full_state_bits
                         << " signal_bits=" << result.search_signal_bits
                         << " full_signal_bits=" << result.full_signal_bits
                         << " initial_zero_rejections=" << result.initial_zero_rejections << '\n';
        switch (result.status) {
        case q3a::pdr::Status::InvariantFound:
            command.enter_stage("pdr_certificate");
            command.certificate_dir = std::filesystem::absolute(evidence).lexically_normal();
            command.certificate = q3a::pdr::certify(
                query_model, property, result.invariant, evidence, memory, command.run_configuration);
            if (command.certificate) {
                command.completed("pdr_certificate_checked");
                command.progress << "Q3A_PDR_CERTIFICATE VERIFIED clauses=" << result.invariant.size() << '\n';
                if (command.activation_analysis) {
                    command.activation->activity = "NOT_REACHED";
                    command.activation->feasibility = "SAT";
                    command.activation->complete = true;
                    command.finish(0, ProofExit::Conclusive, "ACTIVATION_UNREACHABLE");
                } else {
                    command.finish(0, ProofExit::Conclusive, cover ? "UNREACHABLE" : "PROVEN");
                }
            } else {
                command.progress << "Q3A_PDR_LIMIT certificate production or checker limit reached\n";
                command.finish_resource(1, "proof");
            }
            break;
        case q3a::pdr::Status::CounterexampleCandidate:
            // Solve the reachable prefix again and require independent T-IR replay.
            bounded_check_project(project, manifest, property, result.depth, {}, {}, witness_bundle, capture, command,
                activation_model ? &*activation_model : nullptr, activation_model ? &model : nullptr);
            if ((cover && command.status == "COVERED") ||
                (command.activation_analysis && command.status == "ACTIVATION_REACHED")) {
                break;
            }
            if (!cover && command.status == "BOUNDED_FAIL") {
                command.finish(0, ProofExit::Conclusive, "FAIL");
            } else if (command.status != "RESOURCE_LIMIT" && command.status != "ENGINE_ERROR") {
                throw std::runtime_error("PDR candidate did not yield an independently replayed witness");
            }
            break;
        case q3a::pdr::Status::Inconsistent:
            if (command.activation) {
                command.activation->bound = result.depth;
                command.activation->feasibility = "UNSAT";
            }
            if (witness_bundle.empty()) {
                command.finish(1, ProofExit::Inconclusive, "INCONSISTENT_MODEL_OR_ASSUMPTIONS");
            } else {
                bounded_check_project(project, manifest, property, result.depth,
                    {}, {}, witness_bundle, {}, command, nullptr, &model, true);
            }
            break;
        case q3a::pdr::Status::Unknown:
            if (command.activation_analysis) {
                command.activation->bound = result.depth;
                command.activation->activity = "NOT_REACHED";
                command.activation->feasibility = "SAT";
            }
            command.progress << "Q3A_PDR_LIMIT frame bound reached\n";
            command.finish(1, ProofExit::Inconclusive, "UNKNOWN");
            break;
        case q3a::pdr::Status::ResourceLimited:
            command.progress << "Q3A_PDR_LIMIT SAT search budget reached\n";
            command.finish_resource(1, "search");
            break;
        }
    } catch (const q3a::lowering::LoweringError&) {
        throw;
    } catch (const q3a::sat::BitBlastError&) {
        throw;
    } catch (const std::invalid_argument&) {
        throw;
    } catch (const q3a::MemoryBudgetExceeded&) {
        throw;
    } catch (const std::bad_alloc&) {
        throw;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_PDR_ERROR " << error.what() << '\n';
        command.finish(3, ProofExit::EngineError, "ENGINE_ERROR");
    }
}

std::map<std::string, std::string> read_parameter_overrides(
    int argc, const char* const* argv, int& position) {
    std::map<std::string, std::string> overrides;
    while (position < argc && std::string_view(argv[position]) == "--parameter") {
        if (position + 2 >= argc) throw std::invalid_argument("--parameter requires NAME VALUE");
        if (!overrides.emplace(argv[position + 1], argv[position + 2]).second) {
            throw std::invalid_argument("duplicate command-line parameter: " + std::string(argv[position + 1]));
        }
        position += 3;
    }
    return overrides;
}

int verify_pdr_command(int argc, const char* const* argv) {
    try {
        int position = 3;
        const auto overrides = read_parameter_overrides(argc, argv, position);
        const bool activation = argc == position + 5 && std::string_view(argv[position + 4]) == "--check-activation";
        if ((!activation && argc != position + 4) || std::string_view(argv[position]) != "--property" ||
            std::string_view(argv[position + 2]) != "--evidence-dir") {
            throw std::invalid_argument("expected verify-pdr <project.q3a> [--parameter NAME VALUE] --property <name> --evidence-dir <dir> [--check-activation]");
        }
        const q3a::MemoryBudget memory;
        memory.check();
        auto project = q3a::SourceManager::load(std::filesystem::u8path(argv[2]));
        q3a::SourceManager::apply_parameter_overrides(project, overrides);
        const auto model = lower_project_tir(project);
        try {
            std::optional<q3a::lowering::TIRModule> derived;
            if (activation) derived.emplace(q3a::pdr::activation_model(model, argv[position + 1]));
            const auto directory = std::filesystem::u8path(argv[position + 3]);
            const auto checked = q3a::pdr::verify(derived ? *derived : model, argv[position + 1], directory, memory);
            if (!checked) {
                std::cerr << "Q3A_PDR_LIMIT independent checker limit reached\n";
                return 1;
            }
            const auto configuration = q3a::bundle::verify_pdr_run_configuration(
                directory, project, model, argv[position + 1], activation, *checked, memory);
            if (configuration) {
                std::cout << "Q3A_PDR_RUN_CONFIGURATION VERIFIED sha256=" << *configuration << '\n';
            }
        } catch (const q3a::MemoryBudgetExceeded&) {
            throw;
        } catch (const std::bad_alloc&) {
            throw;
        } catch (const std::exception& error) {
            std::cerr << "Q3A_PDR_CERTIFICATE REJECTED " << error.what() << '\n';
            return 3;
        }
        std::cout << "Q3A_PDR_CERTIFICATE VERIFIED\n";
        if (activation) {
            std::cout << "Q3A_PDR_RESULT ACTIVATION_UNREACHABLE\n";
            return 0;
        }
        const auto name = std::string_view(argv[position + 1]);
        const auto target = std::find_if(model.properties.begin(), model.properties.end(),
            [&](const auto& candidate) { return candidate.name == name; });
        if (target != model.properties.end() && target->kind == "cover") {
            std::cout << "Q3A_PDR_RESULT UNREACHABLE\n";
        }
        return 0;
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
        return 1;
    } catch (const std::bad_alloc& error) {
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
        return 1;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_PDR_ERROR " << error.what() << '\n';
        return 2;
    }
}

int product_prove(int argc, const char* const* argv, std::ostream& output, bool console_control,
                  const q3a::ProjectInput* batch_project = nullptr, std::uint64_t job_memory_mib = 0,
                  std::string* job_status = nullptr) {
    ProofCommand command(true);
    command.console_control = console_control;
    command.job_memory_mib = job_memory_mib;
    std::string property;
    std::optional<ProofStop> stop;
    const auto invoke = [&](const std::string& engine, std::vector<const char*> options,
                            const q3a::ProjectInput* preloaded,
                            const std::map<std::string, std::string>& overrides = {}) {
        if (property.empty() || !std::all_of(property.begin(), property.end(), [](unsigned char ch) {
                return ch >= 0x21 && ch <= 0x7e;
            })) {
            property.clear();
            throw std::invalid_argument("expected a printable nonempty property name");
        }
        if (engine != "bmc" && engine != "induction" && engine != "pdr") {
            throw std::invalid_argument("expected bmc, induction, or pdr engine");
        }
        command.engine = engine;
        std::optional<q3a::ProjectInput> overridden_project;
        if (!overrides.empty()) {
            if (preloaded) {
                command.budget().check();
                overridden_project.emplace(*preloaded);
            } else {
                overridden_project.emplace(load_proof_project(std::filesystem::u8path(argv[2]), command));
            }
            q3a::SourceManager::apply_parameter_overrides(*overridden_project, overrides);
            preloaded = &*overridden_project;
        }
        if (engine == "pdr") {
            const auto manifest = std::filesystem::u8path(argv[2]);
            std::optional<q3a::ProjectInput> loaded;
            if (!preloaded) loaded.emplace(load_proof_project(manifest, command));
            run_pdr_command(preloaded ? *preloaded : *loaded, manifest, property, options, command);
            return;
        }

        const char* mode = engine == "bmc" ? "--bmc" : "--prove-inductive";
        std::vector<const char*> arguments{argv[0], mode, argv[2], "--property", property.c_str()};
        arguments.insert(arguments.end(), options.begin(), options.end());
        run_proof_command(static_cast<int>(arguments.size()), arguments.data(), command, preloaded);
    };
    try {
        int position = 3;
        const auto overrides = read_parameter_overrides(argc, argv, position);
        std::filesystem::path cancel_file;
        std::filesystem::path run_record;
        std::unordered_set<std::string_view> control_options;
        while (position < argc) {
            const std::string_view option = argv[position];
            if (option != "--timeout-ms" && option != "--cancel-file" && option != "--run-record") break;
            if (position + 1 >= argc || !*argv[position + 1] || !control_options.insert(option).second) {
                throw std::invalid_argument("missing or duplicate run-control option");
            }
            const auto* value = argv[position + 1];
            if (option == "--timeout-ms") {
                std::uint64_t limit = 0;
                if (!parse_limit(value, limit) || limit == 0 || limit > 86400000) {
                    throw std::invalid_argument("--timeout-ms must be an integer in 1..86400000");
                }
                command.timeout = std::chrono::milliseconds(limit);
            } else {
                auto& path = option == "--cancel-file" ? cancel_file : run_record;
                path = std::filesystem::absolute(std::filesystem::u8path(value)).lexically_normal();
                if (!std::filesystem::is_directory(q3a::bundle::detail::windows_file_path(path.parent_path()))) {
                    throw std::invalid_argument("run-control path must have an existing parent directory");
                }
            }
            position += 2;
        }
        if (!cancel_file.empty()) {
            const auto type = control_path_type(cancel_file);
            if (type != std::filesystem::file_type::not_found && type != std::filesystem::file_type::regular) {
                throw std::invalid_argument("cancel-file path must name a regular file or an absent file");
            }
            if (run_record.empty()) {
                run_record = cancel_file;
                run_record += ".result.json";
            }
            if (CompareStringOrdinal(cancel_file.c_str(), -1, run_record.c_str(), -1, TRUE) == CSTR_EQUAL) {
                throw std::invalid_argument("cancel-file and run-record paths must be distinct");
            }
        }
        if (!run_record.empty() && control_path_type(run_record) != std::filesystem::file_type::not_found) {
            throw std::invalid_argument("run-record output already exists");
        }
        command.cancel_file = std::move(cancel_file);
        command.run_record = std::move(run_record);

        if (argc >= position + 4 && std::string_view(argv[position]) == "--engine" &&
            std::string_view(argv[position + 2]) == "--property") {
            property = argv[position + 3];
            invoke(argv[position + 1], {argv + position + 4, argv + argc}, batch_project, overrides);
        } else if (argc >= position && (argc == position || std::string_view(argv[position]) != "--engine")) {
            auto project = load_proof_project(std::filesystem::u8path(argv[2]), command);
            q3a::SourceManager::apply_parameter_overrides(project, overrides);
            if (project.default_engine.empty() || project.default_property.empty()) {
                throw std::invalid_argument("provide --engine and --property, or select both in the version 2 manifest");
            }
            property = project.default_property;
            const bool bounded = project.default_engine == "bmc";
            if (bounded && !project.default_depth) {
                throw std::invalid_argument("manifest-selected bmc requires option depth");
            }
            const bool pdr = project.default_engine == "pdr";
            const auto depth = std::to_string(project.default_depth.value_or(pdr ? 32 : 1));
            std::vector<const char*> options{bounded ? "--frames" : pdr ? "--max-depth" : "--k", depth.c_str()};
            options.insert(options.end(), argv + position, argv + argc);
            invoke(project.default_engine, std::move(options), &project);
        } else {
            throw std::invalid_argument("expected prove <project.q3a> [--parameter NAME VALUE] [--timeout-ms N] [--cancel-file PATH] [--run-record PATH] [--engine <mode> --property <name>] <engine options>");
        }
    } catch (ProofStop reason) {
        stop = reason;
        switch (reason) {
        case ProofStop::Timeout:
            std::cerr << "Q3A_PROVE_TIMEOUT phase=" << command.stage << '\n';
            command.finish(1, ProofExit::Inconclusive, "TIMEOUT");
            break;
        case ProofStop::CancelFile:
        case ProofStop::CtrlC:
        case ProofStop::CtrlBreak:
            std::cerr << "Q3A_PROVE_CANCELLED cause=" << cancellation_cause(reason)
                      << " phase=" << command.stage << '\n';
            command.finish(1, ProofExit::Inconclusive, "CANCELLED");
            break;
        case ProofStop::ControlError:
            std::cerr << "Q3A_PROVE_ERROR cannot inspect cancel-file control\n";
            command.finish(3, ProofExit::EngineError, "ENGINE_ERROR");
            break;
        }
    } catch (const q3a::frontend::LexError& error) {
        std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
        command.reject_input(error);
    } catch (const q3a::frontend::ParseError& error) {
        std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
        command.reject_input(error);
    } catch (const q3a::elaboration::ElaborationError& error) {
        std::cerr << "Q3A_ELABORATION_ERROR " << error.what() << '\n';
        command.reject_input(error);
    } catch (const q3a::lowering::LoweringError& error) {
        std::cerr << "Q3A_LOWERING_ERROR " << error.what() << '\n';
        command.reject_input(error);
    } catch (const q3a::sat::BitBlastError& error) {
        std::cerr << "Q3A_BITBLAST_ERROR " << error.what() << '\n';
        command.reject_bit_blast(error);
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
        command.finish_resource(1, "memory");
    } catch (const std::bad_alloc& error) {
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
        command.finish_resource(1, "memory");
    } catch (const std::exception& error) {
        std::cerr << "Q3A_PROVE_ERROR " << error.what() << '\n';
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        ProofCommand::Clock::now() - command.started).count();
    const auto cause = cancellation_cause(stop);
    const auto summary = [&](std::string_view record_failure) {
        std::ostringstream out;
        out << "{\"schema_version\":1,\"exit_code\":" << static_cast<int>(command.exit)
            << ",\"status\":" << std::quoted(command.status);
        if (!stop && !command.saved_bundle.empty()) {
            out << ",\"bundle_dir\":" << q3a::bundle::json_string(command.saved_bundle.u8string());
        }
        if (!stop && !command.run_configuration.empty()) {
            out << ",\"run_configuration\":" << command.run_configuration;
            if (command.engine == "pdr") out << ",\"pdr_configuration\":" << command.run_configuration;
        } else if ((stop == ProofStop::Timeout || !cause.empty()) &&
                   !command.interruption_configuration.empty()) {
            out << ",\"resolved_configuration\":" << command.interruption_configuration;
        }
        if (!stop && command.certificate && command.exit == ProofExit::Conclusive) {
            const auto& certificate = *command.certificate;
            out << ",\"certificate\":{\"directory\":"
                << q3a::bundle::json_string(command.certificate_dir.u8string())
                << ",\"build_id\":" << std::quoted(q3a::build_info::kBuildId)
                << ",\"checker_id\":" << std::quoted(q3a::checker::kCheckerId)
                << ",\"model_sha256\":" << std::quoted(certificate.model_sha256)
                << ",\"run_configuration_sha256\":" << std::quoted(certificate.run_configuration_sha256)
                << ",\"obligations\":[";
            const char* separator = "";
            for (const auto& obligation : certificate.obligations) {
                out << separator << "{\"kind\":" << std::quoted(obligation.kind)
                    << ",\"query_sha256\":" << std::quoted(obligation.query_sha256)
                    << ",\"proof_sha256\":" << std::quoted(obligation.proof_sha256) << '}';
                separator = ",";
            }
            out << "]}";
        }
        if (!command.resource_limit.empty()) out << ",\"resource_limit\":" << std::quoted(command.resource_limit);
        if (command.timeout.count() != 0) out << ",\"timeout_ms\":" << command.timeout.count();
        if (command.timeout.count() != 0 || !command.cancel_file.empty() ||
            !command.run_record.empty() || !cause.empty() || !command.run_configuration.empty()) {
            out << ",\"elapsed_ms\":" << elapsed;
        }
        if (stop == ProofStop::Timeout) out << ",\"timeout_stage\":" << std::quoted(command.stage);
        if (!cause.empty()) {
            out << ",\"cancellation_cause\":" << std::quoted(cause)
                << ",\"cancellation_stage\":" << std::quoted(command.stage);
        }
        if (stop || !command.run_record.empty()) {
            out << ",\"build_id\":" << std::quoted(q3a::build_info::kBuildId);
            if (!command.engine.empty()) out << ",\"engine\":" << std::quoted(command.engine);
            if (!command.source_identity.empty()) {
                out << ",\"source_set_sha256\":" << std::quoted(command.source_identity);
            }
            out << ",\"completed_work\":[";
            const char* separator = "";
            for (const auto work : command.completed_work) {
                out << separator << std::quoted(work);
                separator = ",";
            }
            out << ']';
        }
        if (!record_failure.empty()) out << ",\"unrecorded_status\":" << std::quoted(record_failure);
        if (command.input_diagnostic) {
            const auto& diagnostic = *command.input_diagnostic;
            out << ",\"diagnostics\":[{\"code\":" << std::quoted(diagnostic.code)
                << ",\"severity\":\"error\",\"message\":" << q3a::bundle::json_string(diagnostic.message)
                << ",\"location\":{\"file\":" << q3a::bundle::json_string(diagnostic.location.file)
                << ",\"line\":" << diagnostic.location.line
                << ",\"column\":" << diagnostic.location.column << "}}]";
        }
        out << ",\"properties\":[";
        if (!property.empty()) {
            out << "{\"name\":" << std::quoted(property)
                << ",\"status\":" << std::quoted(command.status);
            if (!stop && command.environment_feasibility &&
                (command.exit == ProofExit::Conclusive || command.exit == ProofExit::Inconclusive)) {
                const auto& environment = *command.environment_feasibility;
                const auto* status = environment.status == q3a::sat::Status::Satisfiable ? "SAT" :
                    environment.status == q3a::sat::Status::Unsatisfiable ? "UNSAT" : "UNKNOWN";
                out << ",\"environment_feasibility\":{\"status\":" << std::quoted(status)
                    << ",\"scope\":" << std::quoted(environment.bound == 0 ? "INITIAL_SAMPLE" : "FINITE_PREFIX")
                    << ",\"bound\":" << environment.bound << '}';
            }
            if (!stop && command.activation &&
                (command.exit == ProofExit::Conclusive || command.exit == ProofExit::Inconclusive)) {
                const auto& activity = *command.activation;
                out << ",\"vacuity\":{\"status\":"
                    << std::quoted(activity.complete ? "DETECTED" :
                        activity.activity == "REACHED" ? "NOT_DETECTED_WITHIN_SCOPE" : "INCOMPLETE")
                    << ",\"scope\":" << std::quoted(activity.complete ? "COMPLETE" :
                        activity.bound ? "BOUNDED" : "UNAVAILABLE")
                    << ",\"activation\":" << std::quoted(activity.activity)
                    << ",\"feasibility\":" << std::quoted(activity.feasibility);
                if (activity.bound) out << ",\"bound\":" << *activity.bound;
                if (activity.incomplete_boundary) {
                    out << ",\"boundary_obligations\":"
                        << std::quoted(*activity.incomplete_boundary ? "INCOMPLETE" : "COMPLETE");
                }
                out << '}';
            }
            out << '}';
        }
        out << "]}\n";
        return out.str();
    };
    auto payload = summary({});
    if (!command.run_record.empty() || !cause.empty()) {
        try {
            if (command.run_record.empty()) {
                command.run_record = std::filesystem::current_path() /
                    ("q3a-cancelled-" + std::to_string(GetCurrentProcessId()) + "-" +
                     std::to_string(command.started.time_since_epoch().count()) + ".json");
            }
            write_run_record(command.run_record, payload);
            if (stop == ProofStop::CtrlC || stop == ProofStop::CtrlBreak) {
                std::cerr << "Q3A_RUN_RECORD " << std::quoted(command.run_record.u8string()) << '\n';
            }
        } catch (const std::exception& error) {
            std::cerr << "Q3A_RUN_RECORD_ERROR " << error.what() << '\n';
            const auto undelivered = command.status;
            command.finish(3, ProofExit::EngineError, "ENGINE_ERROR");
            payload = summary(undelivered);
        }
    }
    if (job_status) *job_status = command.status;
    output << payload;
    return static_cast<int>(command.exit);
}

struct ProofBatchJob {
    std::string id;
    std::string engine;
    std::string property;
    std::uint64_t depth = 0;
    std::uint64_t timeout_ms = 0;
    std::optional<std::uint64_t> maximum_search_queries;
    std::optional<std::uint64_t> minimum_feasibility_bound;
    std::map<std::string, std::string> parameters;
};

struct ProofBatchPlan {
    unsigned version = 1;
    std::uint64_t memory_mib = 0;
    std::string sha256;
    std::vector<ProofBatchJob> jobs;
};

ProofBatchPlan read_proof_batch(const std::filesystem::path& path) {
    const auto absolute = q3a::bundle::detail::windows_file_path(std::filesystem::absolute(path));
    q3a::WriteLockedInput input(absolute);
    std::array<char, 64 * 1024 + 1> bytes{};
    auto& file = input.stream();
    file.read(bytes.data(), bytes.size());
    const auto size = static_cast<std::size_t>(file.gcount());
    if (file.bad() || size == bytes.size()) throw std::invalid_argument("batch plan exceeds its read limit");
    const std::string text(bytes.data(), size);
    std::istringstream lines(text);
    std::string line;
    ProofBatchPlan result;
    std::unordered_set<std::string> ids;
    for (std::size_t line_number = 1; std::getline(lines, line); ++line_number) {
        std::istringstream fields(line);
        std::string kind, value, trailing;
        fields >> kind;
        if (line_number == 1) {
            if (!(fields >> value) || kind != "Q3AFORMAL_BATCH" ||
                (value != "1" && value != "2" && value != "3") || fields >> trailing) {
                throw std::invalid_argument("expected Q3AFORMAL_BATCH 1, 2 or 3");
            }
            result.version = static_cast<unsigned>(value.front() - '0');
            continue;
        }
        if (kind.empty()) continue;
        const auto invalid = [line_number] {
            return std::invalid_argument("invalid batch record at line " + std::to_string(line_number));
        };
        if (kind == "memory_mib") {
            if (result.memory_mib != 0 || !result.jobs.empty() || !(fields >> value) ||
                !parse_limit(value, result.memory_mib) || result.memory_mib == 0 ||
                result.memory_mib > 65536 || fields >> trailing) throw invalid();
            continue;
        }
        ProofBatchJob job;
        std::string depth, deadline;
        if (kind != "job" || result.memory_mib == 0 || result.jobs.size() == 128 ||
            !(fields >> job.id >> job.engine >> job.property >> depth >> deadline) ||
            job.id.size() > 48 || !std::all_of(job.id.begin(), job.id.end(), [](char ch) {
                return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_';
            }) || !ids.insert(job.id).second || !parse_limit(depth, job.depth) ||
            !parse_limit(deadline, job.timeout_ms) || job.timeout_ms == 0 || job.timeout_ms > 86400000) {
            throw invalid();
        }
        const bool valid_depth = (job.engine == "bmc" && job.depth <= 10000) ||
            (job.engine == "induction" && job.depth > 0 && job.depth <= 10000) ||
            (job.engine == "pdr" && job.depth > 0 && job.depth <= q3a::pdr::kMaximumDepth);
        if (!valid_depth || !std::all_of(job.property.begin(), job.property.end(), [](unsigned char ch) {
                return ch >= 0x21 && ch <= 0x7e;
            })) throw invalid();
        while (fields >> trailing) {
            if (trailing == "param" && result.version == 3) {
                std::string name, parameter;
                if (!(fields >> name >> parameter) || job.parameters.size() == 32 ||
                    !job.parameters.emplace(std::move(name), std::move(parameter)).second) throw invalid();
                continue;
            }
            std::uint64_t parsed = 0;
            if (result.version < 2 || job.engine != "pdr" || !(fields >> value)) throw invalid();
            if (trailing == "max_queries" && !job.maximum_search_queries &&
                parse_pdr_query_limit(value, parsed)) {
                job.maximum_search_queries = parsed;
            } else if (trailing == "feasibility_frames" && !job.minimum_feasibility_bound &&
                       parse_limit(value, parsed) && parsed <= q3a::pdr::kMaximumDepth) {
                job.minimum_feasibility_bound = parsed;
            } else {
                throw invalid();
            }
        }
        result.jobs.push_back(std::move(job));
    }
    if (result.jobs.empty()) throw std::invalid_argument("batch plan requires at least one job");
    result.sha256 = q3a::sha256_hex(text);
    return result;
}

std::string read_checkpoint_file(const std::filesystem::path& path, std::uint64_t limit) {
    const auto native = q3a::bundle::detail::absolute_windows_file_path(path);
    const q3a::MemoryBudget memory;
    const auto size = std::filesystem::file_size(native);
    if (size > limit) throw std::runtime_error("batch checkpoint file exceeds its read limit");
    memory.check(size);
    q3a::WriteLockedInput input(native);
    std::string bytes(static_cast<std::size_t>(size), '\0');
    auto& stream = input.stream();
    stream.read(bytes.data(), static_cast<std::streamsize>(size));
    if (stream.gcount() != static_cast<std::streamsize>(size) || stream.peek() != std::char_traits<char>::eof() ||
        stream.bad()) throw std::runtime_error("batch checkpoint file changed while reading");
    return bytes;
}

class BatchCheckpoint {
public:
    explicit BatchCheckpoint(const std::filesystem::path& root)
        : lock_(CreateFileW(q3a::bundle::detail::absolute_windows_file_path(root / "batch.lock").c_str(),
              GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr)) {
        if (lock_ == INVALID_HANDLE_VALUE) throw std::invalid_argument("cannot acquire exclusive batch checkpoint lock");
    }
    BatchCheckpoint(const BatchCheckpoint&) = delete;
    BatchCheckpoint& operator=(const BatchCheckpoint&) = delete;
    ~BatchCheckpoint() { CloseHandle(lock_); }

private:
    HANDLE lock_;
};

std::string batch_commit(const std::string& identity, std::uint64_t attempt, const std::string& id,
                         std::string_view payload) {
    return q3a::sha256_hex(identity + '\n' + std::to_string(attempt) + '\n' +
        id + '\n' + q3a::sha256_hex(payload)) + '\n';
}

int product_batch_worker(int argc, const char* const* argv) {
    try {
        std::vector<std::string> args;
        for (int i = 2; i < argc; ++i) args.push_back(q3a::decode_batch_worker_argument(argv[i]));
        std::uint64_t memory = 0, timeout = 0;
        constexpr std::size_t proof_index = 4;
        auto timeout_index = proof_index + 3;
        while (timeout_index + 2 < args.size() && args[timeout_index] == "--parameter") {
            timeout_index += 3;
        }
        if (args.size() < proof_index + 7 || !parse_limit(args[0], memory) || memory == 0 ||
            args[proof_index + 1] != "prove" || timeout_index + 1 >= args.size() ||
            args[timeout_index] != "--timeout-ms" || !parse_limit(args[timeout_index + 1], timeout) ||
            timeout == 0 || timeout > 86400000) {
            throw std::invalid_argument("invalid batch worker invocation");
        }
        const auto log = q3a::bundle::detail::absolute_windows_file_path(std::filesystem::u8path(args[3]));
        if (!_wfreopen(log.c_str(), L"wb", stderr)) return 3;
        wchar_t executable[32768];
        const auto length = GetModuleFileNameW(nullptr, executable, 32768);
        if (length == 0 || length >= 32768) return 3;
        gExecutablePath = std::filesystem::path(executable);
        ProofCommand load(true);
        load.job_memory_mib = memory;
        load.timeout = std::chrono::milliseconds(timeout);
        auto project = load_proof_project(std::filesystem::u8path(args[proof_index + 2]), load);
        if (project.input_hash != args[1] || project.manifest_sha256 != args[2]) {
            std::cerr << "Q3A_BATCH_WORKER_ERROR source or manifest changed after admission\n";
            return 2;
        }
        std::vector<const char*> proof;
        for (std::size_t i = proof_index; i < args.size(); ++i) proof.push_back(args[i].c_str());
        std::ofstream discard("NUL");
        if (!discard) return 3;
        return product_prove(static_cast<int>(proof.size()), proof.data(), discard, false, &project, memory);
    } catch (ProofStop stop) {
        return stop == ProofStop::Timeout ? 65 : 3;
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
        return 66;
    } catch (const std::bad_alloc&) {
        return 66;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_BATCH_WORKER_ERROR " << error.what() << '\n';
        return 3;
    }
}

struct ParallelBatchJob {
    const ProofBatchJob* job;
    std::filesystem::path folder;
    std::string directory;
    std::vector<std::string> arguments;
    std::string* report;
    std::unique_ptr<q3a::BatchWorker> worker;
    ProofCommand::Clock::time_point deadline{};
};

struct ParallelBatchLimits {
    unsigned workers = 1;
    std::uint64_t coordinator_mib = 0;
    std::uint64_t worker_mib = 0;
    unsigned peak_workers = 0;
};

void run_parallel_batch(std::vector<ParallelBatchJob>& jobs, ParallelBatchLimits& limits,
                        const q3a::MemoryBudget& budget, const std::function<bool(bool)>& cancelled_now,
                        const std::string& identity, std::uint64_t attempt, int& aggregate, bool& cancelled) {
    constexpr std::uint64_t mib = 1024 * 1024;
    std::size_t next = 0;
    std::vector<ParallelBatchJob*> active;
    const auto finish = [&](ParallelBatchJob& entry, int code, std::string_view status) {
        const auto record = entry.folder / "result.json";
        std::string payload;
        if (status.empty()) {
            const auto bytes = std::filesystem::file_size(q3a::bundle::detail::absolute_windows_file_path(record));
            budget.check(bytes);
            payload = read_checkpoint_file(record, 64ULL * mib);
            if (!payload.empty() && payload.back() == '\n') payload.pop_back();
        } else {
            std::ostringstream result;
            result << "{\"schema_version\":1,\"exit_code\":" << code << ",\"status\":" << std::quoted(std::string(status));
            if (status == "RESOURCE_LIMIT") result << ",\"resource_limit\":\"memory\"";
            result << '}';
            payload = result.str();
            auto event = record;
            if (std::filesystem::exists(q3a::bundle::detail::absolute_windows_file_path(record))) {
                event = entry.folder / "controller-result.json";
                *entry.report += ",\"result_record\":\"controller-result.json\"";
            }
            write_run_record(event, payload + '\n');
        }
        if (code == 0) {
            write_run_record(entry.folder / "checkpoint.commit", batch_commit(identity, attempt, entry.job->id, payload));
        }
        aggregate = std::max(aggregate, code);
        std::ostringstream suffix;
        suffix << ",\"result_directory\":" << std::quoted(entry.directory) << ",\"reused\":false";
        if (entry.worker) suffix << ",\"worker_peak_commit_bytes\":" << entry.worker->peak_commit_bytes();
        suffix << ",\"result\":" << payload << '}';
        *entry.report += suffix.str();
        entry.worker.reset();
    };

    while (next < jobs.size() || !active.empty()) {
        cancelled = cancelled || cancelled_now(true);
        for (auto it = active.begin(); it != active.end();) {
            auto& entry = **it;
            const auto exit = entry.worker->poll();
            if (!exit && !cancelled && ProofCommand::Clock::now() < entry.deadline) {
                ++it;
                continue;
            }
            if (!exit) {
                entry.worker->stop(1);
                finish(entry, 1, cancelled ? "CANCELLED" : "TIMEOUT");
            } else if (*exit <= 3 && std::filesystem::is_regular_file(
                           q3a::bundle::detail::absolute_windows_file_path(entry.folder / "result.json"))) {
                finish(entry, static_cast<int>(*exit), {});
            } else {
                const bool memory = *exit == 66 || *exit == 0xc0000017UL || *exit == 0xc000012dUL;
                const bool timeout = *exit == 65;
                finish(entry, memory || timeout ? 1 : *exit == 2 ? 2 : 3,
                       memory ? "RESOURCE_LIMIT" : timeout ? "TIMEOUT" : *exit == 2 ? "SETUP_ERROR" : "ENGINE_ERROR");
            }
            it = active.erase(it);
        }
        if (cancelled) {
            while (next < jobs.size()) *jobs[next++].report += ",\"result\":{\"status\":\"NOT_RUN\"}}";
            break;
        }
        while (next < jobs.size() && active.size() < limits.workers) {
            if (cancelled_now(true)) { cancelled = true; break; }
            const auto reservation = (active.size() + 1) * limits.worker_mib * mib;
            if (!q3a::can_reserve_physical_memory(reservation, budget.physical_reserve_bytes())) {
                if (!active.empty()) break;
                finish(jobs[next++], 1, "RESOURCE_LIMIT");
                continue;
            }
            auto& entry = jobs[next++];
            budget.check();
            std::cerr << "Q3A_BATCH_JOB " << entry.job->id << '\n';
            entry.deadline = ProofCommand::Clock::now() + std::chrono::milliseconds(entry.job->timeout_ms);
            entry.worker = std::make_unique<q3a::BatchWorker>(entry.arguments, limits.worker_mib);
            active.push_back(&entry);
            limits.peak_workers = std::max(limits.peak_workers, static_cast<unsigned>(active.size()));
        }
        if (!active.empty()) Sleep(5);
    }
}

int product_batch(int argc, const char* const* argv) {
    constexpr std::array<const char*, 4> statuses{
        "COMPLETED", "INCONCLUSIVE", "SETUP_ERROR", "ENGINE_ERROR"};
    int error_exit = 2;
    try {
        if (argc < 7 || std::string_view(argv[3]) != "--plan" ||
            std::string_view(argv[5]) != "--output-dir") {
            throw std::invalid_argument("expected prove-batch <project.q3a> --plan <file> --output-dir <directory> [--cancel-file <path>] [--checkpoint|--resume]");
        }
        const char* cancel_file = nullptr;
        bool checkpoint = false;
        bool resume = false;
        bool workers_given = false;
        ParallelBatchLimits parallel;
        for (int i = 7; i < argc; ++i) {
            const std::string_view option(argv[i]);
            if (option == "--cancel-file" && !cancel_file && i + 1 < argc) {
                cancel_file = argv[++i];
            } else if ((option == "--checkpoint" || option == "--resume") && !checkpoint) {
                checkpoint = true;
                resume = option == "--resume";
            } else if (option == "--workers" && !workers_given && i + 1 < argc) {
                std::uint64_t count = 0;
                if (!parse_limit(argv[++i], count) || count < 1 || count > 8) {
                    throw std::invalid_argument("batch workers must be between 1 and 8");
                }
                parallel.workers = static_cast<unsigned>(count);
                workers_given = true;
            } else {
                throw std::invalid_argument("invalid or repeated batch option");
            }
        }
        const bool console_control = SetConsoleCtrlHandler(proof_console_handler, TRUE) != FALSE;
        const auto plan = read_proof_batch(std::filesystem::u8path(argv[4]));
        if (parallel.workers > 1) {
            if (!checkpoint) throw std::invalid_argument("parallel batch requires --checkpoint or --resume");
            parallel.coordinator_mib = std::max<std::uint64_t>(64, plan.memory_mib / 4);
            if (plan.memory_mib < parallel.coordinator_mib + 32ULL * parallel.workers) {
                throw std::invalid_argument("parallel batch needs 64 MiB for coordination and at least 32 MiB per worker");
            }
            parallel.worker_mib = (plan.memory_mib - parallel.coordinator_mib) / parallel.workers;
        }
        ProofCommand load_control(true);
        load_control.job_memory_mib = parallel.coordinator_mib;
        load_control.console_control = console_control;
        if (cancel_file) {
            load_control.cancel_file = std::filesystem::absolute(std::filesystem::u8path(cancel_file)).lexically_normal();
        }
        std::optional<q3a::ProjectInput> project;
        std::string_view load_cancellation;
        try {
            project.emplace(load_proof_project(std::filesystem::u8path(argv[2]), load_control));
            load_control.check_control(true);
        } catch (ProofStop reason) {
            load_cancellation = cancellation_cause(reason);
            if (load_cancellation.empty()) {
                error_exit = 3;
                throw std::runtime_error("cannot inspect batch cancel-file control");
            }
            project.reset();
            std::cerr << "Q3A_BATCH_CANCELLED cause=" << load_cancellation << " phase=source_loading\n";
        }
        const auto root = std::filesystem::absolute(std::filesystem::u8path(argv[6])).lexically_normal();
        if (checkpoint && !project) {
            std::cout << "{\"schema_version\":1,\"exit_code\":1,\"status\":\"CANCELLED\","
                "\"cancellation_stage\":\"source_loading\",\"jobs\":[]}\n";
            return 1;
        }
        if (!resume && !std::filesystem::create_directory(q3a::bundle::detail::windows_file_path(root))) {
            throw std::invalid_argument("batch output directory already exists");
        }
        std::optional<BatchCheckpoint> checkpoint_lock;
        std::uint64_t attempt = 0;
        auto run_directory = root;
        std::string checkpoint_identity;
        const auto attempt_directory = [&](std::uint64_t index) {
            return root / ("attempt-" + std::to_string(index));
        };
        const auto is_directory = [](const std::filesystem::path& directory) {
            return std::filesystem::is_directory(q3a::bundle::detail::absolute_windows_file_path(directory));
        };
        if (checkpoint) {
            checkpoint_lock.emplace(root);
            const auto identity_file = root / "checkpoint.identity";
            const auto identity = std::string("Q3AFORMAL_BATCH_CHECKPOINT 1\n") + plan.sha256 + '\n' +
                project->input_hash + '\n' + project->manifest_sha256 + '\n' + q3a::build_info::kBuildId + '\n' +
                q3a::build_info::kComponentHash_proof_checker + '\n';
            checkpoint_identity = q3a::sha256_hex(identity);
            if (resume) {
                if (read_checkpoint_file(identity_file, 1024) != identity) {
                    throw std::invalid_argument("batch checkpoint identity differs from the current inputs or build");
                }
            } else {
                write_run_record(identity_file, identity);
            }
            attempt = 1;
            while (is_directory(attempt_directory(attempt))) ++attempt;
            run_directory = attempt_directory(attempt);
            if (!std::filesystem::create_directory(q3a::bundle::detail::absolute_windows_file_path(run_directory))) {
                throw std::runtime_error("cannot create a new checkpoint attempt directory");
            }
        }
        error_exit = 3;
        if (checkpoint && parallel.workers == 1) load_control.job_memory_mib = plan.memory_mib;
        const auto checkpoint_budget = load_control.budget();
        const auto checkpoint_cancelled = [&](bool force) {
            try {
                load_control.check_control(force);
                return false;
            } catch (ProofStop reason) {
                const auto cause = cancellation_cause(reason);
                if (cause.empty()) throw std::runtime_error("cannot inspect checkpoint cancel-file control");
                std::cerr << "Q3A_BATCH_CANCELLED cause=" << cause << " phase=checkpoint\n";
                return true;
            }
        };
        std::vector<std::string> job_reports(plan.jobs.size());
        std::vector<ParallelBatchJob> pending;
        int aggregate = 0;
        bool cancelled = !load_cancellation.empty();
        for (std::size_t index = 0; index < plan.jobs.size(); ++index) {
            const auto& job = plan.jobs[index];
            auto& job_report = job_reports[index];
            std::ostringstream jobs;
            const auto folder_name = "job-" + job.id;
            jobs << "{\"id\":" << std::quoted(job.id)
                 << ",\"engine\":" << std::quoted(job.engine)
                 << ",\"property\":" << std::quoted(job.property)
                 << ",\"depth\":" << job.depth << ",\"timeout_ms\":" << job.timeout_ms;
            if (job.maximum_search_queries) {
                jobs << ",\"max_queries\":" << *job.maximum_search_queries;
            }
            if (job.minimum_feasibility_bound) {
                jobs << ",\"feasibility_frames\":" << *job.minimum_feasibility_bound;
            }
            if (plan.version == 3) {
                jobs << ",\"parameter_overrides\":{";
                const char* separator = "";
                for (const auto& [name, value] : job.parameters) {
                    jobs << separator << q3a::bundle::json_string(name) << ':' << q3a::bundle::json_string(value);
                    separator = ",";
                }
                jobs << '}';
            }
            if (!cancelled && checkpoint) cancelled = checkpoint_cancelled(true);
            if (cancelled) {
                jobs << ",\"result\":{\"status\":\"NOT_RUN\"}}";
                job_report = jobs.str();
                continue;
            }
            bool reused = false;
            for (auto prior = attempt; resume && prior > 1 && !reused;) {
                --prior;
                const auto folder = attempt_directory(prior) / folder_name;
                const auto marker = folder / "checkpoint.commit";
                if (!std::filesystem::exists(q3a::bundle::detail::absolute_windows_file_path(marker))) continue;
                auto payload = read_checkpoint_file(folder / "result.json", 64ULL * 1024 * 1024);
                if (!payload.empty() && payload.back() == '\n') payload.pop_back();
                if (read_checkpoint_file(marker, 128) != batch_commit(checkpoint_identity, prior, job.id, payload)) {
                    throw std::runtime_error("committed batch result digest differs for job " + job.id);
                }
                try {
                    std::optional<q3a::lowering::TIRModule> pdr_model;
                    std::optional<q3a::ProjectInput> configured;
                    checkpoint_budget.check();
                    if (!job.parameters.empty()) {
                        configured.emplace(*project);
                        q3a::SourceManager::apply_parameter_overrides(*configured, job.parameters);
                    }
                    const auto& effective = configured ? *configured : *project;
                    if (job.engine == "pdr") pdr_model.emplace(lower_project_tir(effective));
                    q3a::bundle::verify_batch_checkpoint(folder, effective, payload, job.engine, job.property,
                        job.depth, job.timeout_ms, plan.memory_mib,
                        job.maximum_search_queries.value_or(q3a::pdr::kDefaultSearchQueries),
                        job.minimum_feasibility_bound.value_or(0), pdr_model ? &*pdr_model : nullptr, checkpoint_budget);
                    cancelled = checkpoint_cancelled(true);
                } catch (ProofStop reason) {
                    const auto cause = cancellation_cause(reason);
                    if (cause.empty()) throw std::runtime_error("cannot inspect checkpoint cancel-file control");
                    std::cerr << "Q3A_BATCH_CANCELLED cause=" << cause << " phase=checkpoint\n";
                    cancelled = true;
                }
                if (cancelled) break;
                jobs << ",\"result_directory\":" << std::quoted("attempt-" + std::to_string(prior) + "/" + folder_name)
                     << ",\"reused\":true,\"result\":" << payload << '}';
                reused = true;
            }
            if (reused || cancelled) {
                if (cancelled) jobs << ",\"result\":{\"status\":\"NOT_RUN\"}}";
                job_report = jobs.str();
                continue;
            }
            const auto folder = run_directory / folder_name;
            if (!std::filesystem::create_directory(q3a::bundle::detail::windows_file_path(folder))) {
                throw std::runtime_error("batch job output directory already exists");
            }
            const auto record = (folder / "result.json").u8string();
            const auto depth_option = job.engine == "pdr" ? "--max-depth" :
                job.engine == "induction" ? "--k" : "--frames";
            std::vector<std::string> arguments{
                argv[0], "prove", argv[2], "--timeout-ms", std::to_string(job.timeout_ms),
                "--run-record", record, "--engine", job.engine, "--property", job.property,
                depth_option, std::to_string(job.depth)};
            if (cancel_file && parallel.workers == 1) {
                arguments.insert(arguments.begin() + 5, {"--cancel-file", cancel_file});
            }
            std::vector<std::string> overrides;
            for (const auto& [name, value] : job.parameters) {
                overrides.insert(overrides.end(), {"--parameter", name, value});
            }
            arguments.insert(arguments.begin() + 3, overrides.begin(), overrides.end());
            if (job.engine == "bmc") {
                arguments.insert(arguments.end(), {"--bundle-dir", (folder / "bundle").u8string()});
            } else if (job.engine == "induction") {
                arguments.insert(arguments.end(),
                    {"--output-prefix", (folder / "proof").u8string(), "--bundle-dir", (folder / "bundle").u8string()});
            } else {
                arguments.insert(arguments.end(),
                    {"--evidence-dir", (folder / "certificate").u8string(), "--bundle-dir", (folder / "bundle").u8string()});
                if (job.maximum_search_queries) {
                    arguments.insert(arguments.end(), {"--max-queries", std::to_string(*job.maximum_search_queries)});
                }
                if (job.minimum_feasibility_bound) {
                    arguments.insert(arguments.end(),
                        {"--feasibility-frames", std::to_string(*job.minimum_feasibility_bound)});
                }
            }
            const auto result_directory = checkpoint
                ? "attempt-" + std::to_string(attempt) + "/" + folder_name : folder_name;
            if (parallel.workers > 1) {
                arguments.insert(arguments.begin(), {project->input_hash, project->manifest_sha256,
                    (folder / "worker.stderr.txt").u8string()});
                job_report = jobs.str();
                pending.push_back({&job, folder, result_directory, std::move(arguments), &job_report, nullptr, {}});
                continue;
            }
            std::vector<const char*> pointers;
            for (const auto& argument : arguments) pointers.push_back(argument.c_str());
            std::ostringstream result;
            std::string status;
            std::cerr << "Q3A_BATCH_JOB " << job.id << '\n';
            const auto code = product_prove(static_cast<int>(pointers.size()), pointers.data(),
                result, console_control, &*project, plan.memory_mib, &status);
            auto payload = result.str();
            if (!payload.empty() && payload.back() == '\n') payload.pop_back();
            aggregate = std::max(aggregate, code);
            cancelled = status == "CANCELLED";
            if (checkpoint && code == 0) {
                write_run_record(folder / "checkpoint.commit", batch_commit(checkpoint_identity, attempt, job.id, payload));
            }
            jobs << ",\"result_directory\":" << std::quoted(result_directory);
            if (checkpoint) jobs << ",\"reused\":false";
            jobs << ",\"result\":" << payload << '}';
            job_report = jobs.str();
        }
        if (parallel.workers > 1) {
            const q3a::MemoryBudget scheduler_budget({}, parallel.coordinator_mib);
            run_parallel_batch(pending, parallel, scheduler_budget, checkpoint_cancelled,
                               checkpoint_identity, attempt, aggregate, cancelled);
        }
        const auto code = cancelled ? 1 : aggregate;
        std::ostringstream report;
        report << "{\"schema_version\":1,\"exit_code\":" << code
               << ",\"status\":" << std::quoted(cancelled ? "CANCELLED" : statuses.at(aggregate))
               << ",\"plan_sha256\":" << std::quoted(plan.sha256)
               << ",\"build_id\":" << std::quoted(q3a::build_info::kBuildId);
        if (project) {
            report << ",\"source_set_sha256\":" << std::quoted(project->input_hash);
        } else {
            report << ",\"cancellation_cause\":" << std::quoted(load_cancellation)
                   << ",\"cancellation_stage\":\"source_loading\"";
        }
        report << ",\"memory_mib\":" << plan.memory_mib << ",\"workers\":" << parallel.workers;
        if (parallel.workers > 1) {
            report << ",\"coordinator_memory_mib\":" << parallel.coordinator_mib
                   << ",\"worker_memory_mib\":" << parallel.worker_mib
                   << ",\"peak_workers\":" << parallel.peak_workers;
        }
        if (plan.version >= 2) report << ",\"plan_schema_version\":" << plan.version;
        if (checkpoint) report << ",\"checkpoint_attempt\":" << attempt;
        report << ",\"jobs\":[";
        if (parallel.workers > 1) {
            std::uint64_t total = 0;
            for (const auto& row : job_reports) total += row.size();
            q3a::MemoryBudget({}, parallel.coordinator_mib).check(3 * total);
        }
        for (std::size_t i = 0; i < job_reports.size(); ++i) {
            if (i != 0) report << ',';
            report << job_reports[i];
        }
        report << "]}\n";
        const auto payload = report.str();
        write_run_record(run_directory / "batch.json", payload);
        std::cout << payload;
        return code;
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
        std::cout << "{\"schema_version\":1,\"exit_code\":1,\"status\":\"INCONCLUSIVE\","
            "\"resource_limit\":\"memory\",\"jobs\":[]}\n";
        return 1;
    } catch (const std::bad_alloc&) {
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY batch allocation failed\n";
        std::cout << "{\"schema_version\":1,\"exit_code\":1,\"status\":\"INCONCLUSIVE\","
            "\"resource_limit\":\"memory\",\"jobs\":[]}\n";
        return 1;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_BATCH_ERROR " << error.what() << '\n';
        std::cout << "{\"schema_version\":1,\"exit_code\":" << error_exit << ",\"status\":"
                  << std::quoted(statuses.at(error_exit)) << ",\"jobs\":[]}\n";
        return error_exit;
    }
}

int product_composition(int argc, const char* const* argv, bool reopen) {
    try {
        const auto directory_option = reopen ? "--evidence-dir" : "--output-dir";
        if (argc < 7 || std::string_view(argv[3]) != "--plan" || std::string_view(argv[5]) != directory_option) {
            throw std::invalid_argument("expected PROJECT --plan FILE and an evidence directory");
        }
        ProofCommand control(true);
        control.console_control = SetConsoleCtrlHandler(proof_console_handler, TRUE) != FALSE;
        for (int i = 7; i < argc; i += 2) {
            if (i + 1 == argc) throw std::invalid_argument("composition option is missing a value");
            const std::string_view option(argv[i]);
            if (option == "--cancel-file" && control.cancel_file.empty()) {
                control.cancel_file = std::filesystem::absolute(std::filesystem::u8path(argv[i + 1]));
                continue;
            }
            std::uint64_t number = 0;
            if (!parse_limit(argv[i + 1], number) || number == 0) {
                throw std::invalid_argument("composition limits must be positive integers");
            }
            if (option == "--timeout-ms" && control.timeout.count() == 0 && number <= 86400000) {
                control.timeout = std::chrono::milliseconds(number);
            } else if (option == "--memory-mib" && control.job_memory_mib == 0 && number <= 65536) {
                control.job_memory_mib = number;
            } else {
                throw std::invalid_argument("invalid or repeated composition limit");
            }
        }
        const auto memory = control.budget();
        memory.check();
        const auto project = load_proof_project(std::filesystem::u8path(argv[2]), control);
        const auto model = lower_project_tir(project);
        memory.check();
        return q3a::composition::check(model, std::filesystem::u8path(argv[4]), std::filesystem::u8path(argv[6]),
            project.manifest_sha256, reopen, memory, std::cout);
    } catch (ProofStop stop) {
        const auto status = stop == ProofStop::Timeout ? "TIMEOUT" :
            cancellation_cause(stop).empty() ? "ENGINE_ERROR" : "CANCELLED";
        std::cout << "{\"status\":" << std::quoted(status) << "}\n";
        return stop == ProofStop::ControlError ? 3 : 1;
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cerr << "Q3A_COMPOSITION_RESOURCE " << error.what() << '\n';
    } catch (const std::bad_alloc&) {
        std::cerr << "Q3A_COMPOSITION_RESOURCE allocation failed\n";
    } catch (const std::exception& error) {
        std::cerr << "Q3A_COMPOSITION_ERROR " << error.what() << '\n';
        std::cout << "{\"status\":\"REJECTED\"}\n";
        return 2;
    }
    std::cout << "{\"status\":\"RESOURCE_LIMIT\"}\n";
    return 1;
}

int product_equivalence(int argc, const char* const* argv, bool reopen) {
    try {
        const auto directory_option = reopen ? "--evidence-dir" : "--output-dir";
        if (argc < 8 || std::string_view(argv[4]) != "--plan" || std::string_view(argv[6]) != directory_option) {
            throw std::invalid_argument("expected REFERENCE IMPLEMENTATION --plan FILE and an evidence directory");
        }
        ProofCommand control(true);
        control.console_control = SetConsoleCtrlHandler(proof_console_handler, TRUE) != FALSE;
        std::size_t depth = 32;
        bool depth_given = false;
        for (int i = 8; i < argc; i += 2) {
            if (i + 1 == argc) throw std::invalid_argument("equivalence option is missing a value");
            const std::string_view option(argv[i]);
            if (option == "--cancel-file" && control.cancel_file.empty()) {
                control.cancel_file = std::filesystem::absolute(std::filesystem::u8path(argv[i + 1]));
                continue;
            }
            std::uint64_t value = 0;
            if (!parse_limit(argv[i + 1], value) || value == 0) {
                throw std::invalid_argument("equivalence limits must be positive integers");
            }
            if (option == "--timeout-ms" && control.timeout.count() == 0 && value <= 86400000) {
                control.timeout = std::chrono::milliseconds(value);
            } else if (option == "--memory-mib" && control.job_memory_mib == 0 && value <= 65536) {
                control.job_memory_mib = value;
            } else if (option == "--max-depth" && !reopen && !depth_given && value <= q3a::pdr::kMaximumDepth) {
                depth = static_cast<std::size_t>(value);
                depth_given = true;
            } else {
                throw std::invalid_argument("invalid or repeated equivalence option");
            }
        }
        const auto memory = control.budget();
        const auto load = [&](const char* path) {
            memory.check();
            const auto project = load_proof_project(std::filesystem::u8path(path), control);
            q3a::equivalence::Design design;
            design.manifest_sha256 = project.manifest_sha256;
            design.model = lower_project_tir(project, &design.ports);
            return design;
        };
        const auto reference = load(argv[2]);
        const auto implementation = load(argv[3]);
        return q3a::equivalence::check(reference, implementation, std::filesystem::u8path(argv[5]),
            std::filesystem::u8path(argv[7]), reopen, depth, memory, std::cout);
    } catch (ProofStop stop) {
        const auto status = stop == ProofStop::Timeout ? "TIMEOUT" :
            cancellation_cause(stop).empty() ? "ENGINE_ERROR" : "CANCELLED";
        std::cout << "{\"status\":" << std::quoted(status) << "}\n";
        return stop == ProofStop::ControlError ? 3 : 1;
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cerr << "Q3A_EQUIVALENCE_RESOURCE " << error.what() << '\n';
    } catch (const std::bad_alloc&) {
        std::cerr << "Q3A_EQUIVALENCE_RESOURCE allocation failed\n";
    } catch (const std::exception& error) {
        std::cerr << "Q3A_EQUIVALENCE_ERROR " << error.what() << '\n';
        std::cout << "{\"status\":\"REJECTED\"}\n";
        return 2;
    }
    std::cout << "{\"status\":\"RESOURCE_LIMIT\"}\n";
    return 1;
}

#ifdef Q3A_ENABLE_DEVELOPMENT_MEMORY
enum class DevelopmentMemoryMode { Prove, VerifyProof, VerifyRange, DebugRange };

int development_memory(int argc, const char* const* argv, DevelopmentMemoryMode mode) {
    const bool proving = mode == DevelopmentMemoryMode::Prove;
    const bool verify_range = mode == DevelopmentMemoryMode::VerifyRange;
    const bool debug_range = mode == DevelopmentMemoryMode::DebugRange;
    const auto report = [](const char* status, int exit_code) {
        std::cout << "{\"schema_version\":1,\"status\":" << std::quoted(status)
                  << ",\"exit_code\":" << exit_code << "}\n";
        return exit_code;
    };
    try {
        const auto evidence_option = (verify_range || debug_range) ? "--trace" : proving ? "--output-dir" : "--evidence-dir";
        if (argc < 9 || std::string_view(argv[3]) != "--property" || std::string_view(argv[5]) != evidence_option ||
            std::string_view(argv[7]) != "--max-cells") {
            throw std::invalid_argument("expected PROJECT --property NAME, the evidence path, and --max-cells N");
        }
        std::uint64_t cells = 0;
        if (!parse_limit(argv[8], cells) || cells == 0) {
            throw std::invalid_argument("maximum memory cell count must be positive");
        }
        ProofCommand control(true);
        control.console_control = SetConsoleCtrlHandler(proof_console_handler, TRUE) != FALSE;
        std::set<std::string_view> seen;
        std::size_t depth = 32;
        std::size_t queries = q3a::pdr::kDefaultSearchQueries;
        bool diagnose_range = false;
        std::filesystem::path range_trace;
        std::filesystem::path test_session;
        std::optional<std::size_t> activation_bound;
        for (int i = 9; i < argc;) {
            const std::string_view option(argv[i++]);
            if (!seen.insert(option).second) throw std::invalid_argument("memory proof option is repeated");
            if (option == "--diagnose-range") {
                if (!proving) throw std::invalid_argument("range diagnosis applies only to memory proof search");
                diagnose_range = true;
                continue;
            }
            if (i == argc) throw std::invalid_argument("memory proof option has no value");
            const auto* raw = argv[i++];
            if (option == "--test-session" && debug_range) {
                test_session = std::filesystem::absolute(std::filesystem::u8path(raw));
                continue;
            }
            if (option == "--range-trace" && proving) {
                range_trace = std::filesystem::u8path(raw);
                if (range_trace.empty()) throw std::invalid_argument("memory range trace requires a file path");
                continue;
            }
            if (option == "--cancel-file") {
                control.cancel_file = std::filesystem::absolute(std::filesystem::u8path(raw));
                continue;
            }
            std::uint64_t value = 0;
            if (!parse_limit(raw, value)) throw std::invalid_argument("invalid memory proof limit");
            if (option == "--activation-frames" && !verify_range && !debug_range && value <= q3a::pdr::kMaximumDepth) {
                activation_bound = static_cast<std::size_t>(value);
                continue;
            }
            if (value == 0) throw std::invalid_argument("memory proof limits must be positive integers");
            if (option == "--max-depth" && proving && value <= q3a::pdr::kMaximumDepth) {
                depth = static_cast<std::size_t>(value);
            } else if (option == "--max-queries" && proving && value <= std::numeric_limits<std::size_t>::max()) {
                queries = static_cast<std::size_t>(value);
            } else if (option == "--timeout-ms" && value <= 86400000) {
                control.timeout = std::chrono::milliseconds(value);
            } else if (option == "--memory-mib" && value <= 65536) {
                control.job_memory_mib = value;
            } else {
                throw std::invalid_argument("invalid memory proof limit");
            }
        }

        const auto memory = control.budget();
        memory.check();
        const auto project = load_proof_project(std::filesystem::u8path(argv[2]), control);
        constexpr auto profile = "Q3A-EXACT-MEMORY-DEVELOPMENT";
        const auto input_identity = q3a::sha256_hex(std::string(profile) + "\n" + project.input_hash +
                                                   "\n" + project.manifest_sha256);
        const auto units = parse_project_units(project, q3a::frontend::SyntaxProfile::ExactMemoryDevelopment);
        if (units.size() != 1) {
            throw std::invalid_argument("the development memory project requires one source unit");
        }
        const auto design = q3a::elaboration::elaborate_top(units, project.top_module,
            project.parameters, profile, input_identity);
        const auto model = q3a::lowering::lower_exact_memory_source(units.front(), design, cells, &memory);
        memory.check();

        using q3a::memory_proof::Outcome;
        const auto evidence = std::filesystem::u8path(argv[6]);
        if (debug_range) {
            const auto session = q3a::bundle::open_memory_range_debug_session(evidence, model, project, argv[4], memory);
            const auto result = q3a::debug::run_native_debug(session, test_session);
            return result == 0 && !test_session.empty() ? report("DEBUG_SESSION_VERIFIED", 0) : result;
        }
        const auto result = verify_range
            ? q3a::memory_proof::Result{Outcome::RangeUnproved, argv[4],
                q3a::memory_proof::reopen_range_trace(model, argv[4], evidence, memory)}
            : q3a::memory_proof::check(model, argv[4], evidence, !proving, depth, queries, memory,
                                      diagnose_range, range_trace, activation_bound);
        const char* status = result.outcome == Outcome::Proven ? (proving ? "PROVEN" : "REVALIDATED")
            : result.outcome == Outcome::Inconsistent ? "INCONSISTENT"
            : result.outcome == Outcome::RangeUnproved ? "RANGE_UNPROVED" : "PROPERTY_UNPROVED";
        int exit_code = result.outcome == Outcome::Proven ? 0 : 1;
        if (verify_range) {
            const bool pending = result.range_witness->boundary_incomplete;
            status = pending ? "RANGE_WITNESS_PENDING_ASSUMPTION" : "RANGE_WITNESS_REVALIDATED";
            exit_code = pending ? 1 : 0;
        }
        using q3a::bundle::json_string;
        std::cout << "{\"schema_version\":1,\"status\":" << std::quoted(status) << ",\"exit_code\":" << exit_code
                  << ",\"profile\":" << json_string(profile) << ",\"property\":" << json_string(result.property)
                  << ",\"model_input_sha256\":" << json_string(input_identity)
                  << ",\"source_set_sha256\":" << json_string(project.input_hash)
                  << ",\"manifest_sha256\":" << json_string(project.manifest_sha256);
        if (result.inconsistent_bound) {
            std::cout << ",\"inconsistent_bound\":" << *result.inconsistent_bound;
        }
        if (result.activation) {
            using q3a::memory_proof::ActivationStatus;
            const auto& checked = *result.activation;
            const char* label = "UNKNOWN";
            switch (checked.status) {
                case ActivationStatus::Activated: label = "ACTIVATED"; break;
                case ActivationStatus::PendingAssumption: label = "PENDING_ASSUMPTION"; break;
                case ActivationStatus::NotFoundWithinBound: label = "NOT_FOUND_WITHIN_BOUND"; break;
                case ActivationStatus::Inconsistent: label = "INCONSISTENT"; break;
                case ActivationStatus::Unknown: break;
            }
            std::cout << ",\"activation\":{\"status\":" << json_string(label)
                      << ",\"transition_bound\":" << checked.bound;
            if (checked.frame) std::cout << ",\"frame\":" << *checked.frame;
            std::cout << '}';
        }
        if (result.range_witness) {
            if (!range_trace.empty()) std::cout << ",\"range_trace_saved\":true";
            const auto& witness = *result.range_witness;
            std::cout << ",\"range_witness\":{\"frame\":" << witness.frame
                      << ",\"boundary_incomplete\":" << (witness.boundary_incomplete ? "true" : "false")
                      << ",\"accesses\":[";
            const char* separator = "";
            for (const auto& access : witness.accesses) {
                std::cout << separator << "{\"property\":" << json_string(access.property)
                          << ",\"file\":" << json_string(access.location.file)
                          << ",\"line\":" << access.location.line << ",\"column\":" << access.location.column
                          << ",\"address_signal\":" << json_string(access.address_signal)
                          << ",\"address\":" << json_string(std::to_string(access.address))
                          << ",\"first\":" << json_string(std::to_string(access.first))
                          << ",\"last\":" << json_string(std::to_string(access.last)) << '}';
                separator = ",";
            }
            std::cout << "]}";
        }
        std::cout << "}\n";
        return exit_code;
    } catch (ProofStop stop) {
        if (stop == ProofStop::ControlError) return report("ENGINE_ERROR", 3);
        return report(stop == ProofStop::Timeout ? "TIMEOUT" : "CANCELLED", 1);
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cerr << "Q3A_MEMORY_RESOURCE " << error.what() << '\n';
        return report("RESOURCE_LIMIT", 1);
    } catch (const std::bad_alloc&) {
        return report("RESOURCE_LIMIT", 1);
    } catch (const std::exception& error) {
        std::cerr << "Q3A_MEMORY_ERROR " << error.what() << '\n';
        return report("REJECTED", 2);
    }
}
#endif

#ifdef Q3A_ENABLE_DEVELOPMENT_EVENT_MASK
enum class DevelopmentEventMode { Check, Replay, Prove, VerifyProof, Debug };

int development_events(int argc, const char* const* argv, DevelopmentEventMode mode) {
    const bool bounded = mode == DevelopmentEventMode::Check;
    const bool proving = mode == DevelopmentEventMode::Prove;
    const bool debug = mode == DevelopmentEventMode::Debug;
    const bool reopen = debug || mode == DevelopmentEventMode::Replay || mode == DevelopmentEventMode::VerifyProof;
    const auto plain = [](const char* status, int code) {
        std::cout << "{\"schema_version\":1,\"status\":" << std::quoted(status)
                  << ",\"exit_code\":" << code << "}\n";
        return code;
    };
    try {
        const auto directory_option = reopen ? "--evidence-dir" : "--output-dir";
        const int option_start = bounded ? 9 : 7;
        if (argc < option_start || std::string_view(argv[3]) != "--property" ||
            std::string_view(argv[5]) != directory_option ||
            (bounded && std::string_view(argv[7]) != "--frames")) {
            throw std::invalid_argument("expected PROJECT --property NAME and an event evidence directory; checking also takes --frames N");
        }
        std::uint64_t steps = 0;
        if (bounded && (!parse_limit(argv[8], steps) || steps > 10000)) {
            throw std::invalid_argument("event window transition count must be in 0..10000");
        }
        ProofCommand control(true);
        control.console_control = SetConsoleCtrlHandler(proof_console_handler, TRUE) != FALSE;
        std::set<std::string_view> seen;
        std::size_t maximum_depth = 32;
        std::size_t maximum_queries = q3a::pdr::kDefaultSearchQueries;
        std::size_t feasibility_bound = 0;
        std::filesystem::path test_session;
        for (int i = option_start; i < argc; i += 2) {
            const std::string_view option(argv[i]);
            if (i + 1 == argc || !seen.insert(option).second) {
                throw std::invalid_argument("event command option has no value or is repeated");
            }
            if (option == "--cancel-file") {
                control.cancel_file = std::filesystem::absolute(std::filesystem::u8path(argv[i + 1]));
                continue;
            }
            if (debug && option == "--test-session") {
                test_session = std::filesystem::absolute(std::filesystem::u8path(argv[i + 1]));
                continue;
            }
            std::uint64_t value = 0;
            if (!parse_limit(argv[i + 1], value) || value == 0) {
                throw std::invalid_argument("event command limits must be positive integers");
            }
            if (option == "--timeout-ms" && value <= 86400000) control.timeout = std::chrono::milliseconds(value);
            else if (option == "--memory-mib" && value <= 65536) control.job_memory_mib = value;
            else if (proving && option == "--max-depth" && value <= q3a::pdr::kMaximumDepth) {
                maximum_depth = static_cast<std::size_t>(value);
            } else if (proving && option == "--max-queries" && value <= std::numeric_limits<std::size_t>::max()) {
                maximum_queries = static_cast<std::size_t>(value);
            } else if (proving && option == "--feasibility-frames" && value <= q3a::pdr::kMaximumDepth) {
                feasibility_bound = static_cast<std::size_t>(value);
            } else throw std::invalid_argument("invalid event command limit");
        }
        const auto memory = control.budget();
        memory.check();
        const auto project = load_proof_project(std::filesystem::u8path(argv[2]), control);
        const auto profile = q3a::lowering::kFreeEventMaskProfile;
        const auto input_identity = q3a::sha256_hex(std::string(profile) + "\n" + project.input_hash +
                                                   "\n" + project.manifest_sha256);
        const auto units = parse_project_units(project, q3a::frontend::SyntaxProfile::Released);
        const auto design = q3a::elaboration::elaborate_top(units, project.top_module,
            project.parameters, profile, input_identity);
        const auto model = q3a::lowering::lower_free_event_mask(units, design);
        const std::string property = argv[4];
        const auto requested_evidence = std::filesystem::u8path(argv[6]);
        const auto evidence = q3a::bundle::detail::absolute_windows_file_path(requested_evidence);
        const auto report = [&](const char* status, int code, const q3a::trace::EventWitnessLocation* witness,
                                const q3a::pdr::CheckedCertificate* certificate = nullptr,
                                const std::string* configuration_hash = nullptr) {
            using q3a::bundle::json_string;
            std::cout << "{\"schema_version\":1,\"status\":" << std::quoted(status)
                      << ",\"exit_code\":" << code << ",\"profile\":" << json_string(profile)
                      << ",\"property\":" << json_string(property)
                      << ",\"model_input_sha256\":" << json_string(input_identity)
                      << ",\"source_set_sha256\":" << json_string(project.input_hash)
                      << ",\"manifest_sha256\":" << json_string(project.manifest_sha256)
                      << ",\"schedule\":\"FREE_EVENT_MASK\"";
            if (witness || bounded) {
                std::cout << ",\"global_frames\":" << (witness ? witness->frame_count : steps + 1);
            }
            if (certificate) {
                std::cout << ",\"certificate_model_sha256\":" << json_string(certificate->model_sha256)
                          << ",\"run_configuration_sha256\":" << json_string(*configuration_hash)
                          << ",\"obligations\":[";
                const char* separator = "";
                for (const auto& obligation : certificate->obligations) {
                    std::cout << separator << "{\"kind\":" << json_string(obligation.kind)
                              << ",\"query_sha256\":" << json_string(obligation.query_sha256)
                              << ",\"proof_sha256\":" << json_string(obligation.proof_sha256) << '}';
                    separator = ",";
                }
                std::cout << ']';
            }
            if (witness) {
                std::cout << ",\"witness_revalidated\":true,\"global_step\":" << witness->global_step
                          << ",\"domain\":" << json_string(witness->domain)
                          << ",\"domain_sample\":" << witness->domain_sample
                          << ",\"open_assumption\":" << (witness->open_assumption ? "true" : "false");
            }
            std::cout << "}\n";
            return code;
        };

        memory.check();
        if (debug) {
            const auto session = q3a::bundle::open_event_debug_session(evidence, model, project, property, memory);
            const auto result = q3a::debug::run_native_debug(session, test_session);
            return result == 0 && !test_session.empty() ? plain("DEBUG_SESSION_VERIFIED", 0) : result;
        }
        if (mode == DevelopmentEventMode::Replay) {
            q3a::WriteLockedInput indexed(evidence / "witness.q3t"), schedule(evidence / "witness.schedule");
            const auto location = q3a::trace::verify_event_witness(indexed.stream(), schedule.stream(), model, property, memory);
            return location.open_assumption ? report("WITNESS_PENDING_ASSUMPTION", 1, &location)
                                            : report("REVALIDATED", 0, &location);
        }

        const auto selected = std::find_if(model.transition.properties.begin(), model.transition.properties.end(),
            [&](const auto& item) { return item.name == property; });
        if (selected == model.transition.properties.end() ||
            (selected->kind != "assert" && selected->kind != "cover")) {
            throw std::invalid_argument("event check requires a named assertion or cover");
        }
        if (mode == DevelopmentEventMode::VerifyProof) {
            if (std::filesystem::exists(evidence / "witness.q3t") ||
                std::filesystem::exists(evidence / "witness.schedule")) {
                throw std::invalid_argument("proof directory contains witness artifacts");
            }
            const auto checked = q3a::pdr::verify(model.transition, property, requested_evidence, memory);
            if (!checked) return report("RESOURCE_LIMIT", 1, nullptr);
            const auto configuration = q3a::bundle::verify_pdr_run_configuration(requested_evidence, project,
                model.transition, property, false, *checked, memory, true);
            if (!configuration) throw std::invalid_argument("event proof is missing its run configuration");
            return report("PROOF_REVALIDATED", 0, nullptr, &*checked, &*configuration);
        }
        if (proving) {
            const auto proof = q3a::pdr::search(model.transition, property, maximum_depth,
                maximum_queries, memory, feasibility_bound);
            switch (proof.status) {
            case q3a::pdr::Status::InvariantFound: {
                set_proof_configuration(control, project, model.transition, *selected, memory,
                    "pdr", maximum_depth, false, maximum_queries, feasibility_bound);
                const auto certificate = q3a::pdr::certify(model.transition, property, proof.invariant,
                    requested_evidence, memory, control.run_configuration);
                if (!certificate) return report("RESOURCE_LIMIT", 1, nullptr);
                return report(selected->kind == "cover" ? "UNREACHABLE" : "PROVEN", 0, nullptr,
                    &*certificate, &certificate->run_configuration_sha256);
            }
            case q3a::pdr::Status::CounterexampleCandidate:
                steps = std::max(proof.depth, proof.feasible_prefix_bound.value_or(0));
                break;
            case q3a::pdr::Status::Inconsistent: return report("INCONSISTENT", 1, nullptr);
            case q3a::pdr::Status::Unknown: return report("INCONCLUSIVE", 1, nullptr);
            case q3a::pdr::Status::ResourceLimited: return report("RESOURCE_LIMIT", 1, nullptr);
            }
        }

        q3a::sat::Solver solver([&](std::uint64_t bytes) { memory.check(bytes); });
        q3a::sat::TransitionCnfEncoder encoder(solver, model.transition);
        encoder.encode(steps);
        encoder.constrain_assumptions();
        const auto result = q3a::sat::classify_event_window(model, property, encoder, solver);
        using q3a::sat::EventWindowOutcome;
        if (proving && result.outcome != EventWindowOutcome::Witness) {
            return report("INCONCLUSIVE", 1, nullptr);
        }
        switch (result.outcome) {
        case EventWindowOutcome::Complete: return report("BOUNDED_COMPLETE", 1, nullptr);
        case EventWindowOutcome::Incomplete: return report("BOUNDED_INCOMPLETE", 1, nullptr);
        case EventWindowOutcome::Inconsistent: return report("INCONSISTENT", 1, nullptr);
        case EventWindowOutcome::Inconclusive: return report("INCONCLUSIVE", 1, nullptr);
        case EventWindowOutcome::Witness: break;
        }
        std::vector<q3a::replay::Frame> frames(encoder.frames().size());
        for (std::size_t frame = 0; frame < frames.size(); ++frame) {
            memory.check();
            for (const auto& [name, bits] : encoder.frames()[frame]) {
                std::uint64_t value = 0;
                for (std::size_t bit = 0; bit < bits.size(); ++bit) {
                    const auto literal = static_cast<std::int64_t>(bits[bit]);
                    const auto assignment = result.assignment.at(static_cast<std::size_t>(literal < 0 ? -literal : literal));
                    if (assignment < 0) throw std::runtime_error("event witness has an unassigned bit");
                    if ((literal > 0) == (assignment == 1)) value |= std::uint64_t{1} << bit;
                }
                frames[frame].emplace(name, value);
            }
        }
        if (!std::filesystem::create_directory(evidence)) {
            throw std::invalid_argument("event witness requires an unused evidence directory");
        }
        std::ofstream indexed(evidence / "witness.q3t", std::ios::binary);
        std::ofstream schedule(evidence / "witness.schedule", std::ios::binary);
        const auto location = q3a::trace::write_event_witness(indexed, schedule, model, property,
            frames, result.witness_frame.value(), memory);
        indexed.close();
        schedule.close();
        if (!indexed || !schedule || location.open_assumption != result.witness_has_open_assumption) {
            throw std::runtime_error("event witness publication or assumption replay failed");
        }
        if (location.open_assumption) return report("WITNESS_PENDING_ASSUMPTION", 1, &location);
        return report(selected->kind == "cover" ? "COVERED" : "FAIL", 0, &location);
    } catch (ProofStop stop) {
        if (stop == ProofStop::ControlError) return plain("ENGINE_ERROR", 3);
        return plain(stop == ProofStop::Timeout ? "TIMEOUT" : "CANCELLED", 1);
    } catch (const q3a::MemoryBudgetExceeded&) {
        return plain("RESOURCE_LIMIT", 1);
    } catch (const std::bad_alloc&) {
        return plain("RESOURCE_LIMIT", 1);
    } catch (const std::exception& error) {
        std::cerr << "Q3A_EVENT_ERROR " << error.what() << '\n';
        return plain("REJECTED", 2);
    }
}
#endif

#ifdef Q3A_ENABLE_DEVELOPMENT_LIVENESS
int development_liveness(int argc, const char* const* argv, bool reopen) {
    const auto plain = [](const char* status, int code) {
        std::cout << "{\"schema_version\":1,\"status\":" << std::quoted(status)
                  << ",\"exit_code\":" << code << "}\n";
        return code;
    };
    try {
        if (argc < 5) throw std::invalid_argument("expected PROJECT and a liveness query");
        q3a::liveness::Query query;
        std::filesystem::path evidence;
        std::filesystem::path vcd;
        ProofCommand control(true);
        control.console_control = SetConsoleCtrlHandler(proof_console_handler, TRUE) != FALSE;
        std::set<std::string_view> seen;
        for (int index = 3; index < argc;) {
            const std::string_view option(argv[index++]);
            if (index == argc || (option != "--justice" && !seen.insert(option).second)) {
                throw std::invalid_argument("missing liveness option value or repeated option");
            }
            const auto* value = argv[index++];
            if (option == "--property") {
                if (*value == '\0') throw std::invalid_argument("liveness property name is empty");
                query.property = value;
            } else if (option == "--request") {
                if (*value == '\0') throw std::invalid_argument("liveness request name is empty");
                query.request = value;
            } else if (option == "--response") {
                if (*value == '\0') throw std::invalid_argument("liveness response name is empty");
                query.response = value;
            } else if (option == "--justice") {
                if (query.justice.size() == 64) throw std::invalid_argument("too many justice signals");
                query.justice.emplace_back(value);
            } else if (option == "--evidence") {
                if (*value == '\0') throw std::invalid_argument("liveness evidence path is empty");
                evidence = std::filesystem::u8path(value);
            } else if (option == "--vcd" && reopen) {
                if (*value == '\0') throw std::invalid_argument("liveness waveform path is empty");
                vcd = std::filesystem::u8path(value);
            } else if (option == "--cancel-file") {
                control.cancel_file = std::filesystem::absolute(std::filesystem::u8path(value));
            } else {
                std::uint64_t limit = 0;
                if (!parse_limit(value, limit) || limit == 0) throw std::invalid_argument("invalid liveness limit");
                if (option == "--max-vertices" && limit <= q3a::liveness::kMaximumVertices) {
                    query.maximum_vertices = static_cast<std::size_t>(limit);
                } else if (option == "--max-edges" && limit <= q3a::liveness::kMaximumEdges) {
                    query.maximum_edges = static_cast<std::size_t>(limit);
                } else if (option == "--timeout-ms" && limit <= 86400000) {
                    control.timeout = std::chrono::milliseconds(limit);
                } else if (option == "--memory-mib" && limit <= 65536) {
                    control.job_memory_mib = limit;
                } else {
                    throw std::invalid_argument("invalid liveness option or limit");
                }
            }
        }
        if (query.property.empty() && (query.request.empty() || query.response.empty())) {
            throw std::invalid_argument("use --property NAME or both --request SIGNAL and --response SIGNAL");
        }
        if (reopen && evidence.empty()) throw std::invalid_argument("liveness verification requires --evidence FILE");
        const auto budget = control.budget();
        budget.check();
        const auto project = load_proof_project(std::filesystem::u8path(argv[2]), control);
        const auto model = lower_project_tir(project);
        const auto graph = q3a::liveness::build_source_graph(model, query, budget);
        budget.check();
        const auto model_hash = q3a::sha256_hex(q3a::lowering::serialize_tir(model));
        const q3a::liveness::EvidenceIdentity identity{model_hash, project.manifest_sha256, q3a::build_info::kBuildId};
        std::string evidence_hash;
        std::string vcd_hash;
        q3a::liveness::Result result;
        if (reopen) {
            auto checked = q3a::liveness::reopen_evidence(evidence, identity, query, graph.graph, budget);
            result = std::move(checked.result);
            evidence_hash = std::move(checked.sha256);
        } else {
            result = q3a::liveness::search(graph.graph);
            if (!q3a::liveness::validate(graph.graph, result)) return plain("ENGINE_ERROR", 3);
            budget.check();
            if (!evidence.empty()) {
                evidence_hash = q3a::liveness::save_evidence(evidence, identity, query, graph.graph, result, budget);
            }
        }
        if (!vcd.empty()) {
            if (!result.lasso) throw std::invalid_argument("liveness waveform export requires a checked loop");
            vcd_hash = q3a::liveness::save_lasso_vcd(vcd, model, graph, *result.lasso, budget);
        } else if (reopen || evidence.empty()) {
            budget.check();
        }
        using q3a::bundle::json_string;
        using q3a::liveness::Status;
        const auto status = result.status == Status::Violation ? "VIOLATION" :
            result.status == Status::NoViolation ? "NO_VIOLATION" : "NO_FAIR_EXECUTION";
        const auto code = result.status == Status::NoFairExecution ? 1 : 0;
        std::cout << "{\"schema_version\":1,\"status\":" << json_string(status)
                  << ",\"exit_code\":" << code << ",\"model_sha256\":" << json_string(model_hash)
                  << ",\"manifest_sha256\":" << json_string(project.manifest_sha256)
                  << ",\"build_id\":" << json_string(q3a::build_info::kBuildId)
                  << ",\"vertices\":" << graph.graph.states.size();
        if (query.property.empty()) {
            std::cout << ",\"request\":" << json_string(query.request)
                      << ",\"response\":" << json_string(query.response);
        } else {
            std::cout << ",\"property\":" << json_string(query.property);
        }
        std::cout << ",\"justice\":[";
        const char* separator = "";
        for (const auto& name : query.justice) {
            std::cout << separator << json_string(name);
            separator = ",";
        }
        std::cout << "],\"checked_graph_evidence\":true";
        if (!evidence_hash.empty()) {
            std::cout << ",\"evidence_sha256\":" << json_string(evidence_hash)
                      << ",\"evidence_revalidated\":" << (reopen ? "true" : "false");
        }
        if (!vcd_hash.empty()) std::cout << ",\"vcd_sha256\":" << json_string(vcd_hash);
        if (result.lasso) {
            const auto layout = [](const char* label, const auto& signals) {
                std::cout << ",\"" << label << "\":[";
                const char* comma = "";
                for (const auto* signal : signals) {
                    std::cout << comma << "{\"name\":" << json_string(signal->name)
                              << ",\"width\":" << signal->width << '}';
                    comma = ",";
                }
                std::cout << ']';
            };
            layout("state_layout", graph.state_layout);
            layout("input_layout", graph.input_layout);
            std::cout << ",\"loop_start\":" << result.lasso->loop_start << ",\"path\":[";
            separator = "";
            for (const auto vertex : result.lasso->path) {
                const auto& sample = graph.samples[vertex];
                std::cout << separator << "{\"state\":" << sample.packed_state << ",\"input\":" << sample.packed_input
                          << ",\"waiting\":" << (sample.waiting ? "true" : "false") << '}';
                separator = ",";
            }
            std::cout << ']';
        }
        std::cout << "}\n";
        return code;
    } catch (ProofStop stop) {
        if (stop == ProofStop::ControlError) return plain("ENGINE_ERROR", 3);
        return plain(stop == ProofStop::Timeout ? "TIMEOUT" : "CANCELLED", 1);
    } catch (const q3a::MemoryBudgetExceeded& error) {
        std::cerr << "Q3A_LIVENESS_RESOURCE " << error.what() << '\n';
        return plain("RESOURCE_LIMIT", 1);
    } catch (const std::bad_alloc&) {
        return plain("RESOURCE_LIMIT", 1);
    } catch (const std::exception& error) {
        std::cerr << "Q3A_LIVENESS_ERROR " << error.what() << '\n';
        return plain("REJECTED", 2);
    }
}
#endif

#ifdef Q3A_ENABLE_DEVELOPMENT_FOUR_STATE
q3a::lowering::TIRModule load_four_state_model(const q3a::ProjectInput& project, bool sampled = false, bool assertions = false) {
    if (project.profile_id != q3a::frontend::kFourStateProfile) {
        throw std::invalid_argument("expected option profile Q3A-FOUR-STATE-DEVELOPMENT");
    }
    const auto units = parse_project_units(project);
    q3a::four_state::require_combinational_project(units, project.top_module, sampled, assertions);
    const auto design = q3a::elaboration::elaborate_top(units, project.top_module, project.parameters,
        project.profile_id, project.input_hash);
    return q3a::lowering::lower_continuous_assignments(units, design);
}

int development_four_state_model(int argc, const char* const* argv) {
    try {
        if (argc != 3) throw std::invalid_argument("expected one four-state PROJECT");
        const auto project = q3a::SourceManager::load(std::filesystem::u8path(argv[2]));
        const auto model = load_four_state_model(project, true, true);
        std::cout << q3a::lowering::serialize_tir(model) << '\n';
        return 0;
    } catch (const std::bad_alloc&) {
        std::cerr << "Q3A_RESOURCE_LIMIT MEMORY four-state model allocation failed\n";
        return 1;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_FOUR_STATE_ERROR " << error.what() << '\n';
        return 2;
    }
}

int development_four_state(int argc, const char* const* argv) {
    try {
        if (argc < 3) throw std::invalid_argument("expected PROJECT [--input NAME BITS ...]");
        q3a::four_state::Frame inputs;
        for (int index = 3; index < argc; index += 3) {
            if (argc - index < 3 || std::string_view(argv[index]) != "--input") {
                throw std::invalid_argument("expected --input NAME BITS");
            }
            if (!inputs.emplace(argv[index + 1], q3a::four_state::Word::parse(argv[index + 2])).second) {
                throw std::invalid_argument("duplicate four-state input");
            }
        }
        const auto project = q3a::SourceManager::load(std::filesystem::u8path(argv[2]));
        const auto model = load_four_state_model(project);
        const auto result = q3a::four_state::evaluate_combinational(model, std::move(inputs));
        using q3a::bundle::json_string;
        std::cout << "{\"schema_version\":1,\"status\":\"EVALUATED\",\"exit_code\":0,\"profile\":"
                  << json_string(project.profile_id) << ",\"manifest_sha256\":" << json_string(project.manifest_sha256)
                  << ",\"model_sha256\":" << json_string(q3a::sha256_hex(q3a::lowering::serialize_tir(model)))
                  << ",\"signals\":{";
        const char* separator = "";
        for (const auto& entry : result) {
            std::cout << separator << json_string(entry.first) << ':' << json_string(entry.second.bits());
            separator = ",";
        }
        std::cout << "}}\n";
        return 0;
    } catch (const std::bad_alloc&) {
        std::cout << "{\"schema_version\":1,\"status\":\"RESOURCE_LIMIT\",\"exit_code\":1}\n";
        return 1;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_FOUR_STATE_ERROR " << error.what() << '\n';
        std::cout << "{\"schema_version\":1,\"status\":\"REJECTED\",\"exit_code\":2}\n";
        return 2;
    }
}
int development_four_state_proof(int argc, const char* const* argv, bool reopen) {
    const auto plain = [](const char* status, int code) {
        std::cout << "{\"schema_version\":1,\"status\":" << std::quoted(status)
                  << ",\"exit_code\":" << code << "}\n";
        return code;
    };
    try {
        const bool assertion = argc > 3 && std::string_view(argv[3]) == "--property";
        const int evidence_index = assertion ? 5 : 6;
        if (argc <= evidence_index + 1 || (!assertion && std::string_view(argv[3]) != "--expect") ||
            std::string_view(argv[evidence_index]) != "--evidence-dir" || !*argv[evidence_index + 1]) {
            throw std::invalid_argument("expected PROJECT --property NAME or --expect OUTPUT BITS, then --evidence-dir DIR");
        }
        ProofCommand control(true);
        control.console_control = SetConsoleCtrlHandler(proof_console_handler, TRUE) != FALSE;
        std::set<std::string_view> seen;
        std::optional<std::size_t> sample;
        std::filesystem::path vcd;
        bool save_counterexample = false;
        for (int index = evidence_index + 2; index < argc;) {
            const std::string_view option(argv[index++]);
            if (!seen.insert(option).second) {
                throw std::invalid_argument("repeated four-state control option");
            }
            if (option == "--save-witness" && !reopen) {
                save_counterexample = true;
                continue;
            }
            if (index == argc) throw std::invalid_argument("missing four-state control option value");
            const auto* value = argv[index++];
            if (option == "--cancel-file" && *value) {
                control.cancel_file = std::filesystem::absolute(std::filesystem::u8path(value));
                continue;
            }
            if (option == "--vcd" && *value) {
                vcd = q3a::bundle::detail::absolute_windows_file_path(std::filesystem::u8path(value));
                continue;
            }
            std::uint64_t limit = 0;
            if (!parse_limit(value, limit)) throw std::invalid_argument("invalid four-state limit");
            if (option == "--steps" && limit <= 128) {
                sample = static_cast<std::size_t>(limit);
                continue;
            }
            if (limit == 0) throw std::invalid_argument("four-state resource limits must be positive");
            if (option == "--timeout-ms" && limit <= 86400000) {
                control.timeout = std::chrono::milliseconds(limit);
            } else if (option == "--memory-mib" && limit <= 65536) {
                control.job_memory_mib = limit;
            } else {
                throw std::invalid_argument("invalid four-state control option");
            }
        }
        const auto memory = control.budget();
        memory.check();
        const q3a::replay::ReplayTiming timing(reopen && vcd.empty());
        const auto started = timing.start();
        const auto project = load_proof_project(std::filesystem::u8path(argv[2]), control);
        if (assertion && !sample) throw std::invalid_argument("four-state properties require --steps");
        const auto model = load_four_state_model(project, sample.has_value(), assertion);
        const q3a::four_state::Claim claim{argv[4],
            assertion ? std::nullopt : std::optional{q3a::four_state::Word::parse(argv[5])}, sample};
        const auto model_hash = q3a::sha256_hex(q3a::lowering::serialize_tir(model));
        const auto identity = model_hash + "\n" + project.manifest_sha256 + "\n" + q3a::build_info::kBuildId;
        const auto evidence = q3a::bundle::detail::absolute_windows_file_path(
            std::filesystem::u8path(argv[evidence_index + 1]));
        if (!vcd.empty() && (!vcd.has_filename() || std::filesystem::exists(vcd) ||
            !std::filesystem::is_directory(vcd.parent_path()) ||
            CompareStringOrdinal(vcd.c_str(), -1, evidence.c_str(), -1, TRUE) == CSTR_EQUAL)) {
            throw std::invalid_argument("four-state VCD requires an unused file path in an existing directory");
        }
        timing.write(std::cerr, "source_model", timing.elapsed(started));
        const auto checked = q3a::four_state::check_exact(model, claim, identity, evidence, memory, reopen,
            save_counterexample, &timing);
        const auto vcd_hash = vcd.empty() || checked.trace.empty() ? std::string{} :
            q3a::four_state::save_waveform(vcd, model, checked, memory);
        using q3a::bundle::json_string;
        using q3a::four_state::ProofOutcome;
        const auto status = checked.outcome == ProofOutcome::Proven ?
            (checked.cover ? "NOT_FOUND_WITHIN_BOUND" : sample ? "BOUNDED_PASS" : "PROVEN") :
            checked.outcome == ProofOutcome::Revalidated ? "REVALIDATED" :
            checked.outcome == ProofOutcome::CoverHit || checked.outcome == ProofOutcome::Counterexample ?
                (checked.assumption_boundary_open ? "WITNESS_PENDING_ASSUMPTION" :
                    checked.cover ? "COVERED" : "COUNTEREXAMPLE") :
            checked.outcome == ProofOutcome::Inconsistent ? "INCONSISTENT" : "UNKNOWN";
        const int code = checked.outcome == ProofOutcome::Unknown || checked.outcome == ProofOutcome::Inconsistent ||
            checked.assumption_boundary_open || (checked.cover && checked.outcome == ProofOutcome::Proven) ? 1 : 0;
        std::cout << "{\"schema_version\":1,\"status\":" << json_string(status) << ",\"exit_code\":" << code
                  << ",\"profile\":" << json_string(model.semantic_profile)
                  << ",\"model_sha256\":" << json_string(model_hash)
                  << ",\"proof_model_sha256\":" << json_string(checked.proof_model_sha256)
                  << ",\"query_sha256\":" << json_string(checked.query_sha256);
        if (assertion) {
            std::cout << ",\"property\":" << json_string(claim.signal)
                      << ",\"property_kind\":" << json_string(checked.cover ? "cover" : "assert");
        } else {
            std::cout << ",\"output\":" << json_string(claim.signal)
                      << ",\"expected\":" << json_string(claim.expected->bits());
        }
        if (sample) std::cout << ",\"steps\":" << *sample;
        if (!vcd_hash.empty()) std::cout << ",\"vcd_sha256\":" << json_string(vcd_hash);
        if (!checked.proof_sha256.empty()) std::cout << ",\"proof_sha256\":" << json_string(checked.proof_sha256);
        if (!checked.witness_sha256.empty()) {
            std::cout << ",\"witness_sha256\":" << json_string(checked.witness_sha256)
                      << ",\"witness_revalidated\":" << (checked.witness_revalidated ? "true" : "false");
        }
        if (checked.outcome == ProofOutcome::Counterexample || checked.outcome == ProofOutcome::CoverHit) {
            if (checked.assumption_boundary_open) std::cout << ",\"assumption_boundary_open\":true";
            const auto write_frame = [&](const q3a::four_state::Frame& frame) {
                std::cout << '{';
                const char* separator = "";
                for (const auto& signal : frame) {
                    std::cout << separator << json_string(signal.first) << ':' << json_string(signal.second.bits());
                    separator = ",";
                }
                std::cout << '}';
            };
            if (checked.attempt_sample) std::cout << ",\"attempt_sample\":" << *checked.attempt_sample;
            if (checked.failure_sample) std::cout << ",\"failure_sample\":" << *checked.failure_sample;
            if (checked.match_sample) std::cout << ",\"match_sample\":" << *checked.match_sample;
            if (checked.antecedent_end_sample) {
                std::cout << ",\"antecedent_end_sample\":" << *checked.antecedent_end_sample;
            }
            std::cout << ",\"source_replayed\":true,\"signals\":";
            const auto witness_sample = checked.match_sample.value_or(
                checked.failure_sample.value_or(checked.trace.size() - 1));
            write_frame(checked.trace.at(witness_sample));
            if (sample) {
                std::cout << ",\"trace\":[";
                const char* separator = "";
                for (const auto& frame : checked.trace) {
                    std::cout << separator;
                    write_frame(frame);
                    separator = ",";
                }
                std::cout << ']';
            }
        }
        std::cout << "}\n";
        return code;
    } catch (ProofStop stop) {
        if (stop == ProofStop::ControlError) return plain("ENGINE_ERROR", 3);
        return plain(stop == ProofStop::Timeout ? "TIMEOUT" : "CANCELLED", 1);
    } catch (const q3a::MemoryBudgetExceeded&) {
        return plain("RESOURCE_LIMIT", 1);
    } catch (const std::bad_alloc&) {
        return plain("RESOURCE_LIMIT", 1);
    } catch (const std::invalid_argument& error) {
        std::cerr << "Q3A_FOUR_STATE_ERROR " << error.what() << '\n';
        return plain("REJECTED", 2);
    } catch (const std::logic_error& error) {
        std::cerr << "Q3A_FOUR_STATE_ERROR " << error.what() << '\n';
        return plain("ENGINE_ERROR", 3);
    } catch (const std::exception& error) {
        std::cerr << "Q3A_FOUR_STATE_ERROR " << error.what() << '\n';
        return plain("REJECTED", 2);
    }
}
#endif

void write_product_help(std::ostream& out) {
    out << R"Q3AHELP(Q3AFormal: block-level RTL formal verification
Usage: q3aformal-sourcecheck COMMAND [options]

  --help
  --version
  --preprocess-project PROJECT
  properties PROJECT [--parameter NAME VALUE ...]
  prove PROJECT [--parameter NAME VALUE ...] [--timeout-ms N]
        [--cancel-file PATH] [--run-record PATH]
        [--engine bmc|induction|pdr --property NAME] ENGINE_OPTIONS
  prove-batch PROJECT --plan FILE --output-dir DIR [--cancel-file PATH] [--checkpoint|--resume] [--workers N]
  prove-composition PROJECT --plan FILE --output-dir DIR [--timeout-ms N] [--memory-mib N] [--cancel-file PATH]
  verify-composition PROJECT --plan FILE --evidence-dir DIR [--timeout-ms N] [--memory-mib N] [--cancel-file PATH]
  check-equivalence REFERENCE IMPLEMENTATION --plan FILE --output-dir DIR [--max-depth N]
                    [--timeout-ms N] [--memory-mib N] [--cancel-file PATH]
  verify-equivalence REFERENCE IMPLEMENTATION --plan FILE --evidence-dir DIR
                     [--timeout-ms N] [--memory-mib N] [--cancel-file PATH]
  verify-pdr PROJECT [--parameter NAME VALUE ...] --property NAME
             --evidence-dir DIR [--check-activation]
  --verify-bundle DIR_OR_INTERRUPTION_RECORD [--require-source-model]
  gui BUNDLE [--obligation base|step] [--reset SIGNAL high|low]
      [--group LABEL SIGNAL] ...
  debug BUNDLE [--obligation base|step] [--reset SIGNAL high|low]
        [--group LABEL SIGNAL] ...
  trace import-vcd FILE [--q3a-roundtrip]
  trace view-vcd FILE
  trace window FILE --first N --last N [--signal NAME ...]

Engine options
  bmc        --frames N [--vcd FILE] [--html FILE] [--bundle-dir DIR]
  induction  --k N --output-prefix PREFIX [--bundle-dir DIR] [--cache-dir DIR]
  pdr        --evidence-dir DIR [--max-depth N] [--max-queries N] [--bundle-dir DIR]
             [--feasibility-frames N] [--check-activation]

Version 2 project manifests can supply engine, property and depth defaults.
Version 2 batch plans accept optional max_queries N and feasibility_frames N on PDR jobs.
BMC and induction accept --trace-all and repeatable --trace-signal NAME
with waveform or bundle output. PDR trace selection requires --bundle-dir. PDR defaults to 10,000 search SAT queries.
The prove and prove-batch commands write JSON to standard output.
Their exit codes are 0 conclusive, 1 incomplete, 2 invalid input or setup,
and 3 engine or evidence error. See the User Guide for legacy commands.
)Q3AHELP";
#ifdef Q3A_ENABLE_DEVELOPMENT_FOUR_STATE
    out << "  dev-lower-four-state PROJECT\n"
           "  dev-eval-four-state PROJECT [--input NAME BITS ...]\n"
           "  dev-prove-four-state PROJECT --expect OUTPUT BITS --evidence-dir DIR [--steps N] [--vcd FILE] [--save-witness]\n"
           "  dev-verify-four-state PROJECT --expect OUTPUT BITS --evidence-dir DIR [--steps N] [--vcd FILE]\n"
           "  dev-prove-four-state PROJECT --property NAME --evidence-dir DIR --steps N [--vcd FILE] [--save-witness]\n"
           "  dev-verify-four-state PROJECT --property NAME --evidence-dir DIR --steps N [--vcd FILE]\n";
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_LIVENESS
    out << "Development explicit liveness\n"
           "  dev-check-liveness PROJECT QUERY [--justice SIGNAL ...] [--evidence FILE]\n"
           "  dev-verify-liveness PROJECT QUERY [--justice SIGNAL ...] --evidence FILE [--vcd FILE]\n"
           "      QUERY is --property NAME or --request SIGNAL --response SIGNAL\n"
           "      [--max-vertices N] [--max-edges N] [--timeout-ms N] [--memory-mib N] [--cancel-file PATH]\n";
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_EVENT_MASK
    out << "Development free-event-mask profile\n"
           "  dev-check-events PROJECT --property NAME --output-dir DIR --frames N\n"
           "  dev-verify-events PROJECT --property NAME --evidence-dir DIR\n"
           "  dev-gui-events PROJECT --property NAME --evidence-dir DIR\n"
           "  dev-prove-events PROJECT --property NAME --output-dir DIR [--max-depth N]\n"
           "  dev-verify-event-proof PROJECT --property NAME --evidence-dir DIR\n";
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_MEMORY
    out << "Development exact-memory profile\n"
           "  dev-prove-memory PROJECT --property NAME --output-dir DIR --max-cells N [--diagnose-range] [--range-trace FILE]\n"
           "  dev-verify-memory PROJECT --property NAME --evidence-dir DIR --max-cells N\n"
           "  dev-verify-memory-range PROJECT --property NAME --trace FILE --max-cells N\n"
           "  dev-gui-memory-range PROJECT --property NAME --trace FILE --max-cells N\n"
           "  Proof and certificate revalidation accept --activation-frames N (0..128).\n";
#endif
}

void write_product_version(std::ostream& out) {
    using q3a::bundle::json_string;
    out << "{\"schema_version\":1,\"tool\":\"q3aformal-sourcecheck\",\"build_id\":"
        << json_string(q3a::build_info::kBuildId)
        << ",\"compiler\":" << json_string(q3a::build_info::kCompiler)
        << ",\"build_configuration\":" << json_string(q3a::build_info::kBuildConfiguration)
        << ",\"checker_id\":" << json_string(q3a::checker::kCheckerId)
        << ",\"proof_artifact_schema\":" << q3a::checker::kProofArtifactSchema << "}\n";
}

} // namespace

static int preprocess_project_command(const std::filesystem::path& path, std::ostream& out) {
    using q3a::bundle::json_string;
    using q3a::frontend::MacroExpansion;
    using q3a::frontend::MacroUse;
    const auto location = [&](const q3a::frontend::SourceLocation& at) {
        out << "{\"file\":" << json_string(at.file) << ",\"line\":" << at.line
            << ",\"column\":" << at.column << ",\"byte_offset\":" << at.byte_offset << '}';
    };
    try {
        std::vector<std::vector<MacroExpansion>> expansion_map;
        const auto project = q3a::SourceManager::load(path, {}, &expansion_map);
        out << "{\"schema_version\":1,\"source_set_sha256\":"
            << json_string(project.input_hash) << ",\"units\":[";
        for (std::size_t index = 0; index < project.sources.size(); ++index) {
            if (index != 0) out << ',';
            const auto& tokens = project.preprocessed_units[index];
            out << "{\"path\":" << json_string(project.sources[index].relative_path) << ",\"tokens\":[";
            const char* separator = "";
            for (const auto& token : tokens) {
                out << separator << "{\"kind\":" << json_string(q3a::frontend::token_kind_name(token.kind))
                    << ",\"text\":" << json_string(token.text) << ",\"leading_space\":" << token.leading_space
                    << ",\"location\":";
                location(token.location);
                out << '}';
                separator = ",";
            }
            out << "],\"expansions\":[";
            separator = "";
            for (const auto& expansion : expansion_map[index]) {
                out << separator << "{\"use\":"
                    << json_string(expansion.use == MacroUse::IncludeOperand ? "include_operand" : "source_tokens")
                    << ",\"invocation\":";
                location(expansion.invocation);
                out << ",\"output_begin\":" << expansion.output_begin
                    << ",\"output_end\":" << expansion.output_end << ",\"steps\":[";
                const char* step_separator = "";
                for (const auto& step : expansion.steps) {
                    out << step_separator << "{\"name\":" << json_string(step.name) << ",\"definition\":";
                    location(step.definition);
                    out << '}';
                    step_separator = ",";
                }
                out << "]}";
                separator = ",";
            }
            out << "]}";
        }
        out << "]}\n";
        return out ? 0 : 1;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_PREPROCESS_ERROR " << error.what() << '\n';
        return 1;
    }
}

static q3a::bundle::DebugOptions parse_debug_options(int argc, char** argv, int from) {
    q3a::bundle::DebugOptions options;
    for (int i = from; i < argc;) {
        const std::string_view option = argv[i++];
        if (option == "--obligation" && i < argc && options.obligation.empty()) {
            options.obligation = argv[i++];
            if (options.obligation != "base" && options.obligation != "step") {
                throw std::invalid_argument("debug obligation requires base or step");
            }
        } else if (option == "--reset" && i + 1 < argc) {
            const std::string signal = argv[i++];
            const std::string level = argv[i++];
            if (signal.empty() || (level != "high" && level != "low") ||
                options.resets.size() == 8 || !options.resets.emplace(signal, level).second) {
                throw std::invalid_argument("debug requires at most eight distinct resets with high or low polarity");
            }
        } else if (option == "--group" && i + 1 < argc) {
            const std::string label = argv[i++];
            const std::string signal = argv[i++];
            if (label.empty() || label.size() > 80 || signal.empty()) {
                throw std::invalid_argument("debug group requires a label and a signal");
            }
            auto& members = options.groups[label];
            if (std::find(members.begin(), members.end(), signal) != members.end()) {
                throw std::invalid_argument("duplicate member in debug group");
            }
            members.push_back(signal);
        } else {
            throw std::invalid_argument("invalid debug option: " + std::string(option));
        }
    }
    return options;
}

static int cli_main(int argc, char** argv) {
    if (argc == 2 && std::string_view(argv[1]) == "--help") {
        write_product_help(std::cout);
        return 0;
    }
    if (argc == 2 && std::string_view(argv[1]) == "--version") {
        write_product_version(std::cout);
        return 0;
    }
    std::error_code executable_error;
    gExecutablePath = std::filesystem::absolute(
        std::filesystem::u8path(argv[0]), executable_error);
    if (executable_error) gExecutablePath = std::filesystem::u8path(argv[0]);
#ifdef Q3A_ENABLE_DEVELOPMENT_FOUR_STATE
    if (argc >= 2 && std::string_view(argv[1]) == "dev-lower-four-state") return development_four_state_model(argc, argv);
    if (argc >= 2 && std::string_view(argv[1]) == "dev-eval-four-state") return development_four_state(argc, argv);
    if (argc >= 2 && std::string_view(argv[1]) == "dev-prove-four-state") return development_four_state_proof(argc, argv, false);
    if (argc >= 2 && std::string_view(argv[1]) == "dev-verify-four-state") return development_four_state_proof(argc, argv, true);
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_LIVENESS
    if (argc >= 2 && std::string_view(argv[1]) == "dev-check-liveness") return development_liveness(argc, argv, false);
    if (argc >= 2 && std::string_view(argv[1]) == "dev-verify-liveness") return development_liveness(argc, argv, true);
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_EVENT_MASK
    if (argc >= 2 && std::string_view(argv[1]) == "dev-check-events") return development_events(argc, argv, DevelopmentEventMode::Check);
    if (argc >= 2 && std::string_view(argv[1]) == "dev-gui-events") return development_events(argc, argv, DevelopmentEventMode::Debug);
    if (argc >= 2 && std::string_view(argv[1]) == "dev-verify-events") return development_events(argc, argv, DevelopmentEventMode::Replay);
    if (argc >= 2 && std::string_view(argv[1]) == "dev-prove-events") return development_events(argc, argv, DevelopmentEventMode::Prove);
    if (argc >= 2 && std::string_view(argv[1]) == "dev-verify-event-proof") return development_events(argc, argv, DevelopmentEventMode::VerifyProof);
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_MEMORY
    if (argc >= 2 && std::string_view(argv[1]) == "dev-prove-memory") {
        return development_memory(argc, argv, DevelopmentMemoryMode::Prove);
    }
    if (argc >= 2 && std::string_view(argv[1]) == "dev-verify-memory") {
        return development_memory(argc, argv, DevelopmentMemoryMode::VerifyProof);
    }
    if (argc >= 2 && std::string_view(argv[1]) == "dev-verify-memory-range") {
        return development_memory(argc, argv, DevelopmentMemoryMode::VerifyRange);
    }
    if (argc >= 2 && std::string_view(argv[1]) == "dev-gui-memory-range") {
        return development_memory(argc, argv, DevelopmentMemoryMode::DebugRange);
    }
#endif

    if (argc == 7 && std::string_view(argv[1]) == "--capture-native-workload") {
        const auto started = std::chrono::steady_clock::now();
        try {
            const std::string_view kind = argv[2];
            const std::string_view mode = argv[6];
            if ((kind != "witness" && kind != "synthetic") || (mode != "untimed" && mode != "visible"))
                throw std::invalid_argument("invalid workload role or capture mode");
            auto plan = q3a::WriteLockedInput(std::filesystem::u8path(argv[4]));
            auto& plan_text = plan.stream();
            std::uint64_t span = 0;
            unsigned count = 0;
            std::string signature;
            plan_text >> signature >> span >> count;
            if (signature != "Q3A_WIN32_VIEWPORT_SCHEDULE_1" || count == 0 || count > 32)
                throw std::invalid_argument("invalid native workload schedule");
            q3a::debug::NativeCaptureRequest request{span, {}, std::filesystem::u8path(argv[5]),
                mode == "visible", started};
            std::vector<std::string> names(16);
            for (auto& name : names) plan_text >> name;
            for (unsigned i = 0; i < count; ++i) {
                std::uint64_t first = 0, frame = 0;
                plan_text >> first >> frame;
                request.viewports.emplace_back(first, frame);
            }
            if (!plan_text) throw std::invalid_argument("incomplete native workload schedule");
            std::string surplus;
            if (plan_text >> surplus) throw std::invalid_argument("extra native workload schedule content");

            const auto input = std::filesystem::u8path(argv[3]);
            q3a::bundle::VerifiedDebugSession session;
            std::unique_ptr<q3a::WriteLockedInput> trace;
            if (kind == "witness") {
                q3a::bundle::DebugOptions options;
                options.resets.emplace("rst", "high");
                session = q3a::bundle::open_verified_debug_session(input, options);
                if (session.frame_count != 321 || session.candidate_frame != 320)
                    throw std::invalid_argument("unexpected source-backed workload size");
            } else {
                trace = std::make_unique<q3a::WriteLockedInput>(input);
                session.frame_count = 10001;
                session.view.run.emplace("Result", "Synthetic indexed trace");
                for (unsigned lane = 0; lane < 384; ++lane) {
                    const auto name = "lane_" + std::to_string(1000 + lane).substr(1);
                    session.view.signals.emplace_back(name, 32, false, "trace", q3a::frontend::SourceLocation{});
                }
                session.write_window = [&trace](std::ostream& output, std::uint64_t first, std::uint64_t last,
                                                 const std::vector<std::string>& selected) {
                    trace->rewind();
                    q3a::trace::write_indexed_window(trace->stream(), output, first, last, selected);
                };
            }
            session.view.selected = std::move(names);
            return q3a::debug::capture_native_workload(session, request, std::cout);
        } catch (const std::exception& error) {
            std::cerr << "Q3A_GUI_WORKLOAD_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    if (argc >= 2 && (std::string_view(argv[1]) == "gui" ||
                     std::string_view(argv[1]) == "--qualify-native-gui")) {
        const bool smoke = std::string_view(argv[1]) == "--qualify-native-gui";
        const int options_start = smoke ? 4 : 3;
        if (argc < options_start) {
            std::cerr << "usage: q3aformal-sourcecheck gui <bundle-directory> [--obligation base|step] "
                         "[--reset SIGNAL high|low] [--group LABEL SIGNAL] ...\n";
            return 2;
        }
        try {
            const auto options = parse_debug_options(argc, argv, options_start);
            const auto session = q3a::bundle::open_verified_debug_session(std::filesystem::u8path(argv[2]), options);
            return q3a::debug::run_native_debug(session, smoke ? std::filesystem::u8path(argv[3]) : std::filesystem::path{});
        } catch (const std::invalid_argument& error) {
            std::cerr << "Q3A_NATIVE_DEBUG_INPUT " << error.what() << '\n';
            return 2;
        } catch (const std::exception& error) {
            std::cerr << "Q3A_NATIVE_DEBUG " << error.what() << '\n';
            return 1;
        }
    }

    if (argc >= 2 && std::string_view(argv[1]) == "debug") {
        if (argc < 3) {
            std::cerr << "usage: q3aformal-sourcecheck debug <bundle-directory> [--obligation base|step] "
                         "[--reset SIGNAL high|low] [--group LABEL SIGNAL] ...\n";
            return 2;
        }
        try {
            const auto options = parse_debug_options(argc, argv, 3);
            q3a::bundle::write_verified_debug_page(std::filesystem::u8path(argv[2]),
                options, std::cout);
            return 0;
        } catch (const q3a::bundle::VerificationResourceLimit& error) {
            std::cerr << "Q3A_DEBUG_RESOURCE_LIMIT " << error.what() << '\n';
            return 1;
        } catch (const q3a::MemoryBudgetExceeded& error) {
            std::cerr << "Q3A_DEBUG_RESOURCE_LIMIT " << error.what() << '\n';
            return 1;
        } catch (const std::bad_alloc& error) {
            std::cerr << "Q3A_DEBUG_RESOURCE_LIMIT " << error.what() << '\n';
            return 1;
        } catch (const std::invalid_argument& error) {
            std::cerr << "Q3A_DEBUG_INPUT_ERROR " << error.what() << '\n';
            return 2;
        } catch (const std::exception& error) {
            std::cerr << "Q3A_DEBUG_ERROR " << error.what() << '\n';
            return 3;
        }
    }

    if (argc >= 2 && std::string_view(argv[1]) == "trace") {
        if (argc < 4) {
            std::cerr << "usage: q3aformal-sourcecheck trace import-vcd <file.vcd> [--q3a-roundtrip]\n"
                         "       q3aformal-sourcecheck trace view-vcd <file.vcd>\n"
                         "       q3aformal-sourcecheck trace window <file.q3atrace> --first N --last N [--signal NAME ...]\n";
            return 2;
        }
        try {
            const q3a::MemoryBudget memory;
            memory.check();
            const std::string_view operation = argv[2];
            const auto path = std::filesystem::absolute(std::filesystem::u8path(argv[3]));
            std::ifstream input(q3a::bundle::detail::windows_file_path(path), std::ios::binary);
            if (!input) throw std::invalid_argument("cannot open trace input");
            if (operation == "import-vcd") {
                const bool roundtrip = argc == 5 && std::string_view(argv[4]) == "--q3a-roundtrip";
                if (argc != 4 && !roundtrip) throw std::invalid_argument("invalid VCD import options");
                q3a::trace::import_vcd(input, std::cout, roundtrip, memory);
            } else if (operation == "view-vcd") {
                if (argc != 4) throw std::invalid_argument("invalid VCD viewer options");
                q3a::trace::write_vcd_viewer(input, std::cout, memory);
            } else if (operation == "window") {
                std::uint64_t first = 0;
                std::uint64_t last = 0;
                if (argc < 8 || std::string_view(argv[4]) != "--first" ||
                    std::string_view(argv[6]) != "--last" ||
                    !parse_limit(argv[5], first) || !parse_limit(argv[7], last)) {
                    throw std::invalid_argument("trace window requires --first N --last N");
                }
                std::vector<std::string> signals;
                for (int i = 8; i < argc; i += 2) {
                    if (i + 1 >= argc || std::string_view(argv[i]) != "--signal") {
                        throw std::invalid_argument("trace window expects --signal NAME");
                    }
                    signals.emplace_back(argv[i + 1]);
                }
                q3a::trace::write_indexed_window(input, std::cout, first, last, signals);
            } else {
                throw std::invalid_argument("unknown trace command");
            }
            return 0;
        } catch (const q3a::MemoryBudgetExceeded& error) {
            std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
            return 1;
        } catch (const std::bad_alloc& error) {
            std::cerr << "Q3A_RESOURCE_LIMIT MEMORY " << error.what() << '\n';
            return 1;
        } catch (const std::invalid_argument& error) {
            std::cerr << "Q3A_TRACE_INPUT_ERROR " << error.what() << '\n';
            return 2;
        } catch (const std::exception& error) {
            std::cerr << "Q3A_TRACE_ERROR " << error.what() << '\n';
            return 3;
        }
    }

    if (argc >= 2 && std::string(argv[1]) == "--verify-bundle") {
        const bool require_source_model = argc == 4 && std::string(argv[3]) == "--require-source-model";
        if (argc != 3 && !require_source_model) {
            std::cerr << "Q3A_BUNDLE_ERROR usage: --verify-bundle <directory-or-interruption-record>"
                         " [--require-source-model]\n";
            return 2;
        }
        try {
            q3a::bundle::reopen_saved_run(
                std::filesystem::u8path(argv[2]), std::cout, require_source_model);
            return 0;
        } catch (const q3a::bundle::VerificationResourceLimit& error) {
            std::cout << "Q3A_BUNDLE_STATUS UNKNOWN\n";
            std::cerr << "Q3A_BUNDLE_RESOURCE_LIMIT " << error.what() << '\n';
            return 3;
        } catch (const q3a::MemoryBudgetExceeded& error) {
            std::cout << "Q3A_BUNDLE_STATUS UNKNOWN\n";
            std::cerr << "Q3A_BUNDLE_RESOURCE_LIMIT " << error.what() << '\n';
            return 3;
        } catch (const std::bad_alloc& error) {
            std::cout << "Q3A_BUNDLE_STATUS UNKNOWN\n";
            std::cerr << "Q3A_BUNDLE_RESOURCE_LIMIT " << error.what() << '\n';
            return 3;
        } catch (const std::exception& error) {
            std::cerr << "Q3A_BUNDLE_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    if (argc >= 2 && std::string(argv[1]) == "--sat-dimacs") {
        return solve_dimacs_file(argc, argv);
    }

    if (argc >= 2 && std::string(argv[1]) == "--transition-cnf") {
        if (argc != 5 || std::string(argv[3]) != "--frames") {
            std::cerr << "Q3A_TRANSITION_CNF_ERROR usage: --transition-cnf "
                         "<project.q3a> --frames <transition-count>\n";
            return 2;
        }
        std::uint64_t transition_count = 0;
        if (!parse_limit(argv[4], transition_count)) {
            std::cerr << "Q3A_TRANSITION_CNF_ERROR invalid transition count\n";
            return 2;
        }
        try {
            const auto project = q3a::SourceManager::load(
                std::filesystem::u8path(argv[2]));
            return transition_cnf_project(project, transition_count);
        } catch (const std::exception& error) {
            std::cerr << "Q3A_TRANSITION_CNF_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    if (argc >= 2 && std::string_view(argv[1]) == "verify-pdr") {
        return verify_pdr_command(argc, argv);
    }
    if (argc >= 2 && std::string_view(argv[1]) == "prove") {
        return product_prove(argc, argv, std::cout,
            SetConsoleCtrlHandler(proof_console_handler, TRUE) != FALSE);
    }
    if (argc >= 2 && std::string_view(argv[1]) == "prove-batch") {
        return product_batch(argc, argv);
    }
    if (argc >= 2 && std::string_view(argv[1]) == "--batch-worker") {
        return product_batch_worker(argc, argv);
    }
    if (argc >= 2 && (std::string_view(argv[1]) == "prove-composition" ||
                      std::string_view(argv[1]) == "verify-composition")) {
        return product_composition(argc, argv, std::string_view(argv[1]) == "verify-composition");
    }
    if (argc >= 2 && (std::string_view(argv[1]) == "check-equivalence" ||
                      std::string_view(argv[1]) == "verify-equivalence")) {
        return product_equivalence(argc, argv, std::string_view(argv[1]) == "verify-equivalence");
    }
    if (argc >= 2 && (std::string_view(argv[1]) == "--bmc" ||
                      std::string_view(argv[1]) == "--prove-inductive")) {
        ProofCommand command;
        return run_proof_command(argc, argv, command);
    }

    if (argc == 3 && std::string(argv[1]) == "--lex") {
        const std::filesystem::path source_path = std::filesystem::u8path(argv[2]);
        std::ifstream input(source_path, std::ios::binary);
        if (!input) {
            std::cerr << "Q3A_LEX_ERROR cannot open input source\n";
            return 1;
        }
        const std::string source((std::istreambuf_iterator<char>(input)),
                                 std::istreambuf_iterator<char>());
        try {
            const auto display_name = source_path.filename().u8string();
            const auto tokens = q3a::frontend::tokenize(source, display_name);
            for (const auto& token : tokens) {
                std::cout << token.location.line << ':' << token.location.column
                          << ' ' << q3a::frontend::token_kind_name(token.kind)
                          << ' ' << std::quoted(token.text) << '\n';
            }
            return 0;
        } catch (const q3a::frontend::LexError& error) {
            std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    if (argc == 3 && std::string(argv[1]) == "--parse") {
        const std::filesystem::path source_path = std::filesystem::u8path(argv[2]);
        std::ifstream input(source_path, std::ios::binary);
        if (!input) {
            std::cerr << "Q3A_PARSE_ERROR cannot open input source\n";
            return 1;
        }
        const std::string source((std::istreambuf_iterator<char>(input)),
                                 std::istreambuf_iterator<char>());
        return parse_and_report(source, source_path.filename().u8string());
    }

    if (argc == 3 && std::string_view(argv[1]) == "--preprocess-project") {
        return preprocess_project_command(std::filesystem::u8path(argv[2]), std::cout);
    }

    if (argc == 3 && std::string(argv[1]) == "--parse-project") {
        try {
            const auto project = q3a::SourceManager::load(
                std::filesystem::u8path(argv[2]));
            const auto units = parse_project_units(project);
            std::cout << "Q3A_PARSE_PROJECT profile=" << project.profile_id
                      << " input_sha256=" << project.input_hash
                      << " sources=" << project.sources.size() << '\n';
            for (std::size_t index = 0; index < units.size(); ++index) {
                report_syntax(units[index], project.sources[index].relative_path);
            }
            return 0;
        } catch (const q3a::frontend::LexError& error) {
            std::cerr << "Q3A_LEX_ERROR " << error.what() << '\n';
            return 1;
        } catch (const std::exception& error) {
            std::cerr << "Q3A_PARSE_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    if (argc == 3 && std::string(argv[1]) == "--elaborate-project") {
        try {
            const auto project = q3a::SourceManager::load(
                std::filesystem::u8path(argv[2]));
            return elaborate_and_report(project);
        } catch (const std::exception& error) {
            std::cerr << "Q3A_ELABORATION_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    if (argc >= 3 && std::string_view(argv[1]) == "properties") {
        try {
            int position = 3;
            const auto overrides = read_parameter_overrides(argc, argv, position);
            if (position != argc) {
                throw std::invalid_argument("expected properties <project.q3a> [--parameter NAME VALUE ...]");
            }
            auto project = q3a::SourceManager::load(std::filesystem::u8path(argv[2]));
            q3a::SourceManager::apply_parameter_overrides(project, overrides);
            const auto model = lower_project_tir(project);
            const q3a::trace::PropertySignalIndex index(model);
            std::cout << "{\"schema_version\":1,\"source_set_sha256\":"
                      << q3a::bundle::json_string(model.input_hash) << ",\"properties\":[";
            const char* separator = "";
            for (const auto& property : model.properties) {
                std::cout << separator << "{\"name\":" << q3a::bundle::json_string(property.name)
                          << ",\"kind\":" << q3a::bundle::json_string(property.kind)
                          << ",\"clock\":" << q3a::bundle::json_string(property.clock)
                          << ",\"edge\":\"posedge\",\"source\":{\"file\":"
                          << q3a::bundle::json_string(property.location.file)
                          << ",\"line\":" << property.location.line
                          << ",\"column\":" << property.location.column << "},\"signals\":";
                q3a::trace::write_property_signals(std::cout, index.for_property(property));
                std::cout << '}';
                separator = ",";
            }
            std::cout << "]}\n";
            return 0;
        } catch (const std::exception& error) {
            std::cerr << "Q3A_PROPERTIES_ERROR " << error.what() << '\n';
            return 2;
        }
    }

    if (argc == 3 && std::string(argv[1]) == "--lower-project") {
        try {
            const auto project = q3a::SourceManager::load(
                std::filesystem::u8path(argv[2]));
            return lower_and_report(project);
        } catch (const std::exception& error) {
            std::cerr << "Q3A_LOWERING_ERROR " << error.what() << '\n';
            return 1;
        }
    }

    if (argc != 2) {
        std::cerr << "usage: q3aformal-sourcecheck <project.q3a> | "
                     "debug <bundle-directory> [--obligation base|step] [--reset SIGNAL high|low] [--group LABEL SIGNAL] ... | "
                     "--lex <source.sv> | --parse <source.sv> | "
                     "--preprocess-project <project.q3a> | --parse-project <project.q3a> | "
                     "--elaborate-project <project.q3a> | "
                     "--lower-project <project.q3a> | "
                     "properties <project.q3a> [--parameter NAME VALUE ...] | "
                     "--transition-cnf <project.q3a> --frames <transition-count> | "
                     "--prove-inductive <project.q3a> --property <scalar-assertion> "
                     "[--k <positive-depth>] --output-prefix <path-prefix> "
                     "[--bundle-dir <directory>] [--cache-dir <directory>] [--trace-all] "
                     "[--trace-signal <name> ...] | "
                     "prove-batch <project.q3a> --plan <file> --output-dir <directory> [--cancel-file <path>] | "
                     "--verify-bundle <directory-or-interruption-record> [--require-source-model] | "
                     "--bmc <project.q3a> --property <property-name> "
                     "--frames <transition-count> [--vcd <output.vcd>] "
                     "[--bundle-dir <directory>] [--trace-all] [--trace-signal <name> ...] | "
                     "--sat-dimacs <input.cnf> [--decision-limit N] "
                     "[--propagation-limit N] [--assume LIT ...]\n";
        return 2;
    }

    try {
        const auto project = q3a::SourceManager::load(
            std::filesystem::u8path(argv[1]));

        std::cout << "Q3A_SOURCE_SET 1\n";
        std::cout << "profile " << project.profile_id << '\n';
        std::cout << "top " << project.top_module << '\n';
        std::cout << "input_sha256 " << project.input_hash << '\n';
        for (const auto& parameter : project.parameters) {
            std::cout << "parameter " << parameter.first << ' '
                      << parameter.second << '\n';
        }
        for (const auto& source : project.sources) {
            std::cout << "source " << source.sha256 << ' '
                      << std::quoted(source.relative_path) << '\n';
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Q3A_SOURCE_ERROR " << error.what() << '\n';
        return 1;
    }
}

int wmain(int argc, wchar_t** argv) {
    return q3a::run_utf8_command_line(argc, argv, cli_main);
}
