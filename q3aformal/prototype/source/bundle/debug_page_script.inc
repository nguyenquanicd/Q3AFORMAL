R"Q3A(<script>
'use strict';
const d = JSON.parse(document.getElementById('debug-data').textContent);
const el = id => document.getElementById(id);
const byName = new Map(d.signals.map((s, id) => [s.name, {...s, id}]));
const key = 'q3a-debug:' + d.run.Bundle + ':' + d.run.Obligation;
const candidate = d.initial.candidate_frame, count = d.initial.frame_count;
const initialSeries = new Map(d.initial.signals.map(s => [s.name, s]));
const limit = 16, blockSize = 256;
const resetNames = Object.keys(d.resets);
const spans = ['16', '32', '64'];
const markerLimit = 128, sessionMaxBytes = 4 * 1024 * 1024;
const defaultGroups = new Map(Object.entries(d.groups).map(([name, members]) => [name, new Set(members)]));
let groups = defaultGroups;
let selected = new Set(d.selected), frame = candidate, source = d.assertion;
let viewportStart = null, renderedSpan = Number(el('span').value), markers = new Set();
const seriesCacheLimit = 96;
const changeIndexLimit = 1024;
let backgroundIndex = null;
let attached = null, renderRevision = 0, attachmentRevision = 0, sessionRevision = 0;

function append(parent, tag, text) {
    const item = document.createElement(tag);
    item.textContent = text;
    parent.append(item);
    return item;
}
for (const [label, value] of Object.entries(d.run)) {
    append(el('run'), 'dt', label);
    append(el('run'), 'dd', value);
}
append(el('run'), 'dt', 'Assumptions');
append(el('run'), 'dd', d.assumptions.join(', ') || 'None');
append(el('run'), 'dt', 'Sampling clocks');
append(el('run'), 'dd', d.clocks.join(', ') || 'None');
el('log').textContent = d.log;
el('frame').max = count - 1;
function renderGroups(current) {
    const picker = el('group');
    picker.replaceChildren();
    append(picker, 'option', 'All signals').value = '';
    for (const name of groups.keys()) append(picker, 'option', name).value = name;
    picker.value = groups.has(current) ? current : '';
}
renderGroups('');

function renderMarkers(current) {
    const picker = el('marker');
    picker.replaceChildren();
    append(picker, 'option', markers.size ? 'Select a marker' : 'No markers').value = '';
    for (const at of [...markers].sort((a, b) => a - b)) {
        append(picker, 'option', 'Frame ' + at).value = String(at);
    }
    picker.value = markers.has(current) ? String(current) : '';
    el('goMarker').disabled = el('removeMarker').disabled = picker.value === '';
    el('addMarker').disabled = markers.has(frame) || markers.size >= markerLimit;
}
renderMarkers();

function showSource(location) {
    source = location;
    const content = Object.hasOwn(d.sources, location.file) ? d.sources[location.file] : null;
    el('sourceLocation').textContent = location.file
        ? location.file + ':' + location.line + ':' + location.column
        : 'No source mapping for this signal.';
    el('sourceRows').replaceChildren();
    if (content === null) {
        append(el('sourceRows'), 'p', 'Source text is unavailable.');
        return;
    }
    const lines = content.split(/\r?\n/);
    for (let i = Math.max(1, location.line - 15); i <= Math.min(lines.length, location.line + 15); ++i) {
        const row = append(el('sourceRows'), 'button', String(i).padStart(4) + '  ' + lines[i - 1]);
        row.classList.toggle('active', i === location.line);
        row.onclick = () => {
            const hit = d.signals.find(s => s.source.file === location.file && s.source.line === i);
            if (hit && (selected.has(hit.name) || selected.size < limit)) {
                selected.add(hit.name);
                el('group').value = '';
                el('search').value = hit.name;
                renderSignals();
            }
            showSource({file:location.file, line:i, column:1});
            refresh();
        };
    }
}

