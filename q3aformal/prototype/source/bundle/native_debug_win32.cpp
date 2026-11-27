
#include "native_debug_win32.hpp"
#include "verify_bundle.hpp"
#include "debug_session_state.hpp"
#include "windows_file_path.hpp"
#include <commdlg.h>
#include <system_error>

#include <algorithm>
#include <iomanip>
#include <ostream>
#include <sstream>
#include <type_traits>
#include <limits>
#include <cwctype>
#include <commctrl.h>
#include <stdexcept>
#include <utility>
#include <windowsx.h>

namespace q3a::debug {
namespace {

constexpr wchar_t window_class[] = L"Q3AFormalNativeDebug";
enum Button : int { Previous = 101, Next, Witness, ZoomIn, ZoomOut, SignalList, OpenSession, SaveSession, ShowSignal, PreviousChange, NextChange, Radix, ToggleMarker, GoToMarker, SignalSearch, GroupName, SaveGroup, UseGroup };

std::wstring widen(const std::string& text) {
    if (text.empty()) return {};
    const auto count = static_cast<int>(text.size());
    if (text.size() > static_cast<std::size_t>(std::numeric_limits<int>::max()))
        throw std::runtime_error("debug text is too large");
    const auto size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), count, nullptr, 0);
    if (size <= 0) throw std::runtime_error("invalid UTF-8 debug text");
    std::wstring result(static_cast<std::size_t>(size), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), count, result.data(), size) != size)
        throw std::runtime_error("cannot decode debug text");
    return result;
}


std::string read_session_file(const std::filesystem::path& path) {
    const auto target = bundle::detail::windows_file_path(std::filesystem::absolute(path));
    const auto opened = CreateFileW(target.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (opened == INVALID_HANDLE_VALUE)
        throw std::system_error(static_cast<int>(GetLastError()), std::system_category(), "cannot open the saved debug session");
    const std::unique_ptr<void, decltype(&CloseHandle)> handle(opened, &CloseHandle);
    LARGE_INTEGER bytes{};
    if (!GetFileSizeEx(handle.get(), &bytes) || bytes.QuadPart < 0 || bytes.QuadPart > 4 * 1024 * 1024)
        throw std::runtime_error("invalid debug session file size");
    std::string data(static_cast<std::size_t>(bytes.QuadPart), '\0');
    DWORD count{};
    if (!data.empty() && (!ReadFile(handle.get(), data.data(), static_cast<DWORD>(data.size()), &count, nullptr) ||
                          count != data.size())) {
        throw std::runtime_error("cannot read the saved debug session");
    }
    return data;
}

void write_session_file(const std::filesystem::path& path, const bundle::VerifiedDebugSession& session,
                        const bundle::DebugSessionState& state) {
    const auto data = bundle::encode_debug_session(session, state);
    const auto target = bundle::detail::windows_file_path(std::filesystem::absolute(path));
    const bool replacing = std::filesystem::exists(target);
    if (replacing) (void)bundle::decode_debug_session(session, read_session_file(path));
    auto stage = target;
    stage += L".q3a-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
    const auto handle = CreateFileW(stage.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) throw std::runtime_error("cannot create the staged debug session");
    const auto size = static_cast<DWORD>(data.size());
    DWORD written{};
    const bool complete = WriteFile(handle, data.data(), size, &written, nullptr) && written == size &&
        FlushFileBuffers(handle);
    const bool closed = CloseHandle(handle) != 0;
    const auto flags = MOVEFILE_WRITE_THROUGH | (replacing ? MOVEFILE_REPLACE_EXISTING : 0);
    if (!complete || !closed || !MoveFileExW(stage.c_str(), target.c_str(), flags)) {
        DeleteFileW(stage.c_str());
        throw std::runtime_error("cannot publish the saved debug session");
    }
}

std::optional<std::filesystem::path> session_path(HWND owner, bool save) {
    std::wstring path(32768, L'\0');
    OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = owner;
    dialog.lpstrFilter = L"Q3A debug session (*.json)\0*.json\0\0";
    dialog.lpstrFile = path.data();
    dialog.nMaxFile = static_cast<DWORD>(path.size());
    dialog.Flags = OFN_EXPLORER | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR |
        (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    if (!(save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog))) {
        if (CommDlgExtendedError()) throw std::runtime_error("Windows could not select the debug session file");
        return std::nullopt;
    }
    return std::filesystem::path(path.c_str());
}


std::wstring control_text(HWND control) {
    const auto len = GetWindowTextLengthW(control);
    std::wstring result(static_cast<std::size_t>(len) + 1, L'\0');
    const auto copied = GetWindowTextW(control, result.data(), len + 1);
    result.resize(static_cast<std::size_t>(copied));
    return result;
}

std::string narrow(const std::wstring& text) {
    if (text.empty()) return {};
    const auto count = static_cast<int>(text.size());
    const auto size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), count, nullptr, 0, nullptr, nullptr);
    if (size <= 0) throw std::runtime_error("invalid Unicode group name");
    std::string result(static_cast<std::size_t>(size), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), count, result.data(), size, nullptr, nullptr) != size)
        throw std::runtime_error("cannot encode group name");
    return result;
}

