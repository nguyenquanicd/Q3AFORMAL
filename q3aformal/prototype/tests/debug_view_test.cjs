'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

class Element {
    children = [];
    attributes = {};
    files = [];
    value = '';
    textContent = '';
    classList = { toggle() {} };

    append(child) { this.children.push(child); }
    replaceChildren() { this.children = []; }
    setAttribute(name, value) { this.attributes[name] = value; }
    click() { this.onclick?.(); }
}

async function main() {
    const [, , pagePath, indexPath] = process.argv;
    const page = fs.readFileSync(pagePath, 'utf8');
    const encoded = page.match(/<script id="debug-data" type="application\/json">([\s\S]*?)<\/script>/)[1];
    const data = JSON.parse(encoded);
    assert.match(Object.values(data.sources)[0], /<\/script><b>/);
    assert.doesNotMatch(encoded, /<\/script><b>/);
    assert.equal(data.initial.frame_count, 801);
    assert.equal(data.run.Result, 'BOUNDED_FAIL');

    const body = page.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
    const nodes = new Map();
    const get = id => {
        if (!nodes.has(id)) nodes.set(id, new Element());
        return nodes.get(id);
    };
    get('debug-data').textContent = encoded;
    get('span').value = '32';
    get('radix').value = 'Hex';
    const document = {
        getElementById: get,
        createElement: () => new Element(),
        createElementNS: () => new Element()
    };
    let savedBlob;
    const url = {createObjectURL(blob) { savedBlob = blob; return 'blob:test'; }, revokeObjectURL() {}};
    let holdIndexYield = false;
    const indexYields = [];
    vm.runInNewContext(body, {document, Blob, TextDecoder, URL:url,
        setTimeout(callback, delay) {
            if (delay !== 0) return;
            if (holdIndexYield) indexYields.push(callback);
            else setImmediate(callback);
        }});
    assert.equal(get('indexChanges').disabled, true);
    assert.match(get('waveStatus').textContent, /verified snapshot/);
    assert.equal(get('frame').value, data.initial.candidate_frame);
    assert.ok(get('wave').children.length > 0);
    assert.match(get('sourceLocation').textContent, /fixture.sv:.*:/);

    assert.deepEqual(data.resets, {a:'low'});
    assert.deepEqual(data.groups['APB control'], ['a']);
    assert.ok(get('wave').children.some(node => node.attributes.class === 'reset' &&
        node.children[0].textContent.startsWith('a asserted at frames ')));
    get('group').value = 'APB control';
    get('group').onchange();
    assert.equal(get('signalList').children.length, 1);
    const a = get('signalList').children.find(row => row.children[1].textContent === 'a [1]');
    a.children[1].click();
    const source = data.signals.find(signal => signal.name === 'a').source;
    assert.equal(get('sourceLocation').textContent, source.file + ':' + source.line + ':' + source.column);
    const row = get('sourceRows').children.find(item => item.textContent.startsWith(String(source.line).padStart(4)));
    row.click();
    assert.equal(get('search').value, 'a');
    assert.equal(get('group').value, '');
    get('search').value = 'clk';
    get('search').oninput();
    const clk = get('signalList').children[0].children[0];
    clk.checked = false;
    clk.onchange();

    get('frame').value = '260';
    get('frame').onchange();
    assert.match(get('waveStatus').textContent, /Attach/);
    const file = new Blob([fs.readFileSync(indexPath)]);
    let bytes = 0;
    let holdReads = false;
    const pendingReads = [];
    get('attach').files = [{
        size:file.size,
        slice(first,last) {
            bytes += last - first;
            const slice = file.slice(first,last);
            if (!holdReads) return slice;
            assert.equal(last - first, 16, 'only offset pairs should be pending');
            return {arrayBuffer: () => new Promise(resolve => {
                pendingReads.push(async () => resolve(await slice.arrayBuffer()));
            })};
        }
    }];
    await get('attach').onchange();
    for (let i = 0; i < 100 && !get('waveStatus').textContent.includes('attached trace preview'); ++i) {
        await new Promise(resolve => setImmediate(resolve));
    }
    assert.match(get('waveStatus').textContent, /Frames 244–275 · attached trace preview/);
    assert.ok(bytes > 0 && bytes < file.size, 'indexed viewing should read a subset of the file');
    assert.ok(get('wave').children.length > 0);

    async function checkSupersededRead(startOldRead) {
        holdReads = true;
        const stale = startOldRead();
        assert.ok(pendingReads.length > 0);
        holdReads = false;
        get('frame').value = '500';
        await get('frame').onchange();
        const currentBytes = bytes;
        await Promise.all(pendingReads.splice(0).map(release => release()));
        await stale;
        assert.equal(bytes, currentBytes, 'a superseded request must not start payload reads');
        assert.equal(get('frame').value, 500);
        assert.match(get('waveStatus').textContent, /Frames 484–515 · attached trace preview/);
    }
    await checkSupersededRead(() => {
        get('frame').value = '780';
        return get('frame').onchange();
    });
    const bytesBeforeWarmRead = bytes;
    get('frame').value = '501';
    await get('frame').onchange();
    assert.equal(bytes, bytesBeforeWarmRead, 'overlapping windows should reuse validated blocks');
    assert.match(get('waveStatus').textContent, /Frames 485–516 · attached trace preview/);
    await get('attach').onchange();
    await checkSupersededRead(() => get('previousChange').onclick());

    const indexButton = get('indexChanges');
    assert.equal(indexButton.disabled, false);
    const idleBytes = bytes;
    const stopped = indexButton.onclick();
    assert.equal(indexButton.textContent, 'Stop indexing');
    await indexButton.onclick();
    await stopped;
    assert.equal(bytes, idleBytes, 'stopping during the yield must not start any reads');
    assert.match(get('indexStatus').textContent, /^Indexing stopped\.$/);

    holdReads = true;
    const interrupted = indexButton.onclick();
    for (let i = 0; i < 100 && pendingReads.length === 0; ++i) {
        await new Promise(resolve => setImmediate(resolve));
    }
    assert.ok(pendingReads.length > 0, 'the background index should have a suspended file read');
    holdReads = false;
    get('frame').value = '501';
    await get('frame').onchange();
    const bytesAfterNavigation = bytes;
    await Promise.all(pendingReads.splice(0).map(release => release()));
    await interrupted;
    assert.equal(bytes, bytesAfterNavigation, 'cancelled indexing must not start payload reads');
    assert.match(get('indexStatus').textContent, /stopped for waveform navigation/);
    assert.match(get('waveStatus').textContent, /Frames 485–516 · attached trace preview/);

    holdIndexYield = true;
    const partial = indexButton.onclick();
    assert.equal(indexYields.length, 1);
    indexYields.shift()();
    for (let i = 0; i < 100 && indexYields.length === 0; ++i) {
        await new Promise(resolve => setImmediate(resolve));
    }
    assert.equal(indexYields.length, 1, 'the second block must yield to foreground work');
    assert.match(get('indexStatus').textContent, /^Indexed 1 of 4 blocks/);
    await indexButton.onclick();
    indexYields.shift()();
    await partial;
    holdIndexYield = false;

    await indexButton.onclick();
    assert.match(get('indexStatus').textContent, /^Indexed 4 blocks for [1-9] signals\.$/);
    assert.equal(indexButton.textContent, 'Index changes');
    assert.equal(get('frame').value, 501, 'background indexing must preserve the cursor');
    const indexedBytes = bytes;
    await get('nextChange').onclick();
    assert.equal(get('frame').value, 502);
    assert.equal(bytes, indexedBytes, 'a warm change search must preserve the viewport cache');
    get('frame').value = '255';
    await get('frame').onchange();
    await get('nextChange').onclick();
    assert.equal(get('frame').value, 256, 'a resumed index must recover the preceding sample after a cached block');
    const detachedJob = indexButton.onclick();
    await get('attach').onchange();
    await detachedJob;
    assert.equal(get('indexStatus').textContent, '', 'reattachment clears old progress');

    get('frame').value = '255';
    get('frame').onchange();
    await get('nextChange').onclick();
    assert.equal(get('frame').value, 256);
    await get('previousChange').onclick();
    assert.equal(get('frame').value, 255);
    get('search').value = 'a';
    get('search').oninput();
    const toggleA = checked => {
        const toggle = get('signalList').children.find(item => item.children[1].textContent === 'a [1]').children[0];
        toggle.checked = checked;
        toggle.onchange();
    };
    toggleA(false);
    await get('nextChange').onclick();
    assert.equal(get('frame').value, 255);
    assert.match(get('waveStatus').textContent, /No further change in the attached trace/);
    toggleA(true);
    get('frame').value = '260';
    await get('frame').onchange();
    get('group').value = 'CSR data';
    get('group').onchange();
    await get('addMarker').onclick();
    assert.equal(get('marker').value, '260');
    assert.ok(get('wave').children.some(node => node.attributes.class === 'marker' &&
        node.children[0].textContent === 'Marker at frame 260'));
    await get('next').onclick();
    assert.equal(get('frame').value, 260, 'panning must preserve the cursor');
    assert.match(get('waveStatus').textContent, /Frames 276–307/);
    assert.ok(!get('wave').children.some(node => node.attributes.class === 'cursor'));
    get('span').value = '16';
    await get('span').onchange();
    assert.match(get('waveStatus').textContent, /Frames 284–299/);
    get('save').click();
    const saved = JSON.parse(await savedBlob.text());
    assert.equal(saved.schema, 2);
    assert.equal(saved.frame, 260);
    assert.equal(saved.viewportStart, 284);
    assert.equal(saved.trace, data.run.Trace);
    assert.deepEqual(saved.markers, [260]);
    assert.deepEqual(saved.groups.find(([name]) => name === 'CSR data'), ['CSR data', ['data_bus']]);
    await get('removeMarker').onclick();
    assert.equal(get('marker').value, '');
    get('jump').click();
    assert.equal(get('frame').value, data.initial.candidate_frame);
    get('restore').files = [savedBlob];
    await get('restore').onchange();
    assert.equal(get('frame').value, 260);
    assert.equal(get('group').value, 'CSR data');
    assert.match(get('waveStatus').textContent, /Frames 284–299/);
    get('marker').value = '260';
    await get('goMarker').onclick();
    assert.match(get('waveStatus').textContent, /Frames 252–267/);
    assert.ok(get('wave').children.some(node => node.attributes.class === 'marker'));
    await get('removeMarker').onclick();
    assert.ok(!get('wave').children.some(node => node.attributes.class === 'marker'));

    const restore = async value => {
        get('restore').files = [new Blob([JSON.stringify(value)])];
        await get('restore').onchange();
    };
    await restore({...saved, groups:[['Session-only group', ['a']]], group:'Session-only group'});
    assert.equal(get('group').value, 'Session-only group');
    assert.ok(get('group').children.some(option => option.value === 'Session-only group'));
    await restore({schema:1,key:saved.key,frame:260,signals:saved.signals,span:'32',
        radix:saved.radix,group:'CSR data',source:saved.source});
    assert.equal(get('group').value, 'CSR data');
    assert.match(get('waveStatus').textContent, /Frames 244–275/);
    assert.equal(get('marker').children.length, 1, 'schema 1 starts without markers');
    for (const bad of [
        {...saved,trace:'other.q3atrace'},
        {...saved,viewportStart:800},
        {...saved,markers:[260,260]},
        {...saved,markers:[801]},
        {...saved,groups:[['Bad', ['unknown']]]}
    ]) {
        await restore(bad);
        assert.match(get('waveStatus').textContent, /Invalid session/);
        assert.equal(get('frame').value, 260);
        assert.equal(get('group').value, 'CSR data');
    }
    get('restore').files = [new Blob([JSON.stringify({...saved,key:'another bundle'})])];
    await get('restore').onchange();
    assert.match(get('waveStatus').textContent, /Invalid session/);
    console.log('PASS: cross-probing, indexed navigation, bounded-cache reuse, superseded reads, background indexing and cancellation, zoom and pan, markers, v1 migration, v2 session round-trip, and invalid session rejection.');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