function renderSignals() {
    const filter = el('search').value.trim().toLowerCase();
    const group = groups.get(el('group').value);
    const matches = d.signals.filter(s => (!group || group.has(s.name)) && s.name.toLowerCase().includes(filter));
    el('signalStatus').textContent = selected.size + ' selected · ' + matches.length + ' matching';
    if (matches.length > 250) el('signalStatus').textContent += ' · filter to view more';
    el('signalList').replaceChildren();
    for (const signal of matches.slice(0, 250)) {
        const row = append(el('signalList'), 'div', '');
        row.className = 'signal';
        const check = append(row, 'input', '');
        check.type = 'checkbox';
        check.setAttribute('aria-label', 'Show ' + signal.name);
        check.checked = selected.has(signal.name);
        check.onchange = () => {
            if (check.checked && selected.size >= limit) {
                check.checked = false;
                el('signalStatus').textContent = 'Select up to ' + limit + ' waveform signals.';
                return;
            }
            if (check.checked) selected.add(signal.name);
            else selected.delete(signal.name);
            renderSignals();
            refresh();
        };
        const name = append(row, 'button', signal.name + ' [' + signal.width + ']');
        name.onclick = () => showSource(signal.source);
    }
}

async function read(file, offset, size) {
    if (!Number.isSafeInteger(offset) || offset < 0 || size < 0 || offset + size > file.size) {
        throw new Error('Trace record is outside the file.');
    }
    return new DataView(await file.slice(offset, offset + size).arrayBuffer());
}
function u64(view, position) {
    const value = Number(view.getBigUint64(position, true));
    if (!Number.isSafeInteger(value)) throw new Error('Invalid trace offset.');
    return value;
}

async function openIndex(file) {
    if (file.size !== d.indexedBytes) throw new Error('Trace size differs from the bundle.');
    const head = await read(file, 0, 32);
    const decoder = new TextDecoder('utf-8', {fatal:true});
    if (decoder.decode(new Uint8Array(head.buffer, 0, 8)) !== 'Q3ATRC1\n' ||
        u64(head, 8) !== count || u64(head, 16) !== candidate ||
        head.getUint32(24, true) !== d.signals.length ||
        head.getUint32(28, true) !== d.initial.property.length) {
        throw new Error('Trace header differs from the bundle.');
    }
    const nameBytes = d.initial.property.length + d.signals.reduce((n,s) => n + s.name.length + 8, 0);
    const names = await read(file, 32, nameBytes);
    let offset = 0;
    const takeName = length => {
        const name = decoder.decode(new Uint8Array(names.buffer, offset, length));
        offset += length;
        return name;
    };
    if (takeName(d.initial.property.length) !== d.initial.property) throw new Error('Wrong trace property.');
    for (const s of d.signals) {
        const length = names.getUint32(offset, true);
        offset += 4;
        if (length !== s.name.length || takeName(length) !== s.name ||
            names.getUint32(offset, true) !== s.width) throw new Error('Wrong signal dictionary.');
        offset += 4;
    }
    const entries = Math.ceil(count / blockSize) + 1;
    const footer = file.size - entries * 8;
    const table = await read(file, footer, entries * 8);
    const blocks = Array.from({length:entries}, (_,i) => u64(table, i * 8));
    const minimum = 8 * (d.signals.length + 1) + 12 * d.signals.length;
    if (blocks[0] !== 32 + nameBytes || blocks.at(-1) !== footer ||
        blocks.some((v,i) => i > 0 && (v - blocks[i - 1] < minimum || v > footer))) {
        throw new Error('Invalid trace block table.');
    }
    return {file, blocks, seriesCache: new Map(), changeIndex: new Map()};
}