struct Window {
    explicit Window(const bundle::VerifiedDebugSession& input, std::uint64_t initial_span = 32)
        : session(input), selected(input.view.selected), span(initial_span) {
        if (session.frame_count == 0 || selected.empty()) throw std::invalid_argument("no validated waveform");
        retained.groups = session.view.groups;
        jump_to_witness();
    }

    const bundle::VerifiedDebugSession& session;
    std::vector<std::string> selected;
    WaveViewport viewport{};
    bundle::DebugSessionState retained;
    frontend::SourceLocation active_source;
    std::filesystem::path test_path;
    std::uint64_t span = 32;
    RECT plot{};
    HWND run{};
    HWND signals{};
    HWND search{};
    HWND group_name{};
    HWND save_group{};
    HWND use_group{};
    std::vector<std::size_t> signal_rows;
    HWND source{};
    HWND location{};
    std::vector<HWND> buttons;
    std::wstring failure;
    bool closed = false;

    struct WindowCacheEntry {
        std::vector<std::string> selection;
        WaveViewport view;
    };
    std::vector<WindowCacheEntry> window_cache;
    std::size_t uncached_windows = 0;
    std::size_t completed_paints = 0;

    WaveViewport window_for(std::uint64_t first, std::uint64_t last, std::uint64_t cursor,
                            const std::vector<std::string>& selection) {
        const auto existing = std::find_if(window_cache.begin(), window_cache.end(), [&](const auto& entry) {
            return entry.view.first == first && entry.view.last == last && entry.selection == selection;
        });
        if (existing != window_cache.end()) {
            std::rotate(existing, existing + 1, window_cache.end());
            auto wave = window_cache.back().view;
            wave.cursor = cursor;
            return wave;
        }
        auto wave = read_verified_viewport(session, first, last, cursor, selection);
        constexpr std::size_t max_cache_entries = 4;
        if (window_cache.size() == max_cache_entries) window_cache.erase(window_cache.begin());
        window_cache.push_back({selection, wave});
        ++uncached_windows;
        return wave;
    }

    void read(std::uint64_t first, std::uint64_t cursor) {
        auto count = std::min(span, session.frame_count);
        first = std::min(first, session.frame_count - count);
        const auto last = first + count - 1;
        viewport = window_for(first, last, cursor, selected);
        viewport.radix = retained.radix == "Binary" ? 2 : retained.radix == "Unsigned" ? 10 : 16;
        viewport.markers = retained.markers;
        if (session.describe_cursor) update_run_panel();
    }

    void jump_to_witness() {
        const auto frame = session.candidate_frame;
        read(frame > span / 2 ? frame - span / 2 : 0, frame);
    }

    void show_source(const frontend::SourceLocation& at) {
        active_source = at;
        auto title = widen(at.file) + L":" + std::to_wstring(at.line);
        SetWindowTextW(location, title.c_str());
        const auto found = session.view.sources.find(at.file);
        if (found == session.view.sources.end()) {
            SetWindowTextW(source, L"Source text unavailable in this bundle.");
            return;
        }
        auto text = widen(found->second);
        for (std::size_t i = 0; i < text.size(); ++i) {
            if (text[i] == L'\n' && (i == 0 || text[i - 1] != L'\r')) {
                text.insert(i, 1, L'\r');
                ++i;
            }
        }
        SetWindowTextW(source, text.c_str());
        if (at.line == 0 || at.line > static_cast<std::size_t>(std::numeric_limits<int>::max())) return;
        const auto start = SendMessageW(source, EM_LINEINDEX, at.line - 1, 0);
        if (start < 0) return;
        const auto length = SendMessageW(source, EM_LINELENGTH, start, 0);
        SendMessageW(source, EM_SETSEL, start, start + length);
        const auto first = SendMessageW(source, EM_GETFIRSTVISIBLELINE, 0, 0);
        const auto target = at.line > 2 ? static_cast<LONG>(at.line - 2) : 0;
        SendMessageW(source, EM_LINESCROLL, 0, target - first);
        SendMessageW(source, EM_SCROLLCARET, 0, 0);
    }

