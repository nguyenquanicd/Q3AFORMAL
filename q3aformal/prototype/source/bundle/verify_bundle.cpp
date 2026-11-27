#include "verify_bundle.hpp"
#include "debug_view.hpp"
#include "waveform_win32.hpp"
#include "debug_session_state.hpp"
#include "indexed_trace.hpp"
#include "trace_capture.hpp"
#include "run_bundle.hpp"
#include "windows_file_path.hpp"

#include "../source_manager/source_manager.hpp"
#include "../source_manager/induction_feasibility.hpp"
#include "../source_manager/vcd_import.hpp"
#include "../source_manager/write_locked_input.hpp"
#include "../frontend/parser.hpp"
#include "../frontend/preprocessor.hpp"
#include "../frontend/lexer.hpp"
#include "../elaborator/elaborator.hpp"
#include "../lowering/lowering.hpp"
#include "../replay/property_replay.hpp"
#include "../replay/replay_timing.hpp"
#include "../sat/sat_solver.hpp"
#include "../sat/pdr.hpp"
#include "../sat/transition_encoder.hpp"
#include "../../checker/proof_artifact.hpp"
#include "q3a_build_info.hpp"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace q3a::bundle {
namespace {

struct JsonValue {
    using Array = std::vector<JsonValue>;
    using Object = std::map<std::string, JsonValue>;
    std::variant<std::nullptr_t, bool, std::uint64_t, std::int64_t, std::string, Array, Object> data;

    bool operator==(const JsonValue& other) const { return data == other.data; }

    const JsonValue& at(const std::string& key) const {
        const auto* object = std::get_if<Object>(&data);
        if (!object) throw std::runtime_error("bundle manifest JSON value is not an object");
        const auto found = object->find(key);
        if (found == object->end()) {
            throw std::runtime_error("bundle manifest is missing field '" + key + "'");
        }
        return found->second;
    }

    const std::string& string() const {
        const auto* value = std::get_if<std::string>(&data);
        if (!value) throw std::runtime_error("bundle manifest field must be a string");
        return *value;
    }

    std::uint64_t number() const {
        const auto* value = std::get_if<std::uint64_t>(&data);
        if (!value) throw std::runtime_error("bundle manifest field must be an unsigned integer");
        return *value;
    }

    const Array& array() const {
        const auto* value = std::get_if<Array>(&data);
        if (!value) throw std::runtime_error("bundle manifest field must be an array");
        return *value;
    }

    const Object& object() const {
        const auto* value = std::get_if<Object>(&data);
        if (!value) throw std::runtime_error("bundle manifest field must be an object");
        return *value;
    }

    bool boolean() const {
        const auto* value = std::get_if<bool>(&data);
        if (!value) throw std::runtime_error("bundle manifest field must be a boolean");
        return *value;
    }

    bool is_null() const {
        return std::holds_alternative<std::nullptr_t>(data);
    }
};

class JsonParser {
public:
    explicit JsonParser(const std::string& input, std::string_view label = "bundle manifest JSON")
        : input_(input), label_(label) {}

    JsonValue parse() {
        auto value = parse_value(0);
        skip_space();
        if (position_ != input_.size()) fail("trailing data");
        return value;
    }

private:
    const std::string& input_;
    std::string_view label_;
    std::size_t position_ = 0;

    [[noreturn]] void fail(const std::string& message) const {
        throw std::runtime_error(std::string(label_) + " " + message +
                                 " at byte " + std::to_string(position_));
    }

    void skip_space() {
        while (position_ < input_.size() &&
               (input_[position_] == ' ' || input_[position_] == '\t' ||
                input_[position_] == '\r' || input_[position_] == '\n')) {
            ++position_;
        }
    }

    bool consume(char expected) {
        skip_space();
        if (position_ < input_.size() && input_[position_] == expected) {
            ++position_;
            return true;
        }
        return false;
    }

    static void append_utf8(std::string& output, std::uint32_t value) {
        if (value <= 0x7f) {
            output.push_back(static_cast<char>(value));
        } else if (value <= 0x7ff) {
            output.push_back(static_cast<char>(0xc0 | (value >> 6)));
            output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        } else if (value <= 0xffff) {
            output.push_back(static_cast<char>(0xe0 | (value >> 12)));
            output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        } else {
            output.push_back(static_cast<char>(0xf0 | (value >> 18)));
            output.push_back(static_cast<char>(0x80 | ((value >> 12) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        }
    }

    std::uint32_t parse_hex_quad() {
        if (input_.size() - position_ < 4) fail("has a truncated unicode escape");
        std::uint32_t value = 0;
        for (unsigned index = 0; index < 4; ++index) {
            const auto character = static_cast<unsigned char>(input_[position_++]);
            value <<= 4;
            if (character >= '0' && character <= '9') value |= character - '0';
            else if (character >= 'a' && character <= 'f') value |= character - 'a' + 10;
            else if (character >= 'A' && character <= 'F') value |= character - 'A' + 10;
            else fail("has an invalid unicode escape");
        }
        return value;
    }

    std::string parse_string() {
        skip_space();
        if (position_ >= input_.size() || input_[position_++] != '"') fail("expected a string");
        std::string output;
        while (position_ < input_.size()) {
            const auto character = static_cast<unsigned char>(input_[position_++]);
            if (character == '"') return output;
            if (character < 0x20) fail("contains an unescaped control character");
            if (character != '\\') {
                output.push_back(static_cast<char>(character));
                continue;
            }
            if (position_ >= input_.size()) fail("has a truncated escape");
            switch (input_[position_++]) {
            case '"': output.push_back('"'); break;
            case '\\': output.push_back('\\'); break;
            case '/': output.push_back('/'); break;
            case 'b': output.push_back('\b'); break;
            case 'f': output.push_back('\f'); break;
            case 'n': output.push_back('\n'); break;
            case 'r': output.push_back('\r'); break;
            case 't': output.push_back('\t'); break;
            case 'u': {
                auto codepoint = parse_hex_quad();
                if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
                    if (input_.size() - position_ < 6 || input_[position_] != '\\' ||
                        input_[position_ + 1] != 'u') fail("has an unpaired high surrogate");
                    position_ += 2;
                    const auto low = parse_hex_quad();
                    if (low < 0xdc00 || low > 0xdfff) fail("has an invalid low surrogate");
                    codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
                } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
                    fail("has an unpaired low surrogate");
                }
                append_utf8(output, codepoint);
                break;
            }
            default: fail("has an invalid string escape");
            }
        }
        fail("has an unterminated string");
    }

    JsonValue parse_number() {
        skip_space();
        const auto start = position_;
        const bool negative = input_[position_] == '-';
        if (negative) ++position_;
        const auto digits = position_;
        while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
            ++position_;
        }
        if (digits == position_ || (position_ - digits > 1 && input_[digits] == '0')) {
            fail("has an invalid integer");
        }
        if (negative) {
            std::int64_t value = 0;
            const auto parsed = std::from_chars(input_.data() + start,
                                                input_.data() + position_, value);
            if (parsed.ec != std::errc{} || parsed.ptr != input_.data() + position_) {
                fail("has an out-of-range signed integer");
            }
            return JsonValue{value};
        }
        std::uint64_t value = 0;
        const auto parsed = std::from_chars(input_.data() + start,
                                            input_.data() + position_, value);
        if (parsed.ec != std::errc{} || parsed.ptr != input_.data() + position_) {
            fail("has an out-of-range unsigned integer");
        }
        return JsonValue{value};
    }

