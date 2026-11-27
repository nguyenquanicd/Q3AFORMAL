#include "word.hpp"

#include <iostream>
#include <stdexcept>
#include <string>

using namespace q3a::four_state;

namespace {

void check(bool condition, const char* operation) {
    if (!condition) throw std::runtime_error(operation);
}

std::string digits(unsigned code) {
    std::string text(4, '0');
    for (auto i = text.rbegin(); i != text.rend(); ++i, code /= 4) *i = "01xz"[code % 4];
    return text;
}

unsigned index(char digit) { return static_cast<unsigned>(std::string_view("01xz").find(digit)); }

Logic as_logic(char digit) { return static_cast<Logic>(index(digit)); }

char scalar_truth(std::string_view bits) {
    if (bits.find('1') != bits.npos) return '1';
    return bits.find_first_of("xz") != bits.npos ? 'x' : '0';
}

void exhaustive() {
    constexpr const char* and_table[] = {"0000", "01xx", "0xxx", "0xxx"};
    constexpr const char* or_table[] = {"01xx", "1111", "x1xx", "x1xx"};
    constexpr const char* xor_table[] = {"01xx", "10xx", "xxxx", "xxxx"};
    std::size_t comparisons = 0;
    for (unsigned lhs = 0; lhs < 256; ++lhs) {
        const auto left = digits(lhs);
        const auto a = Word::parse(left);
        const char la = scalar_truth(left);
        check(a.bits() == left, "packed round trip");
        check(truth(a) == as_logic(la) && reduce_or(a) == as_logic(la), "word truth");
        check(logical_not(a) == as_logic("10xx"[index(la)]), "logical negation");
        check(reduce_and(a) == as_logic(left.find('0') != left.npos ? '0' :
            left.find_first_of("xz") != left.npos ? 'x' : '1'), "reduction and");
        unsigned parity = 0;
        std::string complement;
        for (char bit : left) {
            parity ^= bit == '1';
            complement += "10xx"[index(bit)];
        }
        check(bit_not(a).bits() == complement, "bitwise complement");
        check(reduce_xor(a) == as_logic(left.find_first_of("xz") == left.npos ? "01"[parity] : 'x'),
              "reduction xor");
        for (unsigned rhs = 0; rhs < 256; ++rhs) {
            const auto right = digits(rhs);
            const auto b = Word::parse(right);
            const char lb = scalar_truth(right);
            std::string expected_and, expected_or, expected_xor, merged;
            bool definite_mismatch = false;
            bool unknown = false;
            bool casez = true;
            bool casex = true;
            for (unsigned bit = 0; bit < left.size(); ++bit) {
                const auto l = left[bit];
                const auto r = right[bit];
                const auto li = index(l);
                const auto ri = index(r);
                expected_and += and_table[li][ri];
                expected_or += or_table[li][ri];
                expected_xor += xor_table[li][ri];
                merged += l == r && li < 2 ? l : 'x';
                definite_mismatch |= li < 2 && ri < 2 && l != r;
                unknown |= li >= 2 || ri >= 2;
                casez &= l == r || l == 'z' || r == 'z';
                casex &= l == r || li >= 2 || ri >= 2;
            }
            check(bit_and(a, b).bits() == expected_and, "bitwise and");
            check(bit_or(a, b).bits() == expected_or, "bitwise or");
            check(bit_xor(a, b).bits() == expected_xor, "bitwise xor");
            check(logical_and(a, b) == as_logic(and_table[index(la)][index(lb)]), "logical and");
            check(logical_or(a, b) == as_logic(or_table[index(la)][index(lb)]), "logical or");
            check(equal(a, b) == as_logic(definite_mismatch ? '0' : unknown ? 'x' : '1'), "logical equality");
            check(case_match(a, b) == (left == right), "case equality");
            check(case_match(a, b, CaseMode::ZWildcard) == casez, "casez");
            check(case_match(a, b, CaseMode::XZWildcard) == casex, "casex");
            for (const auto selector : {"00", "1x", "0x", "0z"}) {
                const auto state = scalar_truth(selector);
                check(conditional(Word::parse(selector), a, b).bits() ==
                    (state == '1' ? left : state == '0' ? right : merged), "conditional");
            }
            ++comparisons;
        }
    }
    check(comparisons == 65536, "exhaustive case count");
    std::cout << "operand_pairs=" << comparisons << "\nconditional_cases=" << 4 * comparisons << '\n';
}

template <typename Call>
void rejects(Call call) {
    try {
        call();
    } catch (const std::invalid_argument&) {
        return;
    }
    throw std::runtime_error("expected invalid four-state operation");
}

void boundaries() {
    const auto x = Word::parse("X");
    const auto z = Word::parse("Z");
    const auto wide = z.resized(64, true);
    check(wide.bits() == std::string(64, 'z'), "64-bit Z sign extension");
    check(x.resized(64, true).bits() == std::string(64, 'x'), "64-bit X sign extension");
    check(z.resized(64, false).bits() == std::string(63, '0') + "z", "64-bit zero extension");
    check(wide.resized(1, false).bits() == "z" && wide.slice(63, 1).bits() == "z", "64-bit mask boundary");
    check(concatenate(x.resized(63, true), z).bits() == std::string(63, 'x') + "z", "64-bit concatenation");
    check(conditional(x, wide, wide).bits() == std::string(64, 'x'), "ambiguous mux must not preserve Z");
    check(conditional(Word::parse("1"), wide, wide).bits() == std::string(64, 'z'), "known mux preserves Z");
    check(equal(Word::parse("x1"), Word::parse("x0")) == Logic::Zero, "definite mismatch controls equality");
    rejects([] { Word::parse(""); });
    rejects([] { Word::parse("00?"); });
    rejects([&] { z.resized(65, false); });
    rejects([&] { wide.slice(64, 1); });
    rejects([&] { concatenate(wide, z); });
    rejects([&] { bit_and(wide, z); });
    std::cout << "boundary_and_rejection_checks=14\n";
}

} // namespace

int main() {
    try {
        exhaustive();
        boundaries();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