    static HWND widget(HWND host, const wchar_t* type, DWORD flags,
                       const wchar_t* name = L"", int id = 0) {
        auto control = CreateWindowExW(0, type, name, WS_CHILD | WS_VISIBLE | flags,
            0, 0, 1, 1, host, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (!control) throw std::runtime_error("cannot create debug control");
        SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), FALSE);
        return control;
    }

    void update_signal_list() {
        auto search_for = control_text(search);
        const auto lower = [](wchar_t ch) { return static_cast<wchar_t>(std::towlower(ch)); };
        std::transform(search_for.begin(), search_for.end(), search_for.begin(), lower);
        SendMessageW(signals, LB_RESETCONTENT, 0, 0);
        signal_rows.clear();
        for (std::size_t index = 0; index < session.view.signals.size(); ++index) {
            const auto name = widen(session.view.signals[index].name);
            auto folded = name;
            std::transform(folded.begin(), folded.end(), folded.begin(), lower);
            if (folded.find(search_for) == std::wstring::npos) continue;
            const auto row = SendMessageW(signals, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str()));
            if (row < 0) throw std::runtime_error("cannot list a trace signal");
            signal_rows.push_back(index);
        }
    }

    void update_group_list() {
        SendMessageW(group_name, CB_RESETCONTENT, 0, 0);
        for (const auto& item : retained.groups) {
            const auto label = widen(item.first);
            SendMessageW(group_name, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
        }
        SetWindowTextW(group_name, widen(retained.group).c_str());
    }

    void create(HWND host) {
        run = widget(host, L"EDIT", WS_BORDER | ES_MULTILINE | ES_READONLY | WS_VSCROLL);
        signals = widget(host, L"LISTBOX", WS_BORDER | WS_VSCROLL | LBS_NOTIFY |
            LBS_NOINTEGRALHEIGHT | WS_TABSTOP, L"", SignalList);
        search = widget(host, L"EDIT", WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL, L"", SignalSearch);
        group_name = widget(host, L"COMBOBOX", CBS_DROPDOWN | WS_VSCROLL | WS_TABSTOP, L"", GroupName);
        SendMessageW(search, EM_SETCUEBANNER, FALSE, reinterpret_cast<LPARAM>(L"Search signals"));
        SendMessageW(group_name, CB_SETCUEBANNER, 0, reinterpret_cast<LPARAM>(L"Signal group name"));
        save_group = widget(host, L"BUTTON", BS_PUSHBUTTON | WS_TABSTOP, L"Save group", SaveGroup);
        use_group = widget(host, L"BUTTON", BS_PUSHBUTTON | WS_TABSTOP, L"Use group", UseGroup);
        location = widget(host, L"STATIC", SS_LEFTNOWORDWRAP);
        source = widget(host, L"EDIT", WS_BORDER | ES_MULTILINE | ES_READONLY | WS_VSCROLL |
            WS_HSCROLL | ES_AUTOHSCROLL | ES_NOHIDESEL | WS_TABSTOP);
        SendMessageW(source, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(ANSI_FIXED_FONT)), FALSE);
        const int actions[]{Previous, Next, Witness, ZoomIn, ZoomOut, OpenSession, SaveSession, ShowSignal, PreviousChange, NextChange, Radix, ToggleMarker, GoToMarker};
        const wchar_t* labels[]{L"Previous", L"Next", L"Witness", L"Zoom in", L"Zoom out", L"Open", L"Save", L"Show signal", L"Prev change", L"Next change", L"Radix", L"Mark/clear", L"Next marker"};
        for (std::size_t i = 0; i < sizeof(actions) / sizeof(actions[0]); ++i)
            buttons.push_back(widget(host, L"BUTTON", BS_PUSHBUTTON | WS_TABSTOP, labels[i], actions[i]));

        update_run_panel();
        update_signal_list();
        update_group_list();
    }

    void update_run_panel() {
        if (!run) return;
        std::wstring details;
        if (session.describe_cursor) details = widen(session.describe_cursor(viewport.cursor)) + L"\r\n\r\n";
        for (const auto& [label, value] : session.view.run) details += widen(label + "  " + value) + L"\r\n";
        if (!session.view.assumptions.empty()) details += L"\r\nAssumptions\r\n";
        for (const auto& assumption : session.view.assumptions) details += widen(assumption) + L"\r\n";
        SetWindowTextW(run, details.c_str());
    }

    void layout(int width, int height) {
        if (!source || width < 640 || height < 380) return;
        const int right = width - 10;
        const int vertical_split = height * 2 / 3;
        MoveWindow(run, 10, 10, 242, vertical_split - 15, TRUE);
        MoveWindow(search, 10, vertical_split, 242, 24, TRUE);
        MoveWindow(signals, 10, vertical_split + 28, 242, height - vertical_split - 102, TRUE);
        MoveWindow(group_name, 10, height - 68, 242, 120, TRUE);
        MoveWindow(save_group, 10, height - 34, 117, 24, TRUE);
        MoveWindow(use_group, 134, height - 34, 118, 24, TRUE);
        for (std::size_t i = 0; i < buttons.size(); ++i)
            MoveWindow(buttons[i], 263 + static_cast<int>(i % 4) * 86, 10 + static_cast<int>(i / 4) * 27, 82, 25, TRUE);
        plot = {263, 119, right, vertical_split - 5};
        MoveWindow(location, 263, vertical_split, right - 263, 22, TRUE);
        MoveWindow(source, 263, vertical_split + 22, right - 263, height - vertical_split - 32, TRUE);
    }


    bundle::DebugSessionState snapshot() const {
        auto state = retained;
        state.frame = viewport.cursor;
        state.first = viewport.first;
        state.span = static_cast<unsigned>(span);
        state.signals = selected;
        state.source = active_source;
        return state;
    }

    void load_session(const std::filesystem::path& path) {
        auto state = bundle::decode_debug_session(session, read_session_file(path));
        const auto count = std::min<std::uint64_t>(state.span, session.frame_count);
        const auto centered = state.frame > count / 2 ? state.frame - count / 2 : 0;
        const auto first = state.first.value_or(std::min(centered, session.frame_count - count));
        auto next = window_for(first, first + count - 1, state.frame, state.signals);
        next.radix = state.radix == "Binary" ? 2 : state.radix == "Unsigned" ? 10 : 16;
        next.markers = state.markers;
        selected = state.signals;
        span = state.span;
        viewport = std::move(next);
        if (session.describe_cursor) update_run_panel();
        show_source(state.source);
        retained = std::move(state);
        update_group_list();
    }

    void show_signal_at_source() {
        const auto line = SendMessageW(source, EM_LINEFROMCHAR, static_cast<WPARAM>(-1), 0);
        if (line < 0) return;
        const auto& signals_by_source = session.view.signals;
        const auto found = std::find_if(signals_by_source.begin(), signals_by_source.end(), [&](const auto& signal) {
            return signal.location.file == active_source.file &&
                signal.location.line == static_cast<std::uint64_t>(line) + 1;
        });
        if (found == signals_by_source.end()) {
            SetWindowTextW(location, L"No waveform signal is mapped to this RTL line.");
            return;
        }
        const auto index = static_cast<std::size_t>(found - signals_by_source.begin());
        auto row = std::find(signal_rows.begin(), signal_rows.end(), index);
        if (row == signal_rows.end()) {
            SetWindowTextW(search, L"");
            row = std::find(signal_rows.begin(), signal_rows.end(), index);
        }
        if (row == signal_rows.end()) return;
        SendMessageW(signals, LB_SETCURSEL, static_cast<WPARAM>(row - signal_rows.begin()), 0);
        command(nullptr, SignalList, LBN_SELCHANGE);
    }


    void command(HWND owner, int action, int notification) {
        switch (action) {
        case Previous:
            read(viewport.first > span ? viewport.first - span : 0, viewport.cursor);
            break;
        case Next:
            read(viewport.last + 1, viewport.cursor);
            break;
        case Witness:
            jump_to_witness();
            show_source(session.view.assertion);
            break;
        case ZoomIn:
        case ZoomOut:
            span = action == ZoomIn ? std::max<std::uint64_t>(16, span / 2)
                                    : std::min<std::uint64_t>(64, span * 2);
            read(viewport.cursor > span / 2 ? viewport.cursor - span / 2 : 0, viewport.cursor);
            break;
        case OpenSession:
        case SaveSession: {
            const bool save = action == SaveSession;
            const auto path = test_path.empty() ? session_path(owner, save) : std::optional{test_path};
            if (path) {
                if (save) write_session_file(*path, session, snapshot());
                else load_session(*path);
            }
            break;
        }
        case SignalSearch:
            if (notification == EN_CHANGE) update_signal_list();
            break;
        case SaveGroup: {
            const auto name = narrow(control_text(group_name));
            if (name.empty() || name.size() > 80)
                throw std::invalid_argument("enter a group name with 1 to 80 UTF-8 bytes");
            if (selected.empty()) throw std::invalid_argument("select at least one waveform signal");
            retained.groups[name] = selected;
            retained.group = name;
            update_group_list();
            break;
        }
        case UseGroup: {
            const auto name = narrow(control_text(group_name));
            const auto group = retained.groups.find(name);
            if (group == retained.groups.end()) throw std::invalid_argument("select a saved waveform group");
            selected = group->second;
            retained.group = name;
            read(viewport.first, viewport.cursor);
            break;
        }
        case ToggleMarker: {
            const auto at = std::find(retained.markers.begin(), retained.markers.end(), viewport.cursor);
            if (at != retained.markers.end()) retained.markers.erase(at);
            else if (retained.markers.size() < 128) retained.markers.push_back(viewport.cursor);
            else throw std::runtime_error("debug session has reached the marker limit");
            viewport.markers = retained.markers;
            break;
        }
        case GoToMarker: {
            if (retained.markers.empty()) {
                SetWindowTextW(location, L"No session markers.");
                break;
            }
            auto frame = *std::min_element(retained.markers.begin(), retained.markers.end());
            std::optional<std::uint64_t> next;
            for (const auto marker : retained.markers) {
                if (marker > viewport.cursor && (!next || marker < *next)) next = marker;
            }
            if (next) frame = *next;
            read(frame > span / 2 ? frame - span / 2 : 0, frame);
            break;
        }
        case Radix:
            retained.radix = retained.radix == "Hex" ? "Binary" : retained.radix == "Binary" ? "Unsigned" : "Hex";
            read(viewport.first, viewport.cursor);
            break;
        case PreviousChange:
        case NextChange: {
            if (selected.empty()) break;
            const auto control_index = SendMessageW(signals, LB_GETCURSEL, 0, 0);
            const auto& name = control_index < 0 ? selected.front() :
                session.view.signals.at(signal_rows.at(static_cast<std::size_t>(control_index))).name;
            const auto found = session.find_transition(name, viewport.cursor, action == NextChange);
            if (found) read(*found > span / 2 ? *found - span / 2 : 0, *found);
            else SetWindowTextW(location, action == NextChange ? L"No later transition." : L"No earlier transition.");
            break;
        }
        case ShowSignal:
            show_signal_at_source();
            break;
        case SignalList: {
            if (notification != LBN_SELCHANGE) break;
            const auto index = SendMessageW(signals, LB_GETCURSEL, 0, 0);
            if (index < 0 || static_cast<std::size_t>(index) >= signal_rows.size()) break;
            const auto& signal = session.view.signals[signal_rows[static_cast<std::size_t>(index)]];
            if (std::find(selected.begin(), selected.end(), signal.name) == selected.end()) {
                if (selected.size() < 16) selected.push_back(signal.name);
                else selected.back() = signal.name;
                read(viewport.first, viewport.cursor);
            }
            show_source(signal.location);
            break;
        }
        default:
            break;
        }
    }
};

