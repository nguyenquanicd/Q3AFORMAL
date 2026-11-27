#include "parser.hpp"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>
#include <utility>

namespace q3a::frontend {
namespace {

class Parser {
public:
    Parser(std::vector<Token> tokens, SyntaxProfile profile)
        : tokens_(std::move(tokens)), profile_(profile) {
        if (tokens_.empty() || tokens_.back().kind != TokenKind::End) {
            tokens_.push_back(Token{TokenKind::End, {}, {"<input>", 1, 1, 0}});
        }
    }

    SyntaxUnit run(bool allow_empty) {
        while (!at_end()) {
            if (at("module")) parse_module();
            else if (at("bind")) binds_.push_back(parse_bind());
            else if (at("property")) parse_property_declaration();
            else if (at("sequence")) reject_sequence_declaration();
            else if (property_check_at()) parse_property_check();
            else if (labeled_property_check()) {
                const auto label = advance();
                expect(":");
                parse_property_check(label);
            } else fail(current(), "unsupported top-level construct; expected a module, bind or property");
        }
        if (index_ + 1 != tokens_.size()) {
            fail(current(), "unexpected tokens after the end-of-source marker");
        }
        if (!allow_empty && modules_.empty() && binds_.empty() && standalone_declarations_.empty() &&
            standalone_checks_.empty()) {
            fail(current(), "source file contains no module declaration");
        }
        return SyntaxUnit{std::move(tokens_), std::move(modules_), std::move(binds_),
            std::move(standalone_declarations_), std::move(standalone_checks_),
            std::move(hierarchical_operands_)};
    }

private:
    const Token& current() const { return tokens_[index_]; }
    const Token& look(std::size_t amount = 1) const {
        const auto target = std::min(index_ + amount, tokens_.size() - 1);
        return tokens_[target];
    }
    bool at_end() const { return current().kind == TokenKind::End; }
    bool at(const std::string& text) const { return current().text == text; }
    bool property_check_at(std::size_t offset = 0) const {
        const auto& keyword = look(offset).text;
        return keyword == "assert" || keyword == "assume" || keyword == "cover";
    }
    bool labeled_property_check() const {
        return current().kind == TokenKind::Identifier && look().text == ":" && property_check_at(2);
    }
    bool accept(const std::string& text) {
        if (!at(text)) {
            return false;
        }
        ++index_;
        return true;
    }
    const Token& advance() {
        const auto& token = current();
        if (!at_end()) {
            ++index_;
        }
        return token;
    }
    const Token& expect(const std::string& text) {
        if (!at(text)) {
            fail(current(), "expected '" + text + "', found " + describe(current()));
        }
        return advance();
    }
    const Token& expect_identifier(const std::string& context) {
        if (current().kind != TokenKind::Identifier ||
            current().text.empty() || current().text.front() == '$') {
            fail(current(), "expected identifier for " + context + ", found " +
                             describe(current()));
        }
        return advance();
    }
    static std::string describe(const Token& token) {
        if (token.kind == TokenKind::End) {
            return "end of file";
        }
        return "'" + token.text + "'";
    }
    [[noreturn]] static void fail(const Token& token,
                                  const std::string& message,
                                  InputDiagnosticKind kind = InputDiagnosticKind::Invalid) {
        throw ParseError(token.location, message, kind);
    }

    [[noreturn]] void reject_sequence_declaration() const {
        fail(current(), "named sequence declarations are outside the supported SVA profile",
             InputDiagnosticKind::Unsupported);
    }

    void parse_module() {
        const auto first = index_;
        const auto module_token = expect("module");
        const auto name = expect_identifier("module name");
        current_module_ = ParsedModule{};
        current_module_.name = name.text;
        current_module_.location = module_token.location;
        current_module_.first_token = first;
        current_module_active_ = true;
        has_parameter_port_list_ = accept("#");
        if (has_parameter_port_list_) {
            expect("(");
            parse_parameter_port_list();
            expect(")");
        }
        expect("(");
        parse_port_list();
        expect(")");
        expect(";");

        while (!at_end() && !at("endmodule")) {
            parse_module_item();
        }
        expect("endmodule");
        current_module_.after_last_token = index_;
        modules_.push_back(std::move(current_module_));
        current_module_active_ = false;
    }

    void parse_parameter_port_list() {
        while (!at(")")) {
            const bool local = accept("localparam");
            if (!local) expect("parameter");
            auto& declarations = local ? current_module_.localparams : current_module_.parameters;
            ScalarType type = ScalarType::Untyped;
            bool is_signed = false;
            std::optional<PackedRangeSyntax> range;
            parse_optional_parameter_type(type, is_signed, range);
            const auto name = expect_identifier("parameter name");
            std::optional<ExpressionSpan> initializer;
            if (accept("=")) {
                initializer = parse_expression_span();
            }
            declarations.push_back(ParameterSyntax{
                name.text, name.location, type, is_signed, initializer, local,
                range});
            while (accept(",")) {
                if (at("parameter") || at("localparam")) {
                    break;
                }
                const auto inherited_name = expect_identifier("parameter name");
                std::optional<ExpressionSpan> inherited_initializer;
                if (accept("=")) {
                    inherited_initializer = parse_expression_span();
                }
                declarations.push_back(ParameterSyntax{
                    inherited_name.text, inherited_name.location, type,
                    is_signed, inherited_initializer, local, range});
            }
            if (!at("parameter") && !at("localparam")) {
                break;
            }
        }
    }