    JsonValue parse_value(unsigned depth) {
        if (depth > 128) fail("exceeds the nesting limit");
        skip_space();
        if (position_ >= input_.size()) fail("ends before a value");
        const auto character = input_[position_];
        if (character == '"') return JsonValue{parse_string()};
        if (character == '-' || (character >= '0' && character <= '9')) return parse_number();
        if (input_.compare(position_, 4, "true") == 0) {
            position_ += 4;
            return JsonValue{true};
        }
        if (input_.compare(position_, 5, "false") == 0) {
            position_ += 5;
            return JsonValue{false};
        }
        if (input_.compare(position_, 4, "null") == 0) {
            position_ += 4;
            return JsonValue{nullptr};
        }
        if (consume('[')) {
            JsonValue::Array values;
            if (consume(']')) return JsonValue{std::move(values)};
            do {
                values.push_back(parse_value(depth + 1));
            } while (consume(','));
            if (!consume(']')) fail("array is missing ']' ");
            return JsonValue{std::move(values)};
        }
        if (consume('{')) {
            JsonValue::Object values;
            if (consume('}')) return JsonValue{std::move(values)};
            do {
                auto key = parse_string();
                if (!consume(':')) fail("object field is missing ':'");
                if (!values.emplace(std::move(key), parse_value(depth + 1)).second) {
                    fail("contains a duplicate object key");
                }
            } while (consume(','));
            if (!consume('}')) fail("object is missing '}' ");
            return JsonValue{std::move(values)};
        }
        fail("contains an invalid value");
    }
};

constexpr std::uint64_t kMaximumArtifactBytes = 1024ULL * 1024ULL * 1024ULL;

struct VerifiedArtifact {
    std::string role;
    std::uint64_t size;
    std::string sha256;
};

std::string read_file(const std::filesystem::path& path,
                      std::uint64_t maximum_bytes = kMaximumArtifactBytes) {
    std::error_code error;
    const auto size = std::filesystem::file_size(path, error);
    if (error || size > maximum_bytes) {
        throw std::runtime_error("bundle file is missing, unreadable, or exceeds the read limit: " +
                                 path.u8string());
    }
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot open bundle file: " + path.u8string());
    std::string content(static_cast<std::size_t>(size), '\0');
    if (!content.empty()) input.read(&content[0], static_cast<std::streamsize>(content.size()));
    if (!input || input.peek() != std::char_traits<char>::eof()) {
        throw std::runtime_error("bundle file changed or failed while reading: " + path.u8string());
    }
    return content;
}

std::string normalized_relative_path(const std::string& path) {
    if (path.empty() || path.find('\\') != std::string::npos) {
        throw std::runtime_error("bundle manifest contains an invalid artifact path");
    }
    const auto parsed = std::filesystem::u8path(path);
    if (parsed.is_absolute() || parsed.has_root_name() || parsed.has_root_directory()) {
        throw std::runtime_error("bundle manifest contains a rooted artifact path");
    }
    for (const auto& component : parsed) {
        if (component == "." || component == "..") {
            throw std::runtime_error("bundle manifest artifact path escapes the bundle root");
        }
    }
    if (parsed.lexically_normal().generic_u8string() != path) {
        throw std::runtime_error("bundle manifest artifact path is not normalized");
    }
    return path;
}

std::filesystem::path checked_artifact_path(const std::filesystem::path& root,
                                            const std::string& relative_path) {
    const auto normalized = normalized_relative_path(relative_path);
    auto native_path = normalized;
    std::replace(native_path.begin(), native_path.end(), '/',
                 static_cast<char>(std::filesystem::path::preferred_separator));
    auto current = root;
    const auto relative = std::filesystem::u8path(native_path);
    for (auto iterator = relative.begin(); iterator != relative.end(); ++iterator) {
        current /= *iterator;
        std::error_code error;
        const auto status = std::filesystem::symlink_status(detail::windows_file_path(current), error);
        if (error || std::filesystem::is_symlink(status)) {
            throw std::runtime_error("bundle artifact is missing or traverses a symbolic link: " +
                                     relative_path);
        }
        const auto next = iterator;
        const bool last = std::next(next) == relative.end();
        if ((!last && !std::filesystem::is_directory(status)) ||
            (last && !std::filesystem::is_regular_file(status))) {
            throw std::runtime_error("bundle artifact path has an invalid filesystem type: " +
                                     relative_path);
        }
    }
    return detail::windows_file_path(current);
}

const JsonValue* find_by_id(const std::vector<const JsonValue*>& values,
                            const std::string& id) {
    for (const auto* value : values) {
        if (value->at("id").string() == id) return value;
    }
    return nullptr;
}

bool component_fingerprint_matches(const JsonValue& manifest,
                                  const std::string& component_id,
                                  const std::string& expected_fingerprint) {
    bool found = false;
    for (const auto& component : manifest.at("components").array()) {
        if (component.at("id").string() != component_id) continue;
        if (found || component.at("source_sha256").string() != expected_fingerprint) {
            return false;
        }
        found = true;
    }
    return found;
}

frontend::SourceLocation parse_source_location(const JsonValue& value) {
    frontend::SourceLocation location;
    location.file = value.at("file").string();
    location.line = static_cast<std::size_t>(value.at("line").number());
    location.column = static_cast<std::size_t>(value.at("column").number());
    return location;
}

lowering::TypedExpression parse_tir_expression(const JsonValue& value) {
    lowering::TypedExpression expression;
    expression.kind = value.at("kind").string();
    expression.value = value.at("value").string();
    expression.width = value.at("width").number();
    expression.is_signed = value.at("signed").boolean();
    expression.location = parse_source_location(value.at("source"));
    for (const auto& operand : value.at("operands").array()) {
        expression.operands.push_back(parse_tir_expression(operand));
    }
    return expression;
}

lowering::TIRSequence parse_tir_sequence(const JsonValue& value) {
    lowering::TIRSequence sequence;
    for (const auto& term_value : value.at("terms").array()) {
        lowering::TIRSequenceTerm term;
        term.delay_from_previous = term_value.at("delay_from_previous").number();
        term.repeat_min = term_value.at("repeat_min").number();
        term.repeat_max = term_value.at("repeat_max").number();
        term.location = parse_source_location(term_value.at("source"));
        term.predicate = parse_tir_expression(term_value.at("predicate"));
        sequence.terms.push_back(std::move(term));
    }
    const auto& automaton = value.at("automaton");
    sequence.automaton.state_count = automaton.at("state_count").number();
    sequence.automaton.start_state = automaton.at("start_state").number();
    sequence.automaton.accepting_state = automaton.at("accepting_state").number();
    for (const auto& transition_value : automaton.at("transitions").array()) {
        lowering::TIRSequenceTransition transition;
        transition.source_state = transition_value.at("source_state").number();
        transition.target_state = transition_value.at("target_state").number();
        transition.delay_cycles = transition_value.at("delay_cycles").number();
        transition.repeat_min = transition_value.at("repeat_min").number();
        transition.repeat_max = transition_value.at("repeat_max").number();
        transition.predicate = parse_tir_expression(
            transition_value.at("predicate"));
        transition.location = parse_source_location(
            transition_value.at("source"));
        sequence.automaton.transitions.push_back(std::move(transition));
    }
    return sequence;
}

lowering::TIRModule parse_tir_model(const std::string& content) {
    const auto root = JsonParser(content).parse();
    lowering::TIRModule module;
    module.schema_version = root.at("schema_version").string();
    if (module.schema_version != "Q3A-TIR-0.3" &&
        module.schema_version != "Q3A-TIR-0.4") {
        throw std::runtime_error("bundle T-IR schema is unsupported for replay");
    }
    module.semantic_profile = root.at("semantic_profile").string();
    module.input_hash = root.at("input_sha256").string();
    module.name = root.at("top_module").string();
    for (const auto& signal_value : root.at("signals").array()) {
        lowering::TIRSignal signal;
        signal.name = signal_value.at("name").string();
        signal.width = signal_value.at("width").number();
        signal.is_signed = signal_value.at("signed").boolean();
        signal.role = signal_value.at("role").string();
        signal.location = parse_source_location(signal_value.at("source"));
        module.signals.push_back(std::move(signal));
    }
    for (const auto& clock : root.at("clocks").array()) {
        module.clocks.push_back(clock.string());
    }
    for (const auto& guard_value : root.at("history_guards").array()) {
        lowering::TIRHistoryGuard guard;
        guard.clock = guard_value.at("clock").string();
        guard.delay = guard_value.at("delay").number();
        guard.valid_signal = guard_value.at("valid_signal").string();
        for (const auto& state : guard_value.at("state_chain").array()) {
            guard.state_chain.push_back(state.string());
        }
        module.history_guards.push_back(std::move(guard));
    }
    for (const auto& property_value : root.at("properties").array()) {
        lowering::TIRProperty property;
        property.name = property_value.at("name").string();
        property.kind = property_value.at("kind").string();
        property.clock = property_value.at("clock").string();
        property.implication = property_value.at("implication").string();
        property.history_guard_delay =
            property_value.at("history_guard_delay").number();
        const auto& guard = property_value.at("history_guard_signal");
        if (!guard.is_null()) property.history_guard_signal = guard.string();
        if (module.schema_version == "Q3A-TIR-0.4") {
            property.split_history_guards =
                property_value.at("split_history_guards").boolean();
            property.antecedent_history_guard_delay =
                property_value.at("antecedent_history_guard_delay").number();
            const auto& antecedent_guard =
                property_value.at("antecedent_history_guard_signal");
            if (!antecedent_guard.is_null()) {
                property.antecedent_history_guard_signal =
                    antecedent_guard.string();
            }
            property.consequent_history_guard_delay =
                property_value.at("consequent_history_guard_delay").number();
            const auto& consequent_guard =
                property_value.at("consequent_history_guard_signal");
            if (!consequent_guard.is_null()) {
                property.consequent_history_guard_signal =
                    consequent_guard.string();
            }
        }
        property.location = parse_source_location(property_value.at("source"));
        property.antecedent = parse_tir_sequence(
            property_value.at("antecedent"));
        const auto& consequent = property_value.at("consequent");
        if (!consequent.is_null()) {
            property.consequent = parse_tir_sequence(consequent);
        }
        module.properties.push_back(std::move(property));
    }
    const auto parse_equations = [](const JsonValue& values,
                                    std::vector<lowering::TIREquation>& equations) {
        for (const auto& equation_value : values.array()) {
            lowering::TIREquation equation;
            equation.target = equation_value.at("target").string();
            equation.target_width = equation_value.at("target_width").number();
            equation.location = parse_source_location(equation_value.at("source"));
            equation.expression = parse_tir_expression(
                equation_value.at("expression"));
            equations.push_back(std::move(equation));
        }
    };
    parse_equations(root.at("combinational_equations"),
                    module.combinational_equations);
    parse_equations(root.at("next_state_equations"),
                    module.next_state_equations);
    return module;
}

std::uint64_t parse_trace_value(const std::string& text) {
    if (text.size() < 3 || text[0] != '0' ||
        (text[1] != 'x' && text[1] != 'X')) {
        throw std::runtime_error("bundle BMC trace contains a non-hex signal value");
    }
    std::uint64_t value = 0;
    const auto parsed = std::from_chars(text.data() + 2,
        text.data() + text.size(), value, 16);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
        throw std::runtime_error("bundle BMC trace contains an invalid signal value");
    }
    return value;
}

struct ParsedBmcTrace {
    std::string property;
    std::size_t candidate_frame = 0;
    std::vector<replay::Frame> frames;
};

ParsedBmcTrace parse_bmc_trace(const std::string& content) {
    const auto root = JsonParser(content).parse();
    if (root.at("schema_version").string() != "Q3A-TRACE-JSON-1" ||
        !root.at("validated").boolean()) {
        throw std::runtime_error("bundle BMC trace schema or validated marker is invalid");
    }
    ParsedBmcTrace trace;
    trace.property = root.at("property").string();
    const auto candidate = root.at("candidate_frame").number();
    if (candidate > std::numeric_limits<std::size_t>::max()) {
        throw std::runtime_error("bundle BMC candidate frame exceeds host limits");
    }
    trace.candidate_frame = static_cast<std::size_t>(candidate);
    std::size_t expected_index = 0;
    for (const auto& frame_value : root.at("frames").array()) {
        if (frame_value.at("index").number() != expected_index) {
            throw std::runtime_error("bundle BMC trace frame indices are not contiguous");
        }
        replay::Frame frame;
        for (const auto& signal : frame_value.at("signals").object()) {
            frame.emplace(signal.first, parse_trace_value(signal.second.string()));
        }
        trace.frames.push_back(std::move(frame));
        ++expected_index;
    }
    if (trace.frames.empty() || trace.candidate_frame >= trace.frames.size()) {
        throw std::runtime_error("bundle BMC trace has an invalid frame count or candidate");
    }
    return trace;
}

void replay_induction_witness(const std::string& content,
                              const lowering::TIRModule& model,
                              const std::string& property, const std::string& id,
                              std::uint64_t depth, const std::string& model_hash,
                              const std::string& query_hash) {
    std::istringstream input(content);
    const auto expect = [&](const std::string& expected) {
        std::string line;
        if (!std::getline(input, line) || line != expected) {
            throw std::runtime_error("induction witness identity or record is invalid");
        }
    };
    expect("Q3A_INDUCTION_WITNESS 1");
    expect("obligation " + id);
    expect("depth " + std::to_string(depth));
    expect("model_sha256 " + model_hash);
    expect("query_sha256 " + query_hash);
    const bool base = id == "base";
    if (!base) {
        for (std::uint64_t frame = 0; frame < depth; ++frame) {
            expect("property " + property + " frame=" + std::to_string(frame) + " value=TRUE");
        }
        expect("property " + property + " frame=" + std::to_string(depth) + " value=FALSE");
    }
    const auto number = [](std::string_view text) {
        std::uint64_t value = 0;
        const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
        if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
            throw std::runtime_error("induction witness has an invalid numeric field");
        }
        return value;
    };
    std::string line;
    std::uint64_t claimed_failure = depth;
    if (base) {
        const auto prefix = "property " + property + " frame=";
        constexpr std::string_view suffix = " value=FALSE";
        if (!std::getline(input, line) || line.size() <= prefix.size() + suffix.size() ||
            line.compare(0, prefix.size(), prefix) != 0 ||
            line.compare(line.size() - suffix.size(), suffix.size(), suffix) != 0) {
            throw std::runtime_error("induction base failure record is invalid");
        }
        claimed_failure = number(std::string_view(line).substr(
            prefix.size(), line.size() - prefix.size() - suffix.size()));
    }
    std::map<std::string, std::uint64_t> widths;
    for (const auto& signal : model.signals) widths.emplace(signal.name, signal.width);
    std::vector<replay::Frame> frames;
    bool saw_end = false;
    while (std::getline(input, line)) {
        if (line == "replay VALIDATED frame=" + std::to_string(claimed_failure)) {
            saw_end = true;
            break;
        }
        if (line == "frame " + std::to_string(frames.size()) && frames.size() < 10001) {
            frames.emplace_back();
            continue;
        }
        std::istringstream row(line);
        std::string tag, name, width, value, extra;
        if (frames.empty() || !(row >> tag >> name >> width >> value) || (row >> extra) ||
            tag != "signal" || width.compare(0, 6, "width=") != 0 ||
            value.compare(0, 6, "value=") != 0 || !widths.count(name) ||
            number(std::string_view(width).substr(6)) != widths.at(name) ||
            !frames.back().emplace(name, parse_trace_value(value.substr(6))).second) {
            throw std::runtime_error("induction witness signal or frame record is invalid");
        }
    }
    if (!saw_end || std::getline(input, line)) {
        throw std::runtime_error("induction witness trailer is invalid");
    }
    const auto replayed = replay::validate_induction_countermodel(model, frames, property,
        static_cast<std::size_t>(depth), base ? replay::InductionObligation::Base :
                                               replay::InductionObligation::Step);
    if (!replayed.validated || replayed.failure_frame != claimed_failure) {
        throw std::runtime_error("induction witness replay failed: " + replayed.message);
    }
}

} // namespace

