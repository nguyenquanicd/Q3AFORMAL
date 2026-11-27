#pragma once

#include "word.hpp"
#include "../lowering/lowering.hpp"

#include <map>

namespace q3a::four_state {

using Frame = std::map<std::string, Word>;

void require_combinational_project(const std::vector<frontend::SyntaxUnit>& units,
                                   std::string_view top, bool sampled = false, bool assertions = false);
Word decode_literal(const lowering::TypedExpression& expression);
std::vector<const lowering::TIREquation*> schedule_combinational(const lowering::TIRModule& model);
Frame initialized_state(const lowering::TIRModule& model);
Frame evaluate_sample(const lowering::TIRModule& model,
                      const std::vector<const lowering::TIREquation*>& ordered,
                      Frame inputs, const Frame& state);
bool predicate_true(const lowering::TypedExpression& predicate, const Frame& frame);
Frame advance_state(const lowering::TIRModule& model, const Frame& sample);
Frame evaluate_combinational(const lowering::TIRModule& model, Frame inputs);

} // namespace q3a::four_state