    void parse_optional_parameter_type(
        ScalarType& type,
        bool& is_signed,
        std::optional<PackedRangeSyntax>& range) {
        if (accept("integer")) {
            type = ScalarType::Integer;
            is_signed = true;
            return;
        }
        if (accept("logic")) {
            type = ScalarType::Logic;
        } else if (accept("bit")) {
            type = ScalarType::Bit;
        } else {
            return;
        }
        if (accept("signed")) is_signed = true;
        else if (accept("unsigned")) is_signed = false;
        range = parse_optional_range();
    }

    void parse_port_list() {
        while (!at(")")) {
            PortDirection direction;
            if (accept("input")) direction = PortDirection::Input;
            else if (accept("output")) direction = PortDirection::Output;
            else {
                fail(current(), "only explicit input/output ANSI port declarations are supported");
            }
            ScalarType type;
            if (accept("logic")) type = ScalarType::Logic;
            else if (accept("bit")) type = ScalarType::Bit;
            else {
                fail(current(), "port type must be logic or bit in Phase 0");
            }
            bool is_signed = false;
            if (accept("signed")) is_signed = true;
            else accept("unsigned");
            const auto range = parse_optional_range();
            const auto port = expect_identifier("port name");
            current_module_.ports.push_back(PortSyntax{
                port.text, port.location, direction, type, is_signed, range});
            if (!accept(",")) {
                break;
            }
            while (!at_end() && current().kind == TokenKind::Identifier &&
                   current().text != "input" && current().text != "output") {
                const auto inherited_port = expect_identifier("port name");
                current_module_.ports.push_back(PortSyntax{
                    inherited_port.text, inherited_port.location, direction,
                    type, is_signed, range});
                if (!accept(",")) {
                    break;
                }
            }
        }
    }

    std::optional<PackedRangeSyntax> parse_optional_range() {
        if (!accept("[")) {
            return std::nullopt;
        }
        const auto left = parse_expression_span();
        expect(":");
        const auto right = parse_expression_span();
        expect("]");
        return PackedRangeSyntax{left, right};
    }

    ExpressionSpan parse_expression_span() {
        const auto first = index_;
        parse_expression();
        return ExpressionSpan{first, index_};
    }

    void parse_module_item() {
        if (at("assign")) {
            current_module_.continuous_assignments.push_back(
                parse_continuous_assignment());
        } else if (at("always_comb")) {
            const auto keyword = advance();
            current_module_.processes.push_back(ProcessSyntax{
                ProcessKind::AlwaysComb, keyword.location, std::nullopt,
                parse_block_statement(false)});
        } else if (at("always_ff")) {
            const auto keyword = advance();
            const auto clock = parse_event_control();
            current_module_.processes.push_back(ProcessSyntax{
                ProcessKind::AlwaysFF, keyword.location, clock,
                parse_block_statement(false)});
        } else if (at("property")) {
            parse_property_declaration();
        } else if (at("sequence")) {
            if (profile_ != SyntaxProfile::FourStateDevelopment) reject_sequence_declaration();
            parse_sequence_declaration();
        } else if (at("assert") || at("assume") || at("cover")) {
            parse_property_check();
        } else if (current().kind == TokenKind::Identifier && look().text == ":" &&
                   (look(2).text == "assert" || look(2).text == "assume" ||
                    look(2).text == "cover")) {
            const auto label = advance();
            expect(":");
            parse_property_check(label);
        } else if (at("generate")) {
            parse_generate_region();
        } else if (at("localparam")) {
            parse_parameter_declaration(true);
        } else if (at("parameter")) {
            parse_parameter_declaration(false);
        } else if (at("genvar")) {
            parse_genvar_declaration();
        } else if (at("logic") || at("bit")) {
            auto declarations = parse_signal_declaration(true);
            if (current_module_active_) {
                current_module_.signals.insert(current_module_.signals.end(),
                    declarations.begin(), declarations.end());
            }
        } else if (at("always") || at("function") || at("task") || at("interface") ||
                   at("union") || at("class") || at("import")) {
            fail(current(), "module item " + describe(current()) +
                " is outside the Phase 0 subset");
        } else if (current().kind == TokenKind::Identifier &&
                   current().text.front() != '$') {
            current_module_.instances.push_back(parse_module_instantiation());
        } else {
            fail(current(), "unsupported or malformed module item " + describe(current()));
        }
    }

    void parse_parameter_declaration(bool local,
                                     std::vector<ParameterSyntax>* scoped = nullptr) {
        advance();
        // A parameter in the module body is local when a parameter port
        // list is present, including an empty list.
        local = local || has_parameter_port_list_ || scoped;
        auto& declarations = scoped ? *scoped
            : local ? current_module_.localparams : current_module_.parameters;
        ScalarType type = ScalarType::Untyped;
        bool is_signed = false;
        std::optional<PackedRangeSyntax> range;
        parse_optional_parameter_type(type, is_signed, range);
        const auto name = expect_identifier(local ? "localparam name" : "parameter name");
        expect("=");
        auto initializer = parse_expression_span();
        if (current_module_active_) {
            declarations.push_back(ParameterSyntax{name.text, name.location,
                type, is_signed, initializer, local, range});
        }
        while (accept(",")) {
            const auto inherited_name = expect_identifier(
                local ? "localparam name" : "parameter name");
            expect("=");
            initializer = parse_expression_span();
            if (current_module_active_) {
                declarations.push_back(ParameterSyntax{inherited_name.text,
                    inherited_name.location, type, is_signed, initializer,
                    local, range});
            }
        }
        expect(";");
    }