static void verify_bundle(const std::filesystem::path& bundle_directory,
                          std::ostream& output, VerifiedDebugSession* session,
                          const DebugOptions& debug_options, bool require_source_model,
                          const JsonValue* batch_config = nullptr, std::string_view batch_status = {},
                          const MemoryBudget* batch_memory = nullptr) {
    auto* debug = session ? &session->view : nullptr;
    const MemoryBudget default_memory;
    const auto& memory_budget = batch_memory ? *batch_memory : default_memory;
    const replay::ReplayTiming timing(require_source_model && !session && !batch_config);
    const auto integrity_started = timing.start();
    memory_budget.check();
    std::error_code error;
    const auto absolute = std::filesystem::absolute(bundle_directory, error);
    if (error) throw std::runtime_error("bundle path is not an accessible directory");
    const auto root = detail::canonical_directory(absolute, error);
    if (error || !std::filesystem::is_directory(detail::windows_file_path(root))) {
        throw std::runtime_error("bundle path is not an accessible directory");
    }
    const auto manifest_path = checked_artifact_path(root, "manifest.json");
    const auto sidecar_path = checked_artifact_path(root, "manifest.sha256");
    const auto manifest_content = read_file(manifest_path, 64ULL * 1024ULL * 1024ULL);
    const auto sidecar = read_file(sidecar_path, 1024);
    auto declared_manifest_hash = sidecar;
    while (!declared_manifest_hash.empty() &&
           (declared_manifest_hash.back() == '\n' || declared_manifest_hash.back() == '\r' ||
            declared_manifest_hash.back() == ' ' || declared_manifest_hash.back() == '\t')) {
        declared_manifest_hash.pop_back();
    }
    if (declared_manifest_hash != q3a::sha256_hex(manifest_content)) {
        throw std::runtime_error("bundle manifest SHA-256 does not match manifest.sha256");
    }

    const auto manifest = JsonParser(manifest_content).parse();
    if (manifest.at("schema_version").string() != "Q3A-RUN-BUNDLE-1") {
        throw std::runtime_error("unsupported result bundle schema");
    }
    if (manifest.at("profile").at("id").string() == frontend::kFourStateProfile) {
        throw std::runtime_error("four-state profiles cannot use two-state result bundles");
    }
    const auto& artifact_values = manifest.at("artifacts").array();
    std::map<std::string, VerifiedArtifact> artifacts;
    std::string vcd_path;
    for (const auto& value : artifact_values) {
        const auto path = normalized_relative_path(value.at("path").string());
        const auto role = value.at("role").string();
        const auto expected_size = value.at("size_bytes").number();
        const auto expected_hash = value.at("sha256").string();
        if (expected_hash.size() != 64 || artifacts.count(path) != 0) {
            throw std::runtime_error("bundle manifest has an invalid or duplicate artifact identity");
        }
        const auto native_path = checked_artifact_path(root, path);
        const auto size = std::filesystem::file_size(native_path);
        if (size > kMaximumArtifactBytes) {
            throw std::runtime_error("bundle artifact exceeds the read limit: " + path);
        }
        std::ifstream input(native_path, std::ios::binary);
        if (!input) throw std::runtime_error("cannot open bundle artifact: " + path);
        if (size != expected_size || q3a::sha256_stream(input, expected_size) != expected_hash) {
            throw std::runtime_error("bundle artifact size or SHA-256 mismatch: " + path);
        }
        artifacts.emplace(path, VerifiedArtifact{role, expected_size, expected_hash});
        if (role == "vcd_export") {
            if (!vcd_path.empty()) throw std::runtime_error("multiple VCD waveform artifacts");
            vcd_path = path;
        }
    }
    const auto integrity_elapsed = timing.elapsed(integrity_started);
    // Materialize only what this proof or replay uses. Recheck the bytes used for
    // semantic validation in case a file changed after the inventory pass.
    const auto read_verified = [&](const std::string& path) {
        const auto& record = artifacts.at(path);
        memory_budget.check(record.size);
        auto content = read_file(checked_artifact_path(root, path), record.size);
        if (content.size() != record.size || q3a::sha256_hex(content) != record.sha256) {
            throw std::runtime_error("bundle artifact changed after integrity verification: " + path);
        }
        return content;
    };

    const auto& project = manifest.at("project");
    const auto project_path = project.at("manifest_path").string();
    const auto project_found = artifacts.find(project_path);
    if (project_path != "source-snapshot/project.q3a" ||
        project_found == artifacts.end() || project_found->second.role != "project_manifest" ||
        project_found->second.sha256 != project.at("manifest_sha256").string()) {
        throw std::runtime_error("bundle project manifest identity is invalid");
    }
    const auto header_field = project.object().find("headers");
    const auto include_field = project.object().find("include_dirs");
    std::vector<const JsonValue*> rtl_entries;
    for (const auto& source : project.at("sources").array()) rtl_entries.push_back(&source);
    if (header_field != project.object().end()) {
        for (const auto& header : header_field->second.array()) rtl_entries.push_back(&header);
    }
    for (const auto* entry : rtl_entries) {
        const auto& source = *entry;
        const auto snapshot_path = normalized_relative_path(source.at("snapshot_path").string());
        const auto found = artifacts.find(snapshot_path);
        if (found == artifacts.end() || found->second.role != "rtl_source" ||
            found->second.size != source.at("size_bytes").number() ||
            found->second.sha256 != source.at("sha256").string()) {
            throw std::runtime_error("bundle RTL source snapshot identity is invalid: " +
                                     source.at("path").string());
        }
    }

    const auto& model = manifest.at("model");
    const auto model_path = normalized_relative_path(model.at("path").string());
    const auto model_found = artifacts.find(model_path);
    if (model_found == artifacts.end() || model_found->second.role != "canonical_tir" ||
        model_found->second.size != model.at("size_bytes").number() ||
        model_found->second.sha256 != model.at("sha256").string()) {
        throw std::runtime_error("bundle canonical model identity is invalid");
    }

    const bool compatible_source_pipeline =
        component_fingerprint_matches(manifest, "source_manager",
            q3a::build_info::kComponentHash_source_manager) &&
        component_fingerprint_matches(manifest, "frontend",
            q3a::build_info::kComponentHash_frontend) &&
        component_fingerprint_matches(manifest, "elaborator",
            q3a::build_info::kComponentHash_elaborator) &&
        component_fingerprint_matches(manifest, "lowering_sva",
            q3a::build_info::kComponentHash_lowering_sva);
    std::optional<std::vector<lowering::TIRSignal>> waveform_source_signals;
    const auto source_started = timing.start();
    if (compatible_source_pipeline || require_source_model) {
        q3a::ProjectInput source_project;
        source_project.profile_id = manifest.at("profile").at("id").string();
        const auto syntax_profile = frontend::project_syntax_profile(source_project.profile_id);
        if (!syntax_profile) throw std::runtime_error("unsupported source bundle profile");
        source_project.top_module = project.at("top_module").string();
        source_project.manifest_version = project.at("manifest_schema").string() == "Q3AFORMAL_PROJECT_2" ? 2 : 1;
        if ((header_field != project.object().end() || include_field != project.object().end()) &&
            source_project.manifest_version != 2) {
            throw std::runtime_error("bundle includes require a version 2 project manifest");
        }
        if (include_field != project.object().end()) {
            for (const auto& dir : include_field->second.array()) source_project.include_dirs.push_back(dir.string());
        }
        for (const auto& parameter : project.at("parameters").object()) {
            source_project.parameters.emplace(parameter.first, parameter.second.string());
        }
        const auto macros = project.object().find("macros");
        if (macros != project.object().end()) {
            if (source_project.manifest_version != 2) {
                throw std::runtime_error("bundle macros require a version 2 project manifest");
            }
            for (const auto& macro : macros->second.object()) {
                source_project.macros.emplace(macro.first, macro.second.string());
            }
        }
        std::set<std::string> source_paths;
        for (const auto& source : project.at("sources").array()) {
            const auto path = normalized_relative_path(source.at("path").string());
            const auto snapshot = source.at("snapshot_path").string();
            if (snapshot != "source-snapshot/rtl/" + path || !source_paths.insert(path).second) {
                throw std::runtime_error("bundle resolved RTL source roster is invalid");
            }
            const auto text = read_verified(snapshot);
            source_project.sources.push_back({path, {text.begin(), text.end()}, artifacts.at(snapshot).sha256});
            memory_budget.check();
        }
        std::map<std::string, std::string> archived_headers;
        if (header_field != project.object().end()) {
            for (const auto& header : header_field->second.array()) {
                const auto path = normalized_relative_path(header.at("path").string());
                const auto snapshot = header.at("snapshot_path").string();
                if (snapshot != "source-snapshot/rtl/" + path || !archived_headers.emplace(path, snapshot).second) {
                    throw std::runtime_error("bundle resolved header roster is invalid");
                }
            }
        }
        q3a::preprocess_project_includes(source_project, [&](const std::string& path)
            -> std::optional<std::vector<std::uint8_t>> {
            const auto header = archived_headers.find(path);
            if (header == archived_headers.end()) return std::nullopt;
            const auto bytes = read_verified(header->second);
            return std::vector<std::uint8_t>(bytes.begin(), bytes.end());
        });
        if (source_project.headers.size() != archived_headers.size()) {
            throw std::runtime_error("bundle header roster does not match the active include dependencies");
        }
        if (header_field != project.object().end()) {
            const auto& recorded = header_field->second.array();
            for (std::size_t index = 0; index < recorded.size(); ++index) {
                const auto& used = source_project.headers[index];
                if (used.relative_path != recorded[index].at("path").string() ||
                    used.sha256 != recorded[index].at("sha256").string()) {
                    throw std::runtime_error("bundle include order or header identity does not match");
                }
            }
        }
        source_project.input_hash = q3a::source_set_sha256(source_project);
        if (source_project.sources.empty() || source_project.input_hash !=
                manifest.at("profile").at("source_set_sha256").string()) {
            throw std::runtime_error("bundle resolved RTL source-set identity does not match");
        }
        std::vector<frontend::SyntaxUnit> units;
        if (!source_project.preprocessed_units.empty()) {
            for (auto& tokens : source_project.preprocessed_units) {
                units.push_back(frontend::parse_source(std::move(tokens), source_project.manifest_version == 2, *syntax_profile));
            }
        } else {
            frontend::Preprocessor preprocessor(source_project.macros);
            for (const auto& source : source_project.sources) {
                const std::string text(source.contents.begin(), source.contents.end());
                auto tokens = source_project.manifest_version == 2 ? preprocessor.tokenize_unit(text, source.relative_path)
                    : frontend::tokenize(text, source.relative_path);
                units.push_back(frontend::parse_source(std::move(tokens), source_project.manifest_version == 2, *syntax_profile));
            }
        }
        const auto elaborated = elaboration::elaborate_top(
            units, source_project.top_module, source_project.parameters,
            source_project.profile_id, source_project.input_hash);
        auto regenerated = lowering::lower_continuous_assignments(units, elaborated);
        if (q3a::sha256_hex(lowering::serialize_tir(regenerated)) != model_found->second.sha256) {
            throw std::runtime_error("regenerated T-IR differs from the saved model");
        }
        if (!vcd_path.empty()) waveform_source_signals.emplace(std::move(regenerated.signals));
        output << "Q3A_BUNDLE_SOURCE_MODEL VERIFIED\n";
    } else {
        output << "Q3A_BUNDLE_SOURCE_MODEL UNVERIFIED\n";
    }
    const auto source_elapsed = timing.elapsed(source_started);

    const auto& query_values = manifest.at("queries").array();
    std::vector<const JsonValue*> queries;
    std::set<std::string> query_ids;
    for (const auto& query : query_values) {
        const auto query_path = normalized_relative_path(query.at("cnf_path").string());
        const auto found = artifacts.find(query_path);
        if (!query_ids.insert(query.at("id").string()).second ||
            found == artifacts.end() || found->second.role != "query_cnf" ||
            found->second.sha256 != query.at("cnf_sha256").string()) {
            throw std::runtime_error("bundle query identity is missing, duplicated, or invalid");
        }
        queries.push_back(&query);
    }

    const auto& checker = manifest.at("checker");
    const auto checker_id = checker.at("id").string();
    const auto checker_fingerprint = checker.at("fingerprint_sha256").string();
    const auto checker_schema = checker.at("proof_artifact_schema").string();
    const auto checker_component_id = checker_schema.empty()
        ? std::string("witness_replay")
        : std::string("proof_checker");
    bool matching_component_fingerprint = false;
    for (const auto& component : manifest.at("components").array()) {
        if (component.at("id").string() == checker_component_id) {
            if (matching_component_fingerprint ||
                component.at("source_sha256").string() != checker_fingerprint) {
                throw std::runtime_error("bundle checker and component fingerprints disagree");
            }
            matching_component_fingerprint = true;
        }
    }
    if (!matching_component_fingerprint) {
        throw std::runtime_error("bundle manifest does not fingerprint its recorded checker component");
    }
    // Strict verification checks the archived proof with the current checker
    // on regenerated queries. The artifact format must still be supported.
    const bool can_check_proof = checker_id == q3a::checker::kCheckerId &&
        checker_schema == std::to_string(q3a::checker::kProofArtifactSchema) &&
        (require_source_model || checker_fingerprint == q3a::build_info::kComponentHash_proof_checker);
    const auto& command = manifest.at("command").string();
    const auto& run_result = manifest.at("result");
    const auto& run_property = run_result.at("property").string();
    auto saved_model = parse_tir_model(read_verified(model_path));
    const bool waveform_source_ranges = waveform_source_signals.has_value();
    if (waveform_source_signals) {
        // The checked canonical model omits source-level packed ranges.
        for (std::size_t i = 0; i < saved_model.signals.size(); ++i) {
            saved_model.signals[i].packed_left_index = waveform_source_signals->at(i).packed_left_index;
            saved_model.signals[i].packed_right_index = waveform_source_signals->at(i).packed_right_index;
        }
        waveform_source_signals.reset();
    }
    std::vector<std::string> model_assumptions;
    for (const auto& property : saved_model.properties) {
        if (property.kind == "assume") model_assumptions.push_back(property.name);
    }
    const auto check_assumptions = [&](const JsonValue& value, const char* report) {
        const auto& recorded = value.at("assumptions").array();
        if (recorded.size() != model_assumptions.size() ||
            !std::equal(recorded.begin(), recorded.end(), model_assumptions.begin(),
                [](const auto& name, const auto& expected) { return name.string() == expected; })) {
            throw std::runtime_error(std::string(report) + " assumptions do not match the saved T-IR");
        }
    };
    check_assumptions(manifest, "bundle manifest");
    const auto report = std::find_if(artifacts.begin(), artifacts.end(),
        [](const auto& entry) { return entry.second.role == "property_result"; });
    if (report == artifacts.end() ||
        std::any_of(std::next(report), artifacts.end(),
            [](const auto& entry) { return entry.second.role == "property_result"; })) {
        throw std::runtime_error("bundle requires one property result report");
    }
    const auto property_report = JsonParser(read_verified(report->first)).parse();
    check_assumptions(property_report, "property report");
    if (manifest.at("reset_initial_policy").string() != kResetInitialPolicy) {
        throw std::runtime_error("bundle reset and initial-state policy does not match the supported model");
    }
    const auto target = std::find_if(saved_model.properties.begin(), saved_model.properties.end(),
        [&](const auto& property) { return property.name == run_property && property.kind != "assume"; });
    if (target == saved_model.properties.end() || target->clock.empty() ||
        std::find(saved_model.clocks.begin(), saved_model.clocks.end(), target->clock) == saved_model.clocks.end()) {
        throw std::runtime_error("bundle property has no sampling clock in the saved T-IR");
    }
    const auto sampling = manifest.object().find("sampling_context");
    if (sampling != manifest.object().end() &&
        (sampling->second.at("clock").string() != target->clock ||
         sampling->second.at("edge").string() != "posedge")) {
        throw std::runtime_error("bundle sampling clock or edge does not match the saved T-IR property");
    }
    const auto& property_schema = property_report.at("schema_version").string();
    if (property_schema == "Q3A-PROPERTY-RESULT-2") {
        const auto expected = trace::PropertySignalIndex(saved_model).for_property(*target);
        const auto& recorded = property_report.at("signals");
        const auto matches = [&](const char* key, const std::vector<std::string>& names) {
            const auto& list = recorded.at(key).array();
            return list.size() == names.size() &&
                std::equal(list.begin(), list.end(), names.begin(),
                    [](const auto& entry, const auto& name) { return entry.string() == name; });
        };
        if (property_report.at("property").string() != run_property ||
            !matches("rtl", expected.rtl) || !matches("model", expected.model)) {
            throw std::runtime_error("property signal inventory does not match the saved T-IR");
        }
        output << "Q3A_BUNDLE_PROPERTY_SIGNALS VERIFIED\n";
    } else if (property_schema != "Q3A-PROPERTY-RESULT-1") {
        throw std::runtime_error("unsupported bundle property result schema");
    }
    output << "Q3A_BUNDLE_MODEL_CONTEXT VERIFIED\n";
    const bool activation_witness = run_result.at("status").string() == "ACTIVATION_REACHED";
    if (activation_witness && command != "bmc") {
        throw std::runtime_error("activation witness requires the bounded replay command");
    }
    const auto depth = run_result.at("bound").number();
    const auto archived_config = artifacts.find(kRunConfigurationPath);
    if (batch_config && (archived_config == artifacts.end() || run_result.at("status").string() != batch_status)) {
        throw std::runtime_error("checkpoint result disagrees with the evidence bundle verdict");
    }
    if (archived_config != artifacts.end()) {
        if (archived_config->second.role != "run_configuration") {
            throw std::runtime_error("invalid run configuration artifact role");
        }
        const auto config = JsonParser(read_verified(archived_config->first)).parse();
        if (batch_config && !(config == *batch_config)) {
            throw std::runtime_error("checkpoint result disagrees with the evidence bundle configuration");
        }
        const auto& engine = config.at("engine").string();
        const auto& goal = config.at("goal").string();
        const bool contradiction = run_result.at("status").string() == "INCONSISTENT_MODEL_OR_ASSUMPTIONS";
        const auto version = config.at("manifest_version").number();
        const auto& profile = manifest.at("profile");
        if ((version != 1 && version != 2) ||
            "Q3AFORMAL_PROJECT_" + std::to_string(version) != project.at("manifest_schema").string() ||
            config.at("project_manifest_sha256").string() != project.at("manifest_sha256").string() ||
            config.at("source_set_sha256").string() != profile.at("source_set_sha256").string() ||
            config.at("semantic_profile").string() != profile.at("id").string() ||
            config.at("top_module").string() != project.at("top_module").string() ||
            config.at("build_id").string() != manifest.at("build").at("id").string() ||
            config.at("property").string() != run_property ||
            config.at("property_kind").string() != target->kind ||
            config.at("clock").string() != target->clock ||
            config.at("reset_initial_policy").string() != kResetInitialPolicy ||
            config.at("workers").number() != 1 || config.at("timeout_ms").number() > 86400000 ||
            (goal != (target->kind == "cover" ? "cover" : "safety") &&
             !(goal == "activation" && target->kind == "assert" && engine == "pdr" &&
               (activation_witness || contradiction))) ||
            (activation_witness && goal != "activation")) {
            throw std::runtime_error("bundle run configuration does not match its model or property");
        }
        check_assumptions(config, "run configuration");
        config.at("search_private_limit_bytes").number();
        config.at("search_physical_reserve_bytes").number();
        for (const auto* setting : {"parameters", "macros"}) {
            const auto& saved = config.at(setting).object();
            const auto found = project.object().find(setting);
            if (found == project.object().end() ? !saved.empty() :
                saved.size() != found->second.object().size() ||
                !std::equal(saved.begin(), saved.end(), found->second.object().begin(),
                    [](const auto& a, const auto& b) { return a.first == b.first && a.second.string() == b.second.string(); })) {
                throw std::runtime_error("bundle run configuration settings differ from the archived project");
            }
        }
        const auto& includes = config.at("include_dirs").array();
        if (include_field == project.object().end() ? !includes.empty() :
            includes.size() != include_field->second.array().size() ||
            !std::equal(includes.begin(), includes.end(), include_field->second.array().begin(),
                [](const auto& a, const auto& b) { return a.string() == b.string(); })) {
            throw std::runtime_error("bundle run configuration include directories differ from the archived project");
        }
        for (const auto* roster : {"sources", "headers"}) {
            const auto& saved = config.at(roster).array();
            const auto found = project.object().find(roster);
            if (found == project.object().end() ? !saved.empty() :
                saved.size() != found->second.array().size() ||
                !std::equal(saved.begin(), saved.end(), found->second.array().begin(),
                    [](const auto& a, const auto& b) {
                        return a.at("path").string() == b.at("path").string() &&
                               a.at("sha256").string() == b.at("sha256").string();
                    })) {
                throw std::runtime_error("bundle run configuration source roster differs from the archived project");
            }
        }
        bool bounds_match = false;
        if (engine == "bmc") {
            bounds_match = command == "bmc" && config.at("transition_count").number() == depth;
        } else if (engine == "induction") {
            const auto requested = config.at("induction_depth").number();
            bounds_match = requested >= 1 && requested <= 10000 && target->kind == "assert" &&
                (contradiction ? command == "bmc" &&
                    q3a::induction_feasibility_bound(saved_model, *target, requested) == depth :
                    command == "k-induction" && requested == depth);
        } else if (engine == "pdr") {
            const auto requested = config.at("maximum_depth").number();
            const auto prefix = config.at("minimum_feasibility_bound").number();
            bounds_match = command == "bmc" && requested >= 1 && requested <= q3a::pdr::kMaximumDepth &&
                prefix <= q3a::pdr::kMaximumDepth && config.at("maximum_search_queries").number() > 0 &&
                depth <= (contradiction ? std::max(requested, prefix) : requested);
        }
        if (!bounds_match) {
            throw std::runtime_error("bundle run configuration bounds disagree with the archived query");
        }
        output << "Q3A_BUNDLE_RUN_CONFIGURATION VERIFIED sha256=" << archived_config->second.sha256 << '\n';
    }
    const auto induction_query_kind = [depth](const std::string& id) {
        return (depth == 1 ? "induction-" : "induction-k" + std::to_string(depth) + "-") + id;
    };
    if (command == "k-induction" && run_result.at("status").string() == "PROVEN") {
        if (queries.size() != 2) {
            throw std::runtime_error("proven induction bundle requires a checked base and step");
        }
        for (const auto* id : {"base", "step"}) {
            const auto* query = find_by_id(queries, id);
            if (query == nullptr || query->at("status").string() != "UNSAT_CHECKED") {
                throw std::runtime_error("proven induction bundle requires a checked base and step");
            }
        }
    }
    // Source-required verification matches regenerated obligations before
    // evaluating saved evidence, even across encoder builds.
    const bool can_rebuild_queries = require_source_model || component_fingerprint_matches(
        manifest, "sat_bit_blaster", q3a::build_info::kComponentHash_sat_bit_blaster);
    const auto induction_model = [&]() -> const lowering::TIRModule& {
        if (saved_model.name != project.at("top_module").string() ||
            saved_model.semantic_profile != manifest.at("profile").at("id").string() ||
            saved_model.input_hash != manifest.at("profile").at("source_set_sha256").string()) {
            throw std::runtime_error("induction T-IR identity does not match the bundle project profile");
        }
        return saved_model;
    };
    if (command == "k-induction" && run_result.at("status").string() == "PROVEN") {
        const auto& tir = induction_model();
        const auto target = std::find_if(tir.properties.begin(), tir.properties.end(),
            [&](const auto& property) {
                return property.name == run_property && property.kind == "assert";
            });
        if (target == tir.properties.end()) {
            throw std::runtime_error("induction assertion is missing from the saved model");
        }
        const auto bound = q3a::induction_feasibility_bound(tir, *target, depth);
        sat::Solver solver([&memory_budget](std::uint64_t pending) { memory_budget.check(pending); });
        sat::TransitionCnfEncoder encoder(solver, tir);
        encoder.encode(bound);
        encoder.constrain_assumptions();
        const auto feasible = solver.solve_incremental();
        if (feasible.status == sat::Status::Unsatisfiable) {
            throw std::runtime_error("induction proof has an inconsistent model or assumptions");
        }
        if (feasible.status == sat::Status::Unknown) {
            throw VerificationResourceLimit("induction proof feasibility revalidation was inconclusive");
        }
        output << "Q3A_BUNDLE_INDUCTION_FEASIBILITY VERIFIED bound=" << bound << '\n';
    }
    const auto check_induction_cnf = [&](const std::string& id, const JsonValue& query) {
        const auto& tir = induction_model();
        const auto target = std::find_if(tir.properties.begin(), tir.properties.end(),
            [&](const lowering::TIRProperty& property) {
                return property.name == run_property && property.kind == "assert";
            });
        if (target == tir.properties.end()) {
            throw std::runtime_error("induction assertion is missing from the saved model");
        }
        sat::Solver solver([&memory_budget](std::uint64_t pending) {
            memory_budget.check(pending);
        });
        sat::TransitionCnfEncoder encoder(solver, tir);
        encoder.encode_induction_obligation(*target, depth, id == "base");
        const auto regenerated_hash = q3a::sha256_generated(
            [&](std::ostream& cnf) { solver.write_dimacs(cnf); });
        if (regenerated_hash != query.at("cnf_sha256").string()) {
            throw std::runtime_error("regenerated induction query CNF differs from the saved " +
                                     id + " obligation");
        }
    };
    std::set<std::string> proof_query_ids;
    q3a::checker::CheckerLimits checker_limits;
    checker_limits.check_memory = [&](std::uint64_t pending) { memory_budget.check(pending); };
    std::uint64_t proof_artifacts = 0;
    std::uint64_t accepted_proofs = 0;
    for (const auto& entry : artifacts) {
        if (entry.second.role != "checked_drat_proof") continue;
        ++proof_artifacts;
        const auto filename_begin = entry.first.find_last_of('/');
        const auto filename = entry.first.substr(filename_begin == std::string::npos
            ? 0 : filename_begin + 1);
        const auto extension = std::string(".q3adrat");
        if (filename.size() <= extension.size() ||
            filename.substr(filename.size() - extension.size()) != extension) {
            throw std::runtime_error("bundle proof artifact has an invalid filename");
        }
        const auto query_id = filename.substr(0, filename.size() - extension.size());
        const auto* query = find_by_id(queries, query_id);
        if (command != "k-induction" || !query ||
            (query_id != "base" && query_id != "step") ||
            !proof_query_ids.insert(query_id).second ||
            query->at("algorithm").string() != "k-induction" ||
            run_result.at("algorithm").string() != "k-induction" ||
            query->at("property").string() != run_property ||
            depth != query->at("bound").number() ||
            query->at("kind").string() != induction_query_kind(query_id) ||
            query->at("status").string() != "UNSAT_CHECKED") {
            throw std::runtime_error("bundle proof artifact has no matching checked induction query");
        }
        if (!(can_check_proof && can_rebuild_queries)) continue;
        const auto query_path = query->at("cnf_path").string();
        q3a::checker::ArtifactMetadata expected;
        expected.query_kind = query->at("kind").string();
        expected.checker_id = checker_id;
        expected.model_sha256 = model.at("sha256").string();
        expected.query_sha256 = query->at("cnf_sha256").string();
        check_induction_cnf(query_id, *query);
        q3a::WriteLockedInput cnf_input(checked_artifact_path(root, query_path));
        q3a::WriteLockedInput proof_input(checked_artifact_path(root, entry.first));
        const auto verify_input = [&](q3a::WriteLockedInput& input, const std::string& path) {
            const auto& record = artifacts.at(path);
            if (q3a::sha256_stream(input.stream(), record.size) != record.sha256) {
                throw std::runtime_error("bundle artifact changed after integrity verification: " + path);
            }
            input.rewind();
        };
        verify_input(cnf_input, query_path);
        verify_input(proof_input, entry.first);
        const auto check = q3a::checker::verify_drat_artifact(
            cnf_input.stream(), proof_input.stream(), expected, checker_limits);
        if (check.resource_limited) {
            throw VerificationResourceLimit("DRAT revalidation stopped for " + query_id +
                                            ": " + check.message);
        }
        if (!check.accepted) {
            throw std::runtime_error("bundle DRAT revalidation failed for " + query_id +
                                     ": " + check.message);
        }
        ++accepted_proofs;
        output << "Q3A_BUNDLE_PROOF_CHECK ACCEPTED id=" << query_id
               << " records=" << check.proof_records << '\n';
    }

    for (const auto* query : queries) {
        if (query->at("status").string() == "UNSAT_CHECKED") {
            const auto query_id = query->at("id").string();
            if (!proof_query_ids.count(query_id)) {
                throw std::runtime_error("checked induction query has no saved proof artifact");
            }
        }
    }

    const auto verify_capture = [&](const std::string& capture_path, const lowering::TIRModule& tir,
                                    const std::string& property_name, const char* model_kind) {
        const auto content = read_verified(capture_path);
        const auto capture = JsonParser(content).parse();
        if (capture.at("schema").string() != "Q3A-WAVEFORM-CAPTURE-1" ||
            capture.at("property").string() != property_name) {
            throw std::runtime_error("waveform capture schema or property differs");
        }
        trace::CaptureRequest requested;
        requested.all = capture.at("all").boolean();
        for (const auto& name : capture.at("requested").array()) requested.extra.push_back(name.string());
        const auto selected = std::find_if(tir.properties.begin(), tir.properties.end(),
            [&](const auto& entry) { return entry.name == property_name && entry.kind == model_kind; });
        if (selected == tir.properties.end()) throw std::runtime_error("capture property is missing from the model");
        const auto signals = trace::select_capture_signals(tir, *selected, requested);
        const auto digest = q3a::sha256_generated([&](std::ostream& bytes) {
            trace::write_capture_manifest(bytes, property_name, requested, signals);
        });
        if (digest != artifacts.at(capture_path).sha256) {
            throw std::runtime_error("waveform capture differs from the model signal selection");
        }
        output << "Q3A_BUNDLE_WAVEFORM_CAPTURE VERIFIED\n";
        return signals;
    };

    struct InductionFiles {
        std::string text;
        std::string index;
    };
    std::map<std::string, InductionFiles> induction_files;
    std::string induction_capture_path;
    for (const auto& entry : artifacts) {
        if (command == "k-induction" && entry.second.role == trace::kCaptureRole) {
            if (!induction_capture_path.empty()) throw std::runtime_error("multiple waveform capture manifests");
            induction_capture_path = entry.first;
        }
        const bool binary = entry.second.role == trace::kIndexedInductionRole;
        if (!binary && entry.second.role != "replay_validated_witness") continue;
        const auto filename = std::filesystem::path(entry.first).filename().string();
        const auto id = filename == (binary ? "base.trace.q3atrace" : "base.witness.txt") ? "base" :
                        filename == (binary ? "step.trace.q3atrace" : "step.witness.txt") ? "step" : "";
        if (command != "k-induction" || *id == '\0') {
            throw std::runtime_error("induction witness has no matching SAT obligation");
        }
        if (binary && entry.first != "properties/" + run_property + "/" + filename) {
            throw std::runtime_error("indexed induction witness path does not match its property");
        }
        auto& path = binary ? induction_files[id].index : induction_files[id].text;
        if (!path.empty()) throw std::runtime_error("duplicate induction witness artifact");
        path = entry.first;
    }
    std::set<std::string> replayed_induction;
    for (const auto& entry : induction_files) {
        const auto& id = entry.first;
        const auto* query = find_by_id(queries, id);
        if (!query || depth == 0 || depth > 10000 ||
            query->at("status").string() != "SAT_REPLAY_VALIDATED" ||
            query->at("algorithm").string() != "k-induction" ||
            run_result.at("algorithm").string() != "k-induction" ||
            query->at("kind").string() != induction_query_kind(id) ||
            query->at("bound").number() != depth ||
            query->at("property").string() != run_property) {
            throw std::runtime_error("induction witness has no matching SAT obligation");
        }
        const auto& model_hash = model.at("sha256").string();
        const auto& cnf_hash = query->at("cnf_sha256").string();
        const auto& tir = induction_model();
        if (entry.second.index.empty()) {
            replay_induction_witness(read_verified(entry.second.text), tir, run_property, id,
                                     depth, model_hash, cnf_hash);
        } else {
            const auto& record = artifacts.at(entry.second.index);
            WriteLockedInput input(checked_artifact_path(root, entry.second.index));
            if (q3a::sha256_stream(input.stream(), record.size) != record.sha256) {
                throw std::runtime_error("indexed induction witness changed after integrity verification");
            }
            input.rewind();
            const auto obligation = id == "base" ? replay::InductionObligation::Base
                                                : replay::InductionObligation::Step;
            trace::visit_indexed_witness(input.stream(), tir, run_property, std::nullopt,
                [&](std::uint64_t bytes) { memory_budget.check(bytes); },
                [&](const replay::FrameView& frames, std::size_t candidate) {
                    const auto result = replay::validate_induction_countermodel_view(
                        tir, frames, run_property, static_cast<std::size_t>(depth), obligation);
                    if (!result.validated || result.failure_frame != candidate) {
                        throw std::runtime_error("indexed induction witness replay failed: " + result.message);
                    }
                    if (!entry.second.text.empty()) {
                        const auto digest = q3a::sha256_generated([&](std::ostream& bytes) {
                            write_induction_witness_text(bytes, tir, frames, run_property, obligation,
                                                        depth, candidate, model_hash, cnf_hash);
                        });
                        if (digest != artifacts.at(entry.second.text).sha256) {
                            throw std::runtime_error("indexed induction witness differs from the compatibility text");
                        }
                    }
                });
            output << "Q3A_BUNDLE_INDUCTION_INDEXED_TRACE VERIFIED id=" << id << '\n';
        }
        replayed_induction.insert(id);
        if (can_rebuild_queries) {
            check_induction_cnf(id, *query);
            output << "Q3A_BUNDLE_INDUCTION_WITNESS_QUERY VERIFIED id=" << id << '\n';
        } else {
            output << "Q3A_BUNDLE_INDUCTION_WITNESS_QUERY UNVERIFIED id=" << id << '\n';
        }
        output << "Q3A_BUNDLE_INDUCTION_REPLAY VALIDATED id=" << id << '\n';
    }
    if (!induction_capture_path.empty()) {
        if (replayed_induction.empty()) throw std::runtime_error("waveform capture requires a replay witness");
        verify_capture(induction_capture_path, induction_model(), run_property, "assert");
    }
    bool induction_witness_revalidated = false;
    if (command == "k-induction") {
        const auto result = run_result.at("status").string();
        if (result == "FAIL") {
            if (!replayed_induction.count("base")) {
                throw std::runtime_error("induction failure lacks a replayable base witness");
            }
            induction_witness_revalidated = true;
        } else if (result == "NOT_" + std::to_string(depth) + "_INDUCTIVE") {
            if (!replayed_induction.count("step") || !proof_query_ids.count("base")) {
                throw std::runtime_error("non-inductive result requires a step witness and checked base");
            }
            induction_witness_revalidated = can_check_proof && can_rebuild_queries;
        }
    }

    bool bmc_trace_validated = false;
    bool bmc_query_revalidated = false;
    const auto check_vacuity = [&](const char* reproduced) {
        const auto& fields = manifest.at("result").object();
        const auto saved = fields.find("vacuity");
        if (saved != fields.end() && saved->second.string() != "UNKNOWN" &&
            saved->second.string() != reproduced) {
            throw std::runtime_error("BMC assertion vacuity does not match the saved result");
        }
        output << "Q3A_BUNDLE_BMC_VACUITY " << reproduced << '\n';
    };
    const auto check_boundary = [&](bool incomplete) {
        const auto* reproduced = incomplete ? "INCOMPLETE" : "COMPLETE";
        if (manifest.at("result").at("boundary_obligations").string() != reproduced) {
            throw std::runtime_error("BMC boundary obligations do not match the saved result");
        }
        output << "Q3A_BUNDLE_BMC_BOUNDARY_OBLIGATIONS " << reproduced << '\n';
    };
    const auto check_bmc_cnf = [&](const sat::Solver& solver, const JsonValue& query) {
        // The inventory pass already checked the exact saved artifact bytes.
        const auto regenerated_hash = q3a::sha256_generated(
            [&](std::ostream& cnf) { solver.write_dimacs(cnf); });
        if (regenerated_hash != query.at("cnf_sha256").string()) {
            throw std::runtime_error("regenerated BMC query CNF differs from the saved query");
        }
    };
    std::string bmc_query_unavailable_reason;
    if (!vcd_path.empty() && command != "bmc") {
        throw std::runtime_error("VCD waveform requires a bounded witness");
    }
    if (manifest.at("command").string() == "bmc") {
        const auto result_status = manifest.at("result").at("status").string();
        const auto* expected_kind = activation_witness ? "assertion-activation" :
            result_status == "COVERED" ? "cover" : "assertion";
        bool trace_artifact_found = false;
        std::string trace_artifact_path;
        const VerifiedArtifact* indexed_trace = nullptr;
        std::string indexed_trace_path;
        std::string capture_path;
        for (const auto& artifact : artifacts) {
            if (artifact.second.role == trace::kCaptureRole) {
                if (!capture_path.empty()) throw std::runtime_error("multiple waveform capture manifests");
                capture_path = artifact.first;
            }
            if (artifact.second.role == trace::kIndexedTraceRole) {
                if (indexed_trace != nullptr) throw std::runtime_error("multiple indexed witness artifacts");
                indexed_trace = &artifact.second;
                indexed_trace_path = artifact.first;
            }
            if (artifact.second.role != "replay_validated_trace") continue;
            if (trace_artifact_found) {
                throw std::runtime_error("BMC bundle contains multiple replay trace artifacts");
            }
            trace_artifact_path = artifact.first;
            trace_artifact_found = true;
        }
        if ((!capture_path.empty() || !vcd_path.empty()) && !indexed_trace && !trace_artifact_found) {
            throw std::runtime_error("waveform artifacts require a replay witness");
        }
        if (activation_witness && (!indexed_trace || !trace_artifact_found || capture_path.empty())) {
            throw std::runtime_error("activation bundle requires indexed and replay traces with signal capture");
        }
        if (indexed_trace || trace_artifact_found) {
            if ((result_status != "BOUNDED_FAIL" && result_status != "COVERED" && !activation_witness) ||
                manifest.at("result").at("algorithm").string() !=
                    "bounded-model-checking") {
                throw std::runtime_error("BMC bundle result status or algorithm is invalid for witness replay");
            }
            const auto property_name = manifest.at("result").at("property").string();
            const JsonValue* property_query = nullptr;
            for (const auto* query : queries) {
                if (query->at("property").string() != property_name) continue;
                if (property_query != nullptr) {
                    throw std::runtime_error("BMC bundle has duplicate property query records");
                }
                property_query = query;
            }
            if (property_query == nullptr ||
                property_query->at("algorithm").string() != "bounded-model-checking" ||
                property_query->at("kind").string() != expected_kind ||
                property_query->at("status").string() != "SAT_REPLAY_VALIDATED") {
                throw std::runtime_error("BMC trace is not linked to a matching replay-validated query");
            }
            const auto bound = manifest.at("result").at("bound").number();
            if (bound != property_query->at("bound").number() ||
                bound >= std::numeric_limits<std::size_t>::max()) {
                throw std::runtime_error("BMC trace frame count does not match the recorded bound");
            }
            const auto& tir = saved_model;
            if (tir.name != project.at("top_module").string() ||
                tir.semantic_profile != manifest.at("profile").at("id").string() ||
                tir.input_hash != manifest.at("profile").at("source_set_sha256").string()) {
                throw std::runtime_error("BMC T-IR identity does not match the bundle project profile");
            }
            std::optional<lowering::TIRModule> derived;
            if (activation_witness) {
                memory_budget.check();
                derived.emplace(q3a::pdr::activation_model(tir, property_name));
            }
            const auto& query_model = derived ? *derived : tir;
            trace::CaptureSignals vcd_signals;
            if (!capture_path.empty()) {
                vcd_signals = verify_capture(
                    capture_path, tir, property_name, result_status == "COVERED" ? "cover" : "assert");
            } else if (!vcd_path.empty()) {
                // The original exporter represented clocks only as sample boundaries.
                for (const auto& signal : tir.signals) {
                    if (std::find(tir.clocks.begin(), tir.clocks.end(), signal.name) == tir.clocks.end()) {
                        vcd_signals.push_back(&signal);
                    }
                }
            }
            const auto frame_count = static_cast<std::size_t>(bound + 1);
            std::size_t candidate_frame = 0;
            replay::Result replay_result;
            replay::ReplayTiming::Duration rtl_and_property{};
            replay::ReplayTiming::Duration consistency{};
            replay::ReplayTiming::Duration waveform{};
            const auto decode_started = timing.start();
            const auto replay_frames = [&](const replay::FrameView& frames, std::size_t candidate) {
                const auto evaluate_started = timing.start();
                candidate_frame = candidate;
                replay_result = result_status == "COVERED"
                    ? replay::validate_bounded_cover_view(tir, frames, property_name, candidate)
                    : replay::validate_bounded_counterexample_view(query_model, frames, property_name, candidate);
                rtl_and_property = timing.elapsed(evaluate_started);
                if (replay_result.validated && !vcd_path.empty()) {
                    const auto waveform_started = timing.start();
                    const auto& artifact = artifacts.at(vcd_path);
                    WriteLockedInput input(checked_artifact_path(root, vcd_path));
                    if (q3a::sha256_stream(input.stream(), artifact.size) != artifact.sha256) {
                        throw std::runtime_error("VCD waveform changed after integrity verification");
                    }
                    input.rewind();
                    trace::verify_witness_vcd(input.stream(), tir, vcd_signals, frames,
                                              waveform_source_ranges, memory_budget);
                    waveform = timing.elapsed(waveform_started);
                }
            };
            if (indexed_trace) {
                WriteLockedInput input(checked_artifact_path(root, indexed_trace_path));
                if (q3a::sha256_stream(input.stream(), indexed_trace->size) != indexed_trace->sha256) {
                    throw std::runtime_error("indexed witness changed after integrity verification");
                }
                input.rewind();
                trace::visit_indexed_witness(input.stream(), tir, property_name, frame_count,
                    [&](std::uint64_t bytes) { memory_budget.check(bytes); },
                    [&](const replay::FrameView& frames, std::size_t candidate) {
                        if (trace_artifact_found) {
                            const auto consistency_started = timing.start();
                            const auto expected = q3a::sha256_generated([&](std::ostream& bytes) {
                                write_trace_json(bytes, frames, property_name, candidate);
                            });
                            if (expected != artifacts.at(trace_artifact_path).sha256) {
                                throw std::runtime_error("indexed witness differs from replay-validated JSON values");
                            }
                            consistency = timing.elapsed(consistency_started);
                        }
                        replay_frames(frames, candidate);
                    });
            } else {
                const auto trace = parse_bmc_trace(read_verified(trace_artifact_path));
                if (trace.property != property_name || trace.frames.size() != frame_count) {
                    throw std::runtime_error("BMC trace property or frame count does not match the bundle result");
                }
                replay_frames(trace.frames, trace.candidate_frame);
            }
            if (!replay_result.validated) {
                throw std::runtime_error("bundle BMC witness replay failed: " +
                                         replay_result.message);
            }
            const auto decode = timing.elapsed(decode_started) - rtl_and_property - consistency - waveform;
            if (!vcd_path.empty()) output << "Q3A_BUNDLE_VCD VERIFIED\n";
            if (indexed_trace) output << "Q3A_BUNDLE_INDEXED_TRACE VERIFIED\n";
            bmc_trace_validated = true;
            if (result_status == "BOUNDED_FAIL" || activation_witness) check_vacuity("NONVACUOUS");
            if (can_rebuild_queries) {
                const auto query_started = timing.start();
                check_boundary(replay_result.boundary_incomplete);
                sat::Solver solver([&memory_budget](std::uint64_t pending) {
                    memory_budget.check(pending);
                });
                sat::TransitionCnfEncoder encoder(solver, query_model);
                encoder.encode(bound);
                encoder.constrain_assumptions();
                const auto goal = result_status == "COVERED"
                    ? encoder.add_cover_hit(property_name).hit_literals
                    : encoder.add_assertion_violation(property_name).violation_literals;
                solver.add_clause(goal);
                check_bmc_cnf(solver, *property_query);
                const auto query_elapsed = timing.elapsed(query_started);
                output << "Q3A_BUNDLE_BMC_WITNESS_QUERY VERIFIED\n";
                timing.write(std::cerr, "artifact_integrity", integrity_elapsed);
                timing.write(std::cerr, "source_model", source_elapsed);
                timing.write(std::cerr, "witness_decode", decode);
                timing.write(std::cerr, "witness_consistency", consistency);
                timing.write(std::cerr, "rtl_and_property", rtl_and_property);
                timing.write(std::cerr, "query_regeneration", query_elapsed);
                if (!vcd_path.empty()) timing.write(std::cerr, "waveform_validation", waveform);
            } else {
                output << "Q3A_BUNDLE_BMC_BOUNDARY_OBLIGATIONS UNVERIFIED\n"
                       << "Q3A_BUNDLE_BMC_WITNESS_QUERY UNVERIFIED\n";
            }
            output << "Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames="
                   << frame_count << " candidate_frame="
                   << candidate_frame << '\n';
        } else {
            const auto property_name = manifest.at("result").at("property").string();
            const JsonValue* property_query = nullptr;
            for (const auto* query : queries) {
                if (query->at("property").string() != property_name) continue;
                if (property_query != nullptr) {
                    throw std::runtime_error("BMC bundle has duplicate property query records");
                }
                property_query = query;
            }
            const bool bounded_pass = result_status == "BOUNDED_PASS" &&
                property_query != nullptr &&
                property_query->at("kind").string() == "assertion" &&
                property_query->at("status").string() == "UNSAT";
            const bool cover_miss = result_status == "UNKNOWN" &&
                property_query != nullptr &&
                property_query->at("kind").string() == "cover" &&
                property_query->at("status").string() == "UNSAT";
            const bool inconsistent = result_status == "INCONSISTENT_MODEL_OR_ASSUMPTIONS";
            if (inconsistent && (property_query == nullptr ||
                property_query->at("id").string() != "feasibility" ||
                property_query->at("kind").string() != "model-feasibility" ||
                property_query->at("status").string() != "UNSAT" ||
                manifest.at("result").at("vacuity").string() != "NOT_APPLICABLE")) {
                throw std::runtime_error("BMC inconsistent result requires an UNSAT feasibility query");
            }
            if (bounded_pass || cover_miss || inconsistent) {
                if (manifest.at("result").at("algorithm").string() !=
                        "bounded-model-checking" ||
                    property_query->at("algorithm").string() !=
                        "bounded-model-checking") {
                    throw std::runtime_error("BMC query algorithm identity is invalid");
                }
                if (!can_rebuild_queries) {
                    bmc_query_unavailable_reason =
                        "saved SAT component fingerprint is unavailable";
                } else {
                    const auto bound = manifest.at("result").at("bound").number();
                    if (bound != property_query->at("bound").number()) {
                        throw std::runtime_error("BMC query bound does not match the recorded run bound");
                    }
                    const auto& tir = saved_model;
                    if (tir.name != project.at("top_module").string() ||
                        tir.semantic_profile != manifest.at("profile").at("id").string() ||
                        tir.input_hash != manifest.at("profile").at("source_set_sha256").string()) {
                        throw std::runtime_error("BMC T-IR identity does not match the bundle project profile");
                    }
                    sat::Solver solver([&memory_budget](std::uint64_t pending) {
                        memory_budget.check(pending);
                    });
                    sat::TransitionCnfEncoder encoder(solver, tir);
                    encoder.encode(bound);
                    encoder.constrain_assumptions();
                    const auto target = std::find_if(tir.properties.begin(), tir.properties.end(),
                        [&](const lowering::TIRProperty& property) {
                            return property.name == property_name &&
                                (property.kind == "assert" || property.kind == "cover");
                        });
                    if (target == tir.properties.end()) {
                        throw std::runtime_error("BMC query target is missing from the saved model");
                    }
                    const bool assertion_target = target->kind == "assert";
                    if ((bounded_pass && !assertion_target) ||
                        (cover_miss && assertion_target)) {
                        throw std::runtime_error("BMC query kind disagrees with the saved model");
                    }
                    sat::TransitionCnfEncoder::AssertionQuery assertion;
                    std::vector<sat::Literal> goal;
                    bool boundary_incomplete;
                    if (assertion_target) {
                        assertion = encoder.add_assertion_violation(property_name);
                        boundary_incomplete = encoder.boundary_incomplete(assertion);
                    } else {
                        auto cover = encoder.add_cover_hit(property_name);
                        boundary_incomplete = encoder.boundary_incomplete(cover);
                        goal = std::move(cover.hit_literals);
                    }
                    if (!inconsistent) {
                        const auto feasibility = solver.solve();
                        if (feasibility.status != sat::Status::Satisfiable) {
                            throw std::runtime_error("BMC bounded-query assumptions do not reproduce a satisfiable model");
                        }
                        if (bounded_pass) {
                            const auto activity = encoder.assertion_activity(assertion, feasibility.assignment);
                            if (activity == sat::Status::Unknown) {
                                throw std::runtime_error("BMC bounded-query vacuity could not be rechecked");
                            }
                            check_vacuity(activity == sat::Status::Satisfiable ? "NONVACUOUS" : "VACUOUS");
                            goal = std::move(assertion.violation_literals);
                        }
                        solver.add_clause(goal);
                    }
                    check_bmc_cnf(solver, *property_query);
                    const auto query_result = solver.solve();
                    if (query_result.status != sat::Status::Unsatisfiable) {
                        throw std::runtime_error("BMC query re-execution did not reproduce its recorded UNSAT result");
                    }
                    bmc_query_revalidated = true;
                    check_boundary(boundary_incomplete);
                    output << "Q3A_BUNDLE_BMC_QUERY REVALIDATED status="
                           << (inconsistent ? "INCONSISTENT_MODEL_OR_ASSUMPTIONS" :
                               bounded_pass ? "BOUNDED_PASS" : "NOT_FOUND_WITHIN_BOUND")
                           << " bound=" << bound << '\n';
                }
            }
        }
    }

    const auto run_id = manifest.at("run_id").string();
    const auto status = manifest.at("result").at("status").string();
    output << "Q3A_BUNDLE_INTEGRITY VERIFIED\n"
           << "Q3A_BUNDLE_RUN_ID " << std::quoted(run_id) << '\n'
           << "Q3A_BUNDLE_RESULT_STATUS " << status << '\n'
           << "Q3A_BUNDLE_MODEL_SHA256 " << model.at("sha256").string() << '\n';
    const bool proofs_revalidated = proof_artifacts > 0 && can_check_proof &&
        accepted_proofs == proof_artifacts;
    if (proofs_revalidated) {
        output << "Q3A_BUNDLE_REVALIDATION ACCEPTED proof_artifacts=" << accepted_proofs << '\n'
               << "Q3A_BUNDLE_SCOPE CHECKED_PROOF_FOR_SERIALIZED_TIR\n";
    }
    if (bmc_trace_validated) {
        output << (activation_witness ? "Q3A_BUNDLE_SCOPE REPLAYED_ASSERTION_ACTIVATION_FOR_SERIALIZED_TIR\n"
                                      : "Q3A_BUNDLE_SCOPE REPLAYED_BMC_WITNESS_FOR_SERIALIZED_TIR\n");
    }
    if (bmc_query_revalidated) {
        output << "Q3A_BUNDLE_SCOPE REEXECUTED_BOUNDED_QUERY_FOR_SERIALIZED_TIR\n";
    }
    if (induction_witness_revalidated) {
        output << "Q3A_BUNDLE_SCOPE REPLAYED_INDUCTION_WITNESS_FOR_SERIALIZED_TIR\n";
    }
    if (proofs_revalidated || bmc_trace_validated || bmc_query_revalidated ||
        induction_witness_revalidated) {
        output << "Q3A_BUNDLE_STATUS REVALIDATED\n";
    } else {
        const auto reason = proof_artifacts == 0
            ? !bmc_query_unavailable_reason.empty()
                ? bmc_query_unavailable_reason
                : std::string("no replayable BMC witness or compatible proof artifact is present")
            : !can_check_proof ? std::string("saved proof checker identity is unavailable")
            : !can_rebuild_queries ? std::string("saved induction SAT component fingerprint is unavailable")
            : std::string("not every proof artifact was revalidated");
        if (require_source_model) {
            throw std::runtime_error("source-required verification could not revalidate evidence: " + reason);
        }
        output << "Q3A_BUNDLE_REVALIDATION UNAVAILABLE reason=" << reason << '\n'
               << "Q3A_BUNDLE_STATUS HISTORIC\n";
    }

    if (!debug) return;
    std::string trace_path;
    std::string obligation = activation_witness ? "activation" : "bounded";
    if (command == "k-induction") {
        obligation = debug_options.obligation.empty()
            ? (status == "FAIL" ? "base" : "step")
            : debug_options.obligation;
        const auto found = induction_files.find(obligation);
        if (found != induction_files.end() && replayed_induction.count(obligation)) {
            trace_path = found->second.index;
        }
    } else {
        if (!debug_options.obligation.empty()) {
            throw std::invalid_argument("obligation selection requires a k-induction bundle");
        }
        if (bmc_trace_validated) {
            for (const auto& entry : artifacts) {
                if (entry.second.role == trace::kIndexedTraceRole) trace_path = entry.first;
            }
        }
    }
    if (trace_path.empty()) throw std::invalid_argument("debug requires a replayed indexed witness for the selected obligation");
    const auto& tir = saved_model;
    std::map<std::string, std::uint64_t> widths;
    for (const auto& signal : tir.signals) widths.emplace(signal.name, signal.width);
    debug->groups = debug_options.groups;
    for (const auto& group : debug->groups) {
        for (const auto& name : group.second) {
            if (!widths.count(name)) throw std::invalid_argument("unknown signal in debug group: " + name);
        }
    }
    for (const auto& reset : debug_options.resets) {
        const auto width = widths.find(reset.first);
        if (width == widths.end() || width->second != 1) {
            throw std::invalid_argument("debug reset requires a known one-bit signal: " + reset.first);
        }
    }
    debug->resets = debug_options.resets;
    const auto group_signal = [&](const std::string& group, const std::string& signal) {
        auto& members = debug->groups[group];
        if (std::find(members.begin(), members.end(), signal) == members.end()) members.push_back(signal);
    };
    for (const auto& name : tir.clocks) group_signal("Clocks and resets", name);
    for (const auto& reset : debug->resets) group_signal("Clocks and resets", reset.first);
    for (const auto& signal : tir.signals) {
        if (signal.role == "state" || signal.role == "history_data" || signal.role == "history_valid") {
            group_signal("Model state", signal.name);
        }
        if (signal.name.find('.') == std::string::npos && (signal.role == "input" || signal.role == "output")) {
            group_signal("Top-level ports", signal.name);
        }
    }
    const auto property = std::find_if(tir.properties.begin(), tir.properties.end(), [&](const auto& entry) {
        return entry.name == run_property && entry.kind == (status == "COVERED" ? "cover" : "assert");
    });
    if (property == tir.properties.end()) throw std::runtime_error("debug property has no source mapping");
    debug->assertion = property->location;
    debug->assumptions = std::move(model_assumptions);

    trace::CaptureRequest capture;
    for (const auto& entry : artifacts) {
        if (entry.second.role != trace::kCaptureRole) continue;
        const auto saved = JsonParser(read_verified(entry.first)).parse();
        capture.all = saved.at("all").boolean();
        for (const auto& name : saved.at("requested").array()) capture.extra.push_back(name.string());
    }
    constexpr std::size_t kInitialSignals = 8;
    const auto add = [&](const std::string& name) {
        if (debug->selected.size() < kInitialSignals &&
            std::find(debug->selected.begin(), debug->selected.end(), name) == debug->selected.end()) {
            debug->selected.push_back(name);
        }
    };
    for (const auto& name : capture.extra) add(name);
    for (const auto* signal : trace::select_capture_signals(tir, *property, capture)) {
        add(signal->name);
        group_signal("Default capture", signal->name);
    }

    const auto& indexed = artifacts.at(trace_path);
    struct DebugTraceInput {
        explicit DebugTraceInput(const std::filesystem::path& path) : input(path) {}
        WriteLockedInput input;
        std::mutex readers;
    };
    auto locked = std::make_shared<DebugTraceInput>(checked_artifact_path(root, trace_path));
    auto& input = locked->input;
    if (q3a::sha256_stream(input.stream(), indexed.size) != indexed.sha256) {
        throw std::runtime_error("debug trace changed after replay");
    }
    input.rewind();
    std::optional<std::size_t> frame_count;
    std::size_t candidate = 0;
    trace::visit_indexed_witness(input.stream(), tir, run_property, std::nullopt,
        [&](std::uint64_t bytes) { memory_budget.check(bytes); },
        [&](const replay::FrameView& frames, std::size_t at) {
            frame_count = frames.size();
            candidate = at;
        });
    input.rewind();
    constexpr std::size_t span = 32;
    const auto count = frame_count.value();
    const auto first = std::min(candidate > span / 2 ? candidate - span / 2 : 0,
                                count > span ? count - span : 0);
    std::ostringstream window;
    auto initial_signals = debug->selected;
    for (const auto& reset : debug->resets) {
        if (std::find(initial_signals.begin(), initial_signals.end(), reset.first) == initial_signals.end()) {
            initial_signals.push_back(reset.first);
        }
    }
    trace::write_indexed_window(input.stream(), window, first, std::min(count - 1, first + span - 1),
                                initial_signals);
    debug->initial_window = window.str();
    debug->indexed_bytes = indexed.size;
    session->frame_count = count;
    session->candidate_frame = candidate;
    session->write_window = [locked](std::ostream& output,
        std::uint64_t first, std::uint64_t last, const std::vector<std::string>& selected) {
        const std::lock_guard<std::mutex> guard(locked->readers);
        locked->input.rewind();
        trace::write_indexed_window(locked->input.stream(), output, first, last, selected);
    };
    session->find_transition = [locked = std::move(locked)](const std::string& name,
        std::uint64_t cursor, bool forward) {
        const std::lock_guard<std::mutex> guard(locked->readers);
        locked->input.rewind();
        return trace::find_indexed_transition(locked->input.stream(), name, cursor, forward);
    };
    debug->clocks = tir.clocks;
    debug->signals = std::move(tir.signals);
    std::sort(debug->signals.begin(), debug->signals.end(),
        [](const auto& a, const auto& b) { return a.name < b.name; });
    const auto& limits = manifest.at("resource_limits");
    debug->run = {{"Run", run_id}, {"Bundle", declared_manifest_hash}, {"Property", run_property},
        {"Result", status}, {"Algorithm", run_result.at("algorithm").string()},
        {"Obligation", obligation},
        {activation_witness ? "Activation replay bound" : "Bound", std::to_string(depth)},
        {"Witness frame", std::to_string(candidate)},
        {"Trace", std::filesystem::path(trace_path).filename().u8string()},
        {"Decision limit", std::to_string(limits.at("decisions").number())},
        {"Propagation limit", std::to_string(limits.at("propagations").number())}};
    constexpr std::uint64_t kSourceBudget = 8 * 1024 * 1024;
    std::uint64_t remaining = kSourceBudget;
    for (bool property_file : {true, false}) {
        for (const auto* entry : rtl_entries) {
            const auto& source = *entry;
            const auto& path = source.at("path").string();
            if ((path == debug->assertion.file) != property_file || debug->sources.count(path)) continue;
            const auto bytes = source.at("size_bytes").number();
            if (bytes > remaining) continue;
            debug->sources.emplace(path, read_verified(normalized_relative_path(source.at("snapshot_path").string())));
            remaining -= bytes;
        }
    }
}