async function readSeries(index, s, first, last, cancelled, retainBlocks = true) {
    const changes = [];
    let lastValue = null;
    const push = (at, value) => {
        if (lastValue === value) return;
        lastValue = value;
        changes.push([at, '0x' + value.toString(16)]);
    };
    for (let block = Math.floor(first / blockSize); block <= Math.floor(last / blockSize); ++block) {
        if (cancelled()) return null;
        const base = block * blockSize;
        const frames = Math.min(blockSize, count - base);
        const key = block * d.signals.length + s.id;
        const cache = index.seriesCache;
        const cached = cache.get(key);
        let series = cached;
        if (!series) {
            const start = index.blocks[block];
            const table = index.blocks[block + 1] - (d.signals.length + 1) * 8;
            const pair = await read(index.file, table + s.id * 8, 16);
            if (cancelled()) return null;
            const begin = u64(pair, 0), end = u64(pair, 8), length = end - begin;
            if (end > table - start || length <= 0 || length % 12 || length > frames * 12) {
                throw new Error('Invalid trace signal offsets.');
            }
            series = await read(index.file, start + begin, length);
            if (cancelled()) return null;
        }
        const windowStart = Math.max(first, base);
        let prior = -1, value = 0n, started = false;
        for (let at = 0; at < series.byteLength; at += 12) {
            const sample = series.getUint32(at, true), next = series.getBigUint64(at + 4, true);
            if ((at === 0 && sample !== 0) || sample <= prior || sample >= frames ||
                next >> BigInt(s.width)) throw new Error('Invalid trace value record.');
            prior = sample;
            const absolute = base + sample;
            if (absolute > windowStart && !started) { push(windowStart, value); started = true; }
            value = next;
            if (absolute > windowStart && absolute <= last) push(absolute, value);
        }
        if (!started) push(windowStart, value);
        if (retainBlocks) {
            if (cached) cache.delete(key);
            cache.set(key, series);
            if (cache.size > seriesCacheLimit) cache.delete(cache.keys().next().value);
        }
    }
    return {...s, changes};
}

function valueAt(series, at) {
    let value;
    for (const [sample, next] of series.changes) {
        if (sample > at) break;
        value = next;
    }
    return value;
}
function displayed(value, width) {
    const n = BigInt(value);
    switch (el('radix').value) {
    case 'Binary': return '0b' + n.toString(2).padStart(width, '0');
    case 'Unsigned': return n.toString(10);
    default: return value;
    }
}