    void parse_genvar_declaration() {
        expect("genvar");
        expect_identifier("genvar name");
        while (accept(",")) {
            expect_identifier("genvar name");
        }
        expect(";");
    }

    std::vector<SignalSyntax> parse_signal_declaration(bool module_scope = false) {
        std::vector<SignalSyntax> declarations;
        ScalarType type = ScalarType::Logic;
        if (accept("bit")) type = ScalarType::Bit;
        else expect("logic");
        bool is_signed = false;
        if (accept("signed")) is_signed = true;
        else accept("unsigned");
        const auto range = parse_optional_range();
        do {
            const auto name = expect_identifier("signal name");
            SignalSyntax declaration{name.text, name.location, type, is_signed, range};
            if (module_scope && profile_ == SyntaxProfile::ExactMemoryDevelopment) {
                if (const auto indices = parse_optional_range()) {
                    if (current_module_active_) {
                        current_module_.memories.push_back({std::move(declaration), *indices});
                    }
                    continue;
                }
            }
            declarations.push_back(std::move(declaration));
        } while (accept(","));
        expect(";");
        return declarations;
    }

    ContinuousAssignmentSyntax parse_continuous_assignment() {
        const auto location = current().location;
        expect("assign");
        const auto lvalue_first = index_;
        parse_lvalue();
        const ExpressionSpan lvalue{lvalue_first, index_};
        expect("=");
        const auto expression = parse_expression_span();
        expect(";");
        return ContinuousAssignmentSyntax{lvalue, expression, location};
    }

    void parse_lvalue() {
        expect_identifier("assignment target");
        while (accept("[")) {
            parse_expression();
            if (accept(":")) {
                parse_expression();
            }
            expect("]");
        }
    }

    StatementSyntax parse_block_statement(bool allow_label) {
        const auto begin = expect("begin");
        StatementSyntax block;
        block.kind = StatementKind::Block;
        block.location = begin.location;
        if (allow_label && accept(":")) {
            expect_identifier("generate block label");
        }
        while (!at_end() && !at("end")) {
            block.body.push_back(parse_statement());
        }
        expect("end");
        return block;
    }

    StatementSyntax parse_statement() {
        if (at("begin")) {
            return parse_block_statement(false);
        }
        if (at("if")) {
            const auto if_token = advance();
            expect("(");
            const auto condition = parse_expression_span();
            expect(")");
            StatementSyntax result;
            result.kind = StatementKind::If;
            result.location = if_token.location;
            result.expression = condition;
            result.body.push_back(parse_statement());
            if (accept("else")) {
                result.else_body.push_back(parse_statement());
            }
            return result;
        }
        if (at("case") || at("casez") || at("casex")) {
            if (at("casex") && profile_ != SyntaxProfile::FourStateDevelopment) {
                fail(current(), "casex requires the four-state development profile",
                     InputDiagnosticKind::Unsupported);
            }
            return parse_case_statement();
        }
        const auto location = current().location;
        const auto lvalue_first = index_;
        parse_lvalue();
        const ExpressionSpan lvalue{lvalue_first, index_};
        bool nonblocking = false;
        if (accept("<=")) {
            nonblocking = true;
        } else if (!accept("=")) {
            fail(current(), "procedural assignment requires '=' or '<='");
        }
        const auto expression = parse_expression_span();
        expect(";");
        StatementSyntax result;
        result.kind = StatementKind::Assignment;
        result.location = location;
        result.lvalue = lvalue;
        result.assignment = expression;
        result.nonblocking = nonblocking;
        return result;
    }

    StatementSyntax parse_case_statement() {
        const auto location = current().location;
        const auto keyword = advance().text;
        expect("(");
        const auto selector = parse_expression_span();
        expect(")");
        StatementSyntax result;
        result.kind = keyword == "casex" ? StatementKind::CaseX :
            keyword == "casez" ? StatementKind::CaseZ : StatementKind::Case;
        result.location = location;
        result.expression = selector;
        bool saw_item = false;
        while (!at_end() && !at("endcase")) {
            CaseItemSyntax item;
            item.location = current().location;
            if (accept("default")) {
                item.is_default = true;
                expect(":");
            } else {
                const bool previous = casez_pattern_;
                casez_pattern_ = keyword == "casez";
                item.labels.push_back(parse_expression_span());
                while (accept(",")) {
                    item.labels.push_back(parse_expression_span());
                }
                casez_pattern_ = previous;
                expect(":");
            }
            item.statements.push_back(parse_statement());
            result.case_items.push_back(std::move(item));
            saw_item = true;
        }
        if (!saw_item) {
            fail(current(), "case statement must contain at least one item");
        }
        expect("endcase");
        return result;
    }

