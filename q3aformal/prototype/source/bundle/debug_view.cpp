#include "debug_view.hpp"

#include <iomanip>
#include <ostream>
#include <stdexcept>

namespace q3a::bundle {
namespace {

void write_string(std::ostream& out, const std::string& value) {
    out << '"';
    for (auto byte : value) {
        const auto ch = static_cast<unsigned char>(byte);
        if (ch == '\\' || ch == '"') {
            out << '\\' << byte;
        } else if (ch < 32 || ch == '<' || ch == '>' || ch == '&') {
            out << "\\u00" << std::hex << std::setw(2) << std::setfill('0')
                << static_cast<unsigned>(ch) << std::dec << std::setfill(' ');
        } else {
            out << byte;
        }
    }
    out << '"';
}

void write_strings(std::ostream& out, const std::vector<std::string>& values) {
    out << '[';
    for (std::size_t i = 0; i < values.size(); ++i) {
        if (i) out << ',';
        write_string(out, values[i]);
    }
    out << ']';
}

void write_map(std::ostream& out, const std::map<std::string, std::string>& entries) {
    out << '{';
    bool first = true;
    for (const auto& entry : entries) {
        if (!first) out << ',';
        first = false;
        write_string(out, entry.first);
        out << ':';
        write_string(out, entry.second);
    }
    out << '}';
}

void write_location(std::ostream& out, const frontend::SourceLocation& location) {
    out << "{\"file\":";
    write_string(out, location.file);
    out << ",\"line\":" << location.line << ",\"column\":" << location.column << '}';
}

} // namespace

void write_debug_page(std::ostream& out, const DebugView& view) {
    out << R"Q3A(<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Q3AFormal Debug</title>
<style>
:root{font:15px/1.5 system-ui,sans-serif;color:#172534;background:#edf1f5;--line:#ccd6df;--accent:#185b8e}
*{box-sizing:border-box}body{margin:0}header{display:flex;align-items:center;justify-content:space-between;gap:1rem;flex-wrap:wrap;padding:.75rem 1.25rem;background:#152838;color:#fff}
h1{font-size:1.15rem;margin:0}h2{font-size:1rem;margin:0 0 .65rem;color:#173b56}main{display:grid;grid-template-columns:minmax(15rem,22rem) minmax(0,1fr);gap:.85rem;margin:.85rem}
section{background:white;border:1px solid var(--line);border-radius:.65rem;padding:.85rem;min-width:0}
#signalList,#sourceRows,#waveContainer,pre{overflow:auto}#signalList,#sourceRows{max-height:24rem}
dt{font-weight:650}dd{margin:0 0 .26rem;overflow-wrap:anywhere}.tools{display:flex;align-items:center;gap:.45rem;flex-wrap:wrap;margin:.4rem 0}
button,input,select{font:inherit;max-width:100%}button,select,input{padding:.28rem .45rem;border:1px solid #9daebb;border-radius:.35rem;color:inherit;background:white}
button{cursor:pointer}button:hover{border-color:var(--accent)}button:focus-visible{outline:2px solid #367bbb;outline-offset:1px}
[role=status]{color:#496075;min-height:1.35em}.signal{display:flex;align-items:center;gap:.45rem;border-bottom:1px solid #ecf0f3}.signal button{border:none;text-align:left;overflow-wrap:anywhere}
code,pre,#sourceRows button{font:13px/1.55 ui-monospace,Consolas,monospace}#sourceRows button{display:block;text-align:left;border:0;width:100%;white-space:pre}
#sourceRows .active{background:#e5f2ff;border-left:3px solid var(--accent)}#waveContainer{margin-top:.35rem;border:1px solid var(--line);border-radius:.35rem}
svg{display:block;min-width:100%;font:12px ui-monospace,monospace}.wave{fill:none;stroke:#23648b;stroke-width:2}.cursor{stroke:#19578a}.witness{stroke:#a64b25;stroke-dasharray:4 3}.marker{stroke:#6b3789;stroke-dasharray:2 2}.grid{stroke:#e0e7ed}
#attach{max-width:14rem}@media(max-width:800px){main{grid-template-columns:minmax(0,1fr)}}
</style></head><body>
<header><h1>Q3AFormal Debug</h1><div><button id="save">Save session</button> <label>Load session <input id="restore" type="file" accept=".json"></label></div></header>
<main>
<section aria-labelledby="runHeading"><h2 id="runHeading">Run and property</h2><dl id="run"></dl><button id="assertion">Go to property source</button>
<details><summary>Verification log</summary><pre id="log"></pre></details></section>
<section aria-labelledby="waveHeading"><h2 id="waveHeading">Waveform</h2><div class="tools">
<button id="previous" aria-label="Previous window">←</button><button id="next" aria-label="Next window">→</button>
<button id="previousChange">Previous change</button><button id="nextChange">Next change</button>
<button id="jump">Witness frame</button><label>Frame <input id="frame" type="number" min="0"></label>
<label>Zoom (frames) <select id="span"><option>16</option><option selected>32</option><option>64</option></select></label>
<label>Radix <select id="radix"><option>Hex</option><option>Binary</option><option>Unsigned</option></select></label>
</div><div class="tools"><button id="addMarker">Mark cursor</button>
<label>Marker <select id="marker"></select></label><button id="goMarker">Go to marker</button>
<button id="removeMarker">Remove marker</button></div>
<label>Attach indexed trace <input id="attach" type="file" accept=".q3atrace"></label>
<button id="indexChanges" disabled>Index changes</button><span id="indexStatus" role="status"></span>
<div id="waveStatus" role="status"></div><div id="waveContainer"><svg id="wave" aria-label="Digital waveform"></svg></div></section>
<section aria-labelledby="signalHeading"><h2 id="signalHeading">Hierarchy and signals</h2><input id="search" type="search" aria-label="Search signals" placeholder="Search signals">
<label>Group <select id="group"><option value="">All signals</option></select></label>
<div id="signalStatus" role="status"></div><div id="signalList"></div></section>
<section aria-labelledby="sourceHeading"><h2 id="sourceHeading">RTL and assertion source</h2>
<div id="sourceLocation" role="status"></div><div id="sourceRows"></div></section>
</main><script id="debug-data" type="application/json">)Q3A";
    out << "{\"run\":";
    write_map(out, view.run);
    out << ",\"sources\":";
    write_map(out, view.sources);
    out << ",\"assumptions\":";
    write_strings(out, view.assumptions);
    out << ",\"clocks\":";
    write_strings(out, view.clocks);
    out << ",\"selected\":";
    write_strings(out, view.selected);
    out << ",\"resets\":";
    write_map(out, view.resets);
    out << ",\"groups\":{";
    bool first_group = true;
    for (const auto& group : view.groups) {
        if (!first_group) out << ',';
        first_group = false;
        write_string(out, group.first);
        out << ':';
        write_strings(out, group.second);
    }
    out << '}';
    out << ",\"assertion\":";
    write_location(out, view.assertion);
    out << ",\"signals\":[";
    for (std::size_t i = 0; i < view.signals.size(); ++i) {
        if (i) out << ',';
        const auto& signal = view.signals[i];
        out << "{\"name\":";
        write_string(out, signal.name);
        out << ",\"role\":";
        write_string(out, signal.role);
        out << ",\"width\":" << signal.width << ",\"source\":";
        write_location(out, signal.location);
        out << '}';
    }
    out << "],\"indexedBytes\":" << view.indexed_bytes << ",\"log\":";
    write_string(out, view.verification_log);
    out << ",\"initial\":";
    for (char ch : view.initial_window) {
        if (ch == '<') out << "\\u003c";
        else if (ch == '>') out << "\\u003e";
        else if (ch == '&') out << "\\u0026";
        else out << ch;
    }
    out << "}</script>\n";
    out <<
#include "debug_page_script.inc"
    ;
    if (!out) throw std::runtime_error("cannot write debug view");
}

} // namespace q3a::bundle