function draw(series, resets, first, last) {
    const svg = el('wave'), step = 896 / renderedSpan, left = 280, top = 26, lane = 33;
    const x = sample => left + (sample - first) * step;
    const height = top + lane * series.length + 12, width = x(last + 1) + 6;
    svg.replaceChildren();
    svg.setAttribute('width', width);
    svg.setAttribute('height', height);
    const element = (tag, attrs, text) => {
        const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
        for (const [attr, value] of Object.entries(attrs)) node.setAttribute(attr, value);
        if (text !== undefined) node.textContent = text;
        svg.append(node);
        return node;
    };
    if (d.clocks.length) element('text', {x:8,y:16}, 'Sampling edge at each frame');
    for (const reset of resets) {
        const asserted = d.resets[reset.name] === 'high' ? '0x1' : '0x0';
        const boundaries = [[first, valueAt(reset, first)],
            ...reset.changes.filter(([sample]) => sample > first && sample <= last)];
        boundaries.forEach(([sample, value], i) => {
            if (value !== asserted) return;
            const end = boundaries[i + 1]?.[0] ?? last + 1;
            const band = element('rect', {x:x(sample), y:20, width:x(end)-x(sample),
                height:height-20, class:'reset', fill:'#efc77f', opacity:0.34});
            const title = document.createElementNS('http://www.w3.org/2000/svg', 'title');
            title.textContent = reset.name + ' asserted at frames ' + sample + '–' + (end-1);
            band.append(title);
        });
    }
    for (let sample = first; sample <= last; sample++) {
        element('line', {x1:x(sample),x2:x(sample),y1:20,y2:height,class:'grid'});
        if ((sample - first) % 4 === 0) element('text', {x:x(sample),y:16}, sample);
    }
    series.forEach((s,i) => {
        const y = top + lane * i;
        const label = element('text', {x:8,y:y+14}, s.name.length > 34 ? '…' + s.name.slice(-33) : s.name);
        label.onclick = () => showSource(byName.get(s.name).source);
        const current = valueAt(s, frame);
        if (current !== undefined) element('text', {x:8,y:y+29}, displayed(current, s.width));
        const samples = [[first, valueAt(s, first)], ...s.changes.filter(([at]) => at > first && at <= last)];
        samples.forEach(([at,value], j) => {
            if (value === undefined) return;
            const end = samples[j+1]?.[0] ?? last+1;
            const high = y + (value === '0x0' ? 23 : 6);
            if (s.width === 1) {
                const level = j === 0 ? high : y + (samples[j-1][1] === '0x0' ? 23 : 6);
                element('path', {d:'M '+x(at)+' '+level+' V '+high+' H '+x(end),class:'wave'});
            } else {
                element('rect', {x:x(at),y:y+4,width:x(end)-x(at),height:22,fill:'#e5f2ff',stroke:'#23648b'});
                if (x(end)-x(at) >= 54) element('text', {x:x(at)+4,y:y+19}, displayed(value,s.width));
            }
        });
    });
    if (candidate >= first && candidate <= last) {
        element('line', {x1:x(candidate),x2:x(candidate),y1:20,y2:height,class:'witness'});
    }
    for (const at of markers) {
        if (at < first || at > last) continue;
        const line = element('line', {x1:x(at)+2,x2:x(at)+2,y1:20,y2:height,class:'marker'});
        const title = document.createElementNS('http://www.w3.org/2000/svg', 'title');
        title.textContent = 'Marker at frame ' + at;
        line.append(title);
    }
    if (frame >= first && frame <= last) {
        element('line', {x1:x(frame),x2:x(frame),y1:20,y2:height,class:'cursor'});
    }
    svg.onclick = event => {
        const point = svg.createSVGPoint();
        point.x = event.clientX; point.y = event.clientY;
        const at = point.matrixTransform(svg.getScreenCTM().inverse()).x;
        frame = Math.max(first, Math.min(last, Math.floor((at-left)/step) + first));
        viewportStart = first;
        refresh();
    };
}

function windowStart(span) {
    return Math.min(Math.max(0, viewportStart ?? frame - Math.floor(span / 2)), Math.max(0, count - span));
}

function moveCursor(at) {
    frame = at;
    viewportStart = null;
    return refresh();
}

async function refresh() {
    stopIndexing('Indexing stopped for waveform navigation.');
    updateIndexButton();
    const revision = ++renderRevision;
    const cancelled = () => revision !== renderRevision;
    const span = renderedSpan = Number(el('span').value);
    frame = Math.max(0, Math.min(count-1, Math.trunc(frame)));
    el('frame').value = frame;
    el('addMarker').disabled = markers.has(frame) || markers.size >= markerLimit;
    const first = windowStart(span);
    const last = Math.min(count-1, first+span-1);
    const names = [...new Set([...selected, ...resetNames])];
    const inInitial = first >= d.initial.first && last <= d.initial.last &&
        names.every(name => initialSeries.has(name));
    try {
        let series;
        if (inInitial) {
            series = names.map(name => initialSeries.get(name));
        } else if (attached) {
            el('waveStatus').textContent = 'Reading selected waveform blocks…';
            const index = attached;
            series = await Promise.all(names.map(name => readSeries(index, byName.get(name), first, last, cancelled)));
        } else {
            el('wave').replaceChildren();
            el('waveStatus').textContent = 'Attach ' + d.run.Trace + ' to inspect this signal or frame range.';
            return;
        }
        if (revision !== renderRevision) return;
        draw(series.filter(s => selected.has(s.name)),
             series.filter(s => Object.hasOwn(d.resets, s.name)),first,last);
        el('waveStatus').textContent = 'Frames ' + first + '–' + last +
            (inInitial ? ' · verified snapshot' : ' · attached trace preview');
    } catch (error) {
        if (revision === renderRevision) {
            el('wave').replaceChildren();
            el('waveStatus').textContent = error.message;
        }
    }
}