    std::string parse_scoped_operand() {
        auto name = at("$root") ? advance().text : expect_identifier("signal name").text;
        for (;;) {
            if (at("[") && look(2).text == "]" && look(3).text == ".") {
                advance();
                const auto& index = advance();
                std::uint64_t value = 0;
                const auto parsed = std::from_chars(index.text.data(), index.text.data() + index.text.size(), value);
                if (index.kind != TokenKind::Number || parsed.ec != std::errc{} ||
                    parsed.ptr != index.text.data() + index.text.size()) {
                    fail(index, "hierarchy indices must be nonnegative decimal literals",
                        InputDiagnosticKind::Unsupported);
                }
                expect("]");
                name += "[" + std::to_string(value) + "]";
            }
            if (!accept(".")) break;
            name += "." + expect_identifier("hierarchical signal component").text;
        }
        return name;
    }

    std::string parse_event_control() {
        expect("@");
        expect("(");
        if (at("negedge")) {
            fail(current(), "expected 'posedge', found 'negedge'", InputDiagnosticKind::Unsupported);
        }
        expect("posedge");
        const auto clock = current_module_active_ ? expect_identifier("positive-edge clock").text
                                                  : parse_scoped_operand();
        if (at("or") || at(",") || at("iff")) {
            fail(current(), "event lists and event qualifiers are outside the single positive-edge profile",
                 InputDiagnosticKind::Unsupported);
        }
        expect(")");
        return clock;
    }

    void reject_disable_iff(std::string_view terminator) const {
        if (at("disable") && look().text == "iff") {
            fail(look(), "expected '" + std::string(terminator) + "', found 'iff'",
                 InputDiagnosticKind::Unsupported);
        }
    }

    void parse_sequence_declaration() {
        const auto keyword = expect("sequence");
        const auto name = expect_identifier("sequence name");
        if (accept("(") && !accept(")")) {
            fail(current(), "named sequence parameters are outside the four-state development profile",
                 InputDiagnosticKind::Unsupported);
        }
        expect(";");
        const auto begin = index_;
        parse_sva_sequence(false);
        const ExpressionSpan body{begin, index_};
        expect(";");
        expect("endsequence");
        if (accept(":")) {
            const auto end_name = expect_identifier("endsequence label");
            if (end_name.text != name.text) fail(end_name, "endsequence label differs from declaration");
        }
        current_module_.sequence_declarations.push_back({name.text, keyword.location, body});
    }

    void parse_property_declaration() {
        const auto keyword = expect("property");
        const auto name = expect_identifier("property name");
        const bool reusable = current_module_active_ && profile_ == SyntaxProfile::FourStateDevelopment;
        if (reusable && accept("(") && !accept(")")) {
            fail(current(), "named property parameters are outside the four-state development profile",
                 InputDiagnosticKind::Unsupported);
        }
        expect(";");
        const auto clock = reusable && !at("@") ? std::string{} : parse_event_control();
        reject_disable_iff(";");
        const auto sequence_first = index_;
        parse_sva_sequence(true);
        const ExpressionSpan sequence{sequence_first, index_};
        if (!reusable || !at("endproperty")) expect(";");
        expect("endproperty");
        if (reusable && accept(":")) {
            const auto end_name = expect_identifier("endproperty label");
            if (end_name.text != name.text) fail(end_name, "endproperty label differs from declaration");
        }
        if (generate_depth_ == 0) {
            auto& declarations = current_module_active_
                ? current_module_.property_declarations : standalone_declarations_;
            declarations.push_back(
                PropertyDeclarationSyntax{name.text, keyword.location, clock,
                                          sequence});
        }
    }

    void parse_property_check(std::optional<Token> label = std::nullopt) {
        const auto keyword = advance(); // assert, assume, or cover
        expect("property");
        expect("(");
        PropertyCheckSyntax check;
        check.location = label ? label->location : keyword.location;
        if (label) check.label = label->text;
        if (keyword.text == "assert") {
            check.kind = PropertyCheckKind::Assert;
        } else if (keyword.text == "assume") {
            check.kind = PropertyCheckKind::Assume;
        } else {
            check.kind = PropertyCheckKind::Cover;
        }
        if (at("@")) {
            check.clock = parse_event_control();
            reject_disable_iff(")");
            const auto sequence_first = index_;
            parse_sva_sequence(true);
            check.sequence = ExpressionSpan{sequence_first, index_};
        } else {
            const auto reference = expect_identifier("property reference");
            check.property_reference = reference.text;
            if (current_module_active_ && profile_ == SyntaxProfile::FourStateDevelopment &&
                accept("(") && !accept(")")) {
                fail(current(), "named property arguments are outside the four-state development profile",
                     InputDiagnosticKind::Unsupported);
            }
        }
        expect(")");
        expect(";");
        if (generate_depth_ == 0) {
            auto& checks = current_module_active_ ? current_module_.property_checks : standalone_checks_;
            if (label && std::any_of(checks.begin(), checks.end(), [&](const auto& previous) {
                        return previous.label == check.label;
                    })) {
                fail(*label, "duplicate property check name '" + label->text + "'");
            }
            checks.push_back(std::move(check));
        }
    }

