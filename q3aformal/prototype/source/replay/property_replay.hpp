#pragma once

#include "../lowering/lowering.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace q3a::replay {

using Frame = std::map<std::string, std::uint64_t>;

// Evaluate a typed combinational value in an already decoded frame.
std::uint64_t evaluate_word(const lowering::TypedExpression& expression, const Frame& frame);

class FrameView {
public:
    using ReadFrame = std::function<const Frame&(std::size_t)>;

    FrameView(const std::vector<Frame>& frames)
        : FrameView(frames.size(), [&frames](std::size_t index) -> const Frame& {
            return frames.at(index);
        }) {}

    FrameView(std::size_t size, ReadFrame read) : size_(size), read_(std::move(read)) {}
    std::size_t size() const { return size_; }
    bool empty() const { return size_ == 0; }
    const Frame& front() const { return read_(0); }
    // The returned reference is valid until the next lookup of another frame.
    const Frame& operator[](std::size_t index) const { return read_(index); }

private:
    std::size_t size_;
    ReadFrame read_;
};

struct Result {
    bool validated = false;
    std::string message;
    bool boundary_incomplete = false;
};

struct ActivationReplay {
    Result result;
    std::optional<std::size_t> frame;
};

ActivationReplay validate_bounded_activation(const lowering::TIRModule& module, const FrameView& trace,
                                              const std::string& property_name);

enum class InductionObligation { Base, Step };

struct InductionReplayResult {
    bool validated = false;
    std::size_t failure_frame = static_cast<std::size_t>(-1);
    std::string message;
};

// Independently evaluates a decoded SAT trace against the supported T-IR
// equations, assumptions, and the selected bounded assertion semantics.
Result validate_bounded_counterexample(
    const lowering::TIRModule& module,
    const std::vector<Frame>& trace,
    const std::string& property_name,
    std::size_t candidate_frame);

Result validate_bounded_cover(
    const lowering::TIRModule& module,
    const std::vector<Frame>& trace,
    const std::string& property_name,
    std::size_t candidate_frame);

Result validate_bounded_counterexample_view(
    const lowering::TIRModule& module, const FrameView& trace,
    const std::string& property_name, std::size_t candidate_frame);

Result validate_bounded_cover_view(
    const lowering::TIRModule& module, const FrameView& trace,
    const std::string& property_name, std::size_t candidate_frame);

// Independently replays a SAT model for a supported k-induction base or step
// obligation (scalar/same-sample predicates and restricted overlapped or
// non-overlapped assertions).
// Base traces must start from initialized history-valid state; step traces
// leave that state unconstrained, as required by induction.
InductionReplayResult validate_induction_countermodel(
    const lowering::TIRModule& module,
    const std::vector<Frame>& trace,
    const std::string& property_name,
    std::size_t depth,
    InductionObligation obligation);

InductionReplayResult validate_induction_countermodel_view(
    const lowering::TIRModule& module, const FrameView& trace,
    const std::string& property_name, std::size_t depth, InductionObligation obligation);

} // namespace q3a::replay
