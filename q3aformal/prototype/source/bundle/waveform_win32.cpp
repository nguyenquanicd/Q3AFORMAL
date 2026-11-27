
#include "waveform_win32.hpp"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace q3a::debug {
namespace {

constexpr int label_width = 120;
constexpr int axis_height = 28;
constexpr int minimum_lane_height = 16;
constexpr int maximum_lane_height = 34;

int lane_height_for_plot(const RECT& bounds, std::size_t lanes) {
    const auto available = bounds.bottom - bounds.top - axis_height;
    const auto count = static_cast<int>(std::max<std::size_t>(1, std::min<std::size_t>(lanes, 16)));
    return std::clamp(static_cast<int>(available) / count, minimum_lane_height, maximum_lane_height);
}
constexpr COLORREF waveform_color = RGB(26, 85, 130);
constexpr COLORREF witness_color = RGB(172, 65, 39);
constexpr COLORREF cursor_color = RGB(91, 50, 148);

int plot_left(const RECT& bounds) { return bounds.left + label_width; }

void check_range(const RECT& bounds, const WaveViewport& view) {
    if (bounds.right <= plot_left(bounds) || bounds.bottom <= bounds.top + axis_height ||
        view.first > view.last) {
        throw std::invalid_argument("invalid waveform viewport");
    }
}

int sample_position(const RECT& bounds, const WaveViewport& view, std::uint64_t frame) {
    const auto plot_width = bounds.right - plot_left(bounds);
    const auto sample_count = static_cast<double>(view.last - view.first) + 1.0;
    return plot_left(bounds) +
        static_cast<int>(std::ceil(static_cast<double>(frame - view.first) * plot_width / sample_count));
}

void line(HDC dc, int x0, int y0, int x1, int y1) {
    MoveToEx(dc, x0, y0, nullptr);
    LineTo(dc, x1, y1);
}

std::wstring format_value(std::uint64_t value, unsigned width, unsigned radix) {
    if (radix == 10) return std::to_wstring(value);
    if (radix == 2) {
        std::wstring binary(width, L'0');
        for (unsigned i = 0; i < width; ++i) if ((value >> i) & 1) binary[width - 1 - i] = L'1';
        return L"0b" + binary;
    }
    std::wostringstream text;
    text << L"0x" << std::hex << value;
    return text.str();
}

void draw_text(HDC dc, const std::wstring& text, RECT box) {
    DrawTextW(dc, text.c_str(), -1, &box, DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX | DT_VCENTER);
}

void validate_signal(const WaveSignal& signal, const WaveViewport& view) {
    if (signal.width == 0 || signal.width > 64 || signal.changes.empty() ||
        signal.changes.front().frame != view.first) {
        throw std::invalid_argument("waveform lane lacks its checkpoint sample or width");
    }
    auto previous = view.first;
    for (std::size_t i = 0; i < signal.changes.size(); ++i) {
        const auto& change = signal.changes[i];
        if ((i != 0 && change.frame <= previous) || change.frame > view.last ||
            (signal.width < 64 && change.value >> signal.width)) {
            throw std::invalid_argument("invalid waveform lane change");
        }
        previous = change.frame;
    }
}

} // namespace

std::size_t visible_wave_lanes(const RECT& bounds, const WaveViewport& view) {
    check_range(bounds, view);
    const auto available = bounds.bottom - bounds.top - axis_height;
    const auto height = lane_height_for_plot(bounds, view.signals.size());
    return std::min(view.signals.size(), static_cast<std::size_t>(available / height));
}

std::uint64_t sample_at_pixel(const RECT& bounds, const WaveViewport& view, int x) {
    check_range(bounds, view);
    const auto left = plot_left(bounds);
    if (x <= left) return view.first;
    if (x >= bounds.right) return view.last;
    const auto offset = x - left;
    const auto span = view.last - view.first;
    const auto selection = static_cast<double>(offset) * (static_cast<double>(span) + 1.0) /
        (bounds.right - left);
    return selection >= static_cast<double>(span) ? view.last :
        view.first + static_cast<std::uint64_t>(selection);
}

void append_asserted_reset_ranges(WaveViewport& view, const WaveSignal& reset, bool active_high) {
    if (reset.width != 1) throw std::invalid_argument("a reset lane must be one bit");
    validate_signal(reset, view);
    const auto active = static_cast<std::uint64_t>(active_high);
    for (std::size_t i = 0; i < reset.changes.size(); ++i) {
        const auto& change = reset.changes[i];
        if (change.value != active) continue;
        const auto end = i + 1 < reset.changes.size() ? reset.changes[i + 1].frame - 1 : view.last;
        view.asserted_resets.push_back({change.frame, end});
    }
}

