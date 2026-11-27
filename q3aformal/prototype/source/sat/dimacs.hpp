#pragma once

#include "sat_solver.hpp"

#include <istream>
#include <stdexcept>

namespace q3a::sat {

class DimacsError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

Solver read_dimacs(std::istream& input);

} // namespace q3a::sat