    void parse_sva_sequence(bool allow_implication) {
        const bool previous = in_sva_;
        in_sva_ = true;
        do {
            parse_expression();
            parse_repetition_suffix();
            while (accept("##")) {
                parse_sva_sequence_delay();
                parse_expression();
                parse_repetition_suffix();
            }
        } while (profile_ == SyntaxProfile::FourStateDevelopment &&
                 (accept("or") || accept("and") || accept("intersect") ||
                  accept("within") || accept("throughout")));
        if (allow_implication && (at("|->") || at("|=>"))) {
            advance();
            if (at("s_eventually")) {
                if (profile_ != SyntaxProfile::LivenessDevelopment) {
                    fail(current(), "s_eventually requires the liveness development profile",
                         InputDiagnosticKind::Unsupported);
                }
                advance();
                if (at("[")) {
                    fail(current(), "ranged s_eventually is outside the liveness development profile",
                         InputDiagnosticKind::Unsupported);
                }
            }
            parse_sva_sequence(false);
            if (at("|->") || at("|=>")) {
                fail(current(), "chained SVA implications are outside the Phase 0 grammar",
                     InputDiagnosticKind::Unsupported);
            }
        }
        if (at("and") || at("or") || at("intersect") || at("throughout") ||
            at("within") || at("iff") || at("implies") || at("until") ||
            at("s_until") || at("until_with") || at("s_until_with")) {
            fail(current(), "temporal operator '" + current().text + "' is outside the finite SVA profile",
                 InputDiagnosticKind::Unsupported);
        }
        in_sva_ = previous;
    }

    void parse_sva_sequence_delay() {
        if (at("[*") || (at("[") && look().text == "+" && look(2).text == "]")) {
            fail(current(), "unbounded sequence delay is outside the finite SVA profile",
                 InputDiagnosticKind::Unsupported);
        }
        if (!accept("[")) {
            if (accept("(")) {
                parse_constant_bound("sequence delay", true);
                expect(")");
            } else if (current().kind == TokenKind::Number) {
                validate_number(current(), false);
                advance();
            } else {
                if (at("$")) {
                    fail(current(), "unbounded sequence or repetition bounds are unsupported",
                         InputDiagnosticKind::Unsupported);
                }
                expect_identifier("sequence delay constant");
            }
            return;
        }
        const auto minimum = parse_constant_bound(
            "sequence delay lower bound", true);
        expect(":");
        const auto maximum = parse_constant_bound(
            "sequence delay upper bound", true);
        if (minimum.has_value() && maximum.has_value() &&
            *maximum < *minimum) {
            fail(current(),
                "sequence delay upper bound must be at least its lower bound");
        }
        expect("]");
    }

    void parse_repetition_suffix() {
        if (at("[") && (look().text == "->" || look().text == "=")) {
            fail(look(), "goto and nonconsecutive repetition are outside the finite SVA profile",
                 InputDiagnosticKind::Unsupported);
        }
        if (at("[") && look().text == "+" && look(2).text == "]") {
            fail(look(), "unbounded repetition is outside the finite SVA profile",
                 InputDiagnosticKind::Unsupported);
        }
        if (!accept("[*")) return;
        if (at("]")) {
            fail(current(), "unbounded repetition is outside the finite SVA profile",
                 InputDiagnosticKind::Unsupported);
        }
        const auto minimum = parse_constant_bound("repetition lower bound", false);
        auto maximum = minimum;
        if (accept(":")) {
            maximum = parse_constant_bound("repetition upper bound", false);
        }
        if (maximum.has_value() && minimum.has_value() &&
            *maximum < *minimum) {
            fail(current(), "repetition upper bound must be at least its lower bound");
        }
        expect("]");
    }

    std::optional<std::uint64_t> parse_constant_bound(const std::string& context,
                                                      bool allow_zero) {
        if (current().kind != TokenKind::Number ||
            binary_precedence(look().text) >= 0 || look().text == "?") {
            if (at("$")) {
                fail(current(), "unbounded sequence or repetition bounds are unsupported",
                     InputDiagnosticKind::Unsupported);
            }
            parse_expression();
            return std::nullopt;
        }
        // Sized literals must be interpreted with their declared width and signedness.
        // Leave their numeric checks to the same typed evaluator used by lowering.
        if (current().text.find('\'') != std::string::npos) {
            validate_number(current(), false);
            advance();
            return std::nullopt;
        }
        auto digits = current().text;
        digits.erase(std::remove(digits.begin(), digits.end(), '_'), digits.end());
        std::uint64_t value = 0;
        const auto result = std::from_chars(digits.data(),
                                            digits.data() + digits.size(), value,
                                            10);
        if (result.ec != std::errc{} || result.ptr != digits.data() + digits.size()) {
            parse_expression();
            return std::nullopt;
        }
        if (!allow_zero && value == 0) {
            fail(current(), context + " must be positive in Phase 0", InputDiagnosticKind::Unsupported);
        }
        advance();
        return value;
    }

    void parse_generate_region() {
        expect("generate");
        ++generate_depth_;
        while (!at_end() && !at("endgenerate")) {
            auto item = parse_generate_item();
            if (item) current_module_.generate_items.push_back(std::move(*item));
        }
        expect("endgenerate");
        --generate_depth_;
    }