LRESULT CALLBACK on_message(HWND handle, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_NCCREATE) {
        const auto data = reinterpret_cast<const CREATESTRUCTW*>(lp);
        SetWindowLongPtrW(handle, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(data->lpCreateParams));
    }
    auto* state = reinterpret_cast<Window*>(GetWindowLongPtrW(handle, GWLP_USERDATA));
    if (!state) return DefWindowProcW(handle, message, wp, lp);
    try {
        switch (message) {
        case WM_CREATE: {
            state->create(handle);
            RECT client{};
            if (!GetClientRect(handle, &client)) return -1;
            state->layout(client.right, client.bottom);
            state->show_source(state->session.view.assertion);
            return 0;
        }
        case WM_GETMINMAXINFO: {
            auto* limits = reinterpret_cast<MINMAXINFO*>(lp);
            limits->ptMinTrackSize = {660, 440};
            return 0;
        }
        case WM_SIZE:
            state->layout(LOWORD(lp), HIWORD(lp));
            InvalidateRect(handle, nullptr, TRUE);
            return 0;
        case WM_LBUTTONDOWN: {
            const POINT at{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
            if (PtInRect(&state->plot, at)) {
                state->viewport.cursor = sample_at_pixel(state->plot, state->viewport, at.x);
                if (state->session.describe_cursor) state->update_run_panel();
                InvalidateRect(handle, &state->plot, FALSE);
            }
            return 0;
        }
        case WM_COMMAND:
            state->command(handle, LOWORD(wp), HIWORD(wp));
            InvalidateRect(handle, &state->plot, FALSE);
            return 0;
        case WM_PAINT: {
            PAINTSTRUCT paint{};
            const auto dc = BeginPaint(handle, &paint);
            if (dc && state->plot.right > state->plot.left) {
                try {
                    paint_waveform(dc, state->plot, state->viewport);
                    ++state->completed_paints;
                }
                catch (...) { EndPaint(handle, &paint); throw; }
            }
            EndPaint(handle, &paint);
            return 0;
        }
        case WM_DESTROY:
            state->closed = true;
            PostQuitMessage(0);
            return 0;
        default:
            break;
        }
    } catch (const std::exception& error) {
        try { state->failure = widen(error.what()); }
        catch (...) { state->failure = L"Debug operation failed."; }
        if (state->location) SetWindowTextW(state->location, state->failure.c_str());
        return message == WM_CREATE ? -1 : 0;
    }
    return DefWindowProcW(handle, message, wp, lp);
}