function nearestChange(series, direction, from) {
    let hit = null;
    for (const signal of series) {
        for (const [sample] of signal.changes.slice(1)) {
            if ((sample - from) * direction <= 0) continue;
            if (hit === null || (sample - hit) * direction < 0) hit = sample;
        }
    }
    return hit;
}
async function indexChanges(index, signal, block, cancelled, previousValues = null) {
    const key = block * d.signals.length + signal.id;
    const cached = index.changeIndex.get(key);
    if (cached) {
        index.changeIndex.delete(key);
        index.changeIndex.set(key, cached);
        // A bitmap has no terminal value. The next uncached block must
        // recover its preceding sample if it follows a cached block.
        previousValues?.delete(signal.id);
        return cached;
    }

    const base = block * blockSize;
    const previous = previousValues?.get(signal.id);
    const first = previous === undefined ? Math.max(0, base - 1) : base;
    const series = await readSeries(index, signal, first,
        Math.min(count - 1, base + blockSize - 1), cancelled, previousValues === null);
    if (cancelled()) return null;
    const words = new Uint32Array(blockSize / 32);
    if (previous !== undefined && series.changes[0][1] !== previous) words[0] = 1;
    previousValues?.set(signal.id, series.changes.at(-1)[1]);
    for (const [sample] of series.changes.slice(1)) {
        const offset = sample - base;
        words[offset >>> 5] |= 1 << (offset & 31);
    }
    index.changeIndex.set(key, words);
    if (index.changeIndex.size > changeIndexLimit) {
        index.changeIndex.delete(index.changeIndex.keys().next().value);
    }
    return words;
}

function nearestIndexedChange(bitmaps, direction, from, base) {
    const offset = direction > 0 ? Math.max(0, from - base + 1)
        : Math.min(blockSize - 1, from - base - 1);
    if (offset < 0 || offset >= blockSize) return null;
    const firstWord = offset >>> 5;
    for (let word = firstWord; word >= 0 && word < blockSize / 32; word += direction) {
        let bits = 0;
        for (const bitmap of bitmaps) bits |= bitmap[word];
        if (word === firstWord) {
            const bit = offset & 31;
            bits &= direction > 0 ? -1 << bit : 0xffffffff >>> (31 - bit);
        }
        if (bits !== 0) {
            const nearest = direction > 0 ? bits & -bits : bits;
            return base + word * 32 + 31 - Math.clz32(nearest);
        }
    }
    return null;
}

async function jumpChange(direction) {
    stopIndexing('Indexing stopped for waveform navigation.');
    const revision = ++renderRevision;
    const cancelled = () => revision !== renderRevision;
    const from = frame, names = [...selected], index = attached;
    const start = from + direction;
    if (!names.length || start < 0 || start >= count) {
        el('waveStatus').textContent = names.length ? 'No further change.' : 'Select a waveform signal first.';
        return;
    }
    const within = from >= d.initial.first && from <= d.initial.last &&
        names.every(name => initialSeries.has(name));
    if (within) {
        const hit = nearestChange(names.map(name => initialSeries.get(name)), direction, from);
        if (hit !== null) return moveCursor(hit);
    }
    if (!index) {
        el('waveStatus').textContent = 'No further change in the verified snapshot. Attach the trace to search more frames.';
        return;
    }
    el('waveStatus').textContent = 'Searching selected waveform blocks…';
    try {
        const lastBlock = Math.floor((count - 1) / blockSize);
        for (let block = Math.floor(start / blockSize); block >= 0 && block <= lastBlock; block += direction) {
            const bitmaps = await Promise.all(names.map(name => indexChanges(index, byName.get(name), block, cancelled)));
            if (revision !== renderRevision) return;
            const hit = nearestIndexedChange(bitmaps, direction, from, block * blockSize);
            if (hit !== null) return moveCursor(hit);
        }
        el('waveStatus').textContent = 'No further change in the attached trace.';
    } catch (error) {
        if (revision === renderRevision) el('waveStatus').textContent = error.message;
    }
}