void verify_result_bundle(const std::filesystem::path& bundle_directory, std::ostream& output) {
    verify_bundle(bundle_directory, output, nullptr, {}, false);
}

std::optional<std::string> verify_pdr_run_configuration(const std::filesystem::path& directory,
    const ProjectInput& project, const lowering::TIRModule& original, const std::string& property,
    bool activation, const pdr::CheckedCertificate& certificate, const MemoryBudget& memory,
    bool require_exact_project_identity) {
    const auto root = detail::windows_file_path(std::filesystem::absolute(directory));
    const auto entry = root / pdr::kCertificateRunConfigurationFile;
    std::error_code error;
    const auto type = std::filesystem::symlink_status(entry, error).type();
    if (type == std::filesystem::file_type::not_found &&
        (!error || error == std::errc::no_such_file_or_directory)) return std::nullopt;
    if (error || type != std::filesystem::file_type::regular) {
        throw std::runtime_error("invalid PDR run configuration file");
    }
    constexpr std::uint64_t maximum_record_bytes = 64ULL * 1024ULL * 1024ULL;
    const auto path = checked_artifact_path(root, pdr::kCertificateRunConfigurationFile);
    const auto size = std::filesystem::file_size(path);
    if (size > maximum_record_bytes) throw std::runtime_error("PDR run configuration exceeds the read limit");
    memory.check(size);
    const auto bytes = read_file(path, size);
    const auto envelope = JsonParser(bytes, "PDR run configuration JSON").parse();
    const auto& recorded_obligations = envelope.at("obligations").array();
    if (envelope.at("schema_version").number() != 1 ||
        envelope.at("model_sha256").string() != certificate.model_sha256 ||
        recorded_obligations.size() != certificate.obligations.size() ||
        !std::equal(recorded_obligations.begin(), recorded_obligations.end(), certificate.obligations.begin(),
            [](const auto& record, const auto& checked) {
                return record.at("kind").string() == checked.kind &&
                    record.at("query_sha256").string() == checked.query_sha256 &&
                    record.at("proof_sha256").string() == checked.proof_sha256;
            })) {
        throw std::runtime_error("PDR run configuration disagrees with the checked certificate");
    }
    const auto& config = envelope.at("run_configuration");
    const auto selected = std::find_if(original.properties.begin(), original.properties.end(),
        [&](const auto& entry) { return entry.name == property; });
    const auto version = config.at("manifest_version").number();
    const auto depth = config.at("maximum_depth").number();
    if (selected == original.properties.end() || config.at("engine").string() != "pdr" ||
        config.at("property").string() != property || config.at("property_kind").string() != selected->kind ||
        config.at("goal").string() != (activation ? "activation" : selected->kind == "cover" ? "cover" : "safety") ||
        config.at("clock").string() != selected->clock ||
        config.at("source_set_sha256").string() !=
            (require_exact_project_identity ? project.input_hash : original.input_hash) ||
        (require_exact_project_identity && (version != project.manifest_version ||
            config.at("project_manifest_sha256").string() != project.manifest_sha256)) ||
        config.at("semantic_profile").string() != original.semantic_profile ||
        config.at("top_module").string() != original.name ||
        config.at("reset_initial_policy").string() != kResetInitialPolicy ||
        (version != 1 && version != 2) || depth == 0 || depth > pdr::kMaximumDepth ||
        config.at("maximum_search_queries").number() == 0 ||
        config.at("minimum_feasibility_bound").number() > pdr::kMaximumDepth ||
        config.at("workers").number() != 1 || config.at("timeout_ms").number() > 86400000) {
        throw std::runtime_error("PDR run configuration disagrees with its model, goal or search limits");
    }
    for (const auto* key : {"project_manifest_sha256", "build_id"}) {
        const auto& identity = config.at(key).string();
        if (identity.size() != 64 || !std::all_of(identity.begin(), identity.end(),
                [](const char ch) { return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'); })) {
            throw std::runtime_error("invalid originating PDR run identity");
        }
    }
    const auto matches_settings = [&](const char* key, const auto& expected) {
        const auto& saved = config.at(key).object();
        return saved.size() == expected.size() &&
            std::equal(saved.begin(), saved.end(), expected.begin(), [](const auto& a, const auto& b) {
                return a.first == b.first && a.second.string() == b.second;
            });
    };
    const auto matches_roster = [&](const char* key, const auto& expected) {
        const auto& saved = config.at(key).array();
        return saved.size() == expected.size() &&
            std::equal(saved.begin(), saved.end(), expected.begin(), [](const auto& a, const auto& b) {
                return a.at("path").string() == b.relative_path && a.at("sha256").string() == b.sha256;
            });
    };
    const auto& includes = config.at("include_dirs").array();
    if (!matches_settings("parameters", project.parameters) || !matches_settings("macros", project.macros) ||
        !matches_roster("sources", project.sources) || !matches_roster("headers", project.headers) ||
        includes.size() != project.include_dirs.size() ||
        !std::equal(includes.begin(), includes.end(), project.include_dirs.begin(),
            [](const auto& saved, const auto& expected) { return saved.string() == expected; })) {
        throw std::runtime_error("PDR run configuration disagrees with the resolved source or parameter context");
    }
    config.at("search_private_limit_bytes").number();
    config.at("search_physical_reserve_bytes").number();
    const auto& assumptions = config.at("assumptions").array();
    auto recorded = assumptions.begin();
    for (const auto& entry : original.properties) {
        if (entry.kind != "assume") continue;
        if (recorded == assumptions.end() || (recorded++)->string() != entry.name) {
            throw std::runtime_error("PDR run configuration disagrees with the model assumptions");
        }
    }
    if (recorded != assumptions.end()) {
        throw std::runtime_error("PDR run configuration disagrees with the model assumptions");
    }
    return sha256_hex(bytes);
}

void verify_batch_checkpoint(const std::filesystem::path& directory, const ProjectInput& project,
    std::string_view payload, std::string_view engine, std::string_view property, std::uint64_t depth,
    std::uint64_t timeout_ms, std::uint64_t memory_mib, std::uint64_t maximum_queries,
    std::uint64_t feasibility_frames, const lowering::TIRModule* pdr_model,
    const MemoryBudget& memory) {
    memory.check(payload.size());
    const std::string bytes(payload);
    const auto result = JsonParser(bytes, "batch checkpoint result JSON").parse();
    const auto& status = result.at("status").string();
    const auto& config = result.at("run_configuration");
    const auto limit = config.at("search_private_limit_bytes").number();
    const auto* depth_key = engine == "pdr" ? "maximum_depth" :
        engine == "induction" ? "induction_depth" : "transition_count";
    if (result.at("schema_version").number() != 1 || result.at("exit_code").number() != 0 ||
        result.at("build_id").string() != q3a::build_info::kBuildId ||
        result.at("engine").string() != engine || result.at("timeout_ms").number() != timeout_ms ||
        result.at("source_set_sha256").string() != project.input_hash ||
        config.at("build_id").string() != q3a::build_info::kBuildId ||
        config.at("source_set_sha256").string() != project.input_hash ||
        config.at("project_manifest_sha256").string() != project.manifest_sha256 ||
        config.at("engine").string() != engine || config.at("property").string() != property ||
        config.at(depth_key).number() != depth || config.at("timeout_ms").number() != timeout_ms ||
        limit == 0 || limit > memory_mib * 1024ULL * 1024ULL ||
        (engine == "pdr" && (config.at("maximum_search_queries").number() != maximum_queries ||
                           config.at("minimum_feasibility_bound").number() != feasibility_frames))) {
        throw std::runtime_error("checkpoint result does not identify the requested batch job");
    }
    if (engine == "pdr" && (status == "PROVEN" || status == "UNREACHABLE")) {
        if (!pdr_model) throw std::runtime_error("checkpoint PDR model is unavailable");
        const auto& model = *pdr_model;
        const auto certificate_dir = directory / "certificate";
        const auto certificate = pdr::verify(model, std::string(property), certificate_dir, memory);
        if (!certificate || status != (config.at("property_kind").string() == "cover" ? "UNREACHABLE" : "PROVEN")) {
            throw std::runtime_error("checkpoint PDR verdict could not be reestablished");
        }
        const auto verified = verify_pdr_run_configuration(certificate_dir, project, model,
            std::string(property), false, *certificate, memory);
        const auto descriptor = read_file(detail::absolute_windows_file_path(
            certificate_dir / pdr::kCertificateRunConfigurationFile), 64ULL * 1024ULL * 1024ULL);
        const auto envelope = JsonParser(descriptor, "batch checkpoint certificate JSON").parse();
        const auto& saved_certificate = result.at("certificate");
        if (!verified || *verified != sha256_hex(descriptor) ||
            !(envelope.at("run_configuration") == config) ||
            !(envelope.at("obligations") == saved_certificate.at("obligations")) ||
            saved_certificate.at("directory").string() != certificate_dir.u8string() ||
            saved_certificate.at("model_sha256").string() != certificate->model_sha256 ||
            saved_certificate.at("build_id").string() != q3a::build_info::kBuildId ||
            saved_certificate.at("checker_id").string() != checker::kCheckerId ||
            saved_certificate.at("run_configuration_sha256").string() != *verified) {
            throw std::runtime_error("checkpoint result disagrees with the PDR certificate configuration");
        }
        return;
    }
    const std::string_view bundle_status = engine == "pdr" && status == "FAIL"
        ? std::string_view("BOUNDED_FAIL") : std::string_view(status);
    const auto bundle = directory / "bundle";
    if (result.at("bundle_dir").string() != bundle.u8string()) {
        throw std::runtime_error("checkpoint result points to a different evidence bundle");
    }
    std::ostringstream verified;
    verify_bundle(bundle, verified, nullptr, {}, true, &config, bundle_status, &memory);
}

void reopen_saved_run(const std::filesystem::path& path, std::ostream& output,
                      bool require_source_model) {
    const auto native = detail::windows_file_path(std::filesystem::absolute(path));
    if (!std::filesystem::is_regular_file(native)) {
        verify_bundle(path, output, nullptr, {}, require_source_model);
        return;
    }
    if (require_source_model) {
        throw std::runtime_error("source-required verification needs a formal bundle directory");
    }

    constexpr std::uint64_t maximum_record_bytes = 64 * 1024;
    const auto content = read_file(native, maximum_record_bytes);
    const auto record = JsonParser(content, "interruption record JSON").parse();
    const auto& fields = record.object();
    const auto& status = record.at("status").string();
    const bool timed_out = status == "TIMEOUT";
    if (record.at("schema_version").number() != 1 || record.at("exit_code").number() != 1 ||
        (!timed_out && status != "CANCELLED")) {
        throw std::runtime_error("expected a version 1 interruption record with exit code 1");
    }
    const std::set<std::string> shared_fields{
        "schema_version", "exit_code", "status", "elapsed_ms", "timeout_ms",
        "engine", "build_id", "source_set_sha256", "completed_work", "properties", "resolved_configuration"};
    for (const auto& field : fields) {
        const auto& name = field.first;
        if (shared_fields.count(name) || (timed_out && name == "timeout_stage") ||
            (!timed_out && (name == "cancellation_stage" || name == "cancellation_cause"))) continue;
        throw std::runtime_error("unexpected interruption record field '" + name + "'");
    }
    const auto elapsed = record.at("elapsed_ms").number();
    if (timed_out || fields.count("timeout_ms")) {
        const auto timeout = record.at("timeout_ms").number();
        if (timeout == 0 || timeout > 86400000 || (timed_out && elapsed < timeout)) {
            throw std::runtime_error("inconsistent interruption record deadline and duration");
        }
    }
    const auto& stage = record.at(timed_out ? "timeout_stage" : "cancellation_stage").string();
    const bool loading = stage == "source_loading";
    const auto engine = fields.count("engine") ? record.at("engine").string() : std::string{};
    const auto& build_id = record.at("build_id").string();
    const auto source = fields.count("source_set_sha256") ? record.at("source_set_sha256").string() : std::string{};
    const auto is_digest = [](std::string_view value) {
        return value.size() == 64 && std::all_of(value.begin(), value.end(), [](char ch) {
            return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
        });
    };
    if (!is_digest(build_id) || (loading ? fields.count("source_set_sha256") != 0 : !is_digest(source))) {
        throw std::runtime_error("invalid interruption record build or source identity");
    }
    const auto cause = timed_out ? std::string_view{"deadline"}
                                 : std::string_view{record.at("cancellation_cause").string()};
    if (!timed_out && cause != "cancel_file" && cause != "ctrl_c" && cause != "ctrl_break") {
        throw std::runtime_error("invalid interruption record cancellation cause");
    }
    const bool bounded_stage = stage == "bounded_query" || stage == "witness_replay";
    const bool pdr_stage = stage == "pdr_search" || stage == "pdr_certificate";
    if ((engine != "bmc" && engine != "induction" && engine != "pdr" && !(loading && engine.empty())) ||
        (!loading && stage != "elaboration" &&
         !(stage == "induction_obligations" && engine == "induction") &&
         !(bounded_stage && engine != "induction") && !(pdr_stage && engine == "pdr"))) {
        throw std::runtime_error("invalid interruption record engine or stage");
    }
    const auto& properties = record.at("properties").array();
    const bool target_known = !loading || !engine.empty();
    if (properties.size() != (target_known ? 1u : 0u) ||
        (target_known && (properties.front().object().size() != 2 ||
            properties.front().at("status").string() != status))) {
        throw std::runtime_error("inconsistent interruption record property result");
    }
    const auto property = target_known ? properties.front().at("name").string() : std::string{};
    if (target_known && (property.empty() || !std::all_of(property.begin(), property.end(), [](unsigned char ch) {
            return ch >= 0x21 && ch <= 0x7e;
        }))) {
        throw std::runtime_error("invalid interruption record property name");
    }
    const auto& work = record.at("completed_work").array();
    std::set<std::string> seen;
    for (const auto& entry : work) {
        const auto& item = entry.string();
        const bool induction_work = engine == "induction" &&
            (item == "induction_base_resolved" || item == "induction_step_resolved");
        const bool pdr_work = engine == "pdr" && item == "pdr_search_resolved";
        const bool bounded_work = (engine == "bmc" || seen.count("pdr_search_resolved")) &&
            (item == "feasibility_decided" ||
             (item == "bounded_query_decided" && seen.count("feasibility_decided")) ||
             (item == "witness_replayed" && seen.count("bounded_query_decided")));
        const bool progress_is_valid = item == "project_loaded" ||
            (item == "model_elaborated" && seen.count("project_loaded")) ||
            (seen.count("model_elaborated") && (induction_work || pdr_work || bounded_work));
        if (!progress_is_valid || !seen.insert(item).second) {
            throw std::runtime_error("invalid interruption record completed work");
        }
    }
    const bool pdr_replay_or_certificate = engine == "pdr" && (stage == "pdr_certificate" || bounded_stage);
    if (loading ? !seen.empty() :
        !seen.count("project_loaded") || (stage != "elaboration" && !seen.count("model_elaborated")) ||
        (pdr_replay_or_certificate && !seen.count("pdr_search_resolved")) ||
        (stage == "witness_replay" && !seen.count("bounded_query_decided"))) {
        throw std::runtime_error("interruption record progress disagrees with the stage");
    }

    if (fields.count("resolved_configuration")) {
        const auto& config = record.at("resolved_configuration");
        const auto& manifest = config.at("project_manifest_sha256").string();
        const auto& digest = config.at("configuration_sha256").string();
        const auto version = config.at("manifest_version").number();
        const auto& goal = config.at("goal").string();
        const bool pdr = engine == "pdr";
        const bool induction = engine == "induction";
        if (!seen.count("model_elaborated") || !is_digest(manifest) || !is_digest(digest) ||
            (version != 1 && version != 2) ||
            (goal != "safety" && !(goal == "cover" && !induction) && !(goal == "activation" && pdr)) ||
            config.object().size() != (pdr ? 9u : 7u)) {
            throw std::runtime_error("invalid interruption record resolved configuration");
        }
        config.at("search_private_limit_bytes").number();
        config.at("search_physical_reserve_bytes").number();
        if (pdr && (config.at("maximum_depth").number() == 0 ||
                    config.at("maximum_depth").number() > q3a::pdr::kMaximumDepth ||
                    config.at("maximum_search_queries").number() == 0 ||
                    config.at("minimum_feasibility_bound").number() > q3a::pdr::kMaximumDepth)) {
            throw std::runtime_error("invalid interruption record PDR limits");
        }
        if (induction) {
            const auto depth = config.at("induction_depth").number();
            if (depth == 0 || depth > 10000) {
                throw std::runtime_error("invalid interruption record induction depth");
            }
        } else if (!pdr) {
            config.at("transition_count").number();
        }
        output << "Q3A_RUN_RESOLVED_CONFIGURATION_SHA256 " << digest << '\n';
    }

    output << "Q3A_RUN_RECORD_SHA256 " << q3a::sha256_hex(content) << '\n'
           << "Q3A_RUN_RECORDED_STATUS " << status << '\n'
           << "Q3A_RUN_INTERRUPTION " << cause << " phase=" << stage << " elapsed_ms=" << elapsed << '\n';
    if (target_known) output << "Q3A_RUN_PROPERTY " << std::quoted(property) << " engine=" << engine << '\n';
    output << "Q3A_RUN_BUILD_ID " << build_id << '\n';
    if (!loading) output << "Q3A_RUN_SOURCE_SET_SHA256 " << source << '\n';
    for (const auto& entry : work) output << "Q3A_RUN_COMPLETED " << entry.string() << '\n';
    output << "Q3A_RUN_EVIDENCE INTERRUPTION_METADATA_ONLY\n"
           << "Q3A_RUN_RECORD_STATUS STRUCTURE_VALID\n";
}

VerifiedDebugSession open_verified_debug_session(const std::filesystem::path& bundle_directory,
                                                 const DebugOptions& options, bool require_source_model) {
    VerifiedDebugSession session;
    std::ostringstream log;
    verify_bundle(bundle_directory, log, &session, options, require_source_model);
    session.view.verification_log = log.str();
    return session;
}

#include "native-viewport-adapter.inc"
#include "debug_session_state.inc"

void write_verified_debug_page(const std::filesystem::path& bundle_directory,
                               const DebugOptions& options, std::ostream& output) {
    const auto session = open_verified_debug_session(bundle_directory, options, false);
    write_debug_page(output, session.view);
}

} // namespace q3a::bundle
