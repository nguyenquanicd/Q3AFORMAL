'use strict';

const fs = require('node:fs');
const vm = require('node:vm');
const {performance} = require('node:perf_hooks');

async function run() {
    const [, , htmlPath, tracePath, signal, expected] = process.argv;
    const workload = signal === '--workload' ? JSON.parse(fs.readFileSync(expected, 'utf8')) : null;
    const html = fs.readFileSync(htmlPath, 'utf8');
    const payload = html.match(/<script id="debug-data" type="application\/json">([\s\S]*?)<\/script>/)[1];
    const script = html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
    const data = JSON.parse(payload);
    const elements = new Map();
    const node = () => ({
        children:[], attrs:{}, value:'', textContent:'', classList:{toggle(){}},
        append(value){this.children.push(value)}, replaceChildren(){this.children=[]},
        setAttribute(name, value){this.attrs[name] = value}
    });
    const document = {
        getElementById(id) {
            if (!elements.has(id)) elements.set(id, node());
            return elements.get(id);
        },
        createElement:node, createElementNS:node
    };
    const get = document.getElementById;
    get('debug-data').textContent = payload;
    get('span').value = '32';
    get('radix').value = 'Hex';
    const context = vm.createContext({document, Blob, TextDecoder, setTimeout, signals:workload?.signals ?? [signal]});
    const start = performance.now();
    vm.runInContext(script, context);
    const initial_ms = performance.now() - start;
    vm.runInContext(`{
        const render = refresh;
        refresh = () => globalThis.pendingRefresh = render();
    }`, context);
    if (!get('waveStatus').textContent.includes('verified snapshot')) throw new Error('Initial snapshot did not render');
    if (workload?.assertion &&
        (get('sourceLocation').textContent !== workload.assertion.location ||
        !get('sourceRows').children.some(node => node.textContent.includes(workload.assertion.text)) ||
        !get('wave').children.some(node => node.attrs.class === 'witness'))) {
        throw new Error('The initial witness or property source was not displayed');
    }
    const file = await fs.promises.open(tracePath, 'r');
    try {
        const {size} = await file.stat();
        let bytesRead = 0, reads = 0;
        get('attach').files = [{size, slice(first, last) {
            return {async arrayBuffer() {
                const buffer = new ArrayBuffer(last - first);
                const view = new Uint8Array(buffer);
                let offset = 0;
                ++reads;
                while (offset < view.length) {
                    const result = await file.read(view, offset, view.length - offset, first + offset);
                    if (result.bytesRead === 0) throw new Error('Unexpected end of trace file');
                    offset += result.bytesRead;
                    bytesRead += result.bytesRead;
                }
                return buffer;
            }};
        }}];
        const attachStart = performance.now();
        await get('attach').onchange();
        await context.pendingRefresh;
        const attach_ms = performance.now() - attachStart;
        const attach_bytes = bytesRead, attach_ranges = reads;
        if (data.initial.frame_count < 33) throw new Error('Benchmark requires a viewport outside the snapshot');
        const destination = data.initial.first === 0 ? data.initial.frame_count - 1 : 0;
        const steps = workload?.steps ?? [{frame:destination, values:expected === undefined ? undefined : [expected]}];
        const span = workload?.span ?? 32;
        if (![16, 32, 64].includes(span) || !steps.length ||
            context.signals.length < 1 || context.signals.length > 16 ||
            new Set(context.signals).size !== context.signals.length ||
            !context.signals.every(name => data.signals.some(s => s.name === name))) {
            throw new Error('Invalid viewport measurement workload');
        }
        get('span').value = String(span);
        vm.runInContext('selected = new Set(signals)', context);
        const viewports = [];
        for (const {frame, values, resetActive, direction, noChange, background} of steps) {
            if (!Number.isInteger(frame) || frame < 0 || frame >= data.initial.frame_count ||
                (values !== undefined && values.length !== context.signals.length) ||
                (direction !== undefined && !['next', 'previous'].includes(direction)) ||
                (noChange && direction === undefined) || (background && direction !== undefined)) {
                throw new Error('Invalid viewport measurement step');
            }
            bytesRead = 0;
            reads = 0;
            const from = get('frame').value;
            const navStart = performance.now();
            if (background) {
                await get('indexChanges').onclick();
                if (!/^Indexed \d+ blocks for \d+ signals\.$/.test(get('indexStatus').textContent)) {
                    throw new Error('Background indexing did not complete');
                }
            } else if (direction) {
                await get(direction === 'next' ? 'nextChange' : 'previousChange').onclick();
            } else {
                get('frame').value = String(frame);
                await get('frame').onchange();
            }
            const viewport_ms = performance.now() - navStart;
            const status = get('waveStatus').textContent;
            const expectedStatus = noChange ? 'No further change in the attached trace' : 'attached trace preview';
            if (!status.includes(expectedStatus) || get('frame').value !== frame ||
                bytesRead >= size || (viewports.length === 0 && bytesRead <= 0)) {
                throw new Error('Indexed navigation did not render a selectively read viewport');
            }
            if (values !== undefined) {
                const labels = get('wave').children.filter(node => node.attrs.x === 8);
                for (const [i, name] of context.signals.entries()) {
                    const title = name.length > 34 ? 'â€¦' + name.slice(-33) : name;
                    const label = labels.find(node => node.textContent === title);
                    if (!label || !labels.some(node => node.attrs.y === label.attrs.y + 15 &&
                        node.textContent === values[i])) {
                        throw new Error('Wrong waveform value for ' + name + ' at frame ' + frame);
                    }
                }
            }
            if (resetActive !== undefined) {
                const shaded = get('wave').children.some(node => {
                    if (node.attrs.class !== 'reset') return false;
                    const prefix = workload.resetSignal + ' asserted at frames ';
                    const text = node.children[0].textContent;
                    if (!text.startsWith(prefix)) return false;
                    const band = text.slice(prefix.length).match(/^(\d+)–(\d+)$/);
                    return band && frame >= Number(band[1]) && frame <= Number(band[2]);
                });
                if (shaded !== resetActive) throw new Error('Wrong reset annotation at frame ' + frame);
            }
            viewports.push({destination:frame, viewport_ms, viewport_bytes:bytesRead, viewport_ranges:reads, status,
                ...(resetActive === undefined ? {} : {reset_active:resetActive}),
                ...(direction === undefined ? {} : {direction, from, no_change: !!noChange}),
                ...(background ? {background_index:true, index_status:get('indexStatus').textContent} : {})});
        }
        const searchIndex = steps.some(step => step.direction)
            ? vm.runInContext(`{
                const entries = [...(attached?.changeIndex?.values() ?? [])];
                ({change_index_entries:entries.length,
                  change_index_payload_bytes:entries.reduce((total, bitmap) => total + bitmap.byteLength, 0)})
            }`, context) : {};
        console.log(JSON.stringify({
            method:'Node VM with simulated DOM and file-backed range reads; no browser layout or isolated disk latency',
            node:process.version, trace_frames:data.initial.frame_count, trace_signals:data.signals.length,
            indexed_bytes:size, initial_ms, attach_ms, attach_bytes, attach_ranges,
            peak_process_rss_bytes:process.resourceUsage().maxRSS * 1024,
            ...searchIndex,
            ...(workload ? {signals:context.signals, span, viewports} : {signal, expected_value:expected, ...viewports[0]})
        }, null, 2));
    } finally {
        await file.close();
    }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