function updateIndexButton() {
    const button = el('indexChanges');
    button.disabled = !backgroundIndex && (!attached || !selected.size);
    button.textContent = backgroundIndex ? 'Stop indexing' : 'Index changes';
}

function stopIndexing(message) {
    if (!backgroundIndex) return;
    backgroundIndex = null;
    el('indexStatus').textContent = message;
    updateIndexButton();
}

el('indexChanges').onclick = async () => {
    if (backgroundIndex) {
        stopIndexing('Indexing stopped.');
        return;
    }
    if (!attached || !selected.size) return;
    const index = attached;
    const signals = [...selected].map(name => byName.get(name));
    const blocks = index.blocks.length - 1;
    if (blocks * signals.length > changeIndexLimit) {
        el('indexStatus').textContent = 'Selection exceeds the change index capacity.';
        return;
    }
    const job = {previousValues: new Map()};
    backgroundIndex = job;
    const cancelled = () => backgroundIndex !== job;
    const total = blocks + ' blocks for ' + signals.length + ' signals';
    el('indexStatus').textContent = 'Indexing 0 of ' + total + '�';
    updateIndexButton();
    try {
        for (let block = 0; block < blocks; ++block) {
            await new Promise(resolve => setTimeout(resolve, 0));
            if (cancelled()) return;
            await Promise.all(signals.map(signal => indexChanges(index, signal, block, cancelled, job.previousValues)));
            if (cancelled()) return;
            el('indexStatus').textContent = 'Indexed ' + (block + 1) + ' of ' + total + '�';
        }
        stopIndexing('Indexed ' + total + '.');
    } catch (error) {
        if (!cancelled()) stopIndexing('Indexing failed: ' + error.message);
    }
};

el('attach').onchange = async () => {
    const revision = ++attachmentRevision;
    ++renderRevision;
    attached = null;
    stopIndexing('');
    el('indexStatus').textContent = '';
    updateIndexButton();
    try {
        const file = el('attach').files[0];
        const index = file ? await openIndex(file) : null;
        if (revision !== attachmentRevision) return;
        attached = index;
        return refresh();
    } catch (error) {
        if (revision !== attachmentRevision) return;
        ++renderRevision;
        el('wave').replaceChildren();
        el('waveStatus').textContent = error.message;
    }
};
el('assertion').onclick = () => showSource(d.assertion);
el('jump').onclick = () => moveCursor(candidate);
function pan(direction) {
    viewportStart = windowStart(renderedSpan) + direction * renderedSpan;
    viewportStart = windowStart(renderedSpan);
    return refresh();
}
el('previous').onclick = () => pan(-1);
el('next').onclick = () => pan(1);
el('previousChange').onclick = () => jumpChange(-1);
el('nextChange').onclick = () => jumpChange(1);
el('span').onchange = () => {
    if (viewportStart !== null) {
        viewportStart = windowStart(renderedSpan) + Math.floor((renderedSpan - Number(el('span').value)) / 2);
        viewportStart = windowStart(Number(el('span').value));
    }
    return refresh();
};
el('radix').onchange = refresh;
el('search').oninput = renderSignals;
el('group').onchange = renderSignals;
el('frame').onchange = () => moveCursor(Number(el('frame').value) || 0);
el('marker').onchange = () => renderMarkers(el('marker').value === '' ? null : Number(el('marker').value));
el('addMarker').onclick = () => {
    if (markers.size >= markerLimit) return;
    markers.add(frame);
    renderMarkers(frame);
    return refresh();
};
el('goMarker').onclick = () => {
    if (el('marker').value !== '') return moveCursor(Number(el('marker').value));
};
el('removeMarker').onclick = () => {
    if (el('marker').value === '') return;
    markers.delete(Number(el('marker').value));
    renderMarkers();
    return refresh();
};
el('save').onclick = () => {
    const data = {schema:2,key,trace:d.run.Trace,frame,signals:[...selected],span:el('span').value,
        viewportStart,radix:el('radix').value,group:el('group').value,
        groups:[...groups].map(([name, members]) => [name, [...members]]),markers:[...markers],source};
    const blob = new Blob([JSON.stringify(data)], {type:'application/json'});
    if (blob.size > sessionMaxBytes) {
        el('waveStatus').textContent = 'Session is too large to save.';
        return;
    }
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a'); anchor.href=url; anchor.download='q3a-debug-session.json'; anchor.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
};
function validFrame(value) {
    return Number.isSafeInteger(value) && value >= 0 && value < count;
}