HWND create_debug_window(Window& state) {
    WNDCLASSW kind{};
    kind.lpfnWndProc = on_message;
    kind.hInstance = GetModuleHandleW(nullptr);
    kind.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
    kind.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    kind.lpszClassName = window_class;
    if (!RegisterClassW(&kind) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
        throw std::runtime_error("cannot register the native debug window");
    const auto handle = CreateWindowExW(0, window_class, L"Q3AFormal Debug", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 1150, 730, nullptr, nullptr, kind.hInstance, &state);
    if (!handle) throw std::runtime_error("cannot create the native debug window");
    return handle;
}

} // namespace

WaveViewport read_verified_viewport(const bundle::VerifiedDebugSession& session,
    std::uint64_t first, std::uint64_t last, std::uint64_t cursor,
    const std::vector<std::string>& selected) {
    return bundle::read_native_wave_viewport(session, first, last, cursor, selected);
}

int run_native_debug(const bundle::VerifiedDebugSession& session, const std::filesystem::path& test_path) {
    Window state(session);
    state.test_path = test_path;
    const auto handle = create_debug_window(state);
    if (!test_path.empty()) {
        const auto highlighted = SendMessageW(state.source, EM_LINEFROMCHAR, static_cast<WPARAM>(-1), 0);
        if (highlighted < 0 || static_cast<std::uint64_t>(highlighted) + 1 != session.view.assertion.line) {
            DestroyWindow(handle);
            throw std::runtime_error("the initial source selection does not identify the assertion line");
        }
        const auto first_visible = SendMessageW(state.source, EM_GETFIRSTVISIBLELINE, 0, 0);
        RECT source_bounds{};
        GetClientRect(state.source, &source_bounds);
        const auto source_dc = GetDC(state.source);
        if (!source_dc) {
            DestroyWindow(handle);
            throw std::runtime_error("cannot inspect the native source panel");
        }
        const auto old_font = SelectObject(source_dc, reinterpret_cast<HGDIOBJ>(SendMessageW(state.source, WM_GETFONT, 0, 0)));
        TEXTMETRICW metrics{};
        const bool metrics_available = GetTextMetricsW(source_dc, &metrics) != FALSE;
        if (old_font) SelectObject(source_dc, old_font);
        ReleaseDC(state.source, source_dc);
        if (!metrics_available || first_visible < 0 || first_visible > highlighted || metrics.tmHeight == 0 ||
            highlighted - first_visible >= source_bounds.bottom / metrics.tmHeight) {
            DestroyWindow(handle);
            throw std::runtime_error("the assertion source line is outside the visible source panel");
        }
        const auto cursor_visible = [&] {
            return !session.describe_cursor || control_text(state.run).find(
                widen(session.describe_cursor(state.viewport.cursor))) == 0;
        };
        const bool initial_cursor = cursor_visible();
        const auto initially_uncached = state.uncached_windows;
        const auto moved_cursor = (state.viewport.cursor + 1) % session.frame_count;
        state.read(state.viewport.first, moved_cursor);
        const bool cached = state.uncached_windows == initially_uncached && state.viewport.cursor == moved_cursor && cursor_visible();
        const auto before = state.viewport.first;
        SendMessageW(handle, WM_COMMAND, Previous, 0);
        const bool previous = before == 0 || state.viewport.first < before;
        SendMessageW(handle, WM_COMMAND, Witness, 0);
        const bool witness = state.viewport.cursor == session.candidate_frame && cursor_visible();
        SendMessageW(handle, WM_COMMAND, ZoomIn, 0);
        const bool zoom = state.viewport.last - state.viewport.first < 32;
        const auto signal = std::find_if(session.view.signals.begin(), session.view.signals.end(),
            [](const auto& entry) { return entry.location.line > 0 && !entry.location.file.empty(); });
        bool source = false;
        if (signal != session.view.signals.end()) {
            SendMessageW(state.signals, LB_SETCURSEL, signal - session.view.signals.begin(), 0);
            SendMessageW(handle, WM_COMMAND, MAKEWPARAM(SignalList, LBN_SELCHANGE), 0);
            wchar_t title[256]{};
            GetWindowTextW(state.location, title, 256);
            source = title[0] != L'\0';
        }

        bool restored = false, reverse = false;
        if (source && !test_path.empty()) {
            SendMessageW(handle, WM_COMMAND, ToggleMarker, 0);
            SetWindowTextW(state.group_name, L"Window signals");
            SendMessageW(handle, WM_COMMAND, SaveGroup, 0);
            const auto before_save = state.snapshot();
            SendMessageW(handle, WM_COMMAND, SaveSession, 0);
            SendMessageW(handle, WM_COMMAND, Previous, 0);
            SendMessageW(handle, WM_COMMAND, ZoomOut, 0);
            state.retained.markers.clear();
            state.retained.groups.clear();
            SendMessageW(handle, WM_COMMAND, OpenSession, 0);
            const auto after_load = state.snapshot();
            restored = before_save.frame == after_load.frame && before_save.first == after_load.first &&
                before_save.span == after_load.span && before_save.signals == after_load.signals &&
                before_save.markers.size() == 1 && before_save.markers == after_load.markers &&
                before_save.group == "Window signals" && before_save.group == after_load.group &&
                before_save.groups == after_load.groups &&
                state.viewport.markers == before_save.markers &&
                before_save.source.file == after_load.source.file && before_save.source.line == after_load.source.line;
            SendMessageW(state.signals, LB_SETCURSEL, static_cast<WPARAM>(-1), 0);
            SendMessageW(handle, WM_COMMAND, ShowSignal, 0);
            reverse = SendMessageW(state.signals, LB_GETCURSEL, 0, 0) >= 0;
        }

        const auto expected_group = state.selected;
        state.selected.clear();
        SetWindowTextW(state.group_name, L"Window signals");
        SendMessageW(handle, WM_COMMAND, UseGroup, 0);
        const bool group = state.selected == expected_group && !state.selected.empty();
        SetWindowTextW(state.search, L"__q3a_no_matching_signal__");
        const bool filtered = SendMessageW(state.signals, LB_GETCOUNT, 0, 0) == 0;
        SetWindowTextW(state.search, L"");
        const bool search = filtered &&
            SendMessageW(state.signals, LB_GETCOUNT, 0, 0) == static_cast<LRESULT>(session.view.signals.size());
        const auto original_radix = state.viewport.radix;
        SendMessageW(handle, WM_COMMAND, Radix, 0);
        const bool radix = original_radix != state.viewport.radix;
        bool change = session.frame_count == 1;
        for (std::size_t index = 0; index < session.view.signals.size(); ++index) {
            const auto& name = session.view.signals[index].name;
            const auto expected = session.find_transition(name, 0, true);
            if (!expected) continue;
            state.read(0, 0);
            SendMessageW(state.signals, LB_SETCURSEL, index, 0);
            SendMessageW(handle, WM_COMMAND, NextChange, 0);
            change = state.viewport.cursor == *expected;
            break;
        }

        DestroyWindow(handle);
        if (!initial_cursor || !cached || !previous || !witness || !zoom || !source || !restored || !reverse || !group || !search || !radix || !change || !state.closed || !state.failure.empty())
            throw std::runtime_error("native debug window smoke test failed");
        return 0;
    }
    ShowWindow(handle, SW_SHOW);
    UpdateWindow(handle);
    MSG incoming{};
    BOOL status;
    while ((status = GetMessageW(&incoming, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(handle, &incoming)) {
            TranslateMessage(&incoming);
            DispatchMessageW(&incoming);
        }
    }
    if (status < 0) DestroyWindow(handle);
    return status < 0 ? 1 : 0;
}

int capture_native_workload(const bundle::VerifiedDebugSession& session, const NativeCaptureRequest& request,
                            std::ostream& output) {
    const auto visible = request.show_window;
    if (request.span != 64 || session.view.selected.size() != 16 || request.viewports.empty())
        throw std::invalid_argument("invalid frozen GUI workload dimensions");
    Window state(session, request.span);
    std::unique_ptr<std::remove_pointer_t<HWND>, decltype(&DestroyWindow)> handle(create_debug_window(state), &DestroyWindow);
    const auto hwnd = handle.get();
    if (visible) ShowWindow(hwnd, SW_SHOW);

    const auto emit_viewport = [&](const std::chrono::steady_clock::time_point start, bool cache_hit) {
        if (!state.failure.empty() || state.closed ||
            visible_wave_lanes(state.plot, state.viewport) != session.view.selected.size()) {
            throw std::runtime_error("could not paint all selected workload lanes");
        }
        if (visible) {
            const auto paints = state.completed_paints;
            if (!InvalidateRect(hwnd, &state.plot, FALSE) || !UpdateWindow(hwnd) || !GdiFlush() ||
                state.completed_paints != paints + 1 || !IsWindowVisible(hwnd) || !state.failure.empty()) {
                throw std::runtime_error("visible viewport repaint did not finish");
            }
        } else {
            const auto dc = CreateCompatibleDC(nullptr);
            if (!dc) throw std::runtime_error("cannot create the workload GDI surface");
            std::unique_ptr<std::remove_pointer_t<HDC>, decltype(&DeleteDC)> dc_owner(dc, &DeleteDC);
            std::unique_ptr<std::remove_pointer_t<HBITMAP>, decltype(&DeleteObject)> bitmap(
                CreateBitmap(state.plot.right, state.plot.bottom, 1, 32, nullptr), &DeleteObject);
            if (!bitmap) throw std::runtime_error("cannot create the workload GDI bitmap");
            const auto previous = SelectObject(dc, bitmap.get());
            if (!previous || previous == HGDI_ERROR) throw std::runtime_error("cannot select workload bitmap");
            try { paint_waveform(dc, state.plot, state.viewport); }
            catch (...) { SelectObject(dc, previous); throw; }
            SelectObject(dc, previous);
        }

        output << "{\"frame\":" << state.viewport.cursor << ",\"first\":" << state.viewport.first
               << ",\"last\":" << state.viewport.last << ",\"access\":\""
               << (cache_hit ? "adjacent_cached" : "cold") << '"';
        if (visible) {
            const auto elapsed = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start).count();
            output << ",\"elapsed_ms\":" << std::setprecision(9) << elapsed;
        }
        output << ",\"values\":[";
        for (std::size_t i = 0; i < state.viewport.signals.size(); ++i) {
            const auto& samples = state.viewport.signals[i].changes;
            const auto active = std::find_if(samples.rbegin(), samples.rend(),
                [&](const auto& sample) { return sample.frame <= state.viewport.cursor; });
            if (active == samples.rend()) throw std::runtime_error("viewport lacks the cursor sample");
            if (i != 0) output << ',';
            output << "\"0x" << std::hex << active->value << std::dec << '"';
        }
        output << "]}";
    };

    output << "{\"initial_viewport\":";
    emit_viewport(request.started, false);
    output << ",\"viewports\":[";
    bool first_view = true;
    for (const auto& [first, frame] : request.viewports) {
        const auto from = visible ? std::chrono::steady_clock::now() : request.started;
        const auto reads = state.uncached_windows;
        state.read(first, frame);
        if (state.viewport.first != first || frame < first || frame > state.viewport.last)
            throw std::invalid_argument("workload requested a clamped or offscreen sample");
        if (!first_view) output << ',';
        first_view = false;
        emit_viewport(from, reads == state.uncached_windows);
    }
    output << "],\"signal_count\":" << session.view.signals.size() << ",\"source_cross_probe\":";
    const bool source_backed = session.view.sources.count(session.view.assertion.file) != 0;
    if (source_backed) {
        const auto found = std::find_if(session.view.signals.begin(), session.view.signals.end(),
            [&](const auto& signal) { return signal.location.line > 0 &&
                session.view.sources.count(signal.location.file) != 0; });
        if (found == session.view.signals.end())
            throw std::runtime_error("workload has no source-mapped signal");
        const auto row = static_cast<WPARAM>(found - session.view.signals.begin());
        SendMessageW(state.signals, LB_SETCURSEL, row, 0);
        SendMessageW(hwnd, WM_COMMAND, MAKEWPARAM(SignalList, LBN_SELCHANGE), 0);
        if (state.active_source.file != found->location.file || state.active_source.line != found->location.line)
            throw std::runtime_error("workload signal cross-probe selected a different source line");
        SendMessageW(state.signals, LB_SETCURSEL, static_cast<WPARAM>(-1), 0);
        SendMessageW(hwnd, WM_COMMAND, ShowSignal, 0);
        if (SendMessageW(state.signals, LB_GETCURSEL, 0, 0) < 0)
            throw std::runtime_error("workload source cross-probe did not select a signal");
        SendMessageW(hwnd, WM_COMMAND, Witness, 0);
        if (state.active_source.file != session.view.assertion.file ||
            state.active_source.line != session.view.assertion.line)
            throw std::runtime_error("workload could not restore the assertion location");

        state.test_path = request.session_output;
        const auto before = state.snapshot();
        SendMessageW(hwnd, WM_COMMAND, SaveSession, 0);
        state.read(before.first.value(), (before.frame + 1) % session.frame_count);
        SendMessageW(hwnd, WM_COMMAND, OpenSession, 0);
        const auto restored = state.snapshot();
        if (!state.failure.empty() || before.frame != restored.frame || before.first != restored.first ||
            before.span != restored.span || before.signals != restored.signals)
            throw std::runtime_error("workload session restore round trip did not match");
        const auto& location = session.view.assertion;
        std::istringstream source_text(session.view.sources.at(location.file));
        std::string line;
        for (std::size_t i = 0; i < location.line && std::getline(source_text, line); ++i) {}
        const auto declaration = std::string("p_hold: assert property");
        if (line.find(declaration) == std::string::npos)
            throw std::runtime_error("workload assertion text did not match the verified source line");
        const auto position = location.file + ':' + std::to_string(location.line) + ':' + std::to_string(location.column);
        output << "true,\"session_restore\":true,\"assertion\":{\"location\":" << std::quoted(position)
               << ",\"text\":" << std::quoted(declaration) << '}';
    } else {
        output << "false,\"session_restore\":false";
    }
    output << ",\"mode\":\"" << (visible ? "VISIBLE_WIN32_WORKSPACE" : "OFFSCREEN_UNTIMED") << "\"}\n";
    return 0;
}

} // namespace q3a::debug

