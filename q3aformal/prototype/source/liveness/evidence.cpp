#include "evidence.hpp"

#include "../bundle/windows_file_path.hpp"
#include "../source_manager/platform_support.hpp"
#include "../source_manager/write_locked_input.hpp"
#include "../source_manager/vcd_import.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <string_view>

namespace q3a::liveness {
namespace {

constexpr std::string_view schema = "Q3A_LIVENESS_EVIDENCE_2";
constexpr std::size_t maximum_artifact_bytes = 48 * 1024 * 1024;

const char* label(Status status) {
    switch (status) {
    case Status::Violation: return "VIOLATION";
    case Status::NoViolation: return "NO_VIOLATION";
    case Status::NoFairExecution: return "NO_FAIR_EXECUTION";
    case Status::InvalidGraph: break;
    }
    throw std::invalid_argument("invalid liveness evidence outcome");
}

const std::string& query_field(const std::string& value) {
    static const std::string absent = "-";
    return value.empty() ? absent : value;
}

void write_header(std::ostream& out, const EvidenceIdentity& identity, const Query& query,
                  const Graph& graph) {
    out << schema << '\n' << identity.model_sha256 << '\n' << identity.manifest_sha256 << '\n'
        << identity.build_id << '\n' << (query.property.empty() ? "SIGNALS" : "ASSERTION") << '\n'
        << query_field(query.property) << '\n'
        << query_field(query.request) << '\n' << query_field(query.response) << '\n'
        << query.maximum_vertices << ' ' << query.maximum_edges << ' ' << query.justice.size() << '\n';
    for (const auto& name : query.justice) out << name << '\n';
    out << graph.states.size() << '\n';
}

void write_result(std::ostream& out, const Result& result, const MemoryBudget& budget) {
    out << label(result.status) << '\n';
    if (result.lasso) {
        const auto& lasso = *result.lasso;
        out << "LASSO " << lasso.loop_start << ' ' << lasso.path.size() << '\n';
        for (std::size_t i = 0; i < lasso.path.size(); ++i) {
            if (i % 4096 == 0) budget.check();
            out << lasso.path[i] << '\n';
        }
    }
    if (result.exclusion) {
        const auto& exclusion = *result.exclusion;
        out << "EXCLUSION\n";
        for (std::size_t i = 0; i < exclusion.ranks.size(); ++i) {
            if (i % 4096 == 0) budget.check();
            out << exclusion.reachable[i] << ' ' << exclusion.ranks[i] << '\n';
        }
    }
    out << "END\n";
}

std::string token(std::istream& in) {
    std::string text;
    if (!(in >> std::setw(1025) >> text) || text.size() >= 1025) {
        throw std::invalid_argument("missing or overlong liveness evidence field");
    }
    return text;
}

void require(std::istream& in, std::string_view expected) {
    if (token(in) != expected) throw std::invalid_argument("liveness evidence identity or field mismatch");
}

std::size_t number(std::istream& in, std::size_t maximum) {
    const auto text = token(in);
    const auto end = text.data() + text.size();
    std::size_t result = 0;
    const auto parsed = std::from_chars(text.data(), end, result);
    if (parsed.ec != std::errc{} || parsed.ptr != end || result > maximum) {
        throw std::invalid_argument("liveness evidence number is invalid or outside bounds");
    }
    return result;
}

Result read_result(std::istream& in, const EvidenceIdentity& identity, const Query& query,
                   const Graph& graph, const MemoryBudget& budget) {
    require(in, schema);
    require(in, identity.model_sha256);
    require(in, identity.manifest_sha256);
    require(in, identity.build_id);
    require(in, query.property.empty() ? "SIGNALS" : "ASSERTION");
    require(in, query_field(query.property));
    require(in, query_field(query.request));
    require(in, query_field(query.response));
    require(in, std::to_string(query.maximum_vertices));
    require(in, std::to_string(query.maximum_edges));
    require(in, std::to_string(query.justice.size()));
    for (const auto& name : query.justice) require(in, name);
    const auto vertices = graph.states.size();
    require(in, std::to_string(vertices));
    const auto kind = token(in);
    Result result;
    if (kind == label(Status::Violation)) result.status = Status::Violation;
    else if (kind == label(Status::NoViolation)) result.status = Status::NoViolation;
    else if (kind == label(Status::NoFairExecution)) result.status = Status::NoFairExecution;
    else throw std::invalid_argument("unknown liveness evidence outcome");
    if (result.status != Status::NoFairExecution) {
        require(in, "LASSO");
        const auto limit = (query.justice.size() + 3) * vertices + 1;
        const auto start = number(in, limit);
        const auto count = number(in, limit);
        if (vertices == 0 || count < 2 || start >= count - 1) {
            throw std::invalid_argument("liveness evidence has invalid loop indices");
        }
        budget.check(count * sizeof(Vertex));
        result.lasso.emplace();
        result.lasso->loop_start = start;
        result.lasso->path.reserve(count);
        for (std::size_t i = 0; i < count; ++i) {
            if (i % 4096 == 0) budget.check();
            result.lasso->path.push_back(number(in, vertices - 1));
        }
    }
    if (result.status != Status::Violation) {
        require(in, "EXCLUSION");
        budget.check(vertices * (sizeof(std::size_t) + 1));
        result.exclusion.emplace();
        auto& exclusion = *result.exclusion;
        exclusion.ranks.reserve(vertices);
        exclusion.reachable.reserve(vertices);
        for (std::size_t i = 0; i < vertices; ++i) {
            if (i % 4096 == 0) budget.check();
            exclusion.reachable.push_back(number(in, 1) != 0);
            exclusion.ranks.push_back(number(in, vertices));
        }
    }
    require(in, "END");
    in >> std::ws;
    if (in.bad() || !in.eof()) throw std::invalid_argument("unexpected trailing liveness evidence content");
    return result;
}

void remove_stage(const std::filesystem::path& file, const std::filesystem::path& directory) noexcept {
    std::error_code ignored;
    std::filesystem::remove(file, ignored);
    std::filesystem::remove(directory, ignored);
}

template <typename Writer>
std::string publish_artifact(const std::filesystem::path& path, const MemoryBudget& budget,
                             Writer write) {
    const auto target = bundle::detail::absolute_windows_file_path(path);
    if (!target.has_filename() || std::filesystem::exists(target)) {
        throw std::invalid_argument("liveness output requires an unused file path");
    }
    const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
    const auto stage = target.parent_path() /
        (".q3a-live-" + std::to_string(q3a::process_id()) + "-" + std::to_string(nonce));
    const auto staged_file = stage / "result";
    if (!std::filesystem::create_directory(stage)) throw std::runtime_error("cannot stage liveness evidence");
    try {
        auto digest = write(staged_file);
        budget.check();
        if (q3a::publish_no_replace(staged_file, target)) {
            throw std::runtime_error("cannot publish liveness output without replacing an existing path");
        }
        remove_stage(staged_file, stage);
        return digest;
    } catch (...) {
        remove_stage(staged_file, stage);
        throw;
    }
}

} // namespace

std::string save_evidence(const std::filesystem::path& path, const EvidenceIdentity& identity,
    const Query& query, const Graph& graph, const Result& result, const MemoryBudget& budget) {
    return publish_artifact(path, budget, [&](const auto& staged_file) {
        std::ofstream out(staged_file, std::ios::binary);
        write_header(out, identity, query, graph);
        write_result(out, result, budget);
        out.close();
        if (!out) throw std::runtime_error("cannot write liveness evidence");
        return reopen_evidence(staged_file, identity, query, graph, budget).sha256;
    });
}

SavedEvidence reopen_evidence(const std::filesystem::path& path, const EvidenceIdentity& identity,
    const Query& query, const Graph& graph, const MemoryBudget& budget) {
    WriteLockedInput locked(bundle::detail::absolute_windows_file_path(path));
    auto& in = locked.stream();
    in.seekg(0, std::ios::end);
    const auto bytes = in.tellg();
    if (bytes < 0 || bytes > static_cast<std::streamoff>(maximum_artifact_bytes)) {
        throw std::invalid_argument("cannot determine liveness evidence size or size exceeds its limit");
    }
    locked.rewind();
    auto result = read_result(in, identity, query, graph, budget);
    if (!validate(graph, result)) throw std::invalid_argument("liveness evidence failed graph validation");
    budget.check();
    locked.rewind();
    return {std::move(result), sha256_stream(in, static_cast<std::uint64_t>(bytes))};
}

std::string save_lasso_vcd(const std::filesystem::path& path, const lowering::TIRModule& model,
    const SourceGraph& graph, const Lasso& lasso, const MemoryBudget& budget) {
    std::string scope = "__q3a_liveness";
    const auto occupied = [&](const std::string& name) {
        const auto prefix = name + ".";
        return std::any_of(model.signals.begin(), model.signals.end(), [&](const auto& signal) {
            return signal.name == name || signal.name.compare(0, prefix.size(), prefix) == 0;
        });
    };
    for (std::size_t suffix = 1; occupied(scope); ++suffix) scope = "__q3a_liveness_" + std::to_string(suffix);

    const std::array<const char*, 6> names{"request", "response", "outstanding",
        "loop_start", "loop_active", "loop_close"};
    std::vector<lowering::TIRSignal> diagnostic;
    for (const auto* name : names) {
        diagnostic.emplace_back(scope + "." + name, 1, false, "diagnostic", frontend::SourceLocation{});
    }
    trace::CaptureSignals emitted;
    replay::Frame frame;
    for (const auto& signal : model.signals) emitted.push_back(&signal);
    for (const auto& signal : diagnostic) emitted.push_back(&signal);
    std::uint64_t bytes_per_frame = model.clocks.size() * 16 + 24;
    for (const auto* signal : emitted) {
        bytes_per_frame += signal->width + 16;
        frame.emplace(signal->name, 0);
    }
    constexpr std::uint64_t maximum_payload = 128 * 1024 * 1024;
    if (lasso.path.size() > maximum_payload / bytes_per_frame) {
        throw MemoryBudgetExceeded("liveness waveform exceeds the export size limit");
    }
    const replay::FrameView frames(lasso.path.size(), [&](std::size_t index) -> const replay::Frame& {
        if (index % 256 == 0) budget.check();
        const auto vertex = lasso.path[index];
        reconstruct_sample(graph, vertex, frame);
        const auto& sample = graph.samples.at(vertex);
        const std::array<bool, names.size()> values{sample.request, sample.response, sample.waiting,
            index == lasso.loop_start, index >= lasso.loop_start, index == lasso.path.size() - 1};
        for (std::size_t bit = 0; bit < values.size(); ++bit) frame.at(diagnostic[bit].name) = values[bit];
        return frame;
    });
    return publish_artifact(path, budget, [&](const auto& staged_file) {
        std::ofstream out(staged_file, std::ios::binary);
        trace::write_witness_vcd(out, model, frames, emitted, std::nullopt, "liveness");
        out.close();
        if (!out) throw std::runtime_error("cannot write liveness waveform");
        WriteLockedInput input(staged_file);
        return sha256_stream(input.stream());
    });
}

} // namespace q3a::liveness