function sessionGroups(entries) {
    if (!Array.isArray(entries)) throw new Error('Invalid session groups.');
    const restored = new Map();
    for (const entry of entries) {
        if (!Array.isArray(entry) || entry.length !== 2) throw new Error('Invalid session group.');
        const [name, members] = entry;
        if (typeof name !== 'string' || !name || name.length > 80 || restored.has(name) ||
            !Array.isArray(members) || members.length > byName.size ||
            !members.every(member => byName.has(member)) || new Set(members).size !== members.length) {
            throw new Error('Invalid session group.');
        }
        restored.set(name, new Set(members));
    }
    return restored;
}

el('restore').onchange = async () => {
    const revision = ++sessionRevision;
    try {
        const file = el('restore').files[0];
        if (!file) return;
        if (file.size > sessionMaxBytes) throw new Error('Session file is too large.');
        const saved = JSON.parse(await file.text());
        if (revision !== sessionRevision) return;
        if (!saved || ![1, 2].includes(saved.schema) || saved.key !== key || !Array.isArray(saved.signals) ||
            saved.signals.length > limit || !saved.signals.every(name => byName.has(name)) ||
            !validFrame(saved.frame) || !spans.includes(saved.span) ||
            !['Hex','Binary','Unsigned'].includes(saved.radix)) throw new Error('Invalid session for this bundle.');
        let restoredGroups = defaultGroups, restoredMarkers = [], restoredStart = null;
        if (saved.schema === 2) {
            if (saved.trace !== d.run.Trace || !Array.isArray(saved.markers) || saved.markers.length > markerLimit ||
                !saved.markers.every(validFrame) || new Set(saved.markers).size !== saved.markers.length ||
                (saved.viewportStart !== null && (!validFrame(saved.viewportStart) ||
                    saved.viewportStart > Math.max(0, count - Number(saved.span))))) {
                throw new Error('Invalid session trace, viewport, or markers.');
            }
            restoredGroups = sessionGroups(saved.groups);
            restoredMarkers = saved.markers;
            restoredStart = saved.viewportStart;
        }
        frame=saved.frame; selected=new Set(saved.signals);
        markers=new Set(restoredMarkers); viewportStart=restoredStart; groups=restoredGroups;
        el('span').value=saved.span; el('radix').value=saved.radix;
        renderGroups(saved.group); renderMarkers();
        const loc=saved.source;
        showSource(loc && typeof loc.file === 'string' && Object.hasOwn(d.sources,loc.file) &&
            Number.isSafeInteger(loc.line) && loc.line > 0 &&
            Number.isSafeInteger(loc.column) && loc.column > 0 ? loc : d.assertion);
        renderSignals(); return refresh();
    } catch (error) {
        if (revision === sessionRevision) el('waveStatus').textContent=error.message;
    }
};
showSource(source); renderSignals(); refresh();
</script></body></html>
)Q3A"
