#pragma once

#include "../lowering/lowering.hpp"

#include <iosfwd>
#include <map>

namespace q3a::trace {

inline constexpr char kCaptureRole[] = "waveform_capture";

struct CaptureRequest {
    bool all = false;
    std::vector<std::string> extra;
};

using CaptureSignals = std::vector<const lowering::TIRSignal*>;

struct PropertySignals {
    std::vector<std::string> rtl;
    std::vector<std::string> model;
};

class PropertySignalIndex {
public:
    explicit PropertySignalIndex(const lowering::TIRModule& model);
    PropertySignals for_property(const lowering::TIRProperty& property) const;

private:
    // Generated history is traversed without expanding ordinary design drivers.
    std::map<std::string, const lowering::TypedExpression*> history_;
};

void write_property_signals(std::ostream& output, const PropertySignals& signals);

CaptureSignals select_capture_signals(const lowering::TIRModule& model,
                                      const lowering::TIRProperty& property,
                                      const CaptureRequest& request);

void write_capture_manifest(std::ostream& output, const std::string& property,
                            const CaptureRequest& request, const CaptureSignals& signals);

} // namespace q3a::trace