    std::optional<GenerateSyntax> parse_generate_item() {
        const auto first = index_;
        const auto location = current().location;
        if (accept("if")) {
            expect("(");
            const auto condition = parse_expression_span();
            expect(")");
            GenerateSyntax node;
            node.kind = GenerateKind::Conditional;
            node.location = location;
            node.condition = condition;
            node.first_token = first;
            node.body.push_back(parse_generate_branch());
            if (accept("else")) {
                node.else_body.push_back(parse_generate_branch());
            }
            node.after_last_token = index_;
            return node;
        }
        if (accept("for")) {
            expect("(");
            accept("genvar");
            const auto variable = expect_identifier("generate loop variable");
            expect("=");
            const auto initial_value = parse_expression_span();
            expect(";");
            const auto condition = parse_expression_span();
            expect(";");
            const auto update_variable = expect_identifier("generate loop update variable");
            expect("=");
            const auto update_value = parse_expression_span();
            expect(")");
            GenerateSyntax node;
            node.kind = GenerateKind::Loop;
            node.location = location;
            node.variable = variable.text;
            node.update_variable = update_variable.text;
            node.initial_value = initial_value;
            node.condition = condition;
            node.update_value = update_value;
            node.first_token = first;
            node.body.push_back(parse_generate_branch());
            node.after_last_token = index_;
            return node;
        }
        if (at("begin")) {
            return parse_generate_branch();
        }
        if (at("assign")) {
            GenerateSyntax node;
            node.kind = GenerateKind::Other;
            node.location = location;
            node.first_token = first;
            node.assignment = parse_continuous_assignment();
            node.after_last_token = index_;
            return node;
        } else if (at("localparam") || at("parameter")) {
            GenerateSyntax node;
            node.kind = GenerateKind::Other;
            node.location = location;
            node.first_token = first;
            parse_parameter_declaration(true, &node.constants);
            node.after_last_token = index_;
            return node;
        } else if (at("logic") || at("bit")) {
            GenerateSyntax node;
            node.kind = GenerateKind::Other;
            node.location = location;
            node.first_token = first;
            node.declarations = parse_signal_declaration();
            node.after_last_token = index_;
            return node;
        } else if (at("sequence")) {
            reject_sequence_declaration();
        } else if (current().kind == TokenKind::Identifier &&
                   current().text.front() != '$') {
            GenerateSyntax node;
            node.kind = GenerateKind::Instance;
            node.location = location;
            node.first_token = first;
            node.instance = parse_module_instantiation();
            node.after_last_token = index_;
            return node;
        } else {
            fail(current(), "unsupported generate construct " + describe(current()));
        }
        GenerateSyntax node;
        node.kind = GenerateKind::Other;
        node.location = location;
        node.first_token = first;
        node.after_last_token = index_;
        return node;
    }

    GenerateSyntax parse_generate_branch() {
        if (!at("begin")) {
            auto item = parse_generate_item();
            if (!item) {
                fail(current(), "expected a generate branch item");
            }
            return std::move(*item);
        }
        const auto first = index_;
        const auto location = current().location;
        expect("begin");
        std::string label;
        if (accept(":")) {
            label = expect_identifier("generate block label").text;
        }
        GenerateSyntax block;
        block.kind = GenerateKind::Block;
        block.label = std::move(label);
        block.location = location;
        block.first_token = first;
        while (!at_end() && !at("end")) {
            auto item = parse_generate_item();
            if (item) block.body.push_back(std::move(*item));
        }
        expect("end");
        block.after_last_token = index_;
        return block;
    }

    BindSyntax parse_bind() {
        BindSyntax binding;
        binding.location = expect("bind").location;
        binding.target = expect_identifier("bind target").text;
        while (accept(".")) {
            binding.hierarchical = true;
            binding.target += "." + expect_identifier("bind target instance").text;
            if (accept("[")) {
                const auto& index = advance();
                std::uint64_t value = 0;
                const auto parsed = std::from_chars(index.text.data(), index.text.data() + index.text.size(), value);
                if (index.kind != TokenKind::Number || parsed.ec != std::errc{} ||
                    parsed.ptr != index.text.data() + index.text.size()) {
                    fail(index, "bind target indices must be nonnegative decimal literals",
                         InputDiagnosticKind::Unsupported);
                }
                expect("]");
                binding.target += "[" + std::to_string(value) + "]";
            }
        }
        if (at(":")) {
            fail(current(), "bind target instance lists are unsupported", InputDiagnosticKind::Unsupported);
        }
        binding.instance = parse_module_instantiation();
        return binding;
    }

    InstanceSyntax parse_module_instantiation() {
        const auto module_type = expect_identifier("module type");
        InstanceSyntax instance;
        instance.module_type = module_type.text;
        instance.location = module_type.location;
        std::vector<ParameterOverrideSyntax> parameter_overrides;
        if (accept("#")) {
            expect("(");
            if (!at(")")) {
                do {
                    ParameterOverrideSyntax override;
                    override.location = current().location;
                    if (accept(".")) {
                        override.name = expect_identifier("named parameter override").text;
                        expect("(");
                        override.value = parse_expression_span();
                        expect(")");
                    } else {
                        override.value = parse_expression_span();
                    }
                    parameter_overrides.push_back(std::move(override));
                } while (accept(","));
            }
            expect(")");
        }
        const auto instance_name = expect_identifier("instance name");
        instance.instance_name = instance_name.text;
        instance.parameter_overrides = std::move(parameter_overrides);
        expect("(");
        if (!at(")")) {
            do {
                PortConnectionSyntax connection;
                connection.location = current().location;
                if (accept(".")) {
                    connection.formal_name = expect_identifier("named port connection").text;
                    expect("(");
                    connection.actual = parse_expression_span();
                    expect(")");
                } else {
                    connection.actual = parse_expression_span();
                }
                instance.port_connections.push_back(std::move(connection));
            } while (accept(","));
        }
        expect(")");
        expect(";");
        return instance;
    }