void paint_waveform(HDC context, const RECT& bounds, const WaveViewport& view) {
    check_range(bounds, view);
    if (!context) throw std::invalid_argument("waveform drawing context is missing");
    for (const auto& signal : view.signals) validate_signal(signal, view);
    const auto saved = SaveDC(context);
    if (!saved) throw std::runtime_error("cannot save waveform drawing context");
    struct RestoreContext {
        HDC context;
        int state;
        ~RestoreContext() { RestoreDC(context, state); }
    } restore{context, saved};

    IntersectClipRect(context, bounds.left, bounds.top, bounds.right, bounds.bottom);
    FillRect(context, &bounds, static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH)));
    SelectObject(context, GetStockObject(DC_PEN));
    SelectObject(context, GetStockObject(DEFAULT_GUI_FONT));
    SetBkMode(context, TRANSPARENT);
    SetTextColor(context, RGB(26, 36, 48));

    const auto first_label = std::to_wstring(view.first);
    const auto last_label = std::to_wstring(view.last);
    SIZE last_size{};
    GetTextExtentPoint32W(context, last_label.c_str(), static_cast<int>(last_label.size()), &last_size);
    const auto plot = plot_left(bounds);
    const auto top = bounds.top + axis_height;
    draw_text(context, L"Sample", {bounds.left + 8, bounds.top, plot - 6, top});
    draw_text(context, first_label, {plot + 3, bounds.top, bounds.right - 6, top});
    draw_text(context, last_label, {bounds.right - last_size.cx - 5, bounds.top, bounds.right, top});

    if (!view.asserted_resets.empty()) {
        const auto brush = static_cast<HBRUSH>(GetStockObject(DC_BRUSH));
        SetDCBrushColor(context, RGB(255, 242, 222));
        for (const auto& range : view.asserted_resets) {
            if (range.first > range.last || range.first < view.first || range.last > view.last)
                throw std::invalid_argument("reset annotation exceeds its waveform viewport");
            const RECT band{sample_position(bounds, view, range.first), top,
                            range.last == view.last ? bounds.right : sample_position(bounds, view, range.last + 1),
                            bounds.bottom};
            FillRect(context, &band, brush);
        }
    }

    SetDCPenColor(context, RGB(215, 222, 230));
    line(context, plot, top, plot, bounds.bottom);
    line(context, bounds.left, top - 1, bounds.right, top - 1);
    const auto lane_height = lane_height_for_plot(bounds, view.signals.size());
    const auto high_offset = lane_height / 5;
    const auto low_offset = lane_height - high_offset - 2;
    int row = top;
    for (const auto& signal : view.signals) {
        if (row + lane_height > bounds.bottom) break;
        auto selected = signal.changes.front().value;
        for (std::size_t i = 0; i < signal.changes.size(); ++i) {
            const auto& change = signal.changes[i];
            if (change.frame <= view.cursor) selected = change.value;
            const auto x0 = sample_position(bounds, view, change.frame);
            const bool has_next = i + 1 < signal.changes.size();
            const auto x1 = has_next ? sample_position(bounds, view, signal.changes[i + 1].frame)
                                     : bounds.right;
            SetDCPenColor(context, waveform_color);
            if (signal.width == 1) {
                const auto level = [row, high_offset, low_offset](std::uint64_t value) { return row + (value ? high_offset : low_offset); };
                const auto y = level(change.value);
                line(context, x0, y, x1, y);
                if (has_next) line(context, x1, y, x1, level(signal.changes[i + 1].value));
            } else {
                line(context, x0, row + high_offset, x1, row + high_offset);
                line(context, x0, row + low_offset, x1, row + low_offset);
                if (x1 > x0) line(context, x0, row + high_offset, x0, row + low_offset);
                if (x1 - x0 >= 48)
                    draw_text(context, format_value(change.value, signal.width, view.radix), {x0 + 4, row + high_offset, x1, row + low_offset});
            }
        }
        draw_text(context, signal.name + L"  " + (view.cursor >= view.first && view.cursor <= view.last ? format_value(selected, signal.width, view.radix) : L"-"),
                  {bounds.left + 8, row, plot - 6, row + lane_height});
        SetDCPenColor(context, RGB(215, 222, 230));
        line(context, bounds.left, row + lane_height - 1, bounds.right, row + lane_height - 1);
        row += lane_height;
    }
    for (const auto marker : view.markers) {
        if (marker < view.first || marker > view.last) continue;
        const auto x = sample_position(bounds, view, marker);
        SetDCPenColor(context, RGB(19, 107, 70));
        line(context, x, top, x, bounds.bottom);
    }
    if (view.witness && *view.witness >= view.first && *view.witness <= view.last) {
        const auto x = sample_position(bounds, view, *view.witness);
        SetDCPenColor(context, witness_color);
        line(context, x, top, x, bounds.bottom);
    }
    if (view.cursor >= view.first && view.cursor <= view.last) {
        const auto x = sample_position(bounds, view, view.cursor);
        SetDCPenColor(context, cursor_color);
        line(context, x, top, x, bounds.bottom);
    }
}

} // namespace q3a::debug