    void parse_expression(int minimum_precedence = 0) {
        parse_unary();
        for (;;) {
            const auto& token = current().text;
            const bool four_state_operator = token == "===" || token == "!==" ||
                token == "==?" || token == "!=?" ||
                token == "*" || token == "/" || token == "%" || is_shift_operator(token);
            if (is_unsupported_binary(token) &&
                !(four_state_operator && profile_ == SyntaxProfile::FourStateDevelopment)) {
                fail(current(), "operator '" + current().text +
                                "' is outside the Phase 0 RTL expression subset",
                     InputDiagnosticKind::Unsupported);
            }
            const auto precedence = binary_precedence(current().text);
            if (precedence < minimum_precedence) {
                break;
            }
            const auto op = advance().text;
            (void)op;
            parse_expression(precedence + 1);
        }
        if (minimum_precedence == 0 && accept("?")) {
            parse_expression();
            expect(":");
            parse_expression();
        }
    }

    static int binary_precedence(const std::string& op) {
        if (op == "||") return 1;
        if (op == "&&") return 2;
        if (op == "|") return 3;
        if (op == "^" || op == "~^" || op == "^~") return 4;
        if (op == "&") return 5;
        if (op == "==" || op == "!=" || op == "===" || op == "!==" ||
            op == "==?" || op == "!=?") return 6;
        if (op == "<" || op == "<=" || op == ">" || op == ">=") return 7;
        if (is_shift_operator(op)) return 8;
        if (op == "+" || op == "-") return 9;
        if (op == "*" || op == "/" || op == "%") return 10;
        return -1;
    }

    static bool is_unsupported_binary(const std::string& op) {
        return op == "*" || op == "/" || op == "%" || op == "**" ||
               op == "<<<" || op == ">>>" || op == "===" || op == "!==" ||
               op == "==?" || op == "!=?";
    }

    void parse_unary() {
        if (at("+") || at("-") || at("!") || at("~") ||
            (profile_ == SyntaxProfile::FourStateDevelopment && is_reduction_operator(current().text))) {
            advance();
            parse_unary();
            return;
        }
        if (at("~^") || at("^~")) {
            fail(current(), "reduction XNOR is outside the Phase 0 unary operator subset");
        }
        parse_primary();
    }

    void parse_primary() {
        if (current().kind == TokenKind::Number) {
            validate_number(current(), casez_pattern_);
            advance();
            return;
        }
        if (current().kind == TokenKind::String) {
            fail(current(), "string literals are outside the Phase 0 RTL subset");
        }
        if (current().kind == TokenKind::Identifier) {
            if (current().text == "$past") {
                parse_past_call();
                return;
            }
            if (in_sva_ && ((profile_ == SyntaxProfile::SampledValueDevelopment &&
                 (is_sampled_value_function(current().text) || is_bit_vector_assertion_function(current().text))) ||
                (profile_ == SyntaxProfile::FourStateDevelopment && is_sampled_value_function(current().text)))) {
                const bool sampled = is_sampled_value_function(current().text);
                advance();
                expect("(");
                parse_expression();
                if (at(",")) {
                    fail(current(), sampled ? "sampled-value alternate clocks are outside this profile" :
                         "bit-vector assertion functions require one argument", InputDiagnosticKind::Unsupported);
                }
                expect(")");
                return;
            }
            if (in_sva_ && profile_ == SyntaxProfile::FourStateDevelopment && accept("first_match")) {
                expect("(");
                parse_sva_sequence(false);
                if (at(",")) {
                    fail(current(), "first_match sequence match items are outside this profile",
                         InputDiagnosticKind::Unsupported);
                }
                expect(")");
                return;
            }
            if (in_sva_ && (at("eventually") || at("s_eventually") || at("always") ||
                            at("s_always") || at("nexttime") || at("s_nexttime") ||
                            at("strong") || at("weak") || at("first_match"))) {
                fail(current(), "temporal operator '" + current().text + "' is outside the finite SVA profile",
                     InputDiagnosticKind::Unsupported);
            }
            const bool standalone = in_sva_ && !current_module_active_;
            if (!current().text.empty() && current().text.front() == '$' &&
                !(standalone && at("$root"))) {
                fail(current(), "unsupported system function " + current().text,
                     InputDiagnosticKind::Unsupported);
            }
            if (standalone) {
                const auto first = index_;
                auto name = parse_scoped_operand();
                if (index_ > first + 1) hierarchical_operands_.emplace(first, std::make_pair(index_, std::move(name)));
            } else {
                advance();
            }
            while (at("[")) {
                if (in_sva_ && (look().text == "->" || look().text == "=" ||
                    (look().text == "+" && look(2).text == "]"))) break;
                advance();
                parse_expression();
                if (accept(":") || (profile_ == SyntaxProfile::FourStateDevelopment &&
                        (accept("+:") || accept("-:")))) {
                    parse_expression();
                }
                expect("]");
            }
            if (at("(")) {
                if (in_sva_ && current_module_active_ && profile_ == SyntaxProfile::FourStateDevelopment &&
                    look().text == ")") {
                    advance();
                    advance();
                    return;
                }
                fail(current(), "function calls are outside the Phase 0 RTL subset");
            }
            return;
        }
        if (accept("(")) {
            if (in_sva_) {
                parse_sva_sequence(false);
            } else {
                parse_expression();
            }
            expect(")");
            return;
        }
        if (accept("{")) {
            parse_expression();
            while (accept(",")) {
                parse_expression();
            }
            expect("}");
            return;
        }
        fail(current(), "expected an expression operand, found " + describe(current()),
             in_sva_ && at("@") ? InputDiagnosticKind::Unsupported : InputDiagnosticKind::Invalid);
    }

    void parse_past_call() {
        if (!in_sva_) {
            fail(current(), "$past is supported only in an SVA property");
        }
        advance();
        expect("(");
        parse_expression();
        if (accept(",")) {
            parse_constant_bound("$past delay", false);
            if (at(",")) {
                fail(current(), "$past gating and alternate clocks are outside the finite SVA profile",
                     InputDiagnosticKind::Unsupported);
            }
        }
        expect(")");
    }

    void validate_number(const Token& token, bool allow_casez_wildcards) const {
        const auto quote = token.text.find('\'');
        if (token.text == "'0" || token.text == "'1") {
            return;
        }
        if (quote == std::string::npos) {
            if (token.text.find_first_of(".eE") != std::string::npos) {
                fail(token, "real-number literals are outside the Phase 0 subset");
            }
            return;
        }
        if (quote == 0) {
            if (token.text.size() == 2 && token.text[0] == '\'' &&
                (std::tolower(static_cast<unsigned char>(token.text[1])) == 'x' ||
                 std::tolower(static_cast<unsigned char>(token.text[1])) == 'z')) {
                if (profile_ == SyntaxProfile::FourStateDevelopment) return;
                fail(token,
                    "unbased unsized X/Z fill literals are unsupported; only '0 and '1 are supported",
                    InputDiagnosticKind::Unsupported);
            }
            fail(token, "unsized based literals are unsupported in Phase 0");
        }
        std::size_t base_index = quote + 1;
        if (base_index < token.text.size() &&
            (token.text[base_index] == 's' || token.text[base_index] == 'S')) {
            ++base_index;
        }
        if (base_index >= token.text.size()) {
            fail(token, "malformed based literal");
        }
        const char base = static_cast<char>(std::tolower(
            static_cast<unsigned char>(token.text[base_index])));
        const auto digits = token.text.substr(base_index + 1);
        if (digits.empty()) {
            fail(token, "based literal has no digits");
        }
        for (const char raw : digits) {
            if (raw == '_') continue;
            const char digit = static_cast<char>(std::tolower(
                static_cast<unsigned char>(raw)));
            if ((digit == 'z' || digit == '?') && allow_casez_wildcards) {
                continue;
            }
            if (digit == 'x' || digit == 'z' || digit == '?') {
                if (profile_ == SyntaxProfile::FourStateDevelopment && (base == 'b' || base == 'o' || base == 'h')) continue;
                fail(token, "X/Z data and wildcard digits are allowed only as static casez patterns",
                     InputDiagnosticKind::Unsupported);
            }
            bool valid = false;
            if (base == 'b') valid = digit == '0' || digit == '1';
            if (base == 'o') valid = digit >= '0' && digit <= '7';
            if (base == 'd') valid = digit >= '0' && digit <= '9';
            if (base == 'h') valid = (digit >= '0' && digit <= '9') ||
                                      (digit >= 'a' && digit <= 'f');
            if (!valid) {
                fail(token, "digit is invalid for the literal base");
            }
        }
    }

    std::vector<Token> tokens_;
    SyntaxProfile profile_;
    std::vector<ParsedModule> modules_;
    std::vector<BindSyntax> binds_;
    std::vector<PropertyDeclarationSyntax> standalone_declarations_;
    std::vector<PropertyCheckSyntax> standalone_checks_;
    std::map<std::size_t, std::pair<std::size_t, std::string>> hierarchical_operands_;
    std::size_t index_ = 0;
    bool in_sva_ = false;
    bool casez_pattern_ = false;
    bool current_module_active_ = false;
    bool has_parameter_port_list_ = false;
    std::size_t generate_depth_ = 0;
    ParsedModule current_module_;
};

} // namespace

ParseError::ParseError(SourceLocation location, const std::string& message, InputDiagnosticKind kind)
    : std::runtime_error(location.file + ":" + std::to_string(location.line) +
                         ":" + std::to_string(location.column) + ": " +
                         message),
      location_(std::move(location)), kind_(kind) {}

SyntaxUnit parse_source(std::vector<Token> tokens, bool allow_empty, SyntaxProfile profile) {
    return Parser(std::move(tokens), profile).run(allow_empty);
}

} // namespace q3a::frontend
